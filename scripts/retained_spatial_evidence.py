"""Independent file/event checks for native panorama and retained-blockout evidence."""
import hashlib
import json
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text())


def digest(path):
    require(path.is_file() and not path.is_symlink(), f"missing regular evidence: {path.name}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local(directory, relative):
    path = Path(relative)
    require(not path.is_absolute() and relative and all(part not in (".", "..") for part in path.parts), "unsafe evidence path")
    target = directory / path
    require(target.resolve().is_relative_to(directory.resolve()), "evidence escape")
    return target


def record(entry, label):
    matches = [item for item in entry.get("interactions", []) if item.get("label") == label]
    require(len(matches) == 1, f"missing unique native observation: {label}")
    require(matches[0].get("kind") == "verified-state", "not a verified native observation")
    return matches[0].get("evidence", {})


def inputs(entry, directory, scale):
    require(entry.get("scale") == scale and entry.get("viewport") == [960, 640], "actual native presentation differs")
    require(entry.get("backingScale", 0) > 0, "missing backing scale")
    require(entry.get("screenshots"), "no native screenshots")
    for image in entry["screenshots"]:
        require(local(directory, image).is_file(), "missing screenshot")
    progress = read(local(directory, entry.get("progress", "")))
    require(progress.get("failure") is None and progress.get("interactions") == entry.get("interactions")
            and progress.get("screenshots") == entry.get("screenshots"), "driver log differs from result")
    require(any(action.get("kind") == "pointer" for action in entry.get("interactions", [])), "no native pointer input")


def validate_blockout(directory, imported):
    kind = "import" if imported else "plan"
    entries = read(directory / f"native-blockout-{kind}-result.json")
    require(len(entries) == 3, "all three native blockout scales required")
    for entry, scale in zip(entries, [1.0, 1.25, 1.5]):
        inputs(entry, directory, scale)
        item = record(entry, "native retained blockout")
        media = f"native-blockout-{kind}-{int(scale * 100)}.mov"
        require(item.get("media") == media, "unexpected blockout movie")
        require(item.get("kind") == ("importedGeometry" if imported else "planElevation"), "blockout semantics changed")
        require(item.get("appearanceRejected") is True and item.get("nativeUndoRedo") is True, "missing negative/Undo observations")
        require(item.get("outputSHA256") == digest(directory / media), "actual movie bytes differ")
        require(item.get("nativeFileExport") is True and item.get("export") == media.replace(".mov", "-export.mov"), "native MOV export missing")
        require(digest(local(directory, item["export"])) == item["outputSHA256"], "saved MOV differs")
        require(any(action.get("kind") == "save-panel" and action.get("filename") == item["export"]
                    and action.get("nativeDirectoryAndFilenameTyped") is True and action.get("exactURLVerified") is True
                    for action in entry.get("interactions", [])), "no actual native save panel")
        validate_blockout_receipt(directory, media, directory / (media + ".receipt.json"), item, imported)
        if not imported:
            validate_blockout_recovery(directory, entry, scale)
    return entries


def validate_blockout_receipt(directory, media, receipt_file, item, imported):
    require(item.get("receiptSHA256") == digest(receipt_file), "native receipt differs")
    receipt = read(receipt_file)
    require(receipt.get("schema") == "native-blockout-selection/v1" and receipt.get("shotID") == item.get("shotID"), "foreign blockout receipt")
    require(receipt.get("kind") == ("importedGeometry" if imported else "planElevation")
            and receipt.get("recordedAt") and receipt.get("observation"), "incomplete blockout receipt")
    output = receipt.get("output", {})
    require(output.get("sha256") == item.get("outputSHA256") == digest(local(directory, media)), "receipt binds other movie")
    require(output.get("role") == ("core.shot-blockout-video" if imported else "host.plan-elevation-video"), "wrong blockout output role")
    closure = directory / (media + ".evidence")
    state = receipt.get("stateReferences", [])
    require(isinstance(state, list) and state, "missing native state closure")
    refs = state + [receipt.get("draft", {}), receipt.get("timing", {}), output]
    camera = receipt.get("camera", {})
    refs += [camera[key] for key in ("spatialState", "sceneReference") if key in camera]
    if imported:
        refs.append(receipt.get("original", {}))
        require(receipt.get("originalName") and type(receipt.get("sourceStartValue")) is int and receipt["sourceStartValue"] >= 0,
                "missing original/native source range")
        require(all(type(receipt.get(key)) is int and receipt[key] > 0 for key in
                    ("sourceDurationValue", "sourceTimescale", "sourceDurationTimescale")), "invalid source clock")
    else:
        require(receipt.get("original") is None, "diagram claims imported/rendered origin")
    for ref in refs:
        require(ref.get("sha256") == digest(local(closure, ref.get("path", ""))), "native source closure differs")
    require(all(type(item.get(key)) is int and item[key] > 0 for key in ("durationValue", "durationTimescale")), "no actual decoded duration")
    return receipt


def validate_blockout_recovery(directory, entry, scale):
    from blockout_recovery_binding import validate_bindings
    item, name = validate_bindings(directory, entry, scale)
    require(item.get("directory") == name, "missing actual blockout recovery directory")
    for flag in ("missingReceiptRecovery", "tamperedReceiptRecovery", "explicitConfirmation", "nativeSingleRemoval",
                 "nativeReattachment", "nativeUndoAfterFileRestore", "staleSnapshotRejected", "competingLeaseRejected"):
        require(item.get(flag) is True, "missing native blockout recovery: " + flag)
    root = local(directory, name)
    snapshots = item.get("canonicalSnapshots", {})
    expected_names = {"before", "cleared", "reattached"} | {state + suffix for state in ("missing", "tampered") for suffix in ("-snapshot", "-removed", "-undo")}
    require(set(snapshots) == expected_names, "incomplete canonical snapshot hashes")

    def canonical(name):
        value = read(root / (name + ".json"))
        revision = value.get("header", {}).get("revision")
        require(value.get("schema") == "shot-planning-draft/v1" and type(revision) is int and revision > 0, "invalid canonical shot draft")
        binding = snapshots[name]
        require(binding.get("currentPath") == "shot-planning/current.v1.json"
                and binding.get("versionPath") == f"shot-planning/v{revision}.v1.json"
                and binding.get("sha256") == digest(root / (name + ".json")) == digest(root / (name + ".version.json")),
                "canonical current/version bytes differ from driver")
        return value

    def transition(before, after, shots):
        require(after.get("shots") == shots, "removal changed unrelated shot or confirmed state")
        require({key: value for key, value in before.items() if key not in ("header", "shots")}
                == {key: value for key, value in after.items() if key not in ("header", "shots")}, "shot draft context changed")
        old, new = before["header"], after["header"]
        require(type(new.get("revision")) is int and new["revision"] == old["revision"] + 1
                and new.get("origin") == "userRevision"
                and {key: value for key, value in old.items() if key not in ("revision", "origin", "inputs")}
                == {key: value for key, value in new.items() if key not in ("revision", "origin", "inputs")}, "unexpected canonical revision transition")

    before = canonical("before")
    selected = next((shot for shot in before.get("shots", []) if shot.get("shotID") == item.get("shotID")), None)
    require(selected is not None and selected.get("camera", {}).get("blockingReference"), "missing original shot assignment")
    original = selected["camera"]["blockingReference"]
    require(original.get("sha256") == item.get("receiptSHA256") == digest(root / "original-receipt.json"), "recovery original receipt differs")
    require(original["sha256"] == record(entry, "native retained blockout").get("receiptSHA256"), "recovery did not start with the actual preceding blockout")
    actions = entry.get("interactions", [])
    recover_indices = [index for index, action in enumerate(actions) if action.get("kind") == "pointer" and action.get("id") == "shot-planning.blockout.recover"]
    confirm_indices = [index for index, action in enumerate(actions) if action.get("kind") == "verified-state"
                       and action.get("label") == "native-pointer" and action.get("evidence", {}).get("target") == "button.Remove all assignments"]
    require(len(recover_indices) == len(confirm_indices) == 2, "exactly two recovery clicks and confirmations required")
    prior_name, prior, previous_end = "before", before, -1
    for index, state in enumerate(("missing", "tampered")):
        snapshot = canonical(state + "-snapshot")
        require(snapshots[state + "-snapshot"]["sha256"] == snapshots[prior_name]["sha256"], "damage not joined to preceding canonical state")
        damage = read(root / (state + "-damage.json"))
        refusals = read(root / (state + "-refusals.json"))
        snapshot_hash = snapshots[state + "-snapshot"]["sha256"]
        require(refusals.get("beforeSHA256") == refusals.get("afterSHA256") == snapshot_hash
                and refusals.get("staleError") and refusals.get("leaseError"), "stale/concurrent removal changed canonical bytes")
        damaged_shot = next((shot for shot in snapshot["shots"] if shot.get("shotID") == item["shotID"]), {})
        require(damaged_shot.get("camera", {}).get("blockingReference") == original
                and damage.get("state") == state and damage.get("shotID") == item["shotID"]
                and damage.get("snapshotSHA256") == snapshot_hash and damage.get("path") == original.get("path")
                and damage.get("expectedSHA256") == original.get("sha256"), "recovery targets another receipt or snapshot")
        require(damage.get("actualSHA256") is None and digest(root / "missing.quarantine") == original["sha256"] if state == "missing" else
                damage.get("actualSHA256") == digest(root / "tampered-receipt.bin") != original["sha256"], "no actual receipt damage")
        removed, undone = canonical(state + "-removed"), canonical(state + "-undo")
        cleared_shots = json.loads(json.dumps(snapshot["shots"]))
        for shot in cleared_shots:
            shot.get("camera", {}).pop("blockingReference", None)
        transition(snapshot, removed, cleared_shots)
        transition(removed, undone, snapshot["shots"])
        require(undone["header"].get("inputs") == snapshot["header"].get("inputs"), "native Undo did not restore exact source inputs")
        begin_label, end_label = "blockout recovery begin " + state, "blockout recovery complete " + state
        begin, end = record(entry, begin_label), record(entry, end_label)
        begin_index = next(i for i, action in enumerate(actions) if action.get("label") == begin_label)
        end_index = next(i for i, action in enumerate(actions) if action.get("label") == end_label)
        require(previous_end < begin_index < recover_indices[index] < confirm_indices[index] < end_index,
                "recovery and confirmation events are not joined to each damage case")
        require(begin.get("state") == end.get("state") == state and begin.get("receiptSHA256") == original["sha256"]
                and begin.get("snapshotSHA256") == end.get("snapshotSHA256") == snapshot_hash
                and end.get("removedSHA256") == snapshots[state + "-removed"]["sha256"]
                and end.get("undoSHA256") == snapshots[state + "-undo"]["sha256"], "recovery event hashes differ")
        previous_end, prior_name, prior = end_index, state + "-undo", undone
    single = canonical("cleared")
    single_shots = json.loads(json.dumps(prior["shots"]))
    next(shot for shot in single_shots if shot["shotID"] == item["shotID"])["camera"].pop("blockingReference")
    transition(prior, single, single_shots)
    after = canonical("reattached")
    reattached = next((shot for shot in after.get("shots", []) if shot.get("shotID") == item["shotID"]), None)
    require(reattached is not None, "reattached shot missing")
    replacement = reattached.get("camera", {}).get("blockingReference", {})
    require(replacement.get("sha256") == item.get("reattachedSHA256") == digest(root / "reattached-receipt.json")
            and replacement != original and replacement.get("role") == "host.native-blockout", "no actual fresh reattachment")
    after_shots = json.loads(json.dumps(single_shots))
    next(shot for shot in after_shots if shot["shotID"] == item["shotID"])["camera"]["blockingReference"] = replacement
    transition(single, after, after_shots)
    media = item.get("reattachedOutput", {})
    require(media.get("media") == "reattached.mov", "missing actual reattached movie")
    validate_blockout_receipt(root, media["media"], root / "reattached-receipt.json",
        dict(media, shotID=item["shotID"], receiptSHA256=replacement["sha256"]), False)
    require(any(action.get("kind") == "pointer" and action.get("id") == "shot.blockout.remove" for action in actions), "no actual single removal click")


def validate_panorama_batch(directory, entry, scale, first_receipt):
    from panorama_recovery_binding import validate_bindings
    item, name = validate_bindings(directory, entry, scale, first_receipt)
    require(item.get("directory") == name and item.get("invalidCount") == 2, "missing two-location recovery")
    ids = item.get("locationIDs", [])
    require(isinstance(ids, list) and all(isinstance(identity, str) and identity for identity in ids), "invalid recovery location IDs")
    require(len(ids) == len(set(ids)) == 2 and ids[0] == first_receipt.get("locationID"), "foreign recovery locations")
    for flag in ("missingAndTampered", "subsetRefused", "oneUndoRestoredBoth", "brokenUndoRefusedVisibly",
                 "noncollidingPanoramaView"):
        require(item.get(flag) is True, "missing batch observation: " + flag)
    error = item.get("undoError", "")
    require(isinstance(error, str) and "panorama assignment" in error and "missing or changed" in error
            and not error.startswith("Bible updated; Undo is unavailable."), "actual broken Undo error missing")
    require(record(entry, "panorama undo toast baseline").get("empty") is True, "prior toast was not dismissed")
    for attempt in (1, 2):
        ready = record(entry, "panorama removal undo ready " + str(attempt))
        require(all(ready.get(flag) is True for flag in ("historyInitiallyEmpty", "canUndo", "menuEnabled"))
                and ready.get("actionName") == "Remove Invalid Panorama Assignments"
                and ready.get("menuTitle") == "Undo Remove Invalid Panorama Assignments", "batch removal was not registered in the actual Undo menu")
        actions = entry.get("interactions", [])
        ready_index = next(index for index, action in enumerate(actions) if action.get("label") == "panorama removal undo ready " + str(attempt))
        next_ready = next((index for index in range(ready_index + 1, len(actions))
                           if actions[index].get("label") == "panorama removal undo ready 2"), len(actions))
        require(any(action.get("kind") == "keyboard" and action.get("characters") == "z"
                    and type(action.get("code")) is int and action["code"] == 6
                    and type(action.get("modifiers")) is int and action["modifiers"] == 1 << 20
                    for action in actions[ready_index + 1:next_ready]), "registered removal was not followed by native Cmd-Z")
    actions = entry.get("interactions", [])
    ready = next(index for index, action in enumerate(actions) if action.get("label") == "panorama removal undo ready 2")
    baseline = next(index for index, action in enumerate(actions) if action.get("label") == "panorama undo toast baseline")
    undo = next(index for index in range(ready + 1, len(actions)) if actions[index].get("kind") == "keyboard" and actions[index].get("characters") == "z")
    require(ready < baseline < undo, "previous toast was not dismissed after Undo registration")
    surface = record(entry, "panorama undo surface")
    require(surface.get("workspace") == "production" and surface.get("feedback") == "production.feedback", "Undo refusal left the actual Production surface")
    require(any(action.get("kind") == "pointer" and action.get("id") == "production.feedback.dismiss" for action in actions[undo + 1:]), "visible Undo refusal was not explicitly dismissed")
    case = local(directory, name)
    initial = read(case / "bible-initial.json")
    require(initial == read(directory / f"native-panorama-{int(scale * 100)}-bible-after.json"), "negative baseline differs from actual selected Bible")
    require(type(item.get("initialSecondLocationFixture")) is bool and item["initialSecondLocationFixture"]
            == (ids[1] not in [location.get("id") for location in initial.get("locations", [])]), "second-location creation claim differs from the initial Bible")
    snapshots = item.get("canonicalSnapshots", {})
    require(isinstance(snapshots, dict) and set(snapshots) == {"selected", "removed", "after-undo", "before-blocked-undo", "after-blocked-undo"}, "canonical Bible snapshots missing")
    for state, snapshot in snapshots.items():
        require(isinstance(snapshot, dict) and snapshot.get("file") == "bible-" + state + ".yaml"
                and snapshot.get("sha256") == digest(local(case, snapshot["file"])), "canonical Bible snapshot bytes differ")
    require(snapshots["before-blocked-undo"]["sha256"] == snapshots["after-blocked-undo"]["sha256"], "broken Undo altered canonical bytes")
    selected = read(case / "bible-selected.json")
    require(read(case / "bible-after-undo.json") == selected, "one Undo did not restore the whole Bible")
    removed = read(case / "bible-removed.json")
    require(read(case / "bible-after-blocked-undo.json") == removed, "broken Undo altered the Bible")
    require(selected.get("project") == removed.get("project"), "batch changed project")
    def locations_by_id(bible):
        values = bible.get("locations", [])
        require(isinstance(values, list) and all(isinstance(location, dict) and isinstance(location.get("id"), str) for location in values), "invalid Bible locations")
        require(len({location["id"] for location in values}) == len(values), "duplicate Bible location")
        return {location["id"]: location for location in values}
    locations = locations_by_id(selected)
    after = locations_by_id(removed)
    require(set(locations) == set(after) and all(locations[key] == after[key] for key in locations if key not in ids), "unshown locations changed")
    for index, identity in enumerate(ids):
        require(identity in locations and identity in after, "missing batch location")
        receipt_path = case / f"receipt-{index}.json"
        receipt = read(receipt_path)
        require(receipt.get("schema") == "native-panorama-selection/v1" and receipt.get("locationID") == identity
                and receipt.get("projectID") == selected.get("project"), "foreign batch receipt")
        attributes = locations[identity].get("attributes", {})
        require(attributes.get("core.native-panorama-receipt-sha256") == digest(receipt_path)
                and attributes.get("core.native-panorama-receipt"), "batch Bible did not bind the genuine receipt")
        require(locations[identity].get("scene3d", {}).get("panorama") == receipt.get("panorama", {}).get("path"), "batch source differs")
        expected = dict(locations[identity]); expected["scene3d"] = {"panorama": "", "povs": [], "provider": ""}
        expected["attributes"] = {key: value for key, value in attributes.items() if key not in ("core.native-panorama-receipt", "core.native-panorama-receipt-sha256")}
        require(after[identity] == expected, "batch removal changed appearance or unrelated fields")
        if index == 0:
            require(receipt == first_receipt, "first batch selection differs from actual native owner selection")
        else:
            require(any(view.get("geometry", {}).get("name") == "panorama" for view in receipt.get("views", []))
                    and receipt.get("panorama", {}).get("path", "").endswith("/source.panorama")
                    and receipt["panorama"]["path"] not in [view.get("image", {}).get("path") for view in receipt.get("views", [])], "source/view filename collision remains")
            require(receipt["panorama"].get("sha256") == digest(case / "second-source.panorama") == first_receipt["panorama"]["sha256"], "second actual source bytes differ")
            for view in receipt.get("views", []):
                geometry = view.get("geometry", {})
                require(isinstance(geometry.get("name"), str), "missing second view name")
                require(view.get("image", {}).get("sha256") == digest(local(case, "second-view-" + geometry["name"] + ".png")), "second actual POV bytes differ")
        for attempt in (1, 2):
            damage = read(case / f"damage-{attempt}.json")
            require(isinstance(damage, list) and len(damage) == 2 and all(isinstance(value, dict) for value in damage), "two actual damaged receipts required")
            observed = damage[index]
            require(observed.get("path") == attributes["core.native-panorama-receipt"] and observed.get("expectedSHA256") == digest(receipt_path), "damage targeted other receipt")
            require((index == 0 and observed.get("state") == "missing" and observed.get("exists") is False and observed.get("actualSHA256") is None)
                    or (index == 1 and observed.get("state") == "tampered" and observed.get("exists") is True
                        and observed.get("actualSHA256") not in (None, digest(receipt_path))), "actual missing/tampered bytes not observed")
    for attempt in (1, 2):
        require(record(entry, "actual invalid panorama list " + str(attempt)).get("visibleLocationIDs") == ",".join(ids), "full recovery list not actually visible")
    for name in ("panorama-alias", "copied-pov", "character-sheet"):
        negative = read(case / (name + ".json"))
        require(negative.get("case") == name and negative.get("isError") is True
                and "A panorama geometry anchor cannot supply appearance, style or identity." in negative.get("error", "")
                and negative.get("beforeCopy") == "bible-negative-before.yaml"
                and negative.get("afterCopy") == "bible-negative-after-" + name + ".yaml"
                and negative.get("bibleSHA256Before") == digest(local(case, negative["beforeCopy"]))
                and negative.get("bibleSHA256After") == digest(local(case, negative["afterCopy"]))
                and negative["bibleSHA256Before"] == negative["bibleSHA256After"], "actual write_bible negative missing")
        observation = record(entry, "actual panorama sheet refusal " + name)
        require(observation.get("error") == negative["error"] and observation.get("canonicalUnchanged") is True, "tool refusal differs from observation")
        arguments = negative.get("arguments", {})
        require(isinstance(arguments, dict) and isinstance(negative.get("path"), str), "invalid negative payload")
        def payload_sheets(key):
            entities = arguments.get(key, [])
            require(isinstance(entities, list) and all(isinstance(entity, dict) for entity in entities), "invalid sheet entities")
            result = []
            for entity in entities:
                sheets = entity.get("sheets", [])
                require(isinstance(sheets, list) and all(isinstance(sheet, dict) for sheet in sheets), "invalid sheet payload")
                if key == "characters" or entity.get("id") == ids[0]:
                    result.extend(sheets)
            return result
        require(any(sheet.get("path") == negative["path"] for sheet in payload_sheets("characters" if name == "character-sheet" else "locations")), "sheet alias never submitted")
        require(negative.get("inputCopy") == "negative-input-" + name + ".bin"
                and negative.get("sha256") == digest(local(case, negative["inputCopy"])), "actual submitted negative bytes differ")
        hashes = [view["image"]["sha256"] for view in first_receipt.get("views", [])] if name in ("copied-pov", "character-sheet") else [first_receipt["panorama"]["sha256"]]
        require(negative.get("sha256") in hashes, "negative did not use actual panorama/POV bytes")


def validate_panorama(directory):
    entries = read(directory / "native-panorama-result.json")
    require(len(entries) == 3, "all panorama scales required")
    original_hash = digest(directory / "native-owner-panorama.png")
    geometry = [{"name": name, "yaw": yaw, "pitch": -5, "fov": 75}
                for name, yaw in [("wide_front", 0), ("wide_right", 90), ("wide_back", 180), ("wide_left", -90)]]
    geometry.append({"name": "owner_reverse", "yaw": 180, "pitch": 0, "fov": 60})
    for entry, scale in zip(entries, [1.0, 1.25, 1.5]):
        inputs(entry, directory, scale)
        item = record(entry, "native panorama selection")
        prefix = f"native-panorama-{int(scale * 100)}-"
        require(isinstance(item.get("locationID"), str) and item["locationID"], "missing location identity")
        require(item.get("panoramaSHA256") == original_hash and item.get("viewCount") == 5, "different panorama/view count")
        for flag in ("invalidAspectRejected", "appearanceSheetsPreserved", "bibleChanged", "nativeUndoRedo", "nativeRemoval",
                     "removalUndo", "missingReceiptRecovery", "tamperedReceiptRecovery", "recoveryUndoAfterRestoringOriginalBytes", "appearanceRejected"):
            require(item.get(flag) is True, "missing panorama observation: " + flag)
        actions = entry.get("interactions", [])
        for control, count in [("bible.panorama.remove", 1), ("bible.panorama.remove-invalid", 4)]:
            require(sum(action.get("kind") == "pointer" and action.get("id") == control for action in actions) == count,
                    "missing actual native removal action")
        fields = [action.get("field", {}) for action in actions if action.get("kind") == "text"
                  and action.get("field", {}).get("id") == "bible.panorama.fov"]
        require(fields and isinstance(fields[-1].get("fontPointSize"), (int, float)), "missing rendered field font")
        font = fields[-1]["fontPointSize"]
        require(abs(font - 13 * scale) < 0.5 and item.get("renderedFontPointSize") == font, "rendered font scale differs")
        candidates = list(directory.glob(prefix + "*.v1.json"))
        require(len(candidates) == 1, "missing unique panorama receipt")
        require(digest(candidates[0]) == item.get("receiptSHA256"), "panorama receipt bytes differ")
        receipt = read(candidates[0])
        require(receipt.get("schema") == "native-panorama-selection/v1" and receipt.get("locationID") == item["locationID"], "foreign panorama receipt")
        require(receipt.get("panorama", {}).get("sha256") == original_hash and receipt.get("recordedAt"), "panorama origin mismatch")
        panorama_copy = directory / (prefix + Path(receipt["panorama"]["path"]).name)
        require(digest(panorama_copy) == original_hash, "in-project panorama bytes differ")
        views = receipt.get("views", [])
        require([view.get("geometry") for view in views] == geometry, "actual camera geometry differs")
        for view in views:
            image = directory / (prefix + Path(view["image"]["path"]).name)
            require(view["image"].get("sha256") == digest(image), "actual POV bytes differ")
        locations = {}
        for state in ("before", "after", "removed"):
            bible = read(directory / (prefix + "bible-" + state + ".json"))
            matches = [location for location in bible.get("locations", []) if location.get("id") == item["locationID"]]
            require(len(matches) == 1, "missing unique actual Bible location")
            locations[state] = matches[0]
        attributes = locations["after"].get("attributes", {})
        require(attributes.get("core.native-panorama-receipt") == item.get("receiptPath")
                and attributes.get("core.native-panorama-receipt-sha256") == item["receiptSHA256"], "Bible does not bind selected receipt")
        scene = locations["after"].get("scene3d", {})
        require(scene.get("panorama") == receipt["panorama"]["path"] and scene.get("povs") == geometry
                and scene.get("provider") == "native-import", "Bible binds other panorama geometry")
        removed = locations["removed"]
        require(not removed.get("scene3d", {}).get("panorama") and not removed.get("scene3d", {}).get("povs")
                and not any(key in removed.get("attributes", {}) for key in ("core.native-panorama-receipt", "core.native-panorama-receipt-sha256")),
                "native removal retained a selection")
        validate_panorama_batch(directory, entry, scale, receipt)
        sheets = item.get("appearanceSheets", [])
        require(sheets and len({sheet.get("view") for sheet in sheets}) == len(sheets), "nonempty unique appearance fixture required")
        expected = {sheet.get("view"): sheet.get("path") for sheet in sheets}
        require(all(location.get("sheets") == expected for location in locations.values()), "appearance paths changed")
        for sheet in sheets:
            require(sheet.get("sha256") == digest(local(directory, sheet.get("copy", ""))), "appearance bytes changed")
    return entries


def validate(directory):
    directory = Path(directory)
    return {"plan": validate_blockout(directory, False), "import": validate_blockout(directory, True), "panorama": validate_panorama(directory)}


def validate_report(directory):
    directory = Path(directory)
    validated = validate(directory)
    report = read(directory / "result.json")["productionSpatial"]
    for name, key in (("plan", "nativePlanUI"), ("import", "nativeBlockoutImportUI"), ("panorama", "nativePanoramaUI")):
        require(report.get(key) == validated[name], "runtime report differs from native retained spatial evidence")
    return validated


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    validate_report(args.evidence)
