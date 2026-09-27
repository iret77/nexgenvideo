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
    case_results = []
    output_chunks = []
    for scenario in ("workspace", "cards", "analysis", "provenance", "musicvideo"):
        case_started = time.monotonic()
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
                    "NGV_WORKSPACE_UI_CASE": scenario,
                    "NGV_INSPECTOR_UI_ACCEPTANCE": "1",
                },
                timeout=90,
                check=False,
                text=True,
            )
            case_output = process.stdout
            code = process.returncode
        except subprocess.TimeoutExpired as error:
            case_output = error.stdout or ""
            if isinstance(case_output, bytes):
                case_output = case_output.decode(errors="replace")
            code = 124
        output_chunks.append(case_output)
        case_results.append({
            "case": scenario,
            "exitCode": code,
            "elapsedSeconds": time.monotonic() - case_started,
        })
    output_text = "\n".join(output_chunks)
    log_path.write_text(output_text)
    return_code = next((item["exitCode"] for item in case_results if item["exitCode"] != 0), 0)

    rows = []
    for line in output_text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and "event" in row:
            rows.append(row)

    workspace_rows = [row for row in rows if row.get("event") == "workspace"]
    workspaces = {row.get("workspace") for row in workspace_rows}
    completed = sum(row.get("event") == "completed" for row in rows) == 5
    hidden = [row for row in rows if row.get("event") == "panels-hidden"]
    narrow = [row for row in rows if row.get("event") == "narrow-production"]
    invariants = [row for row in rows if row.get("event") == "invariants"]
    library = [row for row in rows if row.get("event") == "media-library"]
    keyboard = [row for row in rows if row.get("event") == "text-keyboard-isolation"]
    cards = [row for row in rows if row.get("event") == "project-cards"]
    analysis = [row for row in rows if row.get("event") == "analysis-interaction"]
    provenance = [row for row in rows if row.get("event") == "asset-provenance"]
    musicvideo = [row for row in rows if row.get("event") == "musicvideo-startup"]
    inspector = [row for row in rows if row.get("event") == "inspector"]
    open_keyframes = [row for row in inspector if row.get("keyframes") == "open"]
    screenshots = [
        row.get("screenshot")
        for row in workspace_rows + hidden + narrow + library + cards
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
    screenshots += [name for row in analysis + provenance + musicvideo for name in row.get("screenshots", [])]
    valid_images = all(
        isinstance(name, str)
        and (output / name).is_file()
        and (output / name).stat().st_size > 1000
        and (output / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
        for name in screenshots
    )
    valid = (
        return_code == 0
        and completed
        and workspaces == EXPECTED_WORKSPACES
        and len(workspace_rows) == len(EXPECTED_WORKSPACES)
        and len(hidden) == 1
        and len(narrow) == 1
        and set(narrow[0].get("taskControls", []))
        == {"agent.decisions", "agent.diagnostics", "agent.utilities"}
        and len(library) == 1
        and library[0].get("assetCount") == 500
        and set(library[0].get("types", [])) == {"image", "audio", "document"}
        and library[0].get("nestedFolderOpened") is True
        and library[0].get("searchSelectedAsset") == "fixture-498"
        and library[0].get("workspaceStatePreserved") is True
        and len(keyboard) == 1
        and all(keyboard[0].get(key) is True for key in (
            "spaceEditsText", "deleteEditsText", "selectAllTargetsText", "timelineUnchanged",
            "mediaUnchanged", "selectionUnchanged", "playbackUnchanged",
        ))
        and len(cards) == 1
        and abs(cards[0].get("width", 0) - 213) <= 1
        and abs(cards[0].get("height", 0) - 170.4) <= 1
        and cards[0].get("openVerified") is True
        and cards[0].get("unavailableDisabled") is True
        and cards[0].get("unavailableContentSeparated") is True
        and len(analysis) == 1
        and analysis[0].get("selectedStart") == 6
        and analysis[0].get("playedPosition", 0) > 6.1
        and analysis[0].get("zoom") == 2
        and analysis[0].get("fitRestored") is True
        and analysis[0].get("changedSourceDisabled") is True
        and analysis[0].get("savedProjectUnchanged") is True
        and len(analysis[0].get("screenshots", [])) == 3
        and len(provenance) == 1
        and provenance[0].get("families") == ["imported", "generated", "enhanced", "offline"]
        and all(provenance[0].get(key) is True for key in (
            "syntheticReceipts", "exactOriginRendered", "originalSelected",
            "offlineActionsCorrect", "projectUnchanged", "legacyNameReadable",
        ))
        and provenance[0].get("viewportWidth") == 440
        and provenance[0].get("viewportHeight") == 650
        and len(provenance[0].get("screenshots", [])) == 7
        and len(musicvideo) == 1
        and musicvideo[0].get("phases") == [
            "project_init", "analysis", "brief", "production_design", "treatment",
            "storyboard", "bible", "shotlist", "sanity", "frames", "render",
        ]
        and all(musicvideo[0].get(key) is True for key in (
            "externalPackLoaded", "exactBinding", "libraryDidNotAssignTrack",
            "viewingDidNotAdvance", "disabledApprovalDidNotMutate", "intakeCheckpointSettled",
        ))
        and len(musicvideo[0].get("screenshots", [])) == 2
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
        == 21 + len(EXPECTED_INSPECTOR_CASES) + len(EXPECTED_KEYFRAME_LANES)
        and valid_images
    )
    return {
        "completed": valid,
        "elapsedSeconds": time.monotonic() - started,
        "events": rows,
        "exitCode": return_code,
        "cases": case_results,
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
