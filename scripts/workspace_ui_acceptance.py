"""Exercise and verify the native five-workspace editor on a macOS 26 runner."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


EXPECTED_WORKSPACES = {"media", "production", "edit", "postproduction", "export"}
SCALES = (1.0, 1.25, 1.5)


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
    selection_source = [row for row in rows if row.get("event") == "selection-source"]
    selection_timeline = [row for row in rows if row.get("event") == "selection-timeline"]
    invariants = [row for row in rows if row.get("event") == "invariants"]
    screenshots = [
        row.get("screenshot")
        for row in workspace_rows + hidden + narrow + pinned + selection_source + selection_timeline
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
        and invariants[0].get("liveStateUnchanged") is True
        and invariants[0].get("projectBytesUnchanged") is True
        and invariants[0].get("undoUnchanged") is True
        and invariants[0].get("workingCopyUnchanged") is True
        and len(screenshots) == 10
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
