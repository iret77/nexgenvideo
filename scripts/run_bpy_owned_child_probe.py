import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time


EXPECTED_CHILD_SHA256 = "7444d80b48bcec309b19a0c219f71f9fe7d9d913b1e069876f8ca58e4cb07e4e"


def inventory(root, name):
    results = []
    for suffix, command in (("processes", ["ps", "-axo", "pid,ppid,pgid,stat,%cpu,etime,comm"]),
                            ("load", ["sysctl", "vm.loadavg"])):
        with (root / (name + "-" + suffix + ".log")).open("wb") as log:
            result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=5, check=False)
        results.append({"query": suffix, "exitCode": result.returncode})
        if result.returncode:
            raise ValueError("Runner inventory failed: " + suffix)
    return results


def cases_complete(records):
    try:
        cases = [item for item in records if item.get("stage") == "case-result"]
        destroys = [item for item in records if item.get("stage") == "destroy"]
        stopped = [item for item in records if item.get("stage") == "stopped-owned"]
        expected = {(mode, iteration) for mode in range(4) for iteration in range(3)}
        return (len(cases) == 12 and {(item["mode"], item["iteration"]) for item in cases} == expected
                and all(item["error"] == 0 and item["terminationSignal"] == (15 if item["mode"] == 0 else 9)
                        and item["exitStatus"] == (143 if item["mode"] == 0 else 137) for item in cases)
                and len(destroys) == 12 and all(item["error"] == 0 for item in destroys)
                and len(stopped) == 3 and len({item["pid"] for item in stopped}) == 3
                and all(item["result"] == 0 and item["pollError"] == 0 and item["running"] == 1
                        and item["waitCode"] == os.CLD_STOPPED and item["waitStatus"] == signal.SIGSTOP
                        and item["pid"] > 1 and item["waitPID"] == item["pid"] for item in stopped)
                and records[-1] == {"stage": "complete", "cases": 12})
    except (AttributeError, IndexError, KeyError, TypeError):
        return False


def read_records(root):
    return [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines() if line]


def group_members(root, pid):
    lines = (root / "after-processes.log").read_text().splitlines()
    if not lines or lines[0].split()[:3] != ["PID", "PPID", "PGID"]:
        raise ValueError("Process inventory header differs")
    members = []
    for line in lines[1:]:
        fields = line.split(None, 6)
        if len(fields) != 7 or not all(value.isdecimal() for value in fields[:3]):
            raise ValueError("Process inventory row is malformed")
        if int(fields[0]) == pid or int(fields[2]) == pid:
            members.append(int(fields[0]))
    return members


def completed(receipt, cases):
    return (receipt.get("ownedGroupEmpty") is True and "after" in receipt
            and not receipt["timedOut"] and receipt.get("exitCode") == 0 and cases
            and not any(key in receipt for key in
                        ("cleanupError", "reapError", "inventoryError", "caseEvidenceError", "groupResidueError")))


def kill_group(process, receipt):
    try:
        os.killpg(process.pid, signal.SIGKILL)
        receipt["ownedGroupCleanup"] = "sent"
    except ProcessLookupError:
        receipt["ownedGroupCleanup"] = "absent"
    except OSError as error:
        receipt["cleanupError"] = {"type": type(error).__name__, "errno": error.errno}


def finish_process(process, receipt, root, destination):
    try:
        try:
            complete = cases_complete(read_records(root))
        except (OSError, ValueError) as error:
            complete = False
            receipt["caseEvidenceError"] = type(error).__name__
        if (not receipt["timedOut"] and complete
                and receipt.get("kernelExit") == {"code": os.CLD_EXITED, "status": 0}):
            receipt["ownedGroupCleanup"] = "controlled-children-reaped"
        else:
            kill_group(process, receipt)
    finally:
        try:
            receipt["exitCode"] = process.wait(timeout=5)
        except (OSError, subprocess.SubprocessError) as error:
            receipt["reapError"] = type(error).__name__
        finally:
            try:
                receipt["after"] = inventory(root, "after")
                members = group_members(root, process.pid)
                receipt["ownedGroupEmpty"] = not members
                if not receipt["ownedGroupEmpty"]:
                    receipt["groupResidueError"] = "Owned leader or group remains after wait"
                    if "exitCode" in receipt and process.pid in members:
                        receipt["ownedGroupCleanup"] = "refused-reused-leader"
                    else:
                        kill_group(process, receipt)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                receipt["inventoryError"] = type(error).__name__
            receipt["endedAt"] = time.time()
            destination.write_text(json.dumps(receipt, indent=2) + "\n")


def main():
    root = Path(sys.argv[1]).resolve()
    source = Path("Sources/BpySupervisorPOSIX/OwnedChild.c")
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != EXPECTED_CHILD_SHA256:
        raise ValueError("The diagnostic requires the exact reviewed owned-child correction")
    if platform.system() != "Darwin" or platform.machine() != "arm64" or not hasattr(os, "waitid"):
        raise ValueError("The diagnostic requires Apple Silicon macOS and Python 3.13+")
    version = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
    if version.split(".")[0] != "27":
        raise ValueError("The failed producer ran on macOS 27")
    source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if source_sha != os.environ["GITHUB_SHA"]:
        raise ValueError("Checkout and workflow source differ")
    binary = root / "probe"
    receipt = {"sourceSHA": source_sha, "referenceRun": 40353688164, "referenceAttempt": 1,
               "referenceSource": "13743d3e7ff32aec9af6d6047d6c43dd4ade7455",
               "referenceOwnedChildSHA256": "0a6052abb3a616764fb4ca270ccb4911dfd1d05ea3d030f932cd9ab7d5ecb061",
               "ownedChildSHA256": digest, "macOS": version, "kernel": platform.release(),
               "python": sys.version, "runID": os.environ["GITHUB_RUN_ID"],
               "attempt": os.environ["GITHUB_RUN_ATTEMPT"], "startedAt": time.time(),
               "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "probeSourceSHA256": hashlib.sha256(Path("scripts/bpy_owned_child_probe.c").read_bytes()).hexdigest(),
               "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
               "sdk": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip(),
               "target": "arm64-apple-macos26.0",
               "completed": False, "timedOut": False}
    origin = root / "retained-binary.json"
    if origin.exists():
        retained = json.loads(origin.read_text())
        if (retained.get("schema") != "owned-child-binary/v1" or retained.get("sourceSHA") != source_sha
                or retained.get("binarySHA256") != receipt["binarySHA256"]):
            raise ValueError("Retained binary evidence differs from this execution")
        receipt["binaryOrigin"] = retained
    else:
        receipt["binaryOrigin"] = {"kind": "current-checkout", "sourceSHA": source_sha}
    destination = root / "receipt.json"
    destination.write_text(json.dumps(receipt, indent=2) + "\n")
    receipt["before"] = inventory(root, "before")
    with (root / "events.jsonl").open("wb") as log, (root / "stderr.log").open("wb") as errors:
        process = subprocess.Popen([str(binary)], stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=errors, start_new_session=True)
        receipt["pid"] = process.pid
        deadline = time.monotonic() + 45
        try:
            while True:
                status = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                if (status is not None and status.si_pid == process.pid
                        and status.si_code in (os.CLD_EXITED, os.CLD_KILLED, os.CLD_DUMPED)):
                    receipt["kernelExit"] = {"code": status.si_code, "status": status.si_status}
                    break
                if time.monotonic() >= deadline:
                    receipt["timedOut"] = True
                    break
                time.sleep(.01)
        finally:
            finish_process(process, receipt, root, destination)
    try:
        complete = cases_complete(read_records(root))
    except (OSError, ValueError) as error:
        complete = False
        receipt["caseEvidenceError"] = type(error).__name__
    receipt["completed"] = completed(receipt, complete)
    destination.write_text(json.dumps(receipt, indent=2) + "\n")
    return 0 if receipt["completed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
