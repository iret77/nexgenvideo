"""Join native technical edits to retained canonical bytes and independent JSON semantics."""
import hashlib
import json
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
import re


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(root, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute() or ".." in Path(name).parts:
        raise ValueError("Invalid technical evidence path")
    root = Path(root).resolve()
    path = root / name
    path.resolve().relative_to(root)
    if any(value.is_symlink() for value in [path, *path.parents] if value != root and root in value.parents):
        raise ValueError("Aliased technical evidence")
    return path.read_bytes()


def states(rows, label):
    return [row["evidence"] for row in rows if row.get("kind") == "verified-state" and row.get("label") == label]


def unique_rows(values, key):
    result = {value[key]: value for value in values}
    if len(result) != len(values):
        raise ValueError("Duplicate canonical technical identity")
    return result


def snapshot(root, row, label, shot_id):
    prefix = "technical-" + label + "/"
    if row["directory"] != prefix[:-1] or not re.fullmatch(r"[a-f0-9]{64}", row["fingerprint"]):
        raise ValueError("Invalid technical snapshot identity")
    hashes = row["files"]
    if not hashes or any(not name.startswith(prefix) or digest(read(root, name)) != sha for name, sha in hashes.items()):
        raise ValueError("Changed technical snapshot bytes")
    def load(name):
        if name not in hashes:
            raise ValueError("Unbound technical artifact")
        return json.loads(read(root, name))
    def ref(value):
        name = prefix + value["path"]
        if hashes.get(name) != value["sha256"]:
            raise ValueError("Canonical technical reference is not retained")
        return name
    promotion = load(row["promotion"])
    projection, proposal = load(row["decodedProjection"]), load(row["proposal"])
    if prefix + "gates.yaml" not in hashes:
        raise ValueError("Unbound technical gates")
    revision = row["revision"]
    if (type(revision) is not int or revision < 1 or promotion["schema"] != "shot-planning-promotion/v1"
        or projection["schema"] != "shotlist/v5" or promotion["header"]["revision"] != revision
        or projection["header"]["revision"] != revision or ref(promotion["projection"]) != row["projection"]
        or row["projection"] != prefix + f"shotlist/v{revision}.v5.yaml"):
        raise ValueError("Wrong canonical technical revision")
    references = promotion["header"]["inputs"] + projection["header"]["inputs"]
    references += [promotion[key] for key in ("draft", "timing", "bible", "assetGraph", "projection")]
    for reference in references:
        ref(reference)
    execution_refs = [value for value in references if value["role"] == "core.execution-plan"]
    execution_paths = {ref(value) for value in execution_refs}
    if len(execution_paths) != 1:
        raise ValueError("Ambiguous execution plan")
    execution = load(next(iter(execution_paths)))
    if execution != projection["executionPlan"] or [shot["execution"] for shot in proposal["shots"]] != execution["shots"]:
        raise ValueError("Decoded projection disagrees with actual canonical execution JSON")
    if (proposal["expectedDraftFingerprint"] != promotion["draft"]["sha256"]
        or proposal["expectedAssetGraphFingerprint"] != promotion["assetGraph"]["sha256"]
        or projection["draftReference"] != promotion["draft"] or projection["storyboardReference"] != promotion["timing"]):
        raise ValueError("Technical edit lost its approved source binding")
    plans = {value["execution"]["id"]: value for value in proposal["shots"]}
    if len(plans) != len(proposal["shots"]):
        raise ValueError("Duplicate canonical technical shot")
    boundaries = {identity: planned["endFrameBoundary"] for identity, planned in plans.items() if planned.get("endFrameBoundary") is not None}
    if projection["endFrameBoundaries"] != boundaries:
        raise ValueError("Canonical technical end boundaries differ from their proposal")
    timings = unique_rows(projection["timings"], "shotID")
    if set(plans) != set(timings):
        raise ValueError("Canonical technical timing coverage changed")
    for identity, planned in plans.items():
        timing = timings[identity]
        if (timing.get("nativeDurationTicks") != planned.get("nativeDurationTicks")
            or timing["sourceInTicks"] != planned["sourceInTicks"]
            or any(type(timing[key]) is not int for key in ("sourceInTicks", "startTicks", "durationTicks"))):
            raise ValueError("Canonical technical timing differs from its proposal")
    route_refs = {ref(value) for value in references if value["role"] == "core.production-route"}
    if route_refs != {ref(value["route"]) for value in promotion["routes"]}:
        raise ValueError("Canonical technical route references differ from their bindings")
    routes = unique_rows([load(ref(value["route"])) for value in promotion["routes"]], "shot_id")
    if [value["shotID"] for value in promotion["routes"]] != list(routes):
        raise ValueError("Canonical route identity differs from its binding")
    expected_routes = {identity for identity, planned in plans.items()
                       if planned["execution"].get("generation_requirement", {}).get("modality_id") == "video"}
    if set(routes) != expected_routes:
        raise ValueError("Canonical technical route coverage changed")
    for identity, route in routes.items():
        planned = plans[identity]
        if (route["offering"] != planned["selectedOffering"]
            or route["offering"]["catalog_model_id"] != planned["selectedModelID"]):
            raise ValueError("Canonical technical route differs from its proposal")
    template_refs = {ref(value) for value in references if value["role"] == "core.production-input-template"}
    templates = unique_rows([load(name) for name in template_refs], "shot_id")
    expected_templates = {identity for identity, planned in plans.items() if planned["execution"].get("generation_requirement") is not None}
    if set(templates) != expected_templates:
        raise ValueError("Canonical technical template coverage changed")
    demand_refs = {ref(value) for value in references if value["role"] == "core.planned-reference-demands"}
    demands = unique_rows([load(name) for name in demand_refs], "shot_id")
    if set(demands) != expected_templates:
        raise ValueError("Canonical technical demand coverage changed")
    for identity, template in templates.items():
        if template["core_inputs"] != plans[identity].get("coreInputs", {}):
            raise ValueError("Canonical technical template differs from its proposal")
        if demands[identity]["demands"] != plans[identity]["referenceDemands"]:
            raise ValueError("Canonical technical demands differ from their proposal")
    shot, timing = plans[shot_id], timings[shot_id]
    requirement = shot["execution"]["generation_requirement"]
    candidates = load(prefix + "actual-candidates.json")
    candidate = next(value for value in candidates if value["modelID"] == shot["selectedModelID"] and value["offering"] == shot["selectedOffering"])
    if (type(shot["nativeDurationTicks"]) is not int or type(shot["sourceInTicks"]) is not int
        or shot["sourceInTicks"] < 0 or shot["sourceInTicks"] + timing["durationTicks"] > shot["nativeDurationTicks"]
        or requirement["resolution"] not in candidate["resolutions"]
        or not set(requirement["mode_ids"]).issubset(candidate["modeIDs"])):
        raise ValueError("Technical route, template or range differs from actual canonical proposal")
    return {"proposal": proposal, "projection": projection, "promotion": promotion, "shot": shot,
            "gates": read(root, prefix + "gates.yaml"), "candidate": candidate,
            "routes": routes, "templates": templates, "demands": demands, "timings": timings}


def validate(native, directory, require_conditioning=False):
    try:
        rows = native["interactions"]
        result = states(rows, "native technical Shot settings")
        starts = states(rows, "native technical begin")
        if len(result) != 1 or len(starts) != 1:
            return False
        start = next(i for i, row in enumerate(rows) if row.get("kind") == "verified-state" and row.get("label") == "native technical begin")
        end = next(i for i, row in enumerate(rows) if row.get("kind") == "verified-state" and row.get("label") == "native technical Shot settings")
        if start >= end:
            return False
        scoped = rows[start:end]
        labels_in_scope = {"native technical snapshot", "native technical refusal", "native technical capture"}
        if any(row.get("kind") == "verified-state" and row.get("label") in labels_in_scope
               for i, row in enumerate(rows) if not start <= i < end):
            return False
        result = result[0]
        shot_id = result["shotID"]
        labels = ("before", "cancelled", "applied", "undo", "redo", "restored")
        snapshots = states(scoped, "native technical snapshot")
        if ([value["label"] for value in snapshots] != list(labels)
            or any(value["snapshot"] != result[value["label"]] for value in snapshots)
            or starts[0] != {"shotID": shot_id, "fingerprint": result["before"]["fingerprint"]}):
            return False
        values = {label: snapshot(directory, result[label], label, shot_id) for label in labels}
        before, after = values["before"], values["applied"]
        if result["before"]["fingerprint"] != result["cancelled"]["fingerprint"]:
            return False
        before_files = {name.removeprefix("technical-before/"): sha for name, sha in result["before"]["files"].items()}
        cancelled_files = {name.removeprefix("technical-cancelled/"): sha for name, sha in result["cancelled"]["files"].items()}
        if before_files != cancelled_files:
            return False
        for label in ("cancelled", "undo", "restored"):
            if values[label]["proposal"] != before["proposal"]:
                return False
        if values["redo"]["proposal"] != after["proposal"]:
            return False
        revisions = [result[label]["revision"] for label in ("before", "applied", "undo", "redo", "restored")]
        if revisions != sorted(set(revisions)):
            return False
        for value in values.values():
            if value["gates"] != before["gates"]:
                return False
            for key in ("draft", "timing", "bible", "resolutions"):
                if value["promotion"][key] != before["promotion"][key]:
                    return False
            if any(value["promotion"]["assetGraph"][key] != before["promotion"]["assetGraph"][key] for key in ("id", "role", "sha256")):
                return False
            for key in ("mode", "timebase", "sourceBindings", "sourceInputRanges", "editorialBindings", "chains", "endFrameBoundaries"):
                if value["projection"][key] != before["projection"][key]:
                    return False
            if [(v["shotID"], v["startTicks"], v["durationTicks"]) for v in value["projection"]["timings"]] != [(v["shotID"], v["startTicks"], v["durationTicks"]) for v in before["projection"]["timings"]]:
                return False
            if [v for v in value["proposal"]["shots"] if v["execution"]["id"] != shot_id] != [v for v in before["proposal"]["shots"] if v["execution"]["id"] != shot_id]:
                return False
            for identity in before["timings"]:
                if identity != shot_id and value["timings"][identity] != before["timings"][identity]:
                    return False
            for key in ("routes", "templates"):
                if {identity: row for identity, row in value[key].items() if identity != shot_id} != {identity: row for identity, row in before[key].items() if identity != shot_id}:
                    return False
        old, new = before["shot"], after["shot"]
        old_requirement, new_requirement = old["execution"]["generation_requirement"], new["execution"]["generation_requirement"]
        if ({key: value for key, value in old["execution"].items() if key != "generation_requirement"}
            != {key: value for key, value in new["execution"].items() if key != "generation_requirement"}):
            return False
        if (old["nativeDurationTicks"] == new["nativeDurationTicks"] or old["sourceInTicks"] == new["sourceInTicks"]
            or old_requirement["resolution"] == new_requirement["resolution"]
            or [v["asset_id"] for v in old["referenceDemands"]] != [v["asset_id"] for v in new["referenceDemands"]]
            or (require_conditioning and not (old_requirement["requires_last_frame"] is True and new_requirement["requires_last_frame"] is False
                and new_requirement["requires_first_frame"] is True))):
            return False
        for value in (old, new):
            requirement = value["execution"]["generation_requirement"]
            modes = value["coreInputs"]
            if (requirement["requires_first_frame"] != (modes.get("first_frame_mode_id") is not None)
                or requirement["requires_last_frame"] != (modes.get("last_frame_mode_id") is not None)):
                return False
        failures = states(scoped, "native technical refusal")
        expected = ["duration -1", "duration not a time", "trim 999", "missing model", "missing mode"]
        if [row["input"] for row in failures] != expected or any(row["applyEnabled"] is not False or not row["message"].strip() for row in failures):
            return False
        actions = [row["id"] for row in scoped if row.get("kind") == "pointer" and row.get("id") in ("production.technical.cancel", "production.technical.apply")]
        keys = [row for row in scoped if row.get("kind") == "keyboard" and row.get("code") == 6]
        if actions != ["production.technical.cancel", "production.technical.apply"] or [v["characters"] for v in keys] != ["z", "Z", "z"] or [v["modifiers"] for v in keys] != [1048576, 1179648, 1048576]:
            return False
        menus = {row["id"] for row in scoped if row.get("kind") == "menu" and row.get("closed") is True}
        if not {"production.technical." + key for key in ("model", "mode", "resolution", "conditioning")}.issubset(menus):
            return False
        from production_frames_owner_evidence import visible_group
        if not any(row.get("kind") == "visible-group" and row.get("ids") == ["production.technical.apply", "production.technical.cancel"]
                   and visible_group(row) for row in scoped):
            return False
        text = [row["field"] for row in scoped if row.get("kind") == "text"]
        if any(not any(field.get("id") == "production.technical." + key and field.get("actual") == value
            and field.get("expected") == value and field.get("focusLeftTarget") is True for field in text)
            for key, value in (("duration", "-1"), ("duration", "not a time"), ("trim", "999"))):
            return False
        cancel_index = next(i for i, row in enumerate(scoped) if row.get("kind") == "pointer" and row.get("id") == "production.technical.cancel")
        apply_index = next(i for i, row in enumerate(scoped) if row.get("kind") == "pointer" and row.get("id") == "production.technical.apply")
        snapshot_indices = {row["evidence"]["label"]: i for i, row in enumerate(scoped) if row.get("kind") == "verified-state" and row.get("label") == "native technical snapshot"}
        key_indices = [i for i, row in enumerate(scoped) if row.get("kind") == "keyboard" and row.get("code") == 6]
        ordered = [snapshot_indices["before"], cancel_index, snapshot_indices["cancelled"], apply_index,
                   snapshot_indices["applied"], key_indices[0], snapshot_indices["undo"], key_indices[1],
                   snapshot_indices["redo"], key_indices[2], snapshot_indices["restored"]]
        if ordered != sorted(set(ordered)):
            return False
        captures = [(i, row["evidence"]) for i, row in enumerate(scoped) if row.get("kind") == "verified-state" and row.get("label") == "native technical capture"]
        def captured(label):
            found = [(i, row["screenshot"]) for i, row in captures if row["label"] == label]
            if len(found) != 1:
                raise ValueError("Missing timed technical capture")
            i, image = found[0]
            name = image["path"]
            raw = read(directory, name)
            if (native["screenshots"].count(name) != 1 or not name.endswith("-" + label + ".png")
                or digest(raw) != image["sha256"] or not raw.startswith(b"\x89PNG\r\n\x1a\n")):
                raise ValueError("Wrong timed technical screenshot bytes")
            return i, image
        previous = snapshot_indices["before"]
        for i, failure in [(i, row["evidence"]) for i, row in enumerate(scoped) if row.get("kind") == "verified-state" and row.get("label") == "native technical refusal"]:
            capture_index, image = captured("technical-invalid-" + failure["input"].replace(" ", "-"))
            if not previous < capture_index < i < cancel_index or failure["screenshot"] != image:
                return False
            segment = scoped[previous + 1:capture_index]
            if failure["input"].startswith(("duration ", "trim ")):
                field_id, value = failure["input"].split(" ", 1)
                fields = [row["field"] for row in segment if row.get("kind") == "text" and row["field"].get("id") == "production.technical." + field_id]
                if not fields or any(fields[-1].get(key) != value for key in ("actual", "expected")) or fields[-1].get("focusLeftTarget") is not True:
                    return False
            else:
                field_id = failure["input"].split(" ")[1]
                menus = [row for row in segment if row.get("kind") == "menu" and row.get("id") == "production.technical." + field_id]
                if not menus or menus[-1].get("closed") is not True or menus[-1].get("item") != "Choose " + field_id:
                    return False
            previous = i
        cancel_capture, _ = captured("technical-cancel-dirty")
        apply_capture, _ = captured("technical-before-apply")
        restored_capture, _ = captured("technical-original-restored")
        if not previous < cancel_capture < cancel_index < snapshot_indices["cancelled"] < apply_capture < apply_index or not snapshot_indices["restored"] < restored_capture:
            return False
        submitted = list(enumerate(scoped[cancel_index + 1:apply_index], cancel_index + 1))
        for field_id, ticks in (("duration", new["nativeDurationTicks"]), ("trim", new["sourceInTicks"])):
            entered = [(i, row["field"]) for i, row in submitted if row.get("kind") == "text" and row["field"].get("id") == "production.technical." + field_id]
            if not entered:
                return False
            index, field = entered[-1]
            if (index >= apply_capture or field.get("focusLeftTarget") is not True
                or field.get("actual") != field.get("expected")
                or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", field["actual"])
                or (Decimal(field["actual"]) * after["projection"]["timebase"]["ticksPerSecond"]).to_integral_value(rounding=ROUND_HALF_UP) != ticks):
                return False
        suffixes = ["technical-invalid-" + value.replace(" ", "-") for value in expected]
        suffixes += ["technical-cancel-dirty", "technical-before-apply", "technical-original-restored"]
        for suffix in suffixes:
            images = [name for name in native["screenshots"] if name.endswith("-" + suffix + ".png")]
            if len(images) != 1 or not read(directory, images[0]).startswith(b"\x89PNG\r\n\x1a\n"):
                return False
        return True
    except (KeyError, TypeError, ValueError, OSError, StopIteration, AttributeError, InvalidOperation):
        return False
