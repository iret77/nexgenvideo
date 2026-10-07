#!/usr/bin/env python3
"""Summarize exported structural evidence without decrypting project content."""
import argparse
import hashlib
import json
from pathlib import Path


def analyze(folder):
    folder = Path(folder).resolve(strict=True)
    checksums = json.loads((folder / "checksums.json").read_text())
    if not isinstance(checksums, dict) or len(checksums) > 8192:
        raise ValueError("invalid checksum inventory")
    records, incidents, gaps = [], [], []
    total = 0
    for name, digest in checksums.items():
        file = folder / name
        if file.is_symlink() or not file.resolve(strict=True).is_relative_to(folder):
            raise ValueError("recording path escapes export")
        size = file.stat().st_size
        total += size
        if size > 40 * 1024 * 1024 or total > 1024 * 1024 * 1024:
            raise ValueError("recording exceeds bounds")
        data = file.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"checksum mismatch: {name}")
        if name.startswith("events-"):
            records.extend(json.loads(data))
        elif name.endswith("/incident.json"):
            incident = json.loads(data)
            expected = [f"{sample.split(':')[0]}-{index}.stacks"
                        for sample in incident.get("samples", []) for index in range(3)]
            missing = [path for path in expected if path not in checksums]
            incidents.append({"detectedUptime": incident.get("detectedUptime"),
                              "recoveredUptime": incident.get("recoveredUptime"),
                              "processLost": incident.get("processLost", False),
                              "missingStacks": missing})
            if missing:
                gaps.append("requested stack snapshots are missing")
        elif name in ("capture-error.json", "helper-error.json", "self-capture-error.json"):
            issue = json.loads(data)
            gaps.extend(issue if isinstance(issue, list) else [issue])
        elif name == "heartbeat.json" and json.loads(data).get("dropped", 0):
            gaps.append(f"{json.loads(data)['dropped']} dropped recording events/snapshots")
    records.sort(key=lambda item: item["sequence"])
    open_operations = {}
    spans = {"projection", "markdown", "imageDecode", "pipelineRefresh",
             "runtimeApply", "apiApply", "replaySnapshot", "testWait", "testSpin"}
    last = {}
    for record in records:
        operation = record["operation"]
        if operation in spans:
            if record["end"]:
                open_operations.pop(record["correlation"], None)
            else:
                open_operations[record["sequence"]] = record
        if operation in ("runtimeReceive", "runtimeApply", "apiReceive", "apiApply", "context", "scroll", "window"):
            last[operation] = record
    return {"schema": "hang-analysis/1", "verifiedFiles": len(checksums),
            "eventCount": len(records), "incidents": incidents, "gaps": gaps,
            "lastObservedEvents": last, "unfinishedOperations": list(open_operations.values())[-32:],
            "interpretation": "Unfinished operations and samples are evidence, not a proven root cause. Replay scope is declared in export.json."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.folder), indent=2))
