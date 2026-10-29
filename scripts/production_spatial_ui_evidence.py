"""Require actual native scene, pose, location-sketch and Clay interaction evidence."""
import argparse
import json
import math
from pathlib import Path


CASES = {
    "nativeSceneUI": ("native scene camera transform undo redo",
        {"spatial.location.create", "spatial.object.add", "spatial.transform.apply", "spatial.undo", "spatial.redo",
         "spatial.camera.apply", "spatial.camera.render", "spatial.camera.return"},
        {"invalidRatioBlocked", "undoRestoredMatrix", "redoRestoredMatrix", "cameraRenderPreservedScene"}),
    "nativePoseUI": ("native complete shot poses",
        {"shot-planning.spatial.cancel", "shot-planning.spatial.confirm", "shot-planning.spatial.discard",
         "shot-planning.spatial.scrubber", "shot-planning.spatial.set", "shot-planning.spatial.remove"},
        {"cancelPreservedDraft", "pendingTransformBlocked", "sparseReopenPreserved"}),
    "nativeClayUI": ("native full shot Clay render and inspect",
        {"shot-planning.clay.render", "shot-planning.clay.close", "production.input.video.close"}, set()),
    "nativeSpatialStoryboardUI": ("native location sketch assigned",
        {"storyboard.spatial.scene", "storyboard.spatial.camera", "storyboard.spatial.assign", "storyboard.spatial.cancel"},
        {"cancelPreservedStoryboard"}),
}


def validate(report, directory):
    try:
        for case, (label, controls, flags) in CASES.items():
            rows = report[case]
            if [row.get("scale") for row in rows] != [1, 1.25, 1.5]:
                return False
            for row in rows:
                interactions = row["interactions"]
                states = {item.get("label"): item.get("evidence", {}) for item in interactions if item.get("kind") == "verified-state"}
                pointers = {item.get("id") for item in interactions if item.get("kind") == "pointer"}
                if (row.get("viewport") != [960, 640] or not controls.issubset(pointers) or label not in states
                    or not all(states[label].get(key) is True for key in flags)
                    or not any(item.get("kind") == "visible-group" and item.get("frames") for item in interactions)):
                    return False
                if case in {"nativeClayUI", "nativeSpatialStoryboardUI"}:
                    backing = row.get("backingScale")
                    if (row.get("effectiveScale") != row["scale"] or isinstance(backing, bool)
                        or not isinstance(backing, (int, float)) or not math.isfinite(backing) or backing <= 0):
                        return False
                if case == "nativePoseUI":
                    state = states[label]
                    count = state["frameCount"]
                    if count < 3 or state["authoringFrames"] != [0, count // 2, count - 1]:
                        return False
                if case == "nativeClayUI":
                    playback = states.get("complete native Clay playback", {})
                    if (states[label].get("durationSeconds", 0) <= 0 or playback.get("input") != "nativePointer"
                        or playback.get("observedSeconds", 0) <= 0):
                        return False
                images = row["screenshots"]
                if not images or len(images) != len(set(images)):
                    return False
                for image in images:
                    path = local_file(directory, image)
                    if path is None or path.stat().st_size <= 1000 or not path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
                        return False
                progress = local_file(directory, row["progress"])
                if progress is None:
                    return False
                recorded = json.loads(progress.read_text())
                if recorded.get("failure") or recorded.get("interactions") != interactions or recorded.get("screenshots") != images:
                    return False
        return True
    except (KeyError, TypeError, ValueError, OSError, AttributeError):
        return False


def local_file(directory, name):
    if not isinstance(name, str) or Path(name).name != name or name.startswith("."):
        return None
    path = directory / name
    return path if path.is_file() and not path.is_symlink() else None


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    result = json.loads((args.evidence / "result.json").read_text())
    if not validate(result["productionSpatial"], args.evidence):
        raise SystemExit("Native spatial UI evidence is incomplete or inconsistent.")
