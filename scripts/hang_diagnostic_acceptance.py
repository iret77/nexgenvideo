#!/usr/bin/env python3
"""Verify the shipped app's independent capture path; never use owner data."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("symbols", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path.home() / "Library/Logs/NexGenVideo/HangIncidents"
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for mode in ("wait", "spin"):
        before = set(root.glob("*"))
        process = subprocess.Popen([str(args.app / "Contents/MacOS/NexGenVideo")],
                                   env={**os.environ, "NGV_HANG_SELFTEST": mode},
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            process.wait(timeout=65)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise RuntimeError("diagnostic self-test did not recover")
        assert process.returncode == 0, process.returncode
        folders = set(root.glob("*")) - before
        assert len(folders) == 1, "exactly one recording required"
        folder = folders.pop()
        reports = list(folder.glob("incident-*/incident.json"))
        assert len(reports) == 1, "exactly one detected hang required"
        report = json.loads(reports[0].read_text())
        assert len(report["samples"]) == 2, report
        assert report.get("recoveredUptime"), report
        stacks = list(folder.glob("self-*.stacks"))
        assert len(stacks) == 6, "two captures of three raw stack snapshots required"
        symbolized = []
        for stack in stacks:
            text = stack.read_text()
            assert "NGV_SELF_STACKS_V1" in text
            images = [line.split() for line in text.splitlines() if line.startswith("image ")]
            symbol_uuid = subprocess.check_output(["dwarfdump", "--uuid", str(args.symbols)], text=True).split()[1].replace("-", "").lower()
            host = next(image for image in images if image[2] == symbol_uuid)
            addresses = [line for line in text.splitlines() if line.startswith("0x")]
            output = subprocess.check_output(["atos", "-arch", "arm64", "-o",
                str(args.symbols / "Contents/Resources/DWARF/NexGenVideo"), "-l", host[1],
                *addresses], text=True)
            symbolized.append(output)
        marker = "knownMainThreadWait" if mode == "wait" else "knownMainThreadSpin"
        assert any(marker in output for output in symbolized), "missing injected blocking frame"
        events = [record for file in folder.glob("events-*.json") for record in json.loads(file.read_text())]
        assert any(event["operation"] == ("testWait" if mode == "wait" else "testSpin") for event in events)
        results.append({"mode": mode, "samples": len(stacks), "symbolizedMarker": marker, "passed": True})
    (args.output / "result.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
