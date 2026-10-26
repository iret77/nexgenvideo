import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import time
import uuid

from bpy_bundle_layout import paired


ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(proofs, fixture):
    if len(proofs) != 2:
        raise ValueError("both native boundary slots are required")
    for slot, proof in enumerate(proofs):
        executable = fixture / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc/Contents/MacOS/NexGenVideoBpyService"
        if (type(proof.get("slot")) is not int or proof["slot"] != slot
                or proof.get("serviceName") != f"de.h5ventures.nexgenvideo.bpy-service-{slot}"
                or proof.get("serviceExecutable") != str(executable.resolve())):
            raise ValueError("boundary service slot mismatch")
        if proof.get("schema") != "nexgenvideo/bpy-boundary-probe/4":
            raise ValueError("wrong boundary schema")
        uuid.UUID(proof.get("nonce", ""))
        for key in ("outsideWriteDeniedErrno", "networkDeniedErrno", "forkDeniedErrno",
                    "unlinkedBytesObserved", "fileportRetentionDeniedErrno", "fileportBytesObserved"):
            if type(proof.get(key)) is not int:
                raise ValueError("invalid boundary numeric evidence")
        if any(type(value) is not int for value in proof.get("signalDeniedErrnos", [])):
            raise ValueError("invalid signal errno")
        pids = [proof.get(key) for key in ("serviceProcessIdentifier", "supervisorProcessIdentifier", "childProcessIdentifier")]
        if any(type(value) is not int or value <= 1 for value in pids) or len(set(pids)) != 3:
            raise ValueError("invalid boundary process identities")
        if (proof.get("supervisorParentProcessIdentifier") != pids[0]
                or proof.get("childParentProcessIdentifier") != pids[1]):
            raise ValueError("invalid native parent chain")
        for key in ("serviceStartAbsoluteTime", "supervisorStartAbsoluteTime", "childStartAbsoluteTime"):
            if type(proof.get(key)) is not int or proof[key] <= 0:
                raise ValueError("missing process start identity")
        for key in ("allowedWriteSucceeded", "cleanupSupervisorGone", "cleanupChildGone",
                    "internalLinkedWritableDeduplicated", "healthyFollowupSucceeded"):
            if proof.get(key) is not True:
                raise ValueError("missing boundary outcome: " + key)
        if (proof.get("outsideWriteDeniedErrno") not in (1, 13)
                or proof.get("networkDeniedErrno") not in (1, 13)
                or proof.get("forkDeniedErrno") not in (1, 35)
                or len(proof.get("signalDeniedErrnos", [])) != 3
                or any(value not in (1, 13) for value in proof["signalDeniedErrnos"])
                or proof.get("unlinkedBytesObserved", 0) < 1048576
                or proof.get("unlinkedLimitReason") != "disk"):
            raise ValueError("sandbox denial or retained-resource proof missing")
        fileport_denied = proof.get("fileportRetentionDenied") is True and proof.get("fileportRetentionDeniedErrno") in (1, 13)
        fileport_accounted = (proof.get("fileportRetentionDeniedErrno") == 0
                              and proof.get("fileportBytesObserved", 0) >= 1048576
                              and proof.get("fileportLimitReason") == "disk")
        if not (fileport_denied or fileport_accounted):
            raise ValueError("missing fileport proof")
    if proofs[0]["serviceProcessIdentifier"] == proofs[1]["serviceProcessIdentifier"] or proofs[0].get("nonce") == proofs[1].get("nonce"):
        raise ValueError("boundary slots shared their service or execution")


def run(app, output, source_sha):
    if platform.system() != "Darwin" or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("requires macOS and exact source")
    output.mkdir(parents=True, exist_ok=False)
    fixture_root = output.parent.parent / ("bpy-boundary-fixture-" + uuid.uuid4().hex)
    fixture_root.mkdir(exist_ok=False)
    fixture = fixture_root / "NexGenVideo.app"
    process = None
    receipt = {"sourceSHA": source_sha, "completed": False,
               "scope": "Derived ad-hoc-signed CI fixture; not original-app or release acceptance"}
    started = time.monotonic()
    def command(args, timeout=120):
        with (output / "commands.log").open("ab") as log:
            return subprocess.run([str(value) for value in args], stdin=subprocess.DEVNULL,
                                  stdout=log, stderr=log, check=True, timeout=timeout)
    paths = ["Contents/Info.plist", "Contents/MacOS/NexGenVideo"] + [
        f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc/Contents/MacOS/{name}"
        for slot in range(2) for name in ("NexGenVideoBpyService", "NexGenVideoBpySupervisor")]
    before = {name: digest(app / name) for name in paths}
    runtime_before = paired(app)
    try:
        version = subprocess.check_output(["/usr/bin/sw_vers", "-productVersion"], text=True, timeout=10).strip()
        if version.split(".")[0] != "26" or platform.machine() != "arm64":
            raise ValueError("requires released macOS 26 arm64")
        if plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("NGVSourceCommit") != source_sha:
            raise ValueError("original app source mismatch")
        command(["codesign", "--verify", "--deep", "--strict", app])
        excluded = {app / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc/Contents/Resources/BpyRuntime"
                    for slot in range(2)} | {app / "Contents/Resources/BpyRuntimeCompliance"}
        shutil.copytree(app, fixture, symlinks=True,
                        ignore=lambda directory, names: [name for name in names if Path(directory) / name in excluded])
        if any(os.path.samefile(app / name, fixture / name) for name in paths):
            raise ValueError("fixture aliases original files")
        (fixture / "Contents/Resources/BPY_BOUNDARY_PROBE_NONPRODUCT_CI").write_bytes(b"")
        command([ROOT / "scripts/sign_app.sh", fixture, "dev", "boundary", "-"], timeout=120)
        command(["codesign", "--verify", "--deep", "--strict", fixture])
        receipt.update(osVersion=version, originalHashes=before,
                       derivedHashes={name: digest(fixture / name) for name in paths})
        with (output / "stdout.log").open("xb") as stdout, (output / "stderr.log").open("xb") as stderr:
            process = subprocess.Popen([str(fixture / "Contents/MacOS/NexGenVideo")],
                env=dict(os.environ, NGV_SELFTEST_BPY_BOUNDARY=str(output / "proof")),
                stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
            receipt["processIdentifier"] = process.pid
            try:
                code = process.wait(timeout=400)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise ValueError("owned boundary host timed out") from None
        receipt["exitCode"] = code
        if code != 0 or "SELFTEST_BPY_BOUNDARY_OK" not in (output / "stdout.log").read_text():
            raise ValueError("native boundary failed; inspect original logs")
        proofs = [json.loads((output / f"proof.slot{slot}.json").read_text()) for slot in range(2)]
        validate(proofs, fixture)
        receipt["proofs"] = proofs
        receipt["completed"] = True
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        receipt["processReaped"] = process is not None and process.poll() is not None
        pattern = re.compile("(?:" + "|".join(re.escape(value) for value in {str(fixture), str(fixture.resolve())})
            + r")/Contents/XPCServices/NexGenVideoBpyService[01]\.xpc/Contents/(?:MacOS/NexGenVideoBpySupervisor|Resources/BpyRuntime/python)")
        cleanup_error = None
        survivors = []
        try:
            deadline = time.monotonic() + 10
            while True:
                listing = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True, timeout=10)
                survivors = [int(line.split(None, 1)[0]) for line in listing.splitlines() if pattern.search(line)]
                if not survivors or time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            cleanup_error = type(error).__name__
        receipt["survivingOwnedWorkers"] = survivors
        receipt["cleanupObservationError"] = cleanup_error
        receipt["elapsedSeconds"] = time.monotonic() - started
        unchanged = before == {name: digest(app / name) for name in paths} and runtime_before == paired(app)
        try:
            command(["codesign", "--verify", "--deep", "--strict", app])
            receipt["originalSignatureVerifiedAfter"] = True
        except (OSError, subprocess.SubprocessError):
            receipt["originalSignatureVerifiedAfter"] = False
            unchanged = False
        receipt["originalUnchanged"] = unchanged
        receipt["completed"] = receipt["completed"] and unchanged and not survivors and cleanup_error is None
        (output / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if not unchanged:
            raise ValueError("original app changed during derived fixture verification")
        if survivors or cleanup_error is not None:
            raise ValueError("derived boundary workers did not prove complete cleanup")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    run(args.app, args.output, args.source_sha)
