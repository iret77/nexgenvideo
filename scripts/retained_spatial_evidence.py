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


def validate_panorama(directory):
    entries = read(directory / "native-panorama-result.json")
    require(len(entries) == 3, "all panorama scales required")
    original_hash = digest(directory / "native-owner-panorama.png")
    for entry, scale in zip(entries, [1.0, 1.25, 1.5]):
        inputs(entry, directory, scale)
        item = record(entry, "native panorama selection")
        require(item.get("panoramaSHA256") == original_hash and item.get("viewCount") == 5, "different panorama/view count")
        require(item.get("invalidAspectRejected") is True and item.get("appearanceSheetsPreserved") is True
                and item.get("bibleChanged") is True and item.get("nativeUndoRedo") is True, "missing panorama negative/assignment observations")
        candidates = list(directory.glob(f"native-panorama-{int(scale * 100)}-*.v1.json"))
        require(len(candidates) == 1, "missing unique panorama receipt")
        receipt = read(candidates[0])
        require(receipt.get("schema") == "native-panorama-selection/v1" and receipt.get("locationID") == item.get("locationID"), "foreign panorama receipt")
        require(receipt.get("panorama", {}).get("sha256") == original_hash and receipt.get("recordedAt"), "panorama origin mismatch")
        views = receipt.get("views", [])
        require([view.get("geometry", {}).get("name") for view in views] == ["wide_front", "wide_right", "wide_back", "wide_left", "owner_reverse"], "wrong actual POV set")
        require(views[-1]["geometry"] == {"name": "owner_reverse", "yaw": 180, "pitch": 0, "fov": 60}, "custom camera geometry differs")
        for view in views:
            image = directory / f"native-panorama-{int(scale * 100)}-{Path(view['image']['path']).name}"
            require(view["image"].get("sha256") == digest(image), "actual POV bytes differ")
    return entries


def validate(directory):
    directory = Path(directory)
    return {"plan": validate_blockout(directory, False), "import": validate_blockout(directory, True), "panorama": validate_panorama(directory)}


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    validated = validate(args.evidence)
    report = read(args.evidence / "result.json")["productionSpatial"]
    for name, key in (("plan", "nativePlanUI"), ("import", "nativeBlockoutImportUI"), ("panorama", "nativePanoramaUI")):
        require(report.get(key) == validated[name], "runtime report differs from native retained spatial evidence")
