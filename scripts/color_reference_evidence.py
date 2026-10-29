"""Independent byte and chronology checks for the isolated native color case, not AI quality."""
import base64
import copy
import hashlib
import json
import math
from pathlib import Path
from uuid import UUID


def validate(directory):
    try:
        return _validate(Path(directory).resolve())
    except (KeyError, IndexError, TypeError, AttributeError, StopIteration, UnicodeError, OverflowError) as error:
        raise ValueError("Malformed native color evidence") from error


def _validate(root):
    def read(name):
        if not isinstance(name, str) or not name or Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError("Invalid color evidence path")
        path = root
        for part in Path(name).parts:
            path /= part
            if path.is_symlink():
                raise ValueError("Symlinked color evidence")
        path.resolve().relative_to(root)
        if not path.is_file():
            raise ValueError("Missing actual color evidence")
        return path.read_bytes()

    def sha(data):
        return hashlib.sha256(data).hexdigest()

    def artifact(ref, path_key="path", hash_key="sha256"):
        data = read(ref[path_key])
        if sha(data) != ref[hash_key]:
            raise ValueError("Actual color evidence bytes changed")
        return json.loads(data)

    def uuid(value):
        if not isinstance(value, str):
            raise ValueError("Missing native comparison or turn identity")
        return str(UUID(value))

    result = json.loads(read("color-reference-result.json"))
    if (result.get("viewport") != [960, 640] or type(result.get("scale")) not in (int, float) or result.get("scale") not in (1, 1.25, 1.5)
        or result.get("nativeReferenceImport") is not True
        or sha(read("Cool comparison reference.mov")) != result.get("referenceSHA256")):
        raise ValueError("The native comparison lacks its actual imported reference or viewport")
    for key in ("nativeMeasuredComparison", "actualToolReadout", "nativeProposalDiscard", "nativeProposalApply",
                "nativeUndoRedo", "nativeStaleRefusal", "sourceProjectPreserved"):
        if result.get(key) is not True:
            raise ValueError("Missing color owner observation: " + key)
    if result.get("liveAgent") is not False or type(result.get("directMutationRefusals")) is not int or result["directMutationRefusals"] != 3:
        raise ValueError("Unproved AI availability or missing actual mutation refusals")
    actions = result["interactions"]
    if result["progress"] != "native-color-reference.json":
        raise ValueError("The native color driver progress path was substituted")
    if len(result["screenshots"]) != len(set(result["screenshots"])):
        raise ValueError("Repeated native color screenshot paths")
    progress = json.loads(read(result["progress"]))
    if progress.get("schema") != "native-visual-source-progress/v1" or "failure" not in progress or progress["failure"] is not None or progress["interactions"] != actions or progress["screenshots"] != result["screenshots"]:
        raise ValueError("The driver output differs from the returned owner evidence")
    cursor = -1
    strict_actions = False
    action_kinds = {"pointer", "native-pointer", "modified-pointer", "keyboard", "text", "drag", "cross-view-drag",
                    "menu", "context-menu", "segment-accessibility", "file-panel", "file-panel-cancel", "save-panel"}

    def consume(predicate, allow_correction_disclosure=False):
        nonlocal cursor
        disclosed = False
        for index in range(cursor + 1, len(actions)):
            row = actions[index]
            if predicate(row):
                cursor = index
                return row
            if (allow_correction_disclosure and not disclosed and row.get("kind") == "pointer"
                and row.get("id") == "inspector.section.Basic Correction"):
                disclosed = True
                continue
            if strict_actions and row.get("kind") in action_kinds:
                raise ValueError("Unexpected native color action between its observations")
        raise ValueError("Missing or reordered native color action")

    def click(identifier, allow_correction_disclosure=False):
        return consume(lambda row: row.get("kind") == "pointer" and row.get("id") == identifier,
                       allow_correction_disclosure=allow_correction_disclosure)

    def state(label):
        return consume(lambda row: row.get("kind") == "verified-state" and row.get("label") == label)["evidence"]

    def timeline(stage):
        expected = result["timelines"][stage]
        observed = state("native color timeline")
        if observed != {"stage": stage, "artifact": expected}:
            raise ValueError("The actual timeline was not captured after its native action")
        return artifact(expected)

    captured_paths = set()

    def capture(stage):
        evidence = state("native color capture")
        if evidence["stage"] != stage or evidence["path"] not in result["screenshots"]:
            raise ValueError("The native screenshot belongs to another stage")
        if evidence["path"] in captured_paths:
            raise ValueError("The native color screenshot was reused for another stage")
        captured_paths.add(evidence["path"])
        data = read(evidence["path"])
        if not data.startswith(b"\x89PNG\r\n\x1a\n") or sha(data) != evidence["sha256"]:
            raise ValueError("The actual native color screenshot changed")

    consume(lambda row: row.get("kind") == "file-panel" and row.get("path") == "Cool comparison reference.mov"
            and row.get("selectedURLVerified") is True and row.get("nativePathEditorVerified") is True)
    click("color.reference.open")
    strict_actions = True
    click("color.reference.choose"); click("library.pick." + result["referenceID"])
    before = timeline("before")
    measurements = result["measurements"]
    if len(measurements) != 3:
        raise ValueError("All three actual measurements must be retained")
    ids, turns, sessions, mutation_ids = set(), set(), set(), set()

    def measurement(index):
        click("color.reference.measure")
        observed = state("actual native color measurement")
        if observed != measurements[index]:
            raise ValueError("The visible native measurement differs from its retained artifact")
        identity = uuid(observed["comparisonID"])
        if identity in ids:
            raise ValueError("A previous comparison was reused")
        ids.add(identity)
        if observed["toolPath"] != f"actual-color-tool-{index + 1}.json":
            raise ValueError("The measurement artifact was overwritten")
        blocks = artifact(observed, "toolPath", "toolSHA256")
        texts = [row["text"] for row in blocks if row.get("kind") == "text"]
        measured = json.loads(texts[-1])
        images = [row for row in blocks if row.get("kind") == "image"]
        if len(images) != 2 or any(row["mediaType"] != "image/jpeg" for row in images):
            raise ValueError("The independent measurement lost its actual JPEG frames")
        actual_hashes = [sha(base64.b64decode(row["base64"], validate=True)) for row in images]
        if actual_hashes != [observed["toolClipImageSHA256"], observed["toolReferenceImageSHA256"]] \
                or actual_hashes != [observed["clipImageSHA256"], observed["referenceImageSHA256"]]:
            raise ValueError("The displayed frame hashes differ from the actual tool frames")
        for name, expected in measured_rows(measured).items():
            values = [float(value) for value in observed[name].split("|")]
            if any(not math.isfinite(value) for value in values) or values != expected:
                raise ValueError("The native readout changed actual measured values: " + name)
        return observed, measured

    def proposal(index, observation, measured):
        click("color.reference.propose")
        observed = state("actual native color proposal")
        if (observed["comparisonID"] != observation["comparisonID"]
            or observed["requestPath"] != f"actual-color-request-{index + 1}.json"
            or observed["proposalPath"] != f"actual-color-proposal-{index + 1}.json"):
            raise ValueError("The proposal did not bind the fresh native comparison")
        request = artifact(observed, "requestPath", "requestSHA256")
        proposed = artifact(observed, "proposalPath", "proposalSHA256")
        expected = {"comparisonID": observation["comparisonID"], "clipID": result["clipID"], "referenceID": result["referenceID"]}
        if request["scope"] != expected or any(proposed[key] != value for key, value in expected.items()):
            raise ValueError("The proposal targeted another comparison, clip, or reference")
        session, turn = uuid(request["sessionID"]), uuid(request["turnID"])
        if turn in turns:
            raise ValueError("A previous model turn was reused")
        turns.add(turn); sessions.add(session)
        try:
            attempt = request["mutationAttempt"]
            call_id = uuid(attempt["toolUseID"])
            if (call_id in mutation_ids or attempt["toolName"] != "apply_color"
                or attempt["arguments"] != {"clipIds": [result["clipID"]], "exposure": 2}
                or attempt["isError"] is not True
                or not any(row.get("kind") == "text" and "color-comparison turn" in row.get("text", "") for row in attempt["content"])):
                raise ValueError("The actual mutation attempt was not refused for this comparison")
            mutation_ids.add(call_id)
        except (KeyError, TypeError, ValueError, AttributeError) as error:
            raise ValueError("The actual mutation attempt is missing, reused, or not this refusal") from error
        if (proposed["grade"] != {"exposure": 0.5} or not proposed["rationale"]
            or not isinstance(observed["visibleExposure"], str) or float(observed["visibleExposure"]) != proposed["grade"]["exposure"]):
            raise ValueError("The isolated response did not exercise the reviewed exposure")
        if len(request["images"]) != 2 or len(request["imageSHA256"]) != 2:
            raise ValueError("The actual model request lost its ordered frames")
        if request["imageSHA256"] != [observation["clipImageSHA256"], observation["referenceImageSHA256"]]:
            raise ValueError("The request images differ from the actual displayed snapshot frames")
        for image, digest in zip(request["images"], request["imageSHA256"]):
            if image["mediaType"] != "image/jpeg" or sha(base64.b64decode(image["base64"], validate=True)) != digest:
                raise ValueError("The original request image bytes changed")
        measured_json = request["measurementsJSON"]
        marker = "Actual inspect_color measurements:\n"
        actual_json = request["text"].split(marker, 1)[1].split("\nAttached images", 1)[0]
        scope_json = request["text"].split("Native comparison scope: ", 1)[1].split("\n", 1)[0]
        if actual_json != measured_json or json.loads(scope_json) != expected or json.loads(measured_json) != measured:
            raise ValueError("The model request lost the native measured values or scope")

    observed, measured = measurement(0)
    capture("measured-frame-clip"); capture("measured-frame-reference"); capture("measured")
    proposal(0, observed, measured); capture("proposal")
    click("color.reference.discard")
    discarded = state("native color discard")
    if (discarded.get("comparisonID") != observed["comparisonID"]
        or any(discarded.get(key) is not True for key in ("proposalAbsent", "comparisonAbsent", "applyAbsent", "proposeAbsent"))
        or discarded.get("status") != "Color proposal discarded. Measure again for a new comparison."):
        raise ValueError("Discard did not visibly clear the comparison and proposal")
    if timeline("discarded") != before:
        raise ValueError("Discard changed the timeline")
    observed, measured = measurement(1); proposal(1, observed, measured)
    click("color.reference.apply")
    applied = timeline("applied")
    require_exposure_change(before, applied, result["clipID"], 0.5)
    capture("applied")
    for stage, expected, modifiers in (("undone", before, 1 << 20), ("redone", applied, (1 << 20) | (1 << 17)), ("restored", before, 1 << 20)):
        consume(lambda row: row.get("kind") == "keyboard" and row.get("code") == 6 and row.get("modifiers") == modifiers)
        if timeline(stage) != expected:
            raise ValueError("Native Undo/Redo did not restore the exact timeline")
    observed, measured = measurement(2); proposal(2, observed, measured)
    click("inspector.adjust.value.color.exposure.ev", allow_correction_disclosure=True)
    consume(lambda row: row.get("kind") == "text" and row.get("field", {}).get("id") == "inspector.adjust.value.color.exposure.ev"
            and row["field"].get("actual") == row["field"].get("expected") == "0.37"
            and row["field"].get("focusLeftTarget") is True)
    stale = timeline("stale-before")
    require_exposure_change(before, stale, result["clipID"], 0.37)
    click("color.reference.apply")
    if timeline("stale-after") != stale:
        raise ValueError("Stale Apply changed the independently edited timeline")
    capture("stale-refusal")
    if any(row.get("kind") in action_kinds for row in actions[cursor + 1:]):
        raise ValueError("Unexpected native color action after its observations")
    if len(sessions) != 1 or len(result["screenshots"]) < 6:
        raise ValueError("The actual native case lost its session or screenshots")
    return result


def measured_rows(value):
    clip, reference, gap = value["clip"], value["reference"], value["gap"]
    return {
        "mean": [clip["luma"]["mean"], reference["luma"]["mean"], gap["lumaMean"]],
        "black": [clip["luma"]["black"], reference["luma"]["black"], gap["lumaBlack"]],
        "white": [clip["luma"]["white"], reference["luma"]["white"], gap["lumaWhite"]],
        "saturation": [clip["saturation"], reference["saturation"], gap["saturation"]],
        "warmCool": [clip["balance"]["warmCool"], reference["balance"]["warmCool"], gap["warmCool"]],
        "greenMagenta": [clip["balance"]["greenMagenta"], reference["balance"]["greenMagenta"], gap["greenMagenta"]],
        "clipping": [clip["luma"]["clipLowPct"], clip["luma"]["clipHighPct"], reference["luma"]["clipLowPct"], reference["luma"]["clipHighPct"]],
    }


def require_exposure_change(before, after, clip_id, value):
    locations = [(ti, ci) for ti, track in enumerate(before["tracks"]) for ci, clip in enumerate(track["clips"]) if clip["id"] == clip_id]
    if len(locations) != 1:
        raise ValueError("The reviewed color target is not unique")
    ti, ci = locations[0]
    original, changed = before["tracks"][ti]["clips"][ci], after["tracks"][ti]["clips"][ci]
    old_effects, effects = original.get("effects") or [], changed.get("effects") or []
    old = [row for row in old_effects if row["type"] == "color.exposure"]
    exposure = [row for row in effects if row["type"] == "color.exposure"]
    if len(old) > 1 or len(exposure) != 1 or exposure[0]["params"].get("ev") != {"value": value}:
        raise ValueError("The applied exposure differs from the proposal")
    if [row for row in old_effects if row["type"] != "color.exposure"] != [row for row in effects if row["type"] != "color.exposure"]:
        raise ValueError("The color decision changed another effect")
    expected = copy.deepcopy(exposure[0])
    if old:
        if effects.index(exposure[0]) != old_effects.index(old[0]):
            raise ValueError("The color decision moved the existing exposure in the stack")
        if "ev" in old[0]["params"]:
            expected["params"]["ev"] = old[0]["params"]["ev"]
        else:
            expected["params"].pop("ev", None)
        if expected != old[0]:
            raise ValueError("The color decision changed another exposure property")
    elif exposure[0]["enabled"] is not True or exposure[0]["params"] != {"ev": {"value": value}}:
        raise ValueError("The added exposure differs from the reviewed control")
    else:
        UUID(exposure[0]["id"])
        if effects.index(exposure[0]) != 0:
            raise ValueError("The new exposure is not at its canonical stack position")
    normalized = copy.deepcopy(after)
    if "effects" in original:
        normalized["tracks"][ti]["clips"][ci]["effects"] = original["effects"]
    else:
        normalized["tracks"][ti]["clips"][ci].pop("effects", None)
    if normalized != before:
        raise ValueError("The color decision changed another clip or property")
