"""Portable FilmFlow bytes and native adoption; SDK observations are not archived wire proof."""
from collections import Counter
import json
import math
from pathlib import Path
import re
import uuid

from production_technical_owner_evidence import digest, read, states
from production_cover_owner_evidence import raster

RESOURCE = "https://app.filmflow.pro/api/mcp"
SHOT = "get_shotlist#/scenes/0/shots/0"
MISSING = "list_entities#/1/referenceImageUrl"
CAPTURES = {"cancelled-read", "missing-image-blocks-accept", "planning-notes-before-accept", "explicit-native-identity",
            "script-mapping", "duration-refused", "sketch-mapping", "stale-source-refused", "camera-mapping", "offline-reopened"}


def sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def fields(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= set(value) or set(value) - set(required) - set(optional):
        raise ValueError("Unsupported or incomplete portable DTO")


def portable_dtos(root, snapshot):
    values = {}
    for response in snapshot["responses"]:
        tool = response["tool"]
        if tool in values or response["portablePath"] != "dto/" + tool + ".json": raise ValueError("Duplicate tool")
        raw = read(root, response["portablePath"])
        if digest(raw) != response["portableDTOSHA256"] or digest(read(root, "schemas/" + tool + ".json")) != response["toolSchemaSHA256"]:
            raise ValueError("Changed portable response or schema")
        args = json.dumps({"projectId": snapshot["project"]["projectId"]}, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        if response["argumentsSHA256"] != digest(args) or response["sourceObservationEncoding"] != "sdk-decoded-text-utf8" or not sha(response["sourceObservationUTF8SHA256"]) or type(response["sourceObservationUTF8Count"]) is not int or response["sourceObservationUTF8Count"] <= 0:
            raise ValueError("Invalid SDK text observation")
        if response["omissions"] != sorted(set(response["omissions"])): raise ValueError("Duplicate omissions")
        values[tool] = json.loads(raw)
    if set(values) != {"get_project", "list_scenes", "get_shotlist", "list_entities"}: raise ValueError("Incomplete read set")
    project = values["get_project"]
    fields(project, {"projectId", "title", "phase", "state", "role", "aspectRatio", "sketchStyle", "shotNumberingScheme", "counts"},
           {"styleBible", "documentLanguage", "activeScriptVersion"})
    if project["projectId"] != snapshot["project"]["projectId"]: raise ValueError("Different project")
    fields(project["counts"], {"scenes", "shots", "entities"})
    fields(project["activeScriptVersion"], {"versionNumber", "label", "state"})
    for scene in values["list_scenes"]:
        fields(scene, {"sceneNumber", "heading", "shotCount"}, {"intExt", "timeOfDay", "shortTitle", "pageStart", "pageEnd"})
        if not isinstance(scene["sceneNumber"], str): raise ValueError("Lost producer scene string")
    shotlist = values["get_shotlist"]
    fields(shotlist, {"project", "scriptVersion", "scenes"})
    fields(shotlist["project"], {"title", "shotNumberingScheme", "aspectRatio", "sketchStyle"})
    if shotlist["scriptVersion"] != project["activeScriptVersion"]: raise ValueError("Different active Script")
    for scene in shotlist["scenes"]:
        fields(scene, {"sceneNumber", "heading", "shots"}, {"intExt", "timeOfDay"})
        for shot in scene["shots"]:
            fields(shot, {"shotLabel", "shotType", "camera", "lighting", "staging", "charactersInFrame"}, {"variant", "description", "durationSeconds", "targetEntity"})
            fields(shot["camera"], set(), {"move", "moveIntensity", "moveNotes", "lensMm", "height", "angle", "support", "framingNotes"})
            fields(shot["lighting"], set(), {"mood", "complexity", "notes"})
            fields(shot["staging"], set(), {"intent", "notes"})
            if "targetEntity" in shot: fields(shot["targetEntity"], {"name", "type"})
    for entity in values["list_entities"]:
        fields(entity, {"name", "type", "aliases", "isConfirmed"}, {"visualDescription", "notes"})
    return values


def validate(value, output, scale):
    try:
        if (value["schema"] != "ngv.filmflow-owner.v1" or value["scale"] != scale or value["effectiveScale"] != scale
            or scale not in (1, 1.25, 1.5) or value["viewport"] != {"width": 960, "height": 640}
            or type(value["backingScale"]) not in (int, float) or not math.isfinite(value["backingScale"]) or value["backingScale"] <= 0
            or value["liveOAuth"] is not False or value["isolatedSDKTransport"] is not True): return False
        folder = Path(output) / ("filmflow-owner-" + str(round(scale * 100)))
        inventory = value["files"]
        actual = {str(p.relative_to(folder)) for p in folder.rglob("*") if p.is_file() and str(p.relative_to(folder)) != "result.json"}
        if not inventory or set(inventory) != actual or any(not sha(s) or digest(read(folder, p)) != s for p, s in inventory.items()): return False
        stored = json.loads(read(folder, "result.json"))
        if any(value.get(key) != item for key, item in stored.items()) or set(stored) != set(value) - {"event", "os"}: return False
        sid = str(uuid.UUID(value["snapshotID"]))
        if value["snapshotID"] != sid: return False
        snapshot_bytes = read(folder, "snapshot/snapshot.v1.json")
        snapshot = json.loads(snapshot_bytes)
        if (digest(snapshot_bytes) != value["snapshotSHA256"] or snapshot["id"].lower() != sid
            or snapshot["schema"] != "ngv.filmflow-snapshot.v1" or snapshot["resource"] != RESOURCE
            or snapshot["noActiveScript"] is not False or snapshot["startedAt"] > snapshot["finishedAt"]): return False
        dto = portable_dtos(folder / "snapshot", snapshot)
        image = snapshot["images"]
        if len(image) != 1: return False
        image = image[0]; raw_image = read(folder, "snapshot/" + image["path"])
        if (image["sha256"] != digest(raw_image) or image["id"] != image["sha256"] or image["byteCount"] != len(raw_image)
            or (image["width"], image["height"], image["contentType"]) != (320, 180, "public.png")
            or set(image["pointers"]) != {SHOT + "/storyboardImageUrl", "list_entities#/0/referenceImageUrl"}
            or read(folder, "source.png") != raw_image or raster(raw_image)[0:2] != (320, 180) or raster(raw_image)[3] < 2): return False
        if [m["pointer"] for m in snapshot["missingImages"]] != [MISSING] or not snapshot["missingImages"][0]["reason"]: return False
        if sorted(p for r in snapshot["responses"] for p in r["imagePointers"]) != sorted(image["pointers"] + [MISSING]): return False
        if "/unknownSecretURL" not in next(r for r in snapshot["responses"] if r["tool"] == "get_project")["omissions"]: return False
        expected_snapshot_files = {"snapshot.v1.json", image["path"]} | {r["portablePath"] for r in snapshot["responses"]} | {"schemas/" + r["tool"] + ".json" for r in snapshot["responses"]}
        if {p.removeprefix("snapshot/") for p in inventory if p.startswith("snapshot/")} != expected_snapshot_files: return False
        accepted = json.loads(read(folder, "adoptions/" + sid + "/accepted.json"))
        if accepted["snapshotSHA256"] != value["snapshotSHA256"] or accepted["omittedImagePointers"] != [MISSING]: return False
        if read(folder, "gates-before.yaml") != read(folder, "gates-after.yaml"): return False
        if read(folder, "lineage-before.json") != read(folder, "lineage-after.json"): return False
        rows = value["native"]["interactions"]
        progress = json.loads(read(output, value["native"]["progress"]))
        if progress["interactions"] != rows or progress["screenshots"] != value["native"]["screenshots"] or progress.get("failure") is not None: return False
        pointers = Counter(r.get("id") for r in rows if r.get("kind") == "pointer")
        required = {"filmflow.connect": 1, "filmflow.cancel-operation": 1, "filmflow.download": 2, "filmflow.accept": 1,
                    "filmflow.omit." + MISSING: 1, "filmflow.notes.apply": 1, "filmflow.identity.confirm": 1,
                    "filmflow.identity.apply": 1, "filmflow.script.apply": 1, "filmflow.duration.apply": 1,
                    "filmflow.sketch.apply": 1, "filmflow.camera.apply": 2}
        if any(pointers[k] != n for k, n in required.items()): return False
        menus = states(rows, "application-menu")
        if sum(v["path"] == ["File", "Import from FilmFlow…"] and v["closed"] is True for v in menus) != 6 or not any(v["path"] == ["File", "Save"] and v["closed"] is True for v in menus): return False
        keys = [r for r in rows if r.get("kind") == "keyboard" and r.get("code") == 6]
        if sum(r["characters"] == "z" and r["modifiers"] == 1048576 for r in keys) != 8 or sum(r["characters"] == "Z" and r["modifiers"] == 1179648 for r in keys) != 5: return False
        typed = [r["field"] for r in rows if r.get("kind") == "text" and r.get("field", {}).get("id") == "filmflow.identity.name"]
        if len(typed) != 1 or typed[0]["actual"] != "Prepared Harbour Keeper" or typed[0]["actual"] != typed[0]["expected"]: return False
        if states(rows, "FilmFlow transport cancellation") != [{"heldReads": 1, "cancelledReads": 1, "retainedCount": 0}]: return False
        calls = value["calls"]
        if Counter((c["tool"], c.get("stage")) for c in calls if "stage" in c) != Counter({("get_project", "held-before-response"): 1, ("get_project", "transport-cancelled"): 1}): return False
        for response in snapshot["responses"]:
            completed = [c["sdkTextUTF8SHA256"] for c in calls if c["tool"] == response["tool"] and "sdkTextUTF8SHA256" in c]
            if completed != [response["sourceObservationUTF8SHA256"]] * (2 if response["tool"] == "get_project" else 1): return False
        if value["offlineReadCallCountBefore"] != value["offlineReadCallCountAfter"] or value["offlineReadCallCountAfter"] != len(calls): return False
        for label in CAPTURES:
            names = [n for n in value["native"]["screenshots"] if n.endswith("-" + label + ".png")]
            if len(names) != 1 or not read(output, names[0]).startswith(b"\x89PNG\r\n\x1a\n"): return False
        def load(name): return json.loads(read(folder, name + ".json"))
        for label in ("notes-undo", "notes-restored"):
            if read(folder, label + ".json") != read(folder, "notes-before.json"): return False
        if read(folder, "notes-redo.json") != read(folder, "notes-applied.json") or load("notes-applied") == load("notes-before"): return False
        if read(folder, "notes-applied.md") != read(folder, "notes-redo.md") or b"A lantern crosses the empty doorway." not in read(folder, "notes-applied.md"): return False
        identity = load("identity-applied")
        if identity["schema"] != "confirmed-identity-assets/v1" or identity != load("identity-redo"): return False
        before_identity = load("identity-before") if "identity-before.json" in inventory else {"entries": {}}
        if load("identity-undo")["entries"] != before_identity["entries"] or len(identity["entries"]) != len(before_identity["entries"]) + 1: return False
        added = [v for k, v in identity["entries"].items() if k not in before_identity["entries"]]
        if len(added) != 1 or added[0]["identity_name"] != "Prepared Harbour Keeper" or added[0]["role"] != "character" or added[0]["sha256"] != image["sha256"]: return False
        script_before, script_after = load("script-before"), load("script-applied")
        if script_before["scenes"] != load("script-undo")["scenes"] or script_after["scenes"] != load("script-redo")["scenes"]: return False
        old = script_before["scenes"][0]["events"][0]; new = script_after["scenes"][0]["events"][0]
        if new["id"] != old["id"] or new["treatmentBeatIDs"] != old["treatmentBeatIDs"] or new.get("dialogue") != old.get("dialogue") or "A lantern crosses the empty doorway." not in new["action"]: return False
        timing = [load("timing-" + suffix) for suffix in ("before", "applied", "undo", "redo")]
        for item in timing[1:]:
            if any(item[k] != timing[0][k] for k in ("timebase", "mode", "rangeStartTicks", "rangeDurationTicks")): return False
        assets = [t["shots"][0]["moments"][0].get("asset") for t in timing]
        if assets[0] is not None or assets[2] is not None or assets[1]["image"]["sha256"] != image["sha256"] or assets[3]["image"]["sha256"] != image["sha256"]: return False
        proof = json.loads(read(folder, "adoption-outputs/" + assets[1]["proof"]["path"]))
        if digest(read(folder, "adoption-outputs/" + assets[1]["proof"]["path"])) != assets[1]["proof"]["sha256"] or set(proof["source"]) != {"uploaded"} or proof["image"]["sha256"] != image["sha256"]: return False
        plan_before, plan_after = load("planning-before"), load("planning-applied")
        if plan_before["shots"] != load("planning-undo")["shots"] or plan_after["shots"] != load("planning-redo")["shots"]: return False
        if plan_before["shots"][1:] != plan_after["shots"][1:]: return False
        before_shot, after_shot = plan_before["shots"][0], plan_after["shots"][0]
        if after_shot["camera"]["movement"] != "pan" or "Track the harbour light" not in after_shot["camera"]["movementDetail"]: return False
        if {k: v for k, v in before_shot.items() if k != "camera"} != {k: v for k, v in after_shot.items() if k != "camera"}: return False
        if {k: v for k, v in before_shot["camera"].items() if k not in ("movement", "movementDetail")} != {k: v for k, v in after_shot["camera"].items() if k not in ("movement", "movementDetail")}: return False
        stale = states(rows, "FilmFlow stale source refused")
        if len(stale) != 1 or not stale[0]["message"] or stale[0]["originalSHA256"] != digest(read(folder, "snapshot/dto/get_shotlist.json")) or stale[0]["changedSHA256"] != digest(read(folder, "stale-source.json")) or stale[0]["originalSHA256"] == stale[0]["changedSHA256"]: return False
        receipts = []
        for name in inventory:
            if name.startswith("adoptions/") and name.endswith(".json"):
                receipt = json.loads(read(folder, name))
                if receipt.get("schema") != "ngv.filmflow-adoption.v1": continue
                if str(uuid.UUID(receipt["id"])) != Path(name).stem or receipt["mapping"]["snapshotID"].lower() != sid or receipt["mapping"]["snapshotSHA256"] != value["snapshotSHA256"]: return False
                for ref in receipt["outputs"]:
                    if value["adoptionOutputs"].get(ref["path"]) != ref["sha256"] or digest(read(folder, "adoption-outputs/" + ref["path"])) != ref["sha256"] or "current" in Path(ref["path"]).name: return False
                receipts.append(receipt)
        expected = Counter({("brief", "planning-notes", (SHOT,)): 1, ("brief", "list_entities#/0", ("image", "native-identity-confirmation")): 1,
            ("script", SHOT, ("action",)): 1, ("storyboard", SHOT, ("image",)): 1, ("shot_planning", SHOT, ("camera.movementDetail",)): 1})
        if Counter((r["phase"], r["mapping"]["sourceObjectID"], tuple(r["mapping"]["fields"])) for r in receipts) != expected: return False
        script_receipt = next(r for r in receipts if r["phase"] == "script")
        if script_receipt["mapping"]["targetID"] != new["id"] or read(folder, "adoption-outputs/" + script_receipt["outputs"][0]["path"]) != read(folder, "script-applied.json"): return False
        if any(r["projectID"] != identity["project"] for r in receipts): return False
        if next(r for r in receipts if r["phase"] == "storyboard")["mapping"]["targetID"] != timing[1]["shots"][0]["moments"][0]["id"]: return False
        if next(r for r in receipts if r["phase"] == "shot_planning")["mapping"]["targetID"] != after_shot["shotID"]: return False
        for phase, pattern, applied in (("storyboard", r"storyboard/timing-v[1-9][0-9]*\.v1\.json", "timing-applied.json"),
                                        ("shot_planning", r"shot-planning/v[1-9][0-9]*\.v1\.json", "planning-applied.json")):
            receipt = next(r for r in receipts if r["phase"] == phase)
            outputs = [ref for ref in receipt["outputs"] if re.fullmatch(pattern, ref["path"])]
            if len(outputs) != 1 or read(folder, "adoption-outputs/" + outputs[0]["path"]) != read(folder, applied): return False
        if any(digest(read(folder, "adoption-outputs/" + p)) != s for p, s in value["adoptionOutputs"].items()): return False
        persisted = value["persistedFiles"]
        if not persisted or any(digest(read(folder, when + "/" + p)) != s for p, s in persisted.items() for when in ("saved", "reopened")): return False
        archive_prefix = "import/filmflow/" + sid + "/"
        if set(p for p in persisted if p.startswith(archive_prefix)) != {archive_prefix + p for p in expected_snapshot_files}: return False
        if any(read(folder, "saved/" + archive_prefix + p) != read(folder, "snapshot/" + p) for p in expected_snapshot_files): return False
        if json.loads(read(folder, "reopened/shot-planning/current.v1.json"))["shots"] != plan_after["shots"] or value["reopenedSnapshotSHA256"] != value["snapshotSHA256"]: return False
        return True
    except (OSError, ValueError, TypeError, KeyError, IndexError, StopIteration, AttributeError):
        return False


def filmflow_owner_evidence(rows, output, scale):
    candidates = [r for r in rows if r.get("event") == "filmflow-owner" and r.get("scale") == scale]
    completed = [r for r in rows if r.get("event") == "completed"]
    if (len(candidates) != 1 or len(completed) != 1 or completed[0].get("case") != "filmflow" or completed[0].get("scale") != scale
        or any(r.get("event") == "failed" for r in rows) or not validate(candidates[0], Path(output), scale)): return False, []
    return True, candidates[0]["native"]["screenshots"]
