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
        receipt_file = directory / (media + ".receipt.json")
        require(item.get("receiptSHA256") == digest(receipt_file), "native receipt differs")
        receipt = read(receipt_file)
        require(receipt.get("schema") == "native-blockout-selection/v1" and receipt.get("shotID") == item.get("shotID"), "foreign blockout receipt")
        require(receipt.get("kind") == item["kind"] and receipt.get("recordedAt") and receipt.get("observation"), "incomplete blockout receipt")
        output = receipt.get("output", {})
        require(output.get("sha256") == item["outputSHA256"], "receipt binds other movie")
        closure = directory / (media + ".evidence")
        refs = receipt.get("stateReferences", []) + [receipt.get("draft", {}), receipt.get("timing", {}), output]
        if imported:
            refs.append(receipt.get("original", {}))
            require(receipt.get("originalName") and receipt.get("sourceStartValue", -1) >= 0,
                    "missing original/native source range")
            require(receipt.get("sourceDurationValue", 0) > 0 and receipt.get("sourceTimescale", 0) > 0
                    and receipt.get("sourceDurationTimescale", 0) > 0, "invalid source clock")
        else:
            require(receipt.get("original") is None and output.get("role") == "host.plan-elevation-video", "diagram claims imported/rendered origin")
        for ref in refs:
            require(ref.get("sha256") == digest(local(closure, ref.get("path", ""))), "native source closure differs")
        require(item.get("durationValue", 0) > 0 and item.get("durationTimescale", 0) > 0, "no actual decoded duration")
    return entries


def validate_panorama_batch(directory, entry, scale, first_receipt):
    item = record(entry, "native panorama batch recovery")
    name = f"panorama-batch-{int(scale * 100)}"
    require(item.get("directory") == name and item.get("invalidCount") == 2, "missing two-location recovery")
    ids = item.get("locationIDs", [])
    require(len(ids) == len(set(ids)) == 2 and ids[0] == first_receipt.get("locationID"), "foreign recovery locations")
    for flag in ("missingAndTampered", "subsetRefused", "oneUndoRestoredBoth", "brokenUndoRefusedVisibly",
                 "noncollidingPanoramaView", "initialSecondLocationFixture"):
        require(item.get(flag) is True, "missing batch observation: " + flag)
    require("panorama assignment" in item.get("undoError", "") and "missing or changed" in item["undoError"], "actual broken Undo error missing")
    case = local(directory, name)
    selected = read(case / "bible-selected.json")
    require(read(case / "bible-after-undo.json") == selected, "one Undo did not restore the whole Bible")
    removed = read(case / "bible-removed.json")
    require(read(case / "bible-after-blocked-undo.json") == removed, "broken Undo altered the Bible")
    require(selected.get("project") == removed.get("project"), "batch changed project")
    locations = {location["id"]: location for location in selected.get("locations", [])}
    after = {location["id"]: location for location in removed.get("locations", [])}
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
                    and receipt.get("panorama", {}).get("path", "").endswith("/source.panorama"), "source/view filename collision remains")
        for attempt in (1, 2):
            damage = read(case / f"damage-{attempt}.json")
            require(len(damage) == 2, "two actual damaged receipts required")
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
                and negative.get("bibleSHA256Before") == negative.get("bibleSHA256After") and negative.get("bibleSHA256Before"), "actual write_bible negative missing")
        observation = record(entry, "actual panorama sheet refusal " + name)
        require(observation.get("error") == negative["error"] and observation.get("canonicalUnchanged") is True, "tool refusal differs from observation")
        arguments = negative.get("arguments", {})
        if name == "character-sheet":
            require(any(sheet.get("path") == negative.get("path") for character in arguments.get("characters", []) for sheet in character.get("sheets", [])), "character alias never submitted")
        else:
            require(any(location.get("id") == ids[0] and any(sheet.get("path") == negative.get("path") for sheet in location.get("sheets", [])) for location in arguments.get("locations", [])), "sheet alias never submitted")
        hashes = [view["image"]["sha256"] for view in first_receipt.get("views", [])] if name == "copied-pov" else [first_receipt["panorama"]["sha256"]]
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
