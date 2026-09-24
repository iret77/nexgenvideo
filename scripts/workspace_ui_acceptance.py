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
EXPECTED_BUDGET_CASES = {
    "empty": (0, 0, True, 0),
    "zero": (0, 0, True, 1),
    "low": (9.25, 0, True, 1),
    "exceeded": (12.5, 0, True, 1),
    "exceeded-unknown": (12.5, 0, False, 2),
    "unknown-price": (0, 0, False, 1),
    "unknown-currency": (0, 0, False, 1),
    "subscription-credits": (0, 0, False, 1),
    "reserved": (0, 3.25, True, 1),
    "submitted-failure": (0, 4, True, 1),
    "released": (0, 0, True, 1),
}
EXPECTED_BUDGET_LIFECYCLE = {
    "reserved": 1,
    "submitted-failure": 2,
    "charged": 3,
    "released": 2,
}
STATUS_IDENTIFIERS = {
    "editor.statusBar",
    "editor.status.budget",
    "editor.status.aiJobs",
    "editor.status.exportJobs",
}


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


def valid_status_frames(row):
    frames = row.get("statusFrames")
    if not isinstance(frames, dict) or set(frames) != STATUS_IDENTIFIERS:
        return False
    if not all(valid_frame(frame) for frame in frames.values()):
        return False
    status = frames["editor.statusBar"]
    return all(
        contains_frame(status, frames[identifier])
        for identifier in STATUS_IDENTIFIERS - {"editor.statusBar"}
    )


def valid_long_status_context(row):
    value = row.get("statusContext")
    return isinstance(value, str) and len(value) >= 40 and " · " in value


def valid_budget_row(row):
    expected = EXPECTED_BUDGET_CASES.get(row.get("case"))
    if expected is None:
        return False
    charged, reserved, complete, items = expected
    return (
        row.get("charged") == charged
        and row.get("reserved") == reserved
        and row.get("complete") is complete
        and row.get("items") == items
        and valid_frame(row.get("popoverFrame"))
        and isinstance(row.get("statusValue"), str)
        and row["statusValue"].endswith(f"items={items}")
        and isinstance(row.get("screenshot"), str)
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
            timeout=120,
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
    budget = [row for row in rows if row.get("event") == "budget"]
    budget_lifecycle = [row for row in rows if row.get("event") == "budget-lifecycle"]
    unavailable_limits = [row for row in rows if row.get("event") == "budget-limits-unavailable"]
    project_switch = [row for row in rows if row.get("event") == "budget-project-switch"]
    background_status = [row for row in rows if row.get("event") == "background-status"]
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
    screenshots += [row.get("screenshot") for row in budget + project_switch
                    + budget_lifecycle + unavailable_limits]
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
        and all(valid_status_frames(row) for row in workspace_rows)
        and all(valid_long_status_context(row) for row in workspace_rows)
        and len(hidden) == 1
        and len(narrow) == 1
        and valid_status_frames(narrow[0])
        and valid_long_status_context(narrow[0])
        and len(pinned) == 1
        and len(invariants) == 1
        and {(row.get("family"), row.get("keyframes")) for row in inspector}
        == EXPECTED_INSPECTOR_CASES
        and len(inspector) == len(EXPECTED_INSPECTOR_CASES)
        and len(open_keyframes) == len(EXPECTED_KEYFRAME_LANES)
        and all(valid_keyframe_lane_evidence(row) for row in open_keyframes)
        and {row.get("case") for row in budget} == set(EXPECTED_BUDGET_CASES)
        and len(budget) == len(EXPECTED_BUDGET_CASES)
        and all(valid_budget_row(row) for row in budget)
        and len(budget_lifecycle) == len(EXPECTED_BUDGET_LIFECYCLE)
        and {row.get("state") for row in budget_lifecycle} == set(EXPECTED_BUDGET_LIFECYCLE)
        and all(row.get("events") == EXPECTED_BUDGET_LIFECYCLE.get(row.get("state"))
                for row in budget_lifecycle)
        and len(unavailable_limits) == 1
        and len(project_switch) == 1
        and valid_status_frames(project_switch[0])
        and valid_long_status_context(project_switch[0])
        and "planning=none" in project_switch[0].get("emptyValue", "")
        and "stop=none" in project_switch[0].get("emptyValue", "")
        and "planning=10.00" in project_switch[0].get("restoredValue", "")
        and "stop=12.00" in project_switch[0].get("restoredValue", "")
        and len(background_status) == 1
        and background_status[0].get("aiActiveObserved") is True
        and background_status[0].get("exportActiveObserved") is True
        and background_status[0].get("controlsClicked") is True
        and valid_status_frames(background_status[0])
        and invariants[0].get("liveStateUnchanged") is True
        and invariants[0].get("projectBytesUnchanged") is True
        and invariants[0].get("undoUnchanged") is True
        and invariants[0].get("workingCopyUnchanged") is True
        and len(screenshots)
        == 9 + len(EXPECTED_INSPECTOR_CASES) + len(EXPECTED_KEYFRAME_LANES)
        + len(EXPECTED_BUDGET_CASES) + len(EXPECTED_BUDGET_LIFECYCLE) + 1
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
