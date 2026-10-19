"""Exercise the native approval-reset confirmation, real restart and Recovery open."""
import argparse
import hashlib
import json
import math
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


def require_composer_typography(record, label, scale):
    try:
        rows = record["interactions"]
        matches = lambda name: [(i, r["evidence"]) for i, r in enumerate(rows)
                                if r.get("kind") == "verified-state" and r.get("label") == name]
        typed, measured, viewport = matches("native Recovery composer input"), matches("rendered typography"), matches(label)
        if len(typed) != 1 or len(measured) != 1 or len(viewport) != 1:
            raise AssertionError("Missing unique actual Recovery composer/typography evidence")
        ti, text = typed[0]; mi, font = measured[0]; vi, view = viewport[0]
        window = text["window"]
        task = "Apply a project change"
        if (not ti < mi < vi or type(window) is not int or window <= 0
                or text.get("id") != "agent.composer.input" or text.get("controlKind") != "text-view"
                or text.get("task") != task
                or not isinstance(text.get("before"), str) or text.get("after") != text["before"] + "R" or text.get("added") != "R"
                or font.get("id") != text["id"] or font.get("controlKind") != "text-view" or font.get("window") != window
                or font.get("baseSize") != 13 or font.get("scale") != scale
                or any(type(v) not in (int, float) or not math.isfinite(v) or abs(v - 13 * scale) >= .5
                       for v in (font.get("pointSize"), view.get("renderedFontPointSize")))
                or abs(font["pointSize"] - view["renderedFontPointSize"]) >= .01):
            raise AssertionError("Recovery typography is not bound to its actual editable composer")
        clicks = [i for i, r in enumerate(rows[:ti]) if r.get("kind") == "pointer"
                  and r.get("id") == text["id"] and r.get("window") == window]
        ends = [i for i, r in enumerate(rows[:ti]) if r.get("kind") == "keyboard" and r.get("window") == window
                and r.get("code") == 125 and type(r.get("modifiers")) is int and r["modifiers"] & (1 << 20)]
        inputs = [i for i, r in enumerate(rows[:ti]) if r.get("kind") == "keyboard" and r.get("window") == window
                  and r.get("code") == 15 and r.get("characters") == "R" and r.get("modifiers") == 0]
        choices = [i for i, r in enumerate(rows[:ti]) if
                   (r.get("kind") == "menu" and r.get("id") == "agent.task.choose" and r.get("item") == task
                    and r.get("closed") is True and any(p.get("kind") == "pointer" and p.get("id") == "agent.task.choose"
                        and p.get("window") == window for p in rows[:i]))
                   or (r.get("kind") == "verified-state" and r.get("label") == "native-pointer"
                       and r.get("evidence", {}).get("target") == "button." + task and r["evidence"].get("window") == window)]
        if (len(choices) != 1 or len(clicks) != 1 or len(ends) != 1 or len(inputs) != 1
                or not choices[0] < clicks[0] < ends[0] < inputs[0] < ti):
            raise AssertionError("Recovery typography has no ordered real native composer input")
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise AssertionError("Malformed actual Recovery composer evidence") from error


def require_saved_draft(record, saved):
    rows = record["interactions"]
    ti, typed = next((i, r["evidence"]) for i, r in enumerate(rows) if r.get("label") == "native Recovery composer input")
    mi = next(i for i, r in enumerate(rows) if r.get("label") == "rendered typography")
    saves = [(i, r["evidence"]) for i, r in enumerate(rows) if r.get("label") == "native Recovery draft saved"]
    menus = [(i, r["evidence"]) for i, r in enumerate(rows) if r.get("label") == "application-menu"
             and r.get("evidence", {}).get("path") == ["File", "Save"]]
    if len(saves) != 1 or len(menus) != 1 or not ti < mi < menus[0][0] < saves[0][0]:
        raise AssertionError("Recovery draft has no actual native Save")
    observed = saves[0][1]
    identifier = observed["sessionID"]
    if str(uuid.UUID(identifier)).upper() != identifier:
        raise AssertionError("Invalid saved composer session")
    session = json.loads((saved / "chat" / (identifier + ".json")).read_bytes())
    if (observed.get("wasEdited") is not True or observed.get("isEdited") is not False
            or observed.get("window") != typed["window"] or menus[0][1].get("window") != typed["window"]
            or session.get("id") != identifier or session.get("draft", {}).get("text") != typed["after"]
            or observed.get("draft") != typed["after"] or session["draft"].get("task", {}).get("title") != typed["task"]):
        raise AssertionError("Recovery Save lost its actual composer draft")
    return identifier


def require_session_edit(record, output, recovery, originals, identifier):
    matches = [r["evidence"] for r in record["interactions"] if r.get("label") == "native Recovery session edit"]
    if len(matches) != 1:
        raise AssertionError("Missing exact native Recovery session edit")
    edit = matches[0]
    path = "chat/" + identifier + ".json"
    typed = next(r["evidence"] for r in record["interactions"] if r.get("label") == "native Recovery composer input")
    before = (output / "pack-recovery-session-before-input.json").read_bytes()
    after = (output / "pack-recovery-session-after-input.json").read_bytes()
    if (edit.get("path") != path or edit.get("sessionID") != identifier
            or edit.get("beforeSHA256") != hashlib.sha256(before).hexdigest()
            or edit.get("afterSHA256") != hashlib.sha256(after).hexdigest()
            or before == after or (recovery / path).read_bytes() != after
            or [v["sha256"] for v in originals if v["path"] == path] != [hashlib.sha256(before).hexdigest()]):
        raise AssertionError("Recovery session edit is not bound to actual restored bytes")
    prior, current = json.loads(before), json.loads(after)
    for session, expected in ((prior, typed["before"]), (current, typed["after"])):
        if session.get("id") != identifier or session.get("draft", {}).get("text") != expected:
            raise AssertionError("Recovery session edit lost its typed draft")
        session.pop("updatedAt", None)
        session["draft"].pop("text")
        task = session["draft"].get("task", {})
        if task.get("title") != typed["task"]:
            raise AssertionError("Recovery session edit lost its native task")
        task.pop("originContext", None)
    if prior != current:
        raise AssertionError("Native composer edit changed unrelated session state")
    return path


def validate(output, expected_scale=1):
    result = json.loads((output / "pack-recovery-result.json").read_text())
    state = json.loads((output / "pack-recovery-state.json").read_text())
    if (expected_scale not in (1, 1.25, 1.5) or state.get("scale") != expected_scale
            or result.get("effectiveScale") != expected_scale or result.get("viewport") != [960, 640]
            or not abs(result.get("renderedFontPointSize", 0) - 13 * expected_scale) < .5):
        raise AssertionError("Recovery resumed at a different native interface scale or viewport")
    for role in ("initial", "resumed"):
        process = json.loads((output / ("pack-recovery-process-" + role + ".json")).read_text())
        try:
            actual_scale = float(process["scaleArgument"])
        except (ValueError, TypeError, KeyError) as error:
            raise AssertionError("Recovery lost its actual process scale argument") from error
        if actual_scale != expected_scale:
            raise AssertionError("Recovery process scale argument differs from requested scale")
    if result["initialPID"] != state["initialPID"] or result["resumedPID"] == state["initialPID"]:
        raise AssertionError("A real new process did not resume the upgrade")
    if result.get("requestedSelectionRetained") is not True:
        raise AssertionError("The loaded target selection was cleared while consuming the project-open intent")
    saved = file_url(state["projectURL"])
    recovery = Path(result["recoveryURL"])
    if saved == recovery or not saved.is_relative_to(output) or not recovery.is_relative_to(output / "isolated-user"):
        raise AssertionError("The actual Recovery or saved project escaped isolation")
    before = json.loads((output / "pack-recovery-before-restart.json").read_text())
    after = json.loads((output / "pack-recovery-after-restart.json").read_text())
    if before.get("failure") is not None or after.get("failure") is not None:
        raise AssertionError("A native interaction failed")
    for record, label in ((before, "native Recovery viewport before restart"), (after, "native Recovery viewport after restart")):
        require_composer_typography(record, label, expected_scale)
    session_id = require_saved_draft(before, saved)
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
    edited_session = require_session_edit(after, output, recovery, original["files"], session_id)
    if edited_session in archived_paths:
        raise AssertionError("The native composer edited an archived session")
    replaceable = {"ngv.json", "pipeline/gates.yaml", "pipeline/lineage.json"}
    for item in original["files"]:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise AssertionError("An archived reference escaped its Recovery namespace")
        if item["path"] in archived_paths:
            if digest(archived / relative) != item["sha256"]:
                raise AssertionError("Archived exact bytes changed: " + item["path"])
        elif item["path"] not in replaceable and item["path"] != edited_session and digest(recovery / relative) != item["sha256"]:
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
    for record, label in ((before, "native Recovery viewport before restart"), (after, "native Recovery viewport after restart")):
        viewports = [item.get("evidence") for item in record["interactions"]
                     if item.get("kind") == "verified-state" and item.get("label") == label]
        if (len(viewports) != 1 or any(viewports[0].get(k) != v for k, v in
                {"scale": expected_scale, "width": 960, "height": 640}.items())
            or not abs(viewports[0].get("renderedFontPointSize", 0) - 13 * expected_scale) < .5):
            raise AssertionError("Missing independently retained before/after native Recovery scale")
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
            "archivedFilesVerified": len(archived_paths), "providerCalls": 0, "scale": expected_scale}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-pack-zip", type=Path, required=True)
    parser.add_argument("--target-pack-zip", type=Path, required=True)
    parser.add_argument("--scale", type=float, choices=(1, 1.25, 1.5), default=1)
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
                "NGV_SETTINGS_PACK_FIXTURE": str(manifest), "NGV_PACK_RECOVERY_SCALE": str(args.scale)})
    deadline = time.monotonic() + 360
    owner = str(uuid.uuid4())
    executable = args.executable.resolve(strict=True)
    with (output / "pack-recovery.log").open("w") as log:
        process = subprocess.Popen([str(executable), "--ngv-pack-recovery-owner=" + owner,
                                    "-ApplePersistenceIgnoreState", "YES", "-interfaceTextScale", str(args.scale)],
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
            result = validate(output, expected_scale=args.scale)
            (output / "pack-recovery-validation.json").write_text(json.dumps(result, indent=2))
        finally:
            cleanup_owned(output, process, executable, owner)


if __name__ == "__main__":
    main()
