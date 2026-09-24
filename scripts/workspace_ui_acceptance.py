"""Exercise and verify the native five-workspace editor on a macOS 26 runner."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


EXPECTED_WORKSPACES = {"media", "production", "edit", "postproduction", "export"}
EXPECTED_INSPECTOR_CASES = {
    ("text", None),
    ("video", "closed"),
    ("video", "open"),
    ("effects", None),
    ("ai", None),
    ("audio", "closed"),
    ("audio", "open"),
    ("mixed", None),
    ("asset", None),
    ("caption", None),
}
EXPECTED_KEYFRAME_LANES = {
    "audio": ["volume"],
    "video": ["position", "scale", "rotation", "opacity", "crop"],
}
SCALES = (1.0, 1.25, 1.5)


def valid_frame(frame):
    return (
        isinstance(frame, dict)
        and set(frame) == {"height", "width", "x", "y"}
        and frame["height"] > 0
        and frame["width"] > 0
    )


def contains_frame(outer, inner, tolerance=1):
    return (
        inner["x"] >= outer["x"] - tolerance
        and inner["y"] >= outer["y"] - tolerance
        and inner["x"] + inner["width"]
        <= outer["x"] + outer["width"] + tolerance
        and inner["y"] + inner["height"]
        <= outer["y"] + outer["height"] + tolerance
    )


def matching_frame(first, second, tolerance=1):
    return all(abs(first[key] - second[key]) <= tolerance for key in first)


def valid_media_surface(row):
    surface = row.get("mediaSurface")
    panels = row.get("frames")
    if not isinstance(surface, dict) or not isinstance(panels, dict):
        return False
    folder = surface.get("folderTree")
    browser = surface.get("browser")
    source = surface.get("sourcePreview")
    media_panel = panels.get("mediaPanel")
    center_panel = panels.get("previewPanel")
    if not all(valid_frame(frame) for frame in [folder, browser, source, media_panel, center_panel]):
        return False
    vertically_separate = (
        browser["y"] + browser["height"] <= source["y"] + 1
        or source["y"] + source["height"] <= browser["y"] + 1
    )
    return (
        contains_frame(media_panel, folder)
        and contains_frame(center_panel, browser)
        and contains_frame(center_panel, source)
        and vertically_separate
        and row.get("mediaAssetCount", 0) >= 523
        and row.get("bulkThumbnailsLoaded") == 0
        and row.get("bulkIntakeAssignments") == 0
    )


def valid_keyframe_layout(layout, expected_mode, expected_lanes):
    inspector = layout.get("inspectorFrame")
    panel = layout.get("panelFrame")
    ruler = layout.get("rulerFrame")
    ruler_overlay = layout.get("rulerOverlayFrame")
    lanes = layout.get("laneEvidence")
    if (
        layout.get("mode") != expected_mode
        or layout.get("reachableLaneLabels") != expected_lanes
        or not isinstance(layout.get("screenshot"), str)
        or not all(valid_frame(frame) for frame in [inspector, panel, ruler, ruler_overlay])
        or not contains_frame(inspector, ruler)
        or not matching_frame(ruler, ruler_overlay)
        or not isinstance(lanes, list)
        or any(not isinstance(item, dict) for item in lanes)
        or [item.get("property") for item in lanes] != expected_lanes
    ):
        return False
    if expected_mode == "stacked":
        target = layout.get("inspectorWidthTarget")
        if not isinstance(target, (int, float)) or abs(inspector["width"] - target) > 1:
            return False
    elif "inspectorWidthTarget" in layout:
        return False
    for lane in lanes:
        clip = lane.get("clipFrame")
        label = lane.get("labelFrame")
        track = lane.get("trackFrame")
        overlay = lane.get("overlayFrame")
        if (
            lane.get("visible") is not True
            or not all(valid_frame(frame) for frame in [clip, label, track, overlay])
            or not contains_frame(clip, label)
            or not contains_frame(clip, track)
            or not contains_frame(inspector, label)
            or not contains_frame(inspector, track)
            or not matching_frame(track, overlay)
            or abs(track["x"] - ruler["x"]) > 1
            or abs(track["width"] - ruler["width"]) > 1
        ):
            return False
        if expected_mode == "side":
            if label["x"] + label["width"] > track["x"] + 1:
                return False
        elif label["y"] + label["height"] > track["y"] + 1:
            return False
    return True


def valid_keyframe_lane_evidence(row):
    expected = EXPECTED_KEYFRAME_LANES.get(row.get("family"))
    evidence = row.get("laneLayoutEvidence")
    if (
        expected is None
        or not isinstance(evidence, list)
        or any(not isinstance(item, dict) for item in evidence)
        or [item.get("mode") for item in evidence] != ["side", "stacked"]
    ):
        return False
    return all(
        valid_keyframe_layout(layout, mode, expected)
        for layout, mode in zip(evidence, ["side", "stacked"])
    )


def run_scale(executable, output, scale):
    label = str(round(scale * 100))
    log_path = output / f"scale-{label}.log"
    started = time.monotonic()
    try:
        process = subprocess.run(
            [executable],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env={
                **os.environ,
                "NGV_WORKSPACE_UI_ACCEPTANCE": "1",
                "NGV_WORKSPACE_UI_EVIDENCE": str(output.resolve()),
                "NGV_WORKSPACE_UI_SCALE": str(scale),
                "NGV_INSPECTOR_UI_ACCEPTANCE": "1",
            },
            timeout=90,
            check=False,
            text=True,
        )
        log_path.write_text(process.stdout)
    except subprocess.TimeoutExpired as error:
        output_text = error.stdout or ""
        if isinstance(output_text, bytes):
            output_text = output_text.decode(errors="replace")
        log_path.write_text(output_text)
        return {
            "completed": False,
            "elapsedSeconds": time.monotonic() - started,
            "exitCode": None,
            "reason": "runtime-timeout",
            "scale": scale,
        }

    rows = []
    for line in process.stdout.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and "event" in row:
            rows.append(row)

    workspace_rows = [row for row in rows if row.get("event") == "workspace"]
    media_rows = [row for row in workspace_rows if row.get("workspace") == "media"]
    workspaces = {row.get("workspace") for row in workspace_rows}
    completed = any(row.get("event") == "completed" for row in rows)
    hidden = [row for row in rows if row.get("event") == "panels-hidden"]
    narrow = [row for row in rows if row.get("event") == "narrow-production"]
    pinned = [row for row in rows if row.get("event") == "narrow-production-pinned"]
    selection_source = [row for row in rows if row.get("event") == "selection-source"]
    selection_timeline = [row for row in rows if row.get("event") == "selection-timeline"]
    invariants = [row for row in rows if row.get("event") == "invariants"]
    inspector = [row for row in rows if row.get("event") == "inspector"]
    open_keyframes = [row for row in inspector if row.get("keyframes") == "open"]
    screenshots = [
        row.get("screenshot")
        for row in workspace_rows + hidden + narrow + pinned + selection_source + selection_timeline
    ]
    screenshots += [
        row.get("screenshot")
        for row in inspector
        if row.get("keyframes") != "open"
    ]
    screenshots += [
        layout.get("screenshot")
        for row in open_keyframes
        for layout in row.get("laneLayoutEvidence", [])
        if isinstance(layout, dict)
    ]
    valid_images = all(
        isinstance(name, str)
        and (output / name).is_file()
        and (output / name).stat().st_size > 1000
        and (output / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
        for name in screenshots
    )
    valid = (
        process.returncode == 0
        and completed
        and workspaces == EXPECTED_WORKSPACES
        and len(workspace_rows) == len(EXPECTED_WORKSPACES)
        and len(media_rows) == 1
        and valid_media_surface(media_rows[0])
        and len(hidden) == 1
        and len(narrow) == 1
        and len(pinned) == 1
        and len(selection_source) == 1
        and selection_source[0].get("activeAsset") == "selection-source"
        and selection_source[0].get("sourceFrame") == 42
        and selection_source[0].get("sourceIn") == 18
        and selection_source[0].get("sourceOut") == 72
        and selection_source[0].get("timelineFrame") == 96
        and selection_source[0].get("rememberedClip") is True
        and selection_source[0].get("rangeEnabled") is True
        and selection_source[0].get("placementEnabled") is True
        and selection_source[0].get("insertEnabled") is False
        and selection_source[0].get("overwriteEnabled") is True
        and selection_source[0].get("insertUndoVerified") is True
        and selection_source[0].get("overwriteUndoVerified") is True
        and selection_source[0].get("nativeSourceCommands") is True
        and selection_source[0].get("nativeSourceScrub") is True
        and selection_source[0].get("nativeSourceStepAndArrow") is True
        and selection_source[0].get("nativeMultiselectDeselect") is True
        and selection_source[0].get("sameSourceReactivationPreservedPlayback") is True
        and selection_source[0].get("nativeSearchPreservedPlayback") is True
        and selection_source[0].get("sortAndFilterPreservedPlayback") is True
        and selection_source[0].get("nativeGridListToggle") is True
        and selection_source[0].get("listModePreserved") is True
        and selection_source[0].get("contextClickRoutingVerified") is True
        and selection_source[0].get("offlineSourceHandled") is True
        and selection_source[0].get("nativeActiveDeleteUndo") is True
        and len(selection_timeline) == 1
        and selection_timeline[0].get("activeClip") == "selection-clip"
        and selection_timeline[0].get("clipMutationEnabled") is False
        and selection_timeline[0].get("lockedMutationBlocked") is True
        and selection_timeline[0].get("rememberedAsset") is True
        and selection_timeline[0].get("nativeClipSelection") is True
        and selection_timeline[0].get("nativeTrackLock") is True
        and selection_timeline[0].get("nativeLockedDeleteBlocked") is True
        and selection_timeline[0].get("nativeTimelineRuler") is True
        and selection_timeline[0].get("nativeTimelineTrim") is True
        and selection_timeline[0].get("nativeTitleSelection") is True
        and selection_timeline[0].get("nativeEmptySelection") is True
        and selection_timeline[0].get("nativeLinkedAVSelection") is True
        and selection_timeline[0].get("nativeContextTarget") is True
        and selection_timeline[0].get("headerInspectorTargetMatched") is True
        and selection_timeline[0].get("nativeTimelineUndoRedoAfterSourceSwitch") is True
        and selection_timeline[0].get("nativeDisabledPaste") is True
        and selection_timeline[0].get("sourceStatePreserved") is True
        and len(invariants) == 1
        and {(row.get("family"), row.get("keyframes")) for row in inspector}
        == EXPECTED_INSPECTOR_CASES
        and len(inspector) == len(EXPECTED_INSPECTOR_CASES)
        and len(open_keyframes) == len(EXPECTED_KEYFRAME_LANES)
        and all(valid_keyframe_lane_evidence(row) for row in open_keyframes)
        and invariants[0].get("liveStateUnchanged") is True
        and invariants[0].get("projectBytesUnchanged") is True
        and invariants[0].get("undoUnchanged") is True
        and invariants[0].get("workingCopyUnchanged") is True
        and len(screenshots)
        == 10 + len(EXPECTED_INSPECTOR_CASES) + len(EXPECTED_KEYFRAME_LANES)
        and valid_images
    )
    return {
        "completed": valid,
        "elapsedSeconds": time.monotonic() - started,
        "events": rows,
        "exitCode": process.returncode,
        "reason": "completed" if valid else "invalid-evidence",
        "scale": scale,
        "screenshots": screenshots,
    }


def main():
    executable, output_path = sys.argv[1:]
    output = Path(output_path)
    output.mkdir(parents=True, exist_ok=True)
    results = [run_scale(executable, output, scale) for scale in SCALES]
    result = {
        "completed": all(item["completed"] for item in results),
        "runs": results,
    }
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True))
    print(json.dumps(result, sort_keys=True))
    return 0 if result["completed"] else 1


if __name__ == "__main__":
    sys.exit(main())
