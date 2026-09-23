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


def valid_keyframe_lane_evidence(row):
    expected = EXPECTED_KEYFRAME_LANES.get(row.get("family"))
    evidence = row.get("laneLabelEvidence")
    if (
        expected is None
        or row.get("laneLabelVisibility") != "sequential-in-scroll-clip"
        or row.get("reachableLaneLabels") != expected
        or row.get("visibleLaneLabel") != expected[-1]
        or not isinstance(evidence, list)
        or [item.get("property") for item in evidence] != expected
    ):
        return False
    return all(
        item.get("visible") is True
        and valid_frame(item.get("clipFrame"))
        and valid_frame(item.get("panelFrame"))
        and valid_frame(item.get("probeFrame"))
        for item in evidence
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
    open_keyframes = [row for row in inspector if row.get("keyframes") == "open"]
    screenshots = [
        row.get("screenshot")
        for row in workspace_rows + hidden + narrow + pinned + inspector
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
        and invariants[0].get("liveStateUnchanged") is True
        and invariants[0].get("projectBytesUnchanged") is True
        and invariants[0].get("undoUnchanged") is True
        and invariants[0].get("workingCopyUnchanged") is True
        and len(screenshots) == 8 + len(EXPECTED_INSPECTOR_CASES)
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
