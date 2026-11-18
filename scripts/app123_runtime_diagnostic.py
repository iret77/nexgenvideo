"""Capture the first Boundary child report on the retained signed Build 123."""
import argparse
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import zipfile

from bpy_open_diagnostic import stop_owned
from release_acceptance_identity import digest, gui_tools, require
from retained_packaging import collect_source
from reuse_bpy_binary_evidence import api, download, instant
from verify_diagnostic_candidate import verify_signed_bpy

SOURCE = "22c81c1d13e2d99c9320adb457a17b8cabb2b4cf"
REF = "iret77/rc-delivery-base-795"
BRANCH = "iret77/rc-app123-boundary-1191"
PRIOR_HARNESS = "de4d86ade10742675b1951ed7c17b3f8782e9bbc"
SERVICE = "de.h5ventures.nexgenvideo.bpy-service-0"
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
    require(head == os.environ["GITHUB_SHA"] and git("show", "-s", "--format=%P", "HEAD") == PRIOR_HARNESS
            and set(changed) == PATHS
            and set(git("diff", "--name-only", PRIOR_HARNESS, head).splitlines()) == PATHS - {"scripts/fixtures/app-cohort.json"}
            and not git("status", "--porcelain", "--untracked-files=no"),
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
    prior = api("/actions/runs/44385227085")
    prior_job = api("/actions/jobs/135088071105")
    prior_artifact = api("/actions/artifacts/14467029810")
    require((prior["id"], prior["head_sha"], prior["run_attempt"], prior["conclusion"]) ==
            (44385227085, PRIOR_HARNESS, 1, "success")
            and (prior["workflow_id"], prior["path"], prior["event"], prior["status"], prior["actor"]["login"]) ==
            (355242770, ".github/workflows/diagnostic-acceptance.yml", "workflow_dispatch", "completed", "iret77")
            and (prior_job["run_id"], prior_job["head_sha"], prior_job["run_attempt"], prior_job["conclusion"]) ==
            (44385227085, PRIOR_HARNESS, 1, "success") and prior_job["labels"] == ["macrunner"]
            and (prior_job["name"], prior_job["status"]) == ("app123-runtime-diagnostic", "completed")
            and (prior_artifact["id"], prior_artifact["workflow_run"]["id"], prior_artifact["size_in_bytes"]) ==
            (14467029810, 44385227085, 24657250)
            and prior_artifact["name"] == "app123-runtime-observations-44385227085-a1"
            and prior_artifact["workflow_run"]["head_sha"] == PRIOR_HARNESS
            and instant(prior_job["started_at"]) <= instant(prior_artifact["created_at"])
                <= instant(prior_artifact["updated_at"]) <= instant(prior_job["completed_at"])
            and prior_artifact["digest"] == "sha256:7523096900b40c56991e444655b7a506712bb55365a8818ed7182f63a86b3d16"
            and not prior_artifact["expired"] and instant(prior_artifact["expires_at"]) > datetime.now(timezone.utc),
            "Previous Boundary observation origin differs")
    return {"run": run, "app": app, "releaseJob": release, "failures": bound,
            "priorBoundary": {"run": prior, "job": prior_job, "artifact": prior_artifact}}


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


@contextmanager
def owned(argv, output, environment, *, privileged=False):
    with output.open("xb") as log:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        try:
            yield process
        finally:
            stop_owned(process, privileged)


def boundary_fixture(app, output):
    from bpy_boundary_acceptance import run
    from bpy_runtime_acceptance import capture_open_logs
    output.mkdir()
    with capture_open_logs(output/"storage"):
        run(app, output/"native", SOURCE)


def read_member(directory, name, maximum):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(fd, "rb") as handle:
        before = os.fstat(handle.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_nlink <= 1 and 0 < before.st_size <= maximum,
                "Expected a single bounded regular observation file")
        raw = handle.read(maximum + 1)
        after = os.fstat(handle.fileno())
        require(len(raw) == before.st_size and after.st_nlink <= 1
                and (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
                "Observation file changed while reading")
        return raw, before


def capture_report(home, started_ns):
    with ExitStack() as stack:
        def directory(name, parent=None):
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            stack.callback(os.close, fd)
            return fd

        try:
            slot = directory(home)
            for part in ("Library", "Caches", "NexGenVideo", "BpyVolumes", SERVICE):
                slot = directory(part, slot)
            lease_raw, _ = read_member(slot, "lease.json", 16384)
            journal = json.loads(lease_raw)
            nonce = journal["id"]
            require(journal["schema"] == "nexgenvideo/bpy-storage/2" and journal["role"] == "worker"
                    and journal["serviceName"] == SERVICE and journal["pairID"] == nonce
                    and re.fullmatch(r"[A-F0-9]{8}(?:-[A-F0-9]{4}){3}-[A-F0-9]{12}", nonce),
                    "Invalid owned Boundary worker journal")
            lease = journal.get("lease")
            if lease is None:
                return None
            slot_path = home / "Library/Caches/NexGenVideo/BpyVolumes" / SERVICE
            require(lease["mountPath"] == str(slot_path / "mount") and lease["id"] == nonce,
                    "Unexpected owned Boundary mount")
            mount = directory("mount", slot)
            node = directory(nonce, mount)
            node = directory("boundary", node)
            node = directory("denials", node)
            raw, info = read_member(node, "child.json", 4096)
            moment = time.time_ns()
            slot_info = os.fstat(slot)
            require(info.st_dev == os.fstat(mount).st_dev == lease["device"]
                    and slot_info.st_ino == journal["directoryInode"] and slot_info.st_dev == journal["directoryDevice"]
                    and started_ns <= info.st_mtime_ns <= moment,
                    "Boundary report is outside its mounted worker lease or time interval")
        except FileNotFoundError:
            return None

        if not journal.get("workers"):
            try:
                later_raw, _ = read_member(slot, "lease.json", 16384)
                later = json.loads(later_raw)
                stable_keys = ("schema", "id", "pairID", "serviceName", "role", "bootSessionID",
                               "ownerPID", "ownerStart", "servicePID", "serviceStart", "directoryDevice",
                               "directoryInode", "lease")
                if all(later.get(key) == journal[key] for key in stable_keys):
                    lease_raw, journal = later_raw, later
            except FileNotFoundError:
                pass
        provenance = {name: journal[name] for name in ("id", "pairID", "serviceName", "ownerPID",
            "ownerStart", "servicePID", "serviceStart", "directoryDevice", "directoryInode", "bootSessionID")}
        provenance.update({"workerDevice": lease["device"], "leaseSHA256": hashlib.sha256(lease_raw).hexdigest(),
                           "supervisors": journal.get("supervisors", []), "workers": journal.get("workers", [])})
        receipt = {"readAtNS": moment, "observerPID": os.getpid(), "fixtureStartedAtNS": started_ns,
                   "relativeFile": nonce + "/boundary/denials/child.json", "worker": provenance,
                   "file": {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(), "device": info.st_dev,
                            "inode": info.st_ino, "mtimeNS": info.st_mtime_ns, "mode": stat.S_IMODE(info.st_mode),
                            "linksWhenOpened": info.st_nlink}}
        return raw, receipt


def record_processes(report, capture, journal, output):
    pids = (journal["ownerPID"], journal["servicePID"], report["parentProcessIdentifier"], report["processIdentifier"])
    require(all(type(pid) is int and pid > 1 for pid in pids) and len(set(pids)) == len(pids),
            "Boundary process IDs are invalid")
    with (output / "processes-at-capture.log").open("xb") as log:
        status = subprocess.run(["/bin/ps", "-ww", "-p", ",".join(map(str, pids)), "-o", "pid=,ppid=,lstart=,comm="],
                                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=3)
    capture["processListingExitCode"] = status.returncode


def observe_first_report(process, home, output, started_ns):
    deadline = time.monotonic() + 620
    while process.poll() is None and time.monotonic() < deadline:
        found = capture_report(home, started_ns)
        if found is not None:
            raw, observation = found
            with (output / "child.json").open("xb") as evidence:
                evidence.write(raw)
            save(output / "child-capture.json", observation)
            report = json.loads(raw)
            require(report["schema"] == "nexgenvideo/bpy-boundary-child/2" and report["mode"] == "denials"
                    and type(report["allowedWriteSucceeded"]) is bool
                    and all(type(report[key]) is int for key in ("outsideWriteDeniedErrno", "forkDeniedErrno",
                        "networkDeniedErrno", "resourceBytes", "retentionDeniedErrno"))
                    and len(report["signalDeniedErrnos"]) == 3
                    and all(type(errno) is int for errno in report["signalDeniedErrnos"]),
                    "Malformed original Boundary child report")
            try:
                record_processes(report, observation, observation["worker"], output)
            except (OSError, subprocess.SubprocessError) as error:
                observation["processListingError"] = type(error).__name__
            return observation
        time.sleep(0.005)
    return None


def bind_report(observation, native, capture, fixture_stage, report):
    if observation is None:
        return None
    worker = observation["worker"]
    require(native["processIdentifier"] == worker["ownerPID"] and native["sourceSHA"] == SOURCE
            and native["originalHashes"]["Contents/MacOS/NexGenVideo"] == IMAGE,
            "Boundary journal does not belong to the fixture and original app")
    events = [json.loads(line) for line in (capture / "storage/open-events.ndjson").read_text().splitlines()
              if line.startswith("{")]
    nonce = worker["id"]
    host = [value for value in events if value.get("processID") == worker["ownerPID"]
            and value.get("eventMessage", "").startswith(f"bookmark.resolve id={nonce} pair={nonce} role=worker ")]
    service = [value for value in events if value.get("processID") == worker["servicePID"]
               and value.get("eventMessage", "").startswith(f"open.validated session={nonce} owner={nonce} ")
               and f" start={worker['serviceStart']} pair={nonce} " in value["eventMessage"]]
    resolved_host = host[0]["processImagePath"] if host else ""
    expected_host = (re.escape(str(fixture_stage))
                     + r"/bpy-boundary-fixture-[0-9a-f]{32}/NexGenVideo\.app/Contents/MacOS/NexGenVideo")
    xpc = resolved_host.removesuffix("/MacOS/NexGenVideo") + "/XPCServices/NexGenVideoBpyService0.xpc/Contents/MacOS/"
    supervisors = worker["supervisors"]
    children = worker["workers"]
    require(len(supervisors) == 1 and len(children) == 1 and supervisors[0]["pid"] == report["parentProcessIdentifier"]
            and supervisors[0]["parent"] == worker["ownerPID"] and supervisors[0]["start"] > 0
            and supervisors[0]["executable"] == xpc + "NexGenVideoBpySupervisor"
            and children[0]["pid"] == report["processIdentifier"]
            and children[0]["parent"] == report["parentProcessIdentifier"]
            and children[0]["start"] > 0 and children[0]["executable"] == supervisors[0]["executable"],
            "Boundary report parent does not match the worker's recorded supervisor")
    require(len(host) >= 1 and all(value["processImagePath"] == resolved_host for value in host)
            and re.fullmatch(expected_host, resolved_host)
            and any(f" device={worker['workerDevice']} " in value["eventMessage"] for value in host)
            and {"worker", "data"} == {value["eventMessage"].split(" role=")[1].split()[0] for value in service}
            and all(value["processImagePath"] == xpc + "NexGenVideoBpyService" for value in service)
            and any(" role=worker " in value["eventMessage"]
                    and f" device={worker['workerDevice']} " in value["eventMessage"] for value in service),
            "Boundary storage events do not match the captured report")
    return {"capture": observation, "nativeHost": host[0], "serviceValidated": service}


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
            started_ns = time.time_ns()
            started = time.monotonic()
            with owned(argv, output/"harness.log", environment) as process:
                observed = None
                try:
                    observed = observe_first_report(process, Path(environment["HOME"]), output, started_ns)
                except (OSError, subprocess.SubprocessError, ValueError, TypeError, KeyError) as error:
                    if isinstance(error, InterruptedError):
                        raise
                    save(output/"observer-error.json", {"type": type(error).__name__, "error": str(error)})
                process.wait(timeout=max(0.1, 620 - (time.monotonic() - started)))
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
    report = json.loads((output/"child.json").read_bytes()) if observed is not None else None
    bound = bind_report(observed, native, output/"capture", fixture_stage, report)
    if bound is not None:
        save(output/"child-binding.json", bound)
    result = {"originalChildReportBound":bound is not None, "nativeExitCode":process.returncode,
              "wrapperPID":process.pid, "wrapperReaped":process.poll() is not None,
              "traceStarted":trace_started, "traceExitCode":trace.returncode, "traceReaped":trace.poll() is not None,
              "filesystemPositiveControl":positive, "traceStoppedEarly":trace_early,
              "storageStreamReported":bool(storage),
              "observed":bool(trace_started and not trace_early and positive and storage.get("reaped")
                  and not storage.get("stoppedEarly") and not storage.get("cleanupErrors")
                  and native.get("processReaped") and native.get("originalUnchanged")
                  and native.get("originalSignatureVerifiedAfter")
                  and not native.get("survivingOwnedWorkers") and not native.get("cleanupObservationError")
                  and bound is not None)}
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
    result = {}
    try:
        result = boundary(app, stage, output/"boundary")
    finally:
        unchanged = app_bytes(app) == before
        logged(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app], output/"signature-after.log")
        logged(["/usr/bin/xcrun", "stapler", "validate", app], output/"staple-after.log")
        save(output/"outcome.json", dict(boundary=result, appUnchanged=unchanged, measurementOnly=True, runtimeAccepted=False))
        require(unchanged, "Executed App differs from the retained signed original")
    require(result.get("observed"), "The exact Boundary report was not bound; inspect retained originals")


def seal(output, destination):
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
