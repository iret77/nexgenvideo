"""Exercise the native approval-reset confirmation, real restart and Recovery open."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid
from urllib.parse import unquote, urlparse

from settings_owner_acceptance import pack_metadata


def file_url(value):
    parsed = urlparse(value)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
        raise AssertionError("The native saved state contains a nonlocal URL")
    return Path(unquote(parsed.path))


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def owned_process_alive(pid, executable, owner):
    result = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "state=", "-o", "command="],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5, check=False)
    fields = result.stdout.strip().split(maxsplit=1)
    if result.returncode or len(fields) != 2 or fields[0].startswith("Z"):
        return False
    return str(executable) in fields[1] and "--ngv-pack-recovery-owner=" + owner in fields[1]


def owned_process_ids(executable, owner):
    result = subprocess.run(["/bin/ps", "-ww", "-axo", "pid=,command="], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=5, check=True)
    observed = set()
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if (len(fields) == 2 and str(executable) in fields[1]
                and "--ngv-pack-recovery-owner=" + owner in fields[1]):
            observed.add(int(fields[0]))
    return observed


def cleanup_owned(output, process, executable, owner):
    pids = {process.pid}
    for role in ("initial", "reopener", "resumed"):
        path = output / ("pack-recovery-process-" + role + ".json")
        if path.exists():
            record = json.loads(path.read_text())
            if record.get("owner") == owner:
                pids.add(int(record["pid"]))
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        pids.update(owned_process_ids(executable, owner))
        for pid in pids:
            if owned_process_alive(pid, executable, owner):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        time.sleep(0.1)
    pids.update(owned_process_ids(executable, owner))
    for pid in pids:
        if owned_process_alive(pid, executable, owner):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        raise RuntimeError("The owned native Recovery process did not stop")


def validate(output):
    result = json.loads((output / "pack-recovery-result.json").read_text())
    state = json.loads((output / "pack-recovery-state.json").read_text())
    if result["initialPID"] != state["initialPID"] or result["resumedPID"] == state["initialPID"]:
        raise AssertionError("A real new process did not resume the upgrade")
    if result.get("requestedSelectionRetained") is not True:
        raise AssertionError("The loaded target selection was cleared while consuming the project-open intent")
    saved = file_url(state["projectURL"])
    recovery = Path(result["recoveryURL"])
    if saved == recovery or not saved.is_relative_to(output) or not recovery.is_relative_to(output / "isolated-user"):
        raise AssertionError("The actual Recovery or saved project escaped isolation")
    for item in state["savedFiles"]:
        if digest(saved / item["path"]) != item["sha256"]:
            raise AssertionError("The native restart changed saved bytes: " + item["path"])
    saved_paths = {str(path.relative_to(saved)) for path in saved.rglob("*") if path.is_file()}
    if saved_paths != {item["path"] for item in state["savedFiles"]}:
        raise AssertionError("The native upgrade changed the saved package inventory")
    archived = recovery / "pipeline/migration-history" / result["historyFingerprint"]
    history = json.loads((archived / "manifest.v1.json").read_text())
    if history.get("completed") is not True or history.get("retainedStartupPhases") != []:
        raise AssertionError("The actual migration adopted unverified approvals")
    original = history["intent"]
    if original["fingerprint"] != result["historyFingerprint"]:
        raise AssertionError("The immutable history binding changed")
    archived_paths = set(original["archivePaths"])
    if not {"ngv.json", "pipeline/brief.yaml", "pipeline/treatment/v4.md"}.issubset(archived_paths):
        raise AssertionError("Canonical legacy planning history was not archived")
    replaceable = {"ngv.json", "pipeline/gates.yaml", "pipeline/lineage.json"}
    for item in original["files"]:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise AssertionError("An archived reference escaped its Recovery namespace")
        if item["path"] in archived_paths:
            if digest(archived / relative) != item["sha256"]:
                raise AssertionError("Archived exact bytes changed: " + item["path"])
        elif item["path"] not in replaceable and digest(recovery / relative) != item["sha256"]:
            raise AssertionError("Retained original media or timeline bytes changed: " + item["path"])
    source, target = state["source"], state["target"]
    for path, binding in ((saved, source), (recovery, target)):
        settings = json.loads((path / "ngv.json").read_text())
        if (settings.get("activePlugin"), settings.get("activePluginVersion"), settings.get("activePluginProjectSchema")) != (
                binding["id"], binding["version"], binding["projectSchema"]):
            raise AssertionError("The real saved/Recovery version binding is incorrect")
    gates = (recovery / "pipeline/gates.yaml").read_text()
    approvals = re.findall(r"^\s+approved:\s*(true|false)\s*$", gates, re.MULTILINE)
    if len(approvals) != 14 or any(value != "false" for value in approvals):
        raise AssertionError("The actual V2 gates did not all reset")
    namespace = json.loads((recovery / "pipeline/production-output-namespace.v1.json").read_text())
    if (namespace["sourceFingerprint"] != original["fingerprint"] or namespace["id"] != original["namespaceID"]
            or "pipeline/frames/Retained original still.png" not in namespace["protectedPaths"]):
        raise AssertionError("The actual output namespace lost retained-image protection")
    before = json.loads((output / "pack-recovery-before-restart.json").read_text())
    after = json.loads((output / "pack-recovery-after-restart.json").read_text())
    if before.get("failure") is not None or after.get("failure") is not None:
        raise AssertionError("A native interaction failed")
    pointers = [item for item in before["interactions"] if item.get("kind") == "pointer"]
    if sum(item["id"] == "settings.pack.apply." + source["id"] for item in pointers) != 3:
        raise AssertionError("Cancel, stale refusal and real restart were not all entered through the actual control")
    dialogs = [item["evidence"]["title"] for item in before["interactions"]
               if item.get("kind") == "verified-state" and item.get("label") == "native-dialog-pointer"]
    if dialogs.count("Cancel") != 1 or dialogs.count("Upgrade and Restart") != 2 or "OK" not in dialogs:
        raise AssertionError("The native decisions were not actually delivered")
    screenshots = before["screenshots"] + after["screenshots"]
    if len(before["screenshots"]) < 4 or not after["screenshots"] or len(set(screenshots)) != len(screenshots):
        raise AssertionError("Distinct native confirmation and Recovery screenshots are missing")
    for name in screenshots:
        if Path(name).name != name or (output / name).read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise AssertionError("A genuine native screenshot is missing")
    return {"schema": "validated-native-pack-recovery/v1", "initialPID": result["initialPID"], "resumedPID": result["resumedPID"],
            "historyFingerprint": original["fingerprint"], "savedFilesVerified": len(state["savedFiles"]),
            "archivedFilesVerified": len(archived_paths), "providerCalls": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-pack-zip", type=Path, required=True)
    parser.add_argument("--target-pack-zip", type=Path, required=True)
    args = parser.parse_args()
    baseline, target = pack_metadata(args.baseline_pack_zip), pack_metadata(args.target_pack_zip)
    if baseline["id"] != target["id"] or target["id"] != "musicvideo" or target["projectSchema"] != "musicvideo/3.0.0":
        raise ValueError("Supply the actual legacy Musicvideo ZIP and current V2 Musicvideo ZIP")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    home = output / "isolated-user"
    home.mkdir()
    manifest = output / "pack-fixtures.json"
    manifest.write_text(json.dumps({"id": baseline["id"], "displayName": baseline["displayName"],
                                   "baseline": baseline, "target": target}, indent=2))
    safe_keys = {"PATH", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING", "DISPLAY", "TERM"}
    env = {key: value for key, value in os.environ.items() if key in safe_keys}
    env.update({"CFFIXED_USER_HOME": str(home), "NGV_PACK_RECOVERY_ACCEPTANCE": "1",
                "NGV_WORKSPACE_UI_ACCEPTANCE": "1", "NGV_PACK_RECOVERY_EVIDENCE": str(output),
                "NGV_SETTINGS_PACK_FIXTURE": str(manifest)})
    deadline = time.monotonic() + 360
    owner = str(uuid.uuid4())
    executable = args.executable.resolve(strict=True)
    with (output / "pack-recovery.log").open("w") as log:
        process = subprocess.Popen([str(executable), "--ngv-pack-recovery-owner=" + owner,
                                    "-ApplePersistenceIgnoreState", "YES"],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        try:
            returncode = process.wait(timeout=360)
            if returncode:
                failure = output / "pack-recovery-failure.txt"
                detail = failure.read_text() if failure.exists() else "No native failure detail was written"
                raise RuntimeError("The actual initial native pack-upgrade process failed: " + detail)
            while time.monotonic() < deadline:
                if (output / "pack-recovery-failure.txt").exists():
                    raise RuntimeError((output / "pack-recovery-failure.txt").read_text())
                if (output / "pack-recovery-result.json").exists():
                    break
                time.sleep(0.1)
            else:
                raise TimeoutError("No actual Recovery result followed the real process restart")
            resumed = json.loads((output / "pack-recovery-result.json").read_text())["resumedPID"]
            resumed_process = json.loads((output / "pack-recovery-process-resumed.json").read_text())
            reopener_process = json.loads((output / "pack-recovery-process-reopener.json").read_text())
            if (resumed_process.get("owner") != owner or reopener_process.get("owner") != owner
                    or resumed_process["pid"] != resumed or reopener_process["pid"] != resumed):
                raise AssertionError("The actual executable reopener did not become the reported resumed process")
            while time.monotonic() < deadline and owned_process_alive(resumed, executable, owner):
                time.sleep(0.1)
            if owned_process_alive(resumed, executable, owner):
                raise TimeoutError("The actual resumed Recovery process did not exit before validation")
            result = validate(output)
            (output / "pack-recovery-validation.json").write_text(json.dumps(result, indent=2))
        finally:
            cleanup_owned(output, process, executable, owner)


if __name__ == "__main__":
    main()
