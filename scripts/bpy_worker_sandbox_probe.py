"""Bind and observe an isolated sandbox component; never grant app acceptance."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
import zipfile

from bpy_worker_memory_probe import case_specs, validate_case


ROOT = Path(__file__).resolve().parents[1]
SOURCE = "05c763fc9393119cafc9cf9df4e2fb0b6d52c14a"
RUN = 40373287805
ARTIFACT = 12678546679
SIZE = 1646525831
DIGEST = "91ffd9d3d344476959ea31f4c2c147c65aa84d16623de17731c74bc561d6900f"
FILES = {".github/workflows/native-acceptance-probes.yml", "scripts/bpy_worker_sandbox_probe.py",
         "scripts/bpy_worker_sandbox_probe.c", "scripts/bpy_worker_sandbox_probe.sb",
         "scripts/bpy_worker_sandbox_payload.py", "scripts/test_bpy_worker_sandbox_probe.py",
         "scripts/bpy_worker_memory_probe.py", "scripts/test_bpy_worker_memory_probe.py"}
RETAINED_RUN = 40394670788
RETAINED_SOURCE = "0ffbddd688621c025f861b0a66fc3f59a2acc012"
RETAINED_ARTIFACTS = {
    "binary": (12685777245, "worker-sandbox-binaries", 4982,
               "989b8f556e4da2055e61026af640c1747eaa4e341628d42fd01a10086192ed59", 121824609450),
    "runtime": (12686128132, "worker-sandbox-component-40394670788", 751257,
                "fb588678db6f9905f8972b001175e1ab29fc179304c7e47ffc1c3afbf6c01ba2", 121824891750),
}
RETAINED_NATIVE_FILES = {
    "scripts/bpy_worker_sandbox_probe.c": "1cac5edf294d6d306dc4fb67890751b4e577c2c0bdebf9a51fef390ab0576c2d",
    "scripts/bpy_worker_sandbox_probe.sb": "a6327af409af37c1db419ddadcaa84f08ab5fbb477972e8687750caaf120d146",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def execution_identity(environment):
    require(environment.get("GITHUB_RUN_ATTEMPT") == "1", "component reruns are forbidden")
    run_id = environment.get("GITHUB_RUN_ID", "")
    require(run_id.isascii() and run_id.isdecimal() and int(run_id) > 0, "current run identity")
    return dict(runID=int(run_id), runAttempt=1)


def tree_manifest(root):
    entries = {}
    paths = []
    def failed(error):
        raise error
    for directory, folders, files in os.walk(root, onerror=failed, followlinks=False):
        paths.extend(Path(directory) / name for name in folders + files)
    for path in sorted(paths):
        metadata = path.lstat()
        entry = dict(mode=stat.S_IMODE(metadata.st_mode))
        if stat.S_ISLNK(metadata.st_mode):
            entry.update(type="symlink", target=os.readlink(path))
        elif stat.S_ISDIR(metadata.st_mode):
            entry.update(type="directory")
        elif stat.S_ISREG(metadata.st_mode):
            entry.update(type="file", bytes=metadata.st_size, sha256=sha(path))
        else:
            raise ValueError("unsupported runtime entry: " + str(path))
        entries[path.relative_to(root).as_posix()] = entry
    return entries


def require_python_only_change(original, copied):
    require(set(original) == set(copied), "complete copied runtime inventory")
    for name, value in original.items():
        if name == "python/bin/python3.13":
            require(value["type"] == copied[name]["type"] == "file"
                    and value["mode"] == copied[name]["mode"], "regular unchanged-mode Python executable")
        else:
            require(value == copied[name], "unexpected runtime copy change: " + name)


def entitlements(data):
    return {} if not data.strip() else plistlib.loads(data)


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", "repos/iret77/nexgenvideo/" + path], timeout=45))


def validate_retained(run, jobs, artifacts, now):
    require(run.get("id") == RETAINED_RUN and run.get("head_sha") == RETAINED_SOURCE
            and run.get("run_attempt") == 1 and run.get("status") == "completed"
            and run.get("conclusion") == "failure" and run.get("event") == "workflow_dispatch"
            and run.get("path") == ".github/workflows/native-acceptance-probes.yml"
            and run.get("actor", {}).get("login") == "iret77"
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo", "retained component run")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "complete retained jobs")
    selected = {}
    for name, identifier, conclusion in [("sandbox-source", 121824433566, "success"),
            ("sandbox-build", 121824609450, "success"), ("sandbox-runtime", 121824891750, "failure")]:
        matches = [job for job in jobs["jobs"] if job.get("name") == name]
        require(len(matches) == 1, "unique retained job")
        job = matches[0]
        require(job.get("id") == identifier and job.get("status") == "completed"
                and job.get("conclusion") == conclusion and job.get("run_id") == RETAINED_RUN
                and job.get("run_attempt") == 1 and job.get("head_sha") == RETAINED_SOURCE,
                "retained job identity")
        selected[identifier] = job
    instant = lambda value: datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(set(artifacts) == set(RETAINED_ARTIFACTS), "complete retained artifact metadata")
    for kind, (identifier, name, size, digest, job_id) in RETAINED_ARTIFACTS.items():
        artifact = artifacts[kind]
        job = selected[job_id]
        require(artifact.get("id") == identifier and artifact.get("name") == name
                and artifact.get("size_in_bytes") == size and artifact.get("digest") == "sha256:" + digest
                and artifact.get("expired") is False
                and artifact.get("workflow_run", {}).get("id") == RETAINED_RUN
                and artifact.get("workflow_run", {}).get("head_sha") == RETAINED_SOURCE
                and instant(job["started_at"]) <= instant(artifact["created_at"])
                <= instant(artifact["updated_at"]) <= instant(job["completed_at"])
                and instant(artifact["expires_at"]) > now, "retained artifact producer and availability")


def retained_component(output, download):
    run = api(f"actions/runs/{RETAINED_RUN}")
    jobs = api(f"actions/runs/{RETAINED_RUN}/attempts/1/jobs?per_page=100")
    artifacts = {kind: api(f"actions/artifacts/{value[0]}") for kind, value in RETAINED_ARTIFACTS.items()}
    validate_retained(run, jobs, artifacts, datetime.datetime.now(datetime.timezone.utc))
    require(all(sha(ROOT / name) == digest for name, digest in RETAINED_NATIVE_FILES.items()),
            "retained native binary and policy source must be unchanged")
    for kind, (identifier, _, size, digest, _) in RETAINED_ARTIFACTS.items():
        archive = output / ("retained-" + kind + ".zip")
        if download:
            with archive.open("xb") as stream, (output / ("retained-" + kind + ".stderr.log")).open("wb") as errors:
                subprocess.run(["gh", "api", f"repos/iret77/nexgenvideo/actions/artifacts/{identifier}/zip"],
                               stdin=subprocess.DEVNULL, stdout=stream, stderr=errors, check=True, timeout=60)
        require(archive.stat().st_size == size and sha(archive) == digest, "retained complete archive hash")
    with zipfile.ZipFile(output / "retained-runtime.zip") as archive:
        prefix = "_temp/worker-sandbox/"
        for mode, expected in [("native-control", 0), ("native-sandbox", 0), ("exec-control", 93), ("exec-sandbox", 0)]:
            receipt = json.loads(archive.read(prefix + mode + ".process.json"))
            require(receipt["exitCode"] == expected and receipt["reaped"] is True
                    and receipt["timedOut"] is False and receipt["cleanupError"] is None, "retained native exit and cleanup")
        failure = json.loads(archive.read(prefix + "failure.json"))
        require(failure == dict(error="component command failed: python-control", type="ValueError", runtimeAcceptance=False),
                "resume only the original failed Python stage")
        python = json.loads(archive.read(prefix + "python-control.process.json"))
        require(python["exitCode"] == 1 and python["reaped"] is True and python["timedOut"] is False
                and python["cleanupError"] is None, "retained Python failure and cleanup")
        stderr = archive.read(prefix + "python-control.stderr.log").decode()
        require("resource.setrlimit(resource.RLIMIT_AS, (6 * 1024 * 1024 * 1024,) * 2)" in stderr
                and stderr.endswith("ValueError: current limit exceeds maximum limit\n")
                and not any(name.startswith(prefix + "python-sandbox") for name in archive.namelist()),
                "retained failed call and unexecuted confined Python stage")
        require(json.loads(archive.read(prefix + "original-app-verified.json"))
                == dict(artifact=ARTIFACT, bytes=SIZE, sha256=DIGEST), "retained original app binding")
    with zipfile.ZipFile(output / "retained-binary.zip") as archive:
        require(set(archive.namelist()) == {"probe", "build.json", "clang.log", "xcode.log"}, "retained binary inventory")
        build = json.loads(archive.read("build.json"))
        require(build["execution"] == dict(runID=RETAINED_RUN, runAttempt=1)
                and build["sourceSHA"] == RETAINED_SOURCE
                and build["probeSourceSHA256"] == RETAINED_NATIVE_FILES["scripts/bpy_worker_sandbox_probe.c"]
                and build["binarySHA256"] == "0aeec754aaaf404264f65cee5e18a8e9a16fd388241b14c43d798089bf0d8487"
                and hashlib.sha256(archive.read("probe")).hexdigest() == build["binarySHA256"], "retained compiled helper")
        if download:
            binaries = output / "retained-binaries"
            binaries.mkdir()
            for name in archive.namelist():
                (binaries / name).write_bytes(archive.read(name))
    return dict(run=run, jobs=jobs, artifacts=artifacts, build=build,
                reusedModes=["native-control", "native-sandbox", "exec-control", "exec-sandbox"])


def validate(run, jobs, artifact, changed, now):
    require(run.get("id") == RUN and run.get("head_sha") == SOURCE and run.get("run_attempt") == 1
            and run.get("status") == "completed" and run.get("conclusion") == "failure"
            and run.get("event") == "workflow_dispatch" and run.get("path") == ".github/workflows/ci-batch.yml"
            and run.get("actor", {}).get("login") == "iret77"
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo", "original run binding")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "complete original job inventory")
    producer = None
    for name, conclusion in [("Light Checks", "success"), ("Build & Test", "success"),
                             ("Agent UI Evidence", "success"), ("bpy-source / source", "success"),
                             ("diagnostic-startup", "success"), ("bpy-runtime / runtime", "failure")]:
        selected = [j for j in jobs["jobs"] if j.get("name") == "Compile, unit tests, app and native bpy acceptance / " + name]
        require(len(selected) == 1, "unique producer job")
        job = selected[0]
        require(job.get("status") == "completed" and job.get("conclusion") == conclusion
                and job.get("run_id") == RUN and job.get("head_sha") == SOURCE and job.get("run_attempt") == 1,
                "original job identity and result")
        if name == "Build & Test":
            producer = job
            require(job.get("id") == 121755560581, "exact successful build")
        if name == "bpy-runtime / runtime":
            require(job.get("id") == 121773449342 and [s.get("name") for s in job.get("steps", [])
                    if s.get("conclusion") == "failure"] == ["Prove pre-lease and post-exec host-crash cleanup"],
                    "original failure stage")
    require(artifact.get("id") == ARTIFACT and artifact.get("name") == "NexGenVideo-app"
            and artifact.get("size_in_bytes") == SIZE and artifact.get("digest") == "sha256:" + DIGEST
            and artifact.get("expired") is False and artifact.get("workflow_run", {}).get("id") == RUN
            and artifact.get("workflow_run", {}).get("head_sha") == SOURCE, "original artifact binding")
    instant = lambda text: datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    require(instant(producer["started_at"]) <= instant(artifact["created_at"])
            <= instant(artifact["updated_at"]) <= instant(producer["completed_at"])
            and instant(artifact["expires_at"]) > now, "original artifact attempt and availability")
    require(set(changed) <= FILES, "only isolated component tooling may change")


def memory_mode(environment):
    value = environment.get("NGV_SANDBOX_MEMORY_PROBE", "false")
    require(value in ("true", "false"), "explicit memory diagnostic selection")
    require(value != "true" or environment.get("NGV_SANDBOX_RESUME_PYTHON") == "true",
            "memory diagnostic requires retained successful helper")
    return value == "true"


def bind(output):
    output.mkdir(parents=True, exist_ok=False)
    execution = execution_identity(os.environ)
    run = api(f"actions/runs/{RUN}")
    jobs = api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100")
    artifact = api(f"actions/artifacts/{ARTIFACT}")
    changed = subprocess.check_output(["git", "diff", "--name-only", SOURCE, "HEAD"], cwd=ROOT, text=True, timeout=30).splitlines()
    validate(run, jobs, artifact, changed, datetime.datetime.now(datetime.timezone.utc))
    resume = os.environ.get("NGV_SANDBOX_RESUME_PYTHON", "false")
    require(resume in ("true", "false"), "explicit Python continuation mode")
    retained = retained_component(output, download=True) if resume == "true" else None
    save(output / "identity.json", dict(run=run, jobs=jobs, artifact=artifact, changedPaths=changed, execution=execution,
        harnessSHA=os.environ["GITHUB_SHA"], files={name: sha(ROOT / name) for name in sorted(FILES)},
        retained=retained, memoryProbe=memory_mode(os.environ)))


def native_sections(data):
    require(len(data) >= 32, "Mach-O header")
    magic, cpu, _, _, commands, command_bytes, _, _ = struct.unpack_from("<8I", data)
    require(magic == 0xFEEDFACF and cpu == 0x100000C and commands <= 256
            and 32 + command_bytes <= len(data), "arm64 Mach-O command bounds")
    cursor = 32
    sections = []
    for _ in range(commands):
        require(cursor + 8 <= 32 + command_bytes, "Mach-O command header")
        kind, length = struct.unpack_from("<II", data, cursor)
        require(length >= 8 and cursor + length <= 32 + command_bytes, "Mach-O command size")
        if kind == 0x19:
            require(length >= 72, "Mach-O segment")
            count = struct.unpack_from("<I", data, cursor + 64)[0]
            require(length == 72 + count * 80, "Mach-O section bounds")
            for index in range(count):
                at = cursor + 72 + index * 80
                name = data[at:at + 32].hex()
                address, size, offset = struct.unpack_from("<QQI", data, at + 32)
                flags = struct.unpack_from("<I", data, at + 64)[0]
                zero = flags & 0xFF in (1, 0xC, 0x12)
                require(zero or offset + size <= len(data), "Mach-O section payload")
                sections.append((name, address, size, flags, None if zero else hashlib.sha256(data[offset:offset + size]).hexdigest()))
        cursor += length
    require(cursor == 32 + command_bytes and sections, "complete Mach-O section inventory")
    return sections


def signal_group(process, number, privileged=False):
    try:
        os.killpg(process.pid, number)
    except ProcessLookupError:
        return
    except PermissionError:
        require(privileged and process.poll() is None and os.getpgid(process.pid) == process.pid,
                "only owned privileged process groups may be signalled")
        subprocess.run(["sudo", "-n", "/bin/kill", "-" + signal.Signals(number).name.removeprefix("SIG"),
                        "--", "-" + str(process.pid)], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)


def run_command(args, output, *, timeout=60, environment=None, expected=0, privileged=False):
    with output.with_suffix(".stdout.log").open("wb") as stdout, output.with_suffix(".stderr.log").open("wb") as stderr:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                   env=environment, start_new_session=True)
        timed_out = False
        cleanup_error = None
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            code = None
        finally:
            try:
                if process.poll() is None:
                    signal_group(process, signal.SIGTERM, privileged)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        signal_group(process, signal.SIGKILL, privileged)
                        process.wait(timeout=5)
            except Exception as error:
                cleanup_error = str(error)
            finally:
                save(output.with_suffix(".process.json"), dict(pid=process.pid, exitCode=process.returncode,
                     timedOut=timed_out, reaped=process.poll() is not None, cleanupError=cleanup_error))
    require(not timed_out and cleanup_error is None and code == expected, "component command failed: " + output.name)
    return process.pid


def records(path):
    result = []
    for line in path.read_bytes().split(b"\n"):
        if line.startswith(b"NGV_COMPONENT "):
            result.append(json.loads(line.removeprefix(b"NGV_COMPONENT ")))
    return result


def observe_memory(output, runtime, probe, outside, peer, port):
    deadline = time.monotonic() + 180
    outcomes = []
    for case in case_specs():
        require(time.monotonic() < deadline, "memory diagnostic overall deadline")
        require(peer.poll() is None, "owned peer exited before diagnostic")
        name = "memory-" + case["name"]
        work = output / name
        work.mkdir(mode=0o700)
        for directory in ("home", "tmp"):
            (work / directory).mkdir(mode=0o700)
        payload = work / "bpy_worker_memory_probe.py"
        for filename in ("bpy_worker_memory_probe.py", "bpy_worker_sandbox_payload.py"):
            shutil.copyfile(ROOT / "scripts" / filename, work / filename)
            require(sha(ROOT / "scripts" / filename) == sha(work / filename), "exact diagnostic payload copy")
        save(work / "input.json", dict(memoryCase=case))
        environment = dict(HOME=str(work / "home"), TMPDIR=str(work / "tmp"), PATH="", LANG="C.UTF-8", LC_ALL="C.UTF-8")
        receipt = output / (name + ".process.json")
        error = None
        try:
            pid = run_command([str(probe), "python-control", str(ROOT / "scripts/bpy_worker_sandbox_probe.sb"),
                str(work), str(runtime), str(outside), str(payload), str(peer.pid), str(port)], output / name,
                timeout=min(30, max(1, deadline - time.monotonic())), environment=environment)
            observed = [json.loads(line.removeprefix("NGV_MEMORY "))
                        for line in (output / (name + ".stdout.log")).read_text().splitlines()
                        if line.startswith("NGV_MEMORY ")]
            validate_case(case, observed, pid)
        except Exception as failure:
            error = dict(type=type(failure).__name__, message=str(failure))
        require(receipt.exists(), "owned memory process receipt missing")
        process = json.loads(receipt.read_text())
        require(process["reaped"] and process["cleanupError"] is None, "owned memory process cleanup failed")
        outcomes.append(dict(case=case, process=process, error=error, candidateSupported=error is None))
        save(output / "memory-cases.json", dict(cases=outcomes, runtimeAcceptance=False))
        require(not process["timedOut"], "memory diagnostic timed out")
    result = dict(scope="isolated memory candidate measurements", runtimeAcceptance=False,
                  cases=outcomes, candidateSupported=all(item["candidateSupported"] for item in outcomes),
                  limitations=["No bpy import or render in this diagnostic", "No product or sandbox integration proof",
                               "Only the enumerated original-interpreter exec variants tested",
                               "Candidate region flags are not universal permanence proof",
                               "No physical-memory ceiling or memory-entry allocation proof"])
    save(output / "memory-result.json", result)
    require(result["candidateSupported"], "memory candidate contradicted or measurement incomplete")
    return result


def observe(output, identity, binaries):
    output.mkdir(parents=True, exist_ok=False)
    execution = execution_identity(os.environ)
    evidence = json.loads((identity / "identity.json").read_text())
    validate(api(f"actions/runs/{RUN}"), api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100"),
             api(f"actions/artifacts/{ARTIFACT}"), evidence["changedPaths"], datetime.datetime.now(datetime.timezone.utc))
    require(evidence["execution"] == execution and evidence["harnessSHA"] == os.environ["GITHUB_SHA"]
            and evidence["files"] == {name: sha(ROOT / name) for name in sorted(FILES)}, "reviewed harness source")
    memory = memory_mode(os.environ)
    require(evidence.get("memoryProbe") is memory, "source and runtime memory diagnostic selections agree")
    require(subprocess.check_output(["sw_vers", "-productVersion"], text=True).startswith("26.")
            and subprocess.check_output(["uname", "-m"], text=True).strip() == "arm64", "macOS26 arm64")
    build = json.loads((binaries / "build.json").read_text())
    probe = binaries / "probe"
    resume = os.environ.get("NGV_SANDBOX_RESUME_PYTHON", "false")
    require(resume in ("true", "false") and (evidence.get("retained") is not None) == (resume == "true"),
            "source and runtime continuation modes agree")
    retained = retained_component(identity, download=False) if resume == "true" else None
    require(retained is None or build == retained["build"], "retained extracted build receipt")
    build_execution = dict(runID=RETAINED_RUN, runAttempt=1) if retained else execution
    build_source = RETAINED_SOURCE if retained else os.environ["GITHUB_SHA"]
    require(build["execution"] == build_execution and build["sourceSHA"] == build_source and build["binarySHA256"] == sha(probe)
            and build["probeSourceSHA256"] == sha(ROOT / "scripts/bpy_worker_sandbox_probe.c"), "compiled probe binding")
    save(output / "continuation.json", dict(retained=retained, execution=execution, harnessSHA=os.environ["GITHUB_SHA"]))
    archive = output / "original-app.zip"
    with archive.open("xb") as stream, (output / "download.stderr.log").open("wb") as errors:
        subprocess.run(["gh", "api", f"repos/iret77/nexgenvideo/actions/artifacts/{ARTIFACT}/zip"],
                       stdin=subprocess.DEVNULL, stdout=stream, stderr=errors, check=True, timeout=600)
    require(archive.stat().st_size == SIZE and sha(archive) == DIGEST, "complete original archive hash")
    save(output / "original-app-verified.json", dict(artifact=ARTIFACT, bytes=SIZE, sha256=DIGEST))
    candidate = output / "original"
    run_command(["ditto", "-x", "-k", str(archive), str(candidate)], output / "outer-extract", timeout=120)
    run_command(["ditto", "-x", "-k", str(candidate / "NexGenVideo.zip"), str(candidate)], output / "app-extract", timeout=180)
    app = candidate / "NexGenVideo.app"
    require(plistlib.loads((app / "Contents/Info.plist").read_bytes())["NGVSourceCommit"] == SOURCE, "original app source")
    run_command(["codesign", "--verify", "--strict", "--verbose=2", str(app)], output / "original-signature", timeout=120)
    run_command([str(ROOT / "scripts/verify_bpy_bundle.sh"), str(app), "--development"], output / "original-bundle", timeout=360)
    original_runtime = app / "Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/Resources/BpyRuntime"
    original_manifest = tree_manifest(original_runtime)
    save(output / "original-runtime-manifest.json", original_manifest)
    runtime = output / "fixture-runtime"
    shutil.copytree(original_runtime, runtime, symlinks=True)
    require(tree_manifest(runtime) == original_manifest, "byte-exact runtime copy before resealing")
    python = runtime / "python/bin/python3.13"
    require(stat.S_ISREG(python.lstat().st_mode), "Python must be a regular file")
    before = python.read_bytes()
    native_sections(before)
    for name, arguments in [("signature", ["-dvvv"]), ("entitlements", ["-d", "--entitlements", "-", "--xml"])]:
        run_command(["codesign", *arguments, str(python)], output / ("original-python-" + name))
    empty = output / "empty-entitlements.plist"
    empty.write_bytes(plistlib.dumps({}))
    run_command(["codesign", "--force", "--sign", "-", "--timestamp=none", "--entitlements", str(empty), str(python)], output / "fixture-sign")
    run_command(["codesign", "--verify", "--strict", str(python)], output / "fixture-signature")
    run_command(["codesign", "-dvvv", str(python)], output / "fixture-python-signature")
    run_command(["codesign", "-d", "--entitlements", "-", "--xml", str(python)], output / "fixture-entitlements")
    require(entitlements((output / "fixture-entitlements.stdout.log").read_bytes()) == {}, "fixture has no AppSandbox inheritance")
    after = python.read_bytes()
    require(native_sections(before) == native_sections(after), "resealing changed native section content")
    fixture_manifest = tree_manifest(runtime)
    require_python_only_change(original_manifest, fixture_manifest)
    save(output / "fixture-runtime-manifest.json", fixture_manifest)
    save(output / "runtime-variant.json", dict(originalArtifact=ARTIFACT, originalSource=SOURCE,
        originalPythonSHA256=hashlib.sha256(before).hexdigest(), fixturePythonSHA256=hashlib.sha256(after).hexdigest(),
        sectionInventory=native_sections(after), change="Python ad-hoc signature resealed with empty entitlements; native sections unchanged",
        scope="isolated derivative fixture; original app remains unchanged; not installed app or distribution proof",
        signingLimitation="Ad-hoc reseal can change identifier/team and hardened-runtime flags; library validation and distribution signing are not proved"))
    outside = output / "outside-canary.txt"
    outside.write_text("outside-worker-root\n")
    ready = output / "peer-ready.json"
    peer_log = (output / "peer.log").open("wb")
    peer = None
    server = None
    try:
        peer = subprocess.Popen([sys.executable, "-I", "-c",
            "import os,signal,time,json; from pathlib import Path; p=Path(__import__('sys').argv[1]); "
            "signal.signal(signal.SIGUSR1,signal.SIG_IGN); p.write_text(json.dumps({'pid':os.getpid()})); time.sleep(600)", str(ready)],
            stdin=subprocess.DEVNULL, stdout=peer_log, stderr=peer_log, start_new_session=True,
            env={"PATH": "", "LANG": "C.UTF-8"})
        server = socket.socket()
        deadline = time.monotonic() + 10
        while not ready.exists() and peer.poll() is None and time.monotonic() < deadline:
            time.sleep(.05)
        require(ready.exists() and json.loads(ready.read_text())["pid"] == peer.pid and peer.poll() is None, "owned live signal control")
        server.bind(("127.0.0.1", 0))
        server.listen(8)
        memory_result = observe_memory(output, runtime, probe, outside, peer, server.getsockname()[1]) if memory else None
        modes = () if memory else ("python-control", "python-sandbox") if retained else (
            "native-control", "native-sandbox", "exec-control", "exec-sandbox", "python-control", "python-sandbox")
        for mode in modes:
            require(peer.poll() is None, "signal target must remain owned and unreaped")
            work = output / mode
            work.mkdir(mode=0o700)
            for name in ("home", "tmp", "config", "scripts", "data"):
                (work / name).mkdir(mode=0o700)
            payload = work / "payload.py"
            shutil.copyfile(ROOT / "scripts/bpy_worker_sandbox_payload.py", payload)
            save(work / "input.json", dict(outside=str(outside), sitePackages=str(runtime / "site-packages"), confined=mode.endswith("sandbox")))
            environment = {"HOME": str(work / "home"), "TMPDIR": str(work / "tmp"), "PATH": "", "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "BLENDER_USER_CONFIG": str(work / "config"), "BLENDER_USER_SCRIPTS": str(work / "scripts"),
                "BLENDER_USER_DATAFILES": str(work / "data")}
            pid = run_command([str(probe), mode, str(ROOT / "scripts/bpy_worker_sandbox_probe.sb"), str(work),
                str(runtime), str(outside), str(payload), str(peer.pid), str(server.getsockname()[1])],
                output / mode, timeout=180, environment=environment, expected=93 if mode == "exec-control" else 0)
            observed = records(output / (mode + ".stdout.log"))
            require(all(record.get("pid") == pid for record in observed), "native receipt PID")
            if mode.endswith("sandbox"):
                require(len([r for r in observed if r.get("stage") == "sandbox" and r.get("result") == 0]) == 1,
                        "actual sandbox initialization")
                for stage, value in [("before-sandbox", 0), ("after-sandbox", 1)]:
                    require(len([r for r in observed if r.get("stage") == stage and r.get("sandboxed") == value]) == 1,
                            "one sandbox transition from unsandboxed parent")
            if mode.startswith("native"):
                selected = [r for r in observed if r.get("stage") == "denials"]
                require(len(selected) == 1, "native denial receipt")
                values = [selected[0][key] for key in ("readErrno", "writeErrno", "forkErrno", "networkErrno", "signalErrno")]
                require(all(value in (1, 13) for value in values) if mode.endswith("sandbox") else values == [0] * 5,
                        "native positive controls and actual permission denials")
                require((work / "allowed-native.txt").read_bytes() == b"allowed", "allowed native write")
            if mode == "exec-sandbox":
                require(len([r for r in observed if r.get("stage") == "exec-denial" and r.get("errno") in (1, 13)]) == 1,
                        "actual foreign exec denial")
            if mode.startswith("python-"):
                result = json.loads((work / "result.json").read_text())
                lock = json.loads((runtime / "runtime-lock.json").read_text())
                require(result["pid"] == pid and result["pythonVersion"] == [3, 13, 15] and result["bpyVersion"] == [5, 2, 2]
                        and result["renderEngine"] == "CYCLES" and result["device"] == "CPU"
                        and result["denoising"] is False and result["confined"] == mode.endswith("sandbox")
                        and result["executable"] == str(python.resolve())
                        and result["bpyModule"] == str((runtime / "site-packages" / lock["bpyWheelLayout"]["entryPoint"]).resolve()), "actual bundled bpy identity")
                require(set(result["denials"]) == {"read", "write"}
                        and all(value in ((1, 13) if mode.endswith("sandbox") else (0,)) for value in result["denials"].values()),
                        "Python positive controls and permission denials")
                png = (work / "render.png").read_bytes()
                require(png[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png[16:24]) == (32, 32)
                        and (work / "scene.blend").stat().st_size > 0, "actual render and scene outputs")
                require(tree_manifest(runtime) == fixture_manifest, "Python execution changed the runtime fixture")
        require(outside.read_text() == "outside-worker-root\n", "outside data retained")
        result = dict(passed=True, runtimeAcceptance=False,
            scope="isolated memory candidate only" if memory else "isolated component only", memory=memory_result,
            sourceSHA=os.environ["GITHUB_SHA"], originalSource=SOURCE, artifact=ARTIFACT, execution=execution,
            retained=retained, compositeAcrossRuns=retained is not None,
            limitations=["No host/XPC integration or restart ownership proof", "No full bpy or native UI acceptance",
                         "Ad-hoc derivative fixture, no Developer ID/notarized distribution proof",
                         "Standalone helper, not the real supervisor or complete product B4 policy",
                         "No Metal, IPC, fileport, volume or complete hostile-job matrix proof"])
    finally:
        if server is not None:
            server.close()
        if peer is not None:
            if peer.poll() is None:
                peer.terminate()
            try:
                peer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                peer.kill()
                peer.wait(timeout=5)
            save(output / "peer-cleanup.json", dict(pid=peer.pid, exitCode=peer.returncode, reaped=True))
        peer_log.close()
    save(output / "result.json", result)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("bind", "observe"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--identity", type=Path)
    parser.add_argument("--binaries", type=Path)
    args = parser.parse_args()
    started = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    def interrupted(number, _frame):
        raise InterruptedError("component interrupted: " + str(number))
    for number in (signal.SIGTERM, signal.SIGINT):
        signal.signal(number, interrupted)
    try:
        if args.mode == "bind":
            bind(args.output.resolve())
        else:
            observe(args.output.resolve(), args.identity.resolve(), args.binaries.resolve())
    except BaseException as error:
        args.output.mkdir(parents=True, exist_ok=True)
        archive = args.output / "original-app.zip"
        if archive.exists() and not (args.output / "original-app-verified.json").exists():
            failed = args.output / "failed-original-app.zip"
            archive.rename(failed)
            save(args.output / "failed-transfer.json", dict(bytes=failed.stat().st_size, sha256=sha(failed),
                 expectedBytes=SIZE, expectedSHA256=DIGEST))
        save(args.output / "failure.json", dict(error=str(error), type=type(error).__name__, runtimeAcceptance=False))
        raise
    finally:
        if args.mode == "observe" and args.output.is_dir():
            try:
                run_command(["sudo", "-n", "/usr/bin/log", "show", "--start", started, "--style", "ndjson", "--info", "--debug",
                    "--predicate", '(subsystem == "com.apple.sandbox.reporting") OR (subsystem == "com.apple.libsystem.sandbox") OR (sender == "Sandbox")'],
                    args.output / "sandbox-os-log", timeout=60, privileged=True)
            except Exception as error:
                save(args.output / "supplementary-log-error.json", dict(error=str(error)))
                receipt = args.output / "sandbox-os-log.process.json"
                if receipt.exists() and not json.loads(receipt.read_text())["reaped"]:
                    save(args.output / "failure.json", dict(error="owned log process was not reaped", runtimeAcceptance=False))
                    result = args.output / "result.json"
                    if result.exists():
                        value = json.loads(result.read_text())
                        value["passed"] = False
                        save(result, value)
                    raise RuntimeError("owned log process cleanup failed") from error


if __name__ == "__main__":
    main()
