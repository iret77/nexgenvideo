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
EXPECTED_PRODUCTION_SURFACES = {
    ("brief", "brief"),
    ("treatment", "treatment"),
    ("frames", "frames"),
    ("render", "render"),
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


def valid_production_artifact(row):
    phase = row.get("phase")
    value = row.get("artifactID")
    if not isinstance(value, str):
        return False
    if phase == "brief":
        return value.startswith("brief:") and len(value) > len("brief:")
    if phase == "treatment":
        return value == "treatment:v1:Acceptance treatment artifact."
    if phase == "frames":
        return value == "frames:acceptance-shot:acceptance-01-start.png"
    if phase == "render":
        prefix = "render:acceptance-render-shot:"
        digest = value.removeprefix(prefix)
        return (
            value.startswith(prefix)
            and len(digest) == 64
            and all(char in "0123456789abcdef" for char in digest)
        )
    return False


def valid_production_layout(row):
    layout = row.get("productionLayout")
    if not isinstance(layout, dict) or layout.get("mode") != "compact":
        return False
    project = layout.get("projectFrame")
    navigation = layout.get("navigationFrame")
    artifact = layout.get("artifactFrame")
    dock = layout.get("dockFrame")
    open_button = layout.get("openFrame")
    approve_button = layout.get("approveFrame")
    if not all(
        valid_frame(frame)
        for frame in [project, navigation, artifact, dock, open_button, approve_button]
    ):
        return False
    return (
        artifact["width"] >= 300
        and contains_frame(project, navigation)
        and contains_frame(project, artifact)
        and contains_frame(project, dock)
        and contains_frame(dock, open_button)
        and contains_frame(dock, approve_button)
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
    workspaces = {row.get("workspace") for row in workspace_rows}
    completed = any(row.get("event") == "completed" for row in rows)
    hidden = [row for row in rows if row.get("event") == "panels-hidden"]
    narrow = [row for row in rows if row.get("event") == "narrow-production"]
    pinned = [row for row in rows if row.get("event") == "narrow-production-pinned"]
    invariants = [row for row in rows if row.get("event") == "invariants"]
    inspector = [row for row in rows if row.get("event") == "inspector"]
    production_surfaces = [
        row for row in rows if row.get("event") == "production-surface"
    ]
    production_dock = [row for row in rows if row.get("event") == "production-dock"]
    production_budget = [row for row in rows if row.get("event") == "production-budget"]
    production_rewind = [row for row in rows if row.get("event") == "production-rewind"]
    production_read_only = [
        row for row in rows if row.get("event") == "production-read-only"
    ]
    open_keyframes = [row for row in inspector if row.get("keyframes") == "open"]
    screenshots = [
        row.get("screenshot")
        for row in workspace_rows + hidden + narrow + pinned
    ]
    screenshots += [
        row.get("screenshot")
        for row in inspector
        if row.get("keyframes") != "open"
    ]
    screenshots += [
        row.get("screenshot")
        for row in production_surfaces
        + production_dock
        + production_budget
        + production_rewind
        + production_read_only
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
        and len(hidden) == 1
        and len(narrow) == 1
        and len(pinned) == 1
        and len(invariants) == 1
        and {(row.get("family"), row.get("keyframes")) for row in inspector}
        == EXPECTED_INSPECTOR_CASES
        and len(inspector) == len(EXPECTED_INSPECTOR_CASES)
        and len(open_keyframes) == len(EXPECTED_KEYFRAME_LANES)
        and all(valid_keyframe_lane_evidence(row) for row in open_keyframes)
        and {
            (row.get("phase"), row.get("artifact"))
            for row in production_surfaces
        }
        == EXPECTED_PRODUCTION_SURFACES
        and len(production_surfaces) == len(EXPECTED_PRODUCTION_SURFACES)
        and all(
            row.get("focusedWorkspace") == "production"
            for row in production_surfaces
        )
        and all(valid_production_artifact(row) for row in production_surfaces)
        and len(production_dock) == 1
        and production_dock[0].get("approvalEnabled") is False
        and "Frames" in production_dock[0].get("requirement", "")
        and "/" not in production_dock[0].get("requirement", "")
        and "write_" not in production_dock[0].get("requirement", "")
        and len(production_budget) == 1
        and production_budget[0].get("status")
        == "€0.00|Unknown|€150.00|Unknown|0|1|Spend incomplete"
        and len(production_rewind) == 1
        and production_rewind[0].get("phase") == "brief"
        and production_rewind[0].get("closedOnReadinessChange") is True
        and len(production_read_only) == 1
        and production_read_only[0].get("inspectedPhase") == "frames,render"
        and production_read_only[0].get("runningPhase") == "frames"
        and production_read_only[0].get("mutationsDisabled") is True
        and production_read_only[0].get("nativeInspectionWorked") is True
        and production_read_only[0].get("popoverClosedOnReadinessChange") is True
        and valid_production_layout(narrow[0])
        and invariants[0].get("liveStateUnchanged") is True
        and invariants[0].get("projectBytesUnchanged") is True
        and invariants[0].get("undoUnchanged") is True
        and invariants[0].get("workingCopyUnchanged") is True
        and len(screenshots)
        == 8
        + len(EXPECTED_INSPECTOR_CASES)
        + len(EXPECTED_KEYFRAME_LANES)
        + len(EXPECTED_PRODUCTION_SURFACES)
        + 4
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
