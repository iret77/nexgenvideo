"""Compare one immutable app at three locations; never grant runtime acceptance."""
import argparse
from datetime import datetime, timezone, timedelta
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
import zipfile

from bpy_open_diagnostic import command, run as observe, stop_owned
from verify_diagnostic_candidate import verify_bpy_diagnostic


ROOT = Path(__file__).resolve().parents[1]
SOURCE = "d8e509167d3dae41dd37ec77f4bf150418c52624"
RUN = 40271482527
ARTIFACT = 12629361449
DIGEST = "3872bb5fa623c396076b209dfa5f9c3d0e892683c82827b57d3b1dace1453a66"
SIZE = 1327468211
TREE = "388a9cd239f397dc5b4c04c6c31643d4c8cbbd345a5e911c5363b3854bf7158e"
SOURCE_RECEIPT = "6278e6f68a94ec03e7d7bf3a6b7c5d11ae0071d18d59b30de3249157c22a1f22"
ALLOWED = {".github/workflows/diagnostic-acceptance.yml", "scripts/bpy_open_diagnostic.py",
           "scripts/bpy_resource_diagnostic.py", "scripts/test_bpy_resource_diagnostic.py"}
ARMS = ("temporary", "home", "applications")


def require(value, message):
    if not value:
        raise ValueError(message)


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True, timeout=30).stdout.decode().rstrip("\n")


def api(path):
    result = subprocess.run(["gh", "api", "repos/iret77/nexgenvideo/" + path],
                            stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=60)
    return json.loads(result.stdout)


def verify_origin(run, jobs, artifact, changed):
    require(not set(changed) - ALLOWED, "product or unreviewed caller changed")
    require(run.get("run_attempt") == 1, "original producer attempt changed")
    require(run.get("head_repository", {}).get("full_name") == "iret77/nexgenvideo",
            "foreign producer repository")
    verify_bpy_diagnostic(run, jobs, artifact, RUN, SOURCE, ARTIFACT, DIGEST, [])
    require(artifact.get("size_in_bytes") == SIZE, "original artifact size changed")
    expires = datetime.fromisoformat(artifact["expires_at"].replace("Z", "+00:00"))
    require(expires > datetime.now(timezone.utc) + timedelta(hours=6), "artifact retention too short")
    prefix = "Compile, unit tests, app and native bpy acceptance / "
    for name, identity in [("Build & Test", 121407415150), ("bpy-runtime / runtime", 121411720766)]:
        matches = [job for job in jobs["jobs"] if job["name"] == prefix + name]
        require(len(matches) == 1 and matches[0]["id"] == identity, "original job identity changed")


def verify_inputs(environment):
    expected = {"CANDIDATE_RUN": str(RUN), "CANDIDATE_SOURCE": SOURCE,
                "CANDIDATE_ARTIFACT": str(ARTIFACT), "CANDIDATE_DIGEST": DIGEST,
                "REPLAY_KIND": "ci-bpy-resource-diagnostic"}
    require(all(environment.get(key) == value for key, value in expected.items()),
            "workflow inputs differ from the original diagnostic")
    require(not any(environment.get(key) for key in
                    ("PRODUCT_SHA", "PRODUCTS_ID", "PRODUCTS_DIGEST", "FAILURE_ID", "FAILURE_DIGEST")),
            "unrelated replay inputs supplied")


def bind(output):
    verify_inputs(os.environ)
    output.mkdir(parents=True, exist_ok=False)
    head = git("rev-parse", "HEAD")
    require(head == os.environ.get("GITHUB_SHA"), "checkout and execution differ")
    require(not git("status", "--porcelain", "--untracked-files=no"), "tracked source is dirty")
    git("merge-base", "--is-ancestor", SOURCE, head)
    changed = [name for name in git("diff", "--name-only", "--no-renames", "-z", SOURCE, head).split("\0") if name]
    run = api(f"actions/runs/{RUN}")
    jobs = api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100")
    artifact = api(f"actions/artifacts/{ARTIFACT}")
    for name, value in [("run", run), ("jobs", jobs), ("artifact", artifact)]:
        write(output / (name + ".json"), value)
    verify_origin(run, jobs, artifact, changed)
    write(output / "binding.json", dict(schema="nexgenvideo/bpy-resource-diagnostic/1",
          scope="diagnostic-only", runtimeAcceptance=False, harnessSource=head, appSource=SOURCE,
          runID=RUN, attempt=1, artifactID=ARTIFACT, artifactSHA256=DIGEST, artifactSize=SIZE,
          appTreeSHA256=TREE, changed=changed,
          harnessFiles={name: sha(ROOT / name) for name in sorted(ALLOWED)}))


def tree(app):
    spec = importlib.util.spec_from_file_location("ngv_original_tree", ROOT / "scripts/external-gui/acceptance.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.tree_sha256(app)


def download_bytes(args, archive, errors):
    with archive.open("xb") as output, errors.open("xb") as stderr:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=output, stderr=stderr,
                                   start_new_session=True)
        try:
            require(process.wait(timeout=600) == 0, "original artifact download failed")
        finally:
            stop_owned(process)


def archive_receipt(container):
    names = container.namelist()
    require(len(names) == 2 and set(names) == {"NexGenVideo.zip", "bpy-source/bpy-source-receipt.json"},
            "unexpected original artifact members")
    receipt = container.read("bpy-source/bpy-source-receipt.json")
    require(hashlib.sha256(receipt).hexdigest() == SOURCE_RECEIPT, "original bpy source receipt differs")
    require(json.loads(receipt).get("sourceSHA") == SOURCE, "original bpy receipt source differs")
    return receipt


def placement(arm, temporary, home, run_id, attempt):
    require(arm in ARMS, "unknown arm")
    require(re.fullmatch(r"[1-9][0-9]*", run_id or "") and attempt == "1", "fresh run attempt required")
    if arm == "temporary":
        return temporary / "relocated"
    name = "NGV-bpy-diagnostic-" + run_id
    return home / name if arm == "home" else Path("/Applications") / name


def snapshot(app, output):
    runtime = app / "Contents/Resources/BpyRuntime"
    paths = {"pythonAlias": runtime / "python/bin/python3",
             "pythonTarget": runtime / "python/bin/python3.13",
             "supervisor": app / "Contents/Helpers/NexGenVideoBpySupervisor",
             "worker": runtime / "worker.py", "sitePackages": runtime / "site-packages"}
    for slot in range(2):
        service = app / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc"
        paths["service" + str(slot)] = service
        paths["serviceBinary" + str(slot)] = service / "Contents/MacOS/NexGenVideoBpyService"
    statuses = {}
    for role, path in paths.items():
        statuses[role] = {}
        for name, args in [("metadata", ["/bin/ls", "-lde@O", str(path)]),
                           ("xattrs", ["/usr/bin/xattr", "-l", str(path)]),
                           ("stat", ["/usr/bin/stat", "-f", "%N %d %i %u %g %p %f", str(path)])]:
            statuses[role][name] = command(args, output / (role + "-" + name + ".log"))
    write(output / "resource-snapshot.json", statuses)


def prepare(arm, evidence, identity):
    verify_inputs(os.environ)
    evidence.mkdir(parents=True, exist_ok=False)
    binding = json.loads((identity / "binding.json").read_text())
    require(binding["harnessSource"] == os.environ.get("GITHUB_SHA") == git("rev-parse", "HEAD"),
            "runtime harness identity mismatch")
    for name, digest in binding["harnessFiles"].items():
        require(sha(ROOT / name) == digest, "runtime harness bytes changed")
    verify_origin(api(f"actions/runs/{RUN}"), api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100"),
                  api(f"actions/artifacts/{ARTIFACT}"), binding["changed"])
    require(sys.platform == "darwin", "macOS runner required")
    for name, args in [("hostname", ["/bin/hostname"]), ("version", ["/usr/bin/sw_vers"]),
                       ("architecture", ["/usr/bin/uname", "-m"])]:
        require(command(args, evidence / (name + ".log")) == 0, "platform capture failed")
    version = subprocess.run(["/usr/bin/sw_vers", "-buildVersion"], stdin=subprocess.DEVNULL,
                             capture_output=True, check=True, timeout=10).stdout.strip()
    require(version == b"25G83" and (evidence / "architecture.log").read_text().strip() == "arm64",
            "original macOS26 build/architecture required")
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve()
    parent = placement(arm, temporary, Path.home().resolve(), os.environ.get("GITHUB_RUN_ID"),
                       os.environ.get("GITHUB_RUN_ATTEMPT"))
    require(not parent.exists() and not parent.is_symlink(), "occupied diagnostic destination")
    if arm == "applications":
        require(command(["sudo", "-n", "/bin/mkdir", str(parent)], evidence / "placement-create.log") == 0,
                "could not create owned Applications destination")
        require(command(["sudo", "-n", "/usr/sbin/chown", f"{os.getuid()}:{os.getgid()}", str(parent)],
                        evidence / "placement-owner.log") == 0, "could not assign owned destination")
    else:
        parent.mkdir()
    require(parent.resolve() == parent and not parent.is_symlink(), "destination aliases another location")
    archive = temporary / "bpy-resource-original.zip"
    require(not archive.exists(), "occupied original archive")
    download_bytes(["gh", "api", f"repos/iret77/nexgenvideo/actions/artifacts/{ARTIFACT}/zip"],
                   archive, evidence / "artifact-download-stderr.log")
    require(archive.stat().st_size == SIZE and sha(archive) == DIGEST, "original ZIP size/digest mismatch")
    inner = temporary / "bpy-resource-input"
    require(not inner.exists(), "occupied inner archive destination")
    with zipfile.ZipFile(archive) as container:
        (evidence / "bpy-source-receipt.json").write_bytes(archive_receipt(container))
    require(command(["/usr/bin/ditto", "-x", "-k", str(archive), str(inner)],
                    evidence / "outer-extraction.log", timeout=120) == 0, "outer extraction failed")
    require(command(["/usr/bin/ditto", "-x", "-k", str(inner / "NexGenVideo.zip"), str(parent)],
                    evidence / "app-extraction.log", timeout=180) == 0, "app extraction failed")
    app = parent / "NexGenVideo.app"
    require(tree(app) == TREE, "original complete app tree differs")
    with (app / "Contents/Info.plist").open("rb") as stream:
        require(plistlib.load(stream).get("NGVSourceCommit") == SOURCE, "original app source differs")
    require(command([str(ROOT / "scripts/verify_bpy_bundle.sh"), str(app), "--development"],
                    evidence / "bundle-verification.log", timeout=300) == 0, "original bundle verification failed")
    require(command(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(app)],
                    evidence / "app-signature.log") == 0, "original app signature failed")
    for slot in range(2):
        require(command(["/usr/bin/codesign", "-d", "--entitlements", ":-",
                         str(app / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc")],
                        evidence / f"service-{slot}-signature.log") == 0, "service signature capture failed")
    snapshot(app, evidence)
    commands = [("mounts", ["/sbin/mount"]), ("sip", ["/usr/bin/csrutil", "status"]),
                ("gatekeeper", ["/usr/sbin/spctl", "--status"]),
                ("extensions", ["/usr/bin/systemextensionsctl", "list"]),
                ("enrollment", ["/usr/bin/profiles", "status", "-type", "enrollment"]),
                ("software", ["/usr/sbin/system_profiler", "SPSoftwareDataType"]),
                ("location", ["/usr/bin/stat", "-f", "%N %d %i %u %g %p %f", str(parent)])]
    status = {name: command(args, evidence / (name + ".log"), timeout=45) for name, args in commands}
    profile = Path("/System/Library/Sandbox/Profiles/application.sb")
    status["applicationProfile"] = command(["/bin/cat", str(profile)], evidence / "application-profile.txt")
    write(evidence / "system-probes.json", status)
    write(evidence / "runner-image.json", {name: os.environ.get(name) for name in
          ("ImageOS", "ImageVersion", "RUNNER_OS", "RUNNER_ARCH")})
    denied = temporary / "denied"
    (denied / "foreign-project").mkdir(parents=True, exist_ok=False)
    for name, content in [("provider-secret", "provider-secret"), ("canonical-artifact", "canonical-project-truth"),
                          ("foreign-project/scene.blend", "foreign-project")]:
        (denied / name).write_text(content)
    with (Path.home() / "ngv-bpy-host-home-secret").open("x") as stream:
        stream.write("host-home-secret")
    approved = temporary / "approved-input"
    approved.mkdir()
    (approved / "fixture.json").write_text('{"approved":true}')
    (approved / "symlink.json").symlink_to(denied / "provider-secret")
    (approved / "hardlink-source").write_text("hardlink")
    os.link(approved / "hardlink-source", approved / "hardlink.json")
    fake = temporary / "fake-bin"
    fake.mkdir()
    for name in ("python3", "blender"):
        (fake / name).write_text("#!/bin/sh\nexit 99\n")
        (fake / name).chmod(0o755)
    write(evidence / "placement.json", dict(arm=arm, app=str(app), realpath=str(app.resolve()),
          sourceSHA=SOURCE, appTreeSHA256=TREE, artifactID=ARTIFACT, artifactSHA256=DIGEST,
          harnessSource=binding["harnessSource"], scope="diagnostic-only", runtimeAcceptance=False))


def survivors(raw, app):
    prefix = str(app) + "/"
    result = []
    for line in raw.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and fields[1].startswith(prefix):
            result.append(dict(pid=int(fields[0]), executable=fields[1]))
    return result


def resource_control(raw, app):
    expected = {str(app / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc/Contents/MacOS/NexGenVideoBpyService")
                for slot in range(2)}
    groups = {}
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        if not isinstance(event, dict) or event.get("processImagePath") not in expected:
            continue
        message = event.get("eventMessage", "")
        match = re.match(r"open\.runtime-(resource|preflight) session=([A-Fa-f0-9-]{36}) pid=([0-9]+) start=([0-9]+) (.*)", message)
        if not match:
            continue
        kind, session, pid, start, detail = match.groups()
        if int(pid) != event.get("processID") or int(start) <= 0:
            continue
        key = (int(pid), int(start), session)
        group = groups.setdefault(key, {"roles": set(), "preflight": False})
        if kind == "preflight":
            group["preflight"] = True
        else:
            role = re.match(r"role=([A-Za-z]+) ", detail)
            if role:
                group["roles"].add(role[1])
    roles = {"pythonAlias", "pythonTarget", "supervisor", "worker", "sitePackages"}
    records = [dict(pid=key[0], start=key[1], session=key[2], roles=sorted(group["roles"]),
                    complete=group["preflight"] and group["roles"] == roles)
               for key, group in sorted(groups.items())]
    return dict(complete=bool(records) and all(record["complete"] for record in records), sessions=records)


def orphan_pattern(app):
    escaped = "".join("\\" + char if char in ".^$*+?{}[]\\|()" else char for char in str(app))
    return escaped + r"/Contents/(Helpers/NexGenVideoBpySupervisor|Resources/BpyRuntime/python)"


def inspect(evidence):
    placement_record = json.loads((evidence / "placement.json").read_text())
    app = Path(placement_record["app"])
    output = evidence / "observation"
    probe = Path(os.environ["RUNNER_TEMP"]) / "evidence/host-crash-before-authorization"
    try:
        require(tree(app) == TREE, "app changed before execution")
        observe(app, output, SOURCE, probe, policy=True)
    finally:
        remaining, command_pids, errors, actual_tree = None, None, [], None
        try:
            for _ in range(40):
                process = subprocess.run(["/bin/ps", "-axo", "pid=,comm="], stdin=subprocess.DEVNULL,
                                         capture_output=True, check=True, timeout=10)
                (evidence / "post-processes.log").write_bytes(process.stdout)
                remaining = survivors(process.stdout.decode(), app)
                full = subprocess.run(["/usr/bin/pgrep", "-f", orphan_pattern(app)], stdin=subprocess.DEVNULL,
                                      capture_output=True, timeout=10)
                require(full.returncode in (0, 1), "original full-command orphan check failed")
                command_pids = [int(value) for value in full.stdout.split()]
                if not remaining and not command_pids:
                    break
                time.sleep(0.25)
        except Exception as error:
            errors.append("process-observation: " + repr(error))
        try:
            actual_tree = tree(app)
        except Exception as error:
            errors.append("post-tree: " + repr(error))
        control = {"complete": False, "sessions": []}
        observer = {}
        try:
            control = resource_control((output / "unified-stream.ndjson").read_bytes(), app)
            observer = json.loads((output / "evidence-verdict.json").read_text())
        except Exception as error:
            errors.append("observation-receipt: " + repr(error))
        write(evidence / "resource-observation-control.json", control)
        write(evidence / "post-execution.json", dict(runtimeAcceptance=False, appTreeSHA256=actual_tree,
              originalTreeSHA256=TREE, survivingProcesses=remaining, fullCommandPIDs=command_pids,
              errors=errors, resourceObservationComplete=control["complete"],
              comparisonInstrumentsComplete=not errors and control["complete"]
                  and observer.get("instrumentsComplete") is True and actual_tree == TREE
                  and remaining == [] and command_pids == [],
              cleanup="Owned observers/probe reaped by original harness; no foreign process signalled. "
                      "Owned app directory retained until ephemeral runner teardown."))
    # Diagnostic outcomes remain failed CI, including a non-reproduction.
    return 1


def main():
    interrupted = False

    def cancel(number, _frame):
        nonlocal interrupted
        if not interrupted:
            interrupted = True
            raise InterruptedError("diagnostic interrupted: " + str(number))

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, cancel)
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("bind", "prepare", "observe"))
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--identity", type=Path)
    parser.add_argument("--arm", choices=ARMS)
    args = parser.parse_args()
    if args.command == "bind":
        bind(args.evidence)
    elif args.command == "prepare":
        require(args.arm and args.identity, "arm and identity required")
        prepare(args.arm, args.evidence, args.identity)
    else:
        raise SystemExit(inspect(args.evidence))


if __name__ == "__main__":
    main()
