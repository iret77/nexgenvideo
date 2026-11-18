"""Measure only the three failed Build 123 runtime paths on the retained signed app."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
import zipfile

from bpy_open_diagnostic import read_regular, stop_owned
from release_acceptance_identity import digest, gui_tools, require
from retained_packaging import collect_source
from reuse_bpy_binary_evidence import api, download, instant
from verify_diagnostic_candidate import verify_signed_bpy

SOURCE = "22c81c1d13e2d99c9320adb457a17b8cabb2b4cf"
REF = "iret77/rc-delivery-base-795"
BRANCH = "iret77/rc-app123-diagnostic-1190"
RUN = 44324570507
ID = 14443479233
ARCHIVE = "4eacfe5620c925e391cf2a1935ee9548cbe7aa2e866de9df7f7bc7cb5932bee5"
TREE = "651c50fb28cce3c7417864364547a914925459e8af209879a0e4cefb6cf8236b"
IMAGE = "b55b8ca4633ed767c615c81868e010eeb8d3e0ae0f3a78548eac3be9abe64a55"
DWARF = "5ffdba2ccee9e39bc221b2b409d70791f3232c5d05797df8a8d01428b591f622"
UUID = "3D6DF417-F27C-31C3-94D5-F7DCAEA09C6A"
PATHS = {".github/workflows/diagnostic-acceptance.yml",
         "scripts/app123_runtime_diagnostic.py", "scripts/fixtures/app-cohort.json"}
FAILURES = {
    "diagnostic-acceptance": (
        134937235316, 14454848302, "diagnostic-runtime-acceptance",
        "eaa005929d31599fc4c14c10761807ccddc6663cef3a9095626bf1047e7aacf1",
        ["Verify signed production capture and exact symbolization"]),
    "bpy-runtime / runtime": (
        134937236124, 14446677200, f"managed-bpy-runtime-evidence-{SOURCE}",
        "b3235398754eb1d55f2c707fc94541115c2a56db9ed5130e617ab2fbdf845213",
        ["Run real bpy acceptance without ambient Blender or Python",
         "Prove both sandbox boundary slots using an explicitly derived fixture"]),
}


def save(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def git(*args):
    return subprocess.check_output(["git", *args], stdin=subprocess.DEVNULL, text=True, timeout=20).strip()


def context():
    expected = {"candidate_kind": "app123-runtime-diagnostic", "run_id": str(RUN),
                "source_sha": SOURCE, "artifact_id": str(ID), "artifact_sha256": ARCHIVE}
    defaults = {"interface_scale": "1", "journey_scenario": "journey"}
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_bytes())
    values = event["inputs"]
    require(os.environ["GITHUB_ACTIONS"] == "true" and os.environ["GITHUB_REPOSITORY"] == "iret77/nexgenvideo"
            and os.environ["GITHUB_ACTOR"] == "iret77" and os.environ["GITHUB_RUN_ATTEMPT"] == "1"
            and os.environ["GITHUB_REF_NAME"] == BRANCH and os.environ["GITHUB_EVENT_NAME"] == "workflow_dispatch",
            "Unexpected diagnostic execution")
    require(all(values.get(k) == v for k, v in expected.items())
            and all(not v or v == defaults.get(k) for k, v in values.items() if k not in expected),
            "The diagnostic accepts only its exact existing Build 123 selectors")
    head = git("rev-parse", "HEAD")
    changed = git("diff", "--no-renames", "--name-only", SOURCE, head).splitlines()
    require(head == os.environ["GITHUB_SHA"] and git("show", "-s", "--format=%P", "HEAD") == SOURCE
            and set(changed) == PATHS and not git("status", "--porcelain", "--untracked-files=no"),
            "The diagnostic must be one clean harness-only commit from the production source")
    return dict(runID=int(os.environ["GITHUB_RUN_ID"]), harnessSHA=head, actor="iret77",
                artifactID=ID, appSourceSHA=SOURCE, harnessFiles={name:digest(Path(name)) for name in sorted(PATHS)})


def producer():
    run = api(f"/actions/runs/{RUN}")
    jobs = api(f"/actions/runs/{RUN}/attempts/1/jobs?per_page=100")
    app = api(f"/actions/artifacts/{ID}")
    verify_signed_bpy(run, jobs, app, RUN, SOURCE, ID, ARCHIVE, sorted(PATHS), harness_paths=PATHS)
    require(run["actor"]["login"] == "iret77" and run["run_attempt"] == 1 and run["head_branch"] == REF
            and run["status"] == "completed" and run["conclusion"] == "failure",
            "Original release attempt changed")
    release, = [job for job in jobs["jobs"] if job["name"] == "release"]
    require(release["labels"] == ["macrunner"] and app["size_in_bytes"] == 1680147867,
            "Signed App producer or archive size changed")
    bound = {}
    for name, (job_id, artifact_id, artifact_name, checksum, failed_steps) in FAILURES.items():
        job, = [item for item in jobs["jobs"] if item["name"] == name]
        require((job["id"], job["run_id"], job["run_attempt"], job["head_sha"], job["labels"],
                 job["status"], job["conclusion"]) == (job_id, RUN, 1, SOURCE, ["macrunner"], "completed", "failure")
                and [s["name"] for s in job["steps"] if s["conclusion"] == "failure"] == failed_steps,
                "Original failure job or steps changed: " + name)
        item = api(f"/actions/artifacts/{artifact_id}")
        require(item["id"] == artifact_id and item["name"] == artifact_name and item["digest"] == "sha256:" + checksum
                and not item["expired"] and item["workflow_run"]["id"] == RUN and item["workflow_run"]["head_sha"] == SOURCE
                and instant(job["started_at"]) <= instant(item["created_at"]) <= instant(item["updated_at"])
                    <= instant(job["completed_at"])
                and instant(item["expires_at"]) > datetime.now(timezone.utc),
                "Original failed-job artifact changed: " + name)
        bound[name] = {"job": job, "artifact": item}
    return {"run": run, "app": app, "releaseJob": release, "failures": bound}


def bind(output):
    output.mkdir(parents=True, exist_ok=False)
    identity = context()
    product = producer()
    source, proof, log = collect_source(44294213062, SOURCE, REF)
    require(source["artifact"]["id"] == 14422188902
            and source["proofSHA256"] == "7a7f52a9b922dd0a71e602241abf4f043f2e3d6dd765ce04d158726c207039c1",
            "Original qualified source differs")
    (output / "source-proof.zip").write_bytes(proof)
    (output / "source-job.log").write_bytes(log)
    save(output / "identity.json", {"execution": identity, "producer": product, "source": source})


def child_environment(home):
    home.mkdir(parents=True, exist_ok=False)
    environment = {k: os.environ[k] for k in ("PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "RUNNER_TEMP",
        "GITHUB_ACTIONS", "GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA")
        if k in os.environ}
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home))
    return environment


def logged(argv, output, *, env=None, timeout=120):
    with output.open("xb") as stdout:
        subprocess.run([str(x) for x in argv], stdin=subprocess.DEVNULL,
                       stdout=stdout, stderr=subprocess.STDOUT, env=env, timeout=timeout, check=True)


def app_bytes(app):
    value = gui_tools().metadata(app, SOURCE)
    require(value["CFBundleVersion"] == "123" and value["CFBundleShortVersionString"] == "1.8.0"
            and value["treeSHA256"] == TREE and value["executableSHA256"] == IMAGE,
            "Restored App differs from the exact notarized original")
    return value


def restore(product, stage, evidence):
    archive = stage / "diagnostic.zip"
    download(product["app"], archive)
    members = ["diagnostic-app.zip", "diagnostic-symbols.zip", "bpy-source/bpy-source-receipt.json"]
    with zipfile.ZipFile(archive) as bundle:
        require(sorted(bundle.namelist()) == sorted(members), "Unexpected diagnostic archive members")
        for name in members:
            with bundle.open(name) as data, (stage / Path(name).name).open("xb") as output:
                shutil.copyfileobj(data, output, 1024 * 1024)
    for name in members[:2]:
        logged(["/usr/bin/ditto", "-x", "-k", stage / name, stage],
               evidence / (name + ".log"), timeout=180)
    app = stage / "NexGenVideo.app"
    symbols = stage / "diagnostic-symbols/NexGenVideo.dSYM/Contents/Resources/DWARF/NexGenVideo"
    require(digest(symbols) == DWARF, "Wrong original Build 123 dSYM")
    binary = app / "Contents/MacOS/NexGenVideo"
    for name, image in (("app", binary), ("symbols", symbols)):
        logged(["/usr/bin/xcrun", "dwarfdump", "--uuid", image], evidence / (name + "-uuid.log"))
        require(re.search(r"\b" + UUID + r" \(arm64\)", (evidence / (name + "-uuid.log")).read_text()),
                "App and dSYM UUID differ")
    logged(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app], evidence / "signature-before.log")
    logged(["/usr/bin/xcrun", "stapler", "validate", app], evidence / "staple-before.log")
    logged(["/usr/sbin/spctl", "-a", "-vvv", "-t", "exec", app], evidence / "gatekeeper.log")
    return app


def identify(process, executable):
    if process.poll() is not None:
        return None
    reply = subprocess.run(["/bin/ps", "-ww", "-p", str(process.pid), "-o", "pid=,ppid=,lstart=,comm="],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2)
    fields = reply.stdout.decode(errors="replace").strip().split(None, 7)
    if reply.returncode != 0 or len(fields) != 8 or fields[:2] != [str(process.pid), str(os.getpid())]:
        return None
    if Path(fields[-1]).resolve() != executable.resolve():
        return None
    return dict(pid=process.pid, ppid=os.getpid(), start=" ".join(fields[2:7]), executable=str(executable))


def sample(process, executable, initial, output, name, deadline, environment):
    record = {"name": name, "before": identify(process, executable), "didSample": False}
    if record["before"] != initial or initial is None or deadline - time.monotonic() < 3:
        return record
    sample_path = output / (name + ".sample.log")
    argv = ["/usr/bin/sample", str(process.pid), "1", "-file", str(sample_path)]
    with (output / (name + ".stdout.log")).open("xb") as stdout, (output / (name + ".stderr.log")).open("xb") as stderr:
        sampler = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, env=environment)
        record.update(didSample=True, argv=argv, samplerPID=sampler.pid, collectedAt=time.time())
        try:
            sampler.wait(timeout=max(0.1, min(7, deadline - time.monotonic() - 2)))
        except subprocess.TimeoutExpired:
            record["timedOut"] = True
            sampler.kill()
            sampler.wait(timeout=2)
        finally:
            if sampler.poll() is None:
                sampler.kill()
                sampler.wait(timeout=2)
            record.update(exitCode=sampler.returncode, reaped=sampler.poll() is not None)
    record["after"] = identify(process, executable)
    if sample_path.is_file() and not sample_path.is_symlink():
        record["rawSampleSHA256"] = digest(sample_path)
        record["rawSampleBytes"] = sample_path.stat().st_size
    return record


def remaining_group(pgid):
    data = subprocess.check_output(["/bin/ps", "-ww", "-axo", "pid=,pgid=,comm="],
                                   stdin=subprocess.DEVNULL, text=True, timeout=4)
    return [dict(pid=int(parts[0]), executable=parts[2])
            for line in data.splitlines() if len(parts := line.strip().split(None, 2)) == 3 and parts[1] == str(pgid)]


def reap_app(process):
    before = []
    try:
        before = remaining_group(process.pid)
    finally:
        if process.poll() is None or before:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)
    deadline = time.monotonic() + 4
    while (remaining := remaining_group(process.pid)) and time.monotonic() < deadline:
        time.sleep(0.1)
    return {"observedBeforeCleanup":before, "remaining":remaining}


def diagnostic(app, stage, output):
    import hang_diagnostic_acceptance as capture
    output.mkdir()
    environment = child_environment(stage / "diagnostic-home")
    root = Path(environment["HOME"]) / "Library/Logs/NexGenVideo/HangIncidents"
    key_root = stage / "private-replay"
    key_root.mkdir(mode=0o700)
    environment.update(NGV_HANG_SELFTEST="wait", NGV_HANG_SELFTEST_KEY=str(key_root / "replay.key"),
                       NGV_HANG_SELFTEST_EXPORT=str(key_root / "export"))
    binary = app / "Contents/MacOS/NexGenVideo"
    started = time.monotonic()
    deadline = started + 65
    log = (output / "capture-wait.log").open("xb")
    try:
        process = subprocess.Popen([str(binary)], stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, env=environment, start_new_session=True)
    finally:
        log.close()
    capture._capture_processes[process.pid] = "wait"
    records, initial, reason, timed_out = [], None, None, False
    try:
        initial = identify(process, binary)
        while process.poll() is None and time.monotonic() < deadline:
            elapsed = time.monotonic() - started
            if initial is None and elapsed < 5:
                initial = identify(process, binary)
            if not records:
                for path in root.parent.glob("NexGenVideo-*-main-thread-hang.json"):
                    try:
                        raw = read_regular(path, 1024 * 1024)
                        if json.loads(raw)["processID"] == process.pid:
                            (output / "watchdog-at-trigger.json").write_bytes(raw)
                            reason = "owned-watchdog"
                            records.append(sample(process, binary, initial, output, "early", deadline, environment))
                            break
                    except (FileNotFoundError, KeyError, ValueError):
                        continue
                if elapsed >= 15 and not records:
                    reason = "early-time-control"
                    records.append(sample(process, binary, initial, output, "early", deadline, environment))
            if elapsed >= 45 and len(records) == 1 and not (
                    records[0].get("rawSampleBytes") and records[0].get("exitCode") == 0):
                records.append(sample(process, binary, initial, output, "late", deadline, environment))
            time.sleep(min(0.15, max(0, deadline - time.monotonic())))
        timed_out = process.poll() is None
    finally:
        observed_seconds = time.monotonic() - started
        cleanup = reap_app(process)
        save(output / "wait-process.json", dict(identity=initial, hostPID=process.pid, exitCode=process.returncode,
             watchedSeconds=observed_seconds, timedOut=timed_out, reaped=process.poll() is not None,
             originalLimitSeconds=65, firstProbeTrigger=reason, samples=records, ownedGroupCleanup=cleanup))
        capture.retain_capture_recordings(root, set(), output, home=Path(environment["HOME"]))
        require(not cleanup["remaining"], "Diagnostic process group did not exit")
    sampled = any(x.get("didSample") for x in records)
    return {"observed": initial is not None and (sampled or not timed_out),
            "timeout": timed_out, "originalExitCode": process.returncode,
            "rawSampleAvailable":any(x.get("rawSampleBytes", 0) > 0 and x.get("exitCode") == 0 for x in records)}


def fixture_environment(stage, output):
    environment = child_environment(stage / "scene-home")
    denied = stage / "denied"
    approved = stage / "approved-input"
    fake = stage / "fake-bin"
    for directory in (denied / "foreign-project", approved, fake):
        directory.mkdir(parents=True)
    sentinel = Path(environment["HOME"]) / "ngv-bpy-host-home-secret"
    inputs = [(denied/"provider-secret", "provider-secret"), (denied/"canonical-artifact", "canonical-project-truth"),
              (denied/"foreign-project/scene.blend", "foreign-project"), (sentinel, "host-home-secret")]
    for path, content in inputs:
        path.write_text(content)
    (approved/"fixture.json").write_text('{"approved":true}')
    (approved/"symlink.json").symlink_to(inputs[0][0])
    (approved/"hardlink-source").write_text("hardlink")
    os.link(approved/"hardlink-source", approved/"hardlink.json")
    for name in ("python3", "blender"):
        path = fake/name
        path.write_text("#!/bin/sh\nexit 99\n")
        path.chmod(0o700)
    environment.update(PATH=str(fake), BLENDER_USER_CONFIG=str(denied/"foreign-blender"),
        PYTHONPATH=str(denied/"foreign-python"), NGV_TEST_SECRET="must-not-cross-xpc",
        NGV_BPY_DENIED_PATHS=json.dumps([str(path) for path, _ in inputs]),
        NGV_BPY_APPROVED_INPUT_DIR=str(approved), NGV_SELFTEST_BPY=str(output),
        NGV_BPY_CAPTURE_SANDBOX_LOGS="1")
    return environment


@contextmanager
def owned(argv, output, environment, *, privileged=False):
    with output.open("xb") as log:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        try:
            yield process
        finally:
            stop_owned(process, privileged)


def scene(app, stage, output, observer):
    output.mkdir()
    native = output / "native"
    snapshots = output / "ax"
    snapshots.mkdir()
    environment = fixture_environment(stage, native)
    deadline = time.time() + 1800
    argv = [sys.executable, "-I", "scripts/bpy_runtime_acceptance.py", str(app), "--mode", "runtime",
            "--source-sha", SOURCE, "--deadline", str(deadline), "--capture-open-logs", "--output", str(native)]
    done = output / "app-completed.json"
    progress = native / "spatial-scene-100.json"
    with owned(argv, output/"harness.log", environment) as process:
        while process.poll() is None and not progress.is_file() and time.time() < deadline + 45:
            time.sleep(0.1)
        if progress.is_file() and process.poll() is None:
            content = read_regular(progress, 4 * 1024 * 1024)
            (output / "observer-trigger.json").write_bytes(content)
            args = [str(observer), str(native/"process.json"), str(app/"Contents/MacOS/NexGenVideo"),
                    SOURCE, str(snapshots), str(done)]
            with owned(args, output/"ax-observer.log", environment) as ax:
                process.wait(timeout=max(1, deadline + 45 - time.time()))
                host = json.loads(read_regular(native/"process.json", 4096))
                save(done, {"pid":host["pid"], "sourceSHA":SOURCE})
                try:
                    ax.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    stop_owned(ax)
                save(output/"observer-process.json", dict(pid=ax.pid, exitCode=ax.returncode, reaped=ax.poll() is not None))
        else:
            process.wait(timeout=max(1, deadline + 45 - time.time()))
    observed = []
    completion = snapshots / "observer-completion.json"
    if progress.is_file() and completion.is_file():
        host = json.loads(read_regular(native / "process.json", 4096))
        pointer = [row for row in json.loads(read_regular(progress, 4 * 1024 * 1024))["interactions"]
                   if row.get("kind") == "pointer" and row.get("id") == "spatial.location.create"]
        if len(pointer) == 1:
            center = pointer[0]
            up = [row["postedUptime"] for row in center.get("nativeInput", {}).get("posted", [])
                  if row["type"] == 2 and not row.get("cleanup")]
            for path in sorted(snapshots.glob("ax-sample-*.json")):
                row = json.loads(read_regular(path, 2 * 1024 * 1024))
                if (len(up) == 1 and row.get("processAlive") and row["processIdentity"]["pid"] == host["pid"]
                        and row["AXWindowsStatus"] == 0 and row["windows"]
                        and row["startedUptime"] <= up[0] + 4 and row["completedUptime"] >= up[0] - 1
                        and any(window.get("kCGWindowNumber") == center["window"] for window in row["CGWindows"])):
                    observed.append(path.name)
    result = {"nativeExitCode":process.returncode, "wrapperPID":process.pid, "wrapperReaped":process.poll() is not None,
              "sceneReached":progress.is_file(), "axObservationComplete":bool(observed),
              "windowSampleFilesAtCreate":observed}
    save(output/"scene-process.json", result)
    return result


def boundary_fixture(app, output):
    from bpy_boundary_acceptance import run
    from bpy_runtime_acceptance import capture_open_logs
    output.mkdir()
    with capture_open_logs(output/"storage"):
        run(app, output/"native", SOURCE)


def boundary(app, stage, output):
    output.mkdir()
    environment = child_environment(stage/"boundary-home")
    fixture_stage = stage / "boundary-fixture"
    fixture_stage.mkdir()
    capture = fixture_stage / "capture"
    argv = [sys.executable, str(Path(__file__).resolve()), "boundary-fixture", "--app", str(app), "--output", str(capture)]
    trace_args = ["/usr/bin/sudo", "-n", "/usr/bin/fs_usage", "-w", "-f", "filesys", "-f", "pathname",
                  "-f", "exec", "-t", "150", "NexGenVideo", "NexGenVideoBpyService", "NexGenVideoBpySupervisor", "cat"]
    marker = fixture_stage / "ngv-boundary-trace-positive-control"
    marker.write_text("filesystem observer ready\n")
    with owned(trace_args, output/"filesystem-trace.log", environment, privileged=True) as trace:
        time.sleep(0.5)
        trace_started = trace.poll() is None
        with (output / "trace-control.log").open("xb") as control:
            pulse = subprocess.run(["/bin/cat", str(marker)], stdin=subprocess.DEVNULL, stdout=control,
                                   stderr=subprocess.STDOUT, env=environment, timeout=5)
        try:
            with owned(argv, output/"harness.log", environment) as process:
                process.wait(timeout=620)
                trace_early = trace.poll() is not None
        finally:
            if capture.is_dir() and not capture.is_symlink():
                capture.rename(output/"capture")
    storage_receipt = output/"capture/storage/open-capture.json"
    native_receipt = output/"capture/native/result.json"
    native = json.loads(native_receipt.read_bytes()) if native_receipt.is_file() else {}
    storage = json.loads(storage_receipt.read_bytes()) if storage_receipt.is_file() else {}
    positive = pulse.returncode == 0 and any(marker.name.encode() in row
        for row in (output / "filesystem-trace.log").open("rb"))
    result = {"nativeExitCode":process.returncode, "wrapperPID":process.pid, "wrapperReaped":process.poll() is not None,
              "traceStarted":trace_started, "traceExitCode":trace.returncode, "traceReaped":trace.poll() is not None,
              "filesystemPositiveControl":positive, "traceStoppedEarly":trace_early,
              "storageStreamReported":bool(storage),
              "observed":bool(trace_started and not trace_early and positive and storage.get("reaped")
                  and not storage.get("stoppedEarly") and not storage.get("cleanupErrors")
                  and native.get("processReaped") and native.get("originalUnchanged"))}
    save(output/"boundary-process.json", result)
    return result


def observe(binding_path, output):
    identity = context()
    require(platform.system() == "Darwin" and platform.machine() == "arm64"
            and platform.mac_ver()[0].split(".")[0] == "27", "Expected macrunner macOS 27 arm64")
    binding = json.loads(binding_path.read_bytes())
    require(binding["execution"] == identity and binding["producer"] == producer(),
            "The native job did not receive the bound original producer")
    require(binding["source"]["sourceSHA"] == SOURCE and binding["source"]["runID"] == 44294213062, "Missing source receipt")
    output.mkdir(parents=True, exist_ok=False)
    stage = Path(os.environ["RUNNER_TEMP"]).resolve() / "app123-signed-input"
    stage.mkdir()
    save(output/"identity.json", identity)
    logged(["/usr/bin/sw_vers"], output/"operating-system.log")
    app = restore(binding["producer"], stage, output)
    before = app_bytes(app)
    save(output/"app-before.json", before)
    observer = stage/"scene-observer"
    scoped = {}
    try:
        try:
            logged(["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    "scripts/scene_history_ax_observer.swift", "-o", observer],
                   output/"observer-compile.log", timeout=90)
        except (OSError, subprocess.SubprocessError) as error:
            scoped["observerTool"] = {"error": str(error)}
        for name, measure, extra in (("diagnostic", diagnostic, ()), ("scene", scene, (observer,)),
                                     ("boundary", boundary, ())):
            try:
                scoped[name] = measure(app, stage, output/name, *extra)
            except InterruptedError:
                raise
            except (OSError, subprocess.SubprocessError, RuntimeError, ValueError, AssertionError) as error:
                scoped[name] = {"measurementError": type(error).__name__, "detail": str(error)}
    finally:
        unchanged = app_bytes(app) == before
        logged(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app], output/"signature-after.log")
        logged(["/usr/bin/xcrun", "stapler", "validate", app], output/"staple-after.log")
        save(output/"outcome.json", dict(cases=scoped, appUnchanged=unchanged, measurementOnly=True, runtimeAccepted=False))
        require(unchanged, "Executed App differs from the retained signed original")
    require(scoped.get("diagnostic", {}).get("observed")
            and scoped.get("scene", {}).get("axObservationComplete")
            and scoped.get("boundary", {}).get("observed"), "One or more observations were incomplete; inspect retained originals")


def seal(output, destination):
    import stat
    require(output.is_dir() and not output.is_symlink(), "Missing diagnostic evidence")
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
        for path in sorted(output.rglob("*")):
            name = path.relative_to(output).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                item = zipfile.ZipInfo(name)
                item.create_system = 3
                item.external_attr = mode << 16
                archive.writestr(item, os.fsencode(os.readlink(path)))
            elif stat.S_ISREG(mode):
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as stream, archive.open(name, "w", force_zip64=True) as member:
                    require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "Evidence file changed type")
                    shutil.copyfileobj(stream, member, 1024 * 1024)
            else:
                require(stat.S_ISDIR(mode), "Unexpected special evidence path")


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("mode", choices=("bind", "observe", "boundary-fixture", "seal"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binding", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    def interrupted(number, _frame):
        raise InterruptedError(f"Interrupted by signal {number}")
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    if args.mode == "bind":
        bind(args.output)
    elif args.mode == "observe":
        observe(args.binding, args.output.resolve())
    else:
        require(os.environ.get("GITHUB_ACTIONS") == "true" and platform.system() == "Darwin", "Expected native CI fixture")
        if args.mode == "seal":
            seal(args.output, args.archive)
        else:
            boundary_fixture(args.app, args.output)


if __name__ == "__main__":
    main()
