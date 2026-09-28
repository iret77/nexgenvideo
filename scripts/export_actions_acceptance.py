#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    executable = args.app / "Contents" / "MacOS" / "NexGenVideo"
    if not executable.is_file():
        raise SystemExit(f"app executable not found: {executable}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    environment = {
        **os.environ,
        "NGV_EXPORT_ACTIONS_SELFTEST": "1",
        "NGV_EXPORT_ACTIONS_SELFTEST_OUTPUT": str(args.output.resolve()),
    }
    completed = subprocess.run(
        [str(executable)],
        env=environment,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    if completed.returncode != 0:
        raise SystemExit(
            f"native export actions failed ({completed.returncode})\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    if "SELFTEST_EXPORT_ACTIONS_OK" not in completed.stdout:
        raise SystemExit(f"native export actions produced no success marker: {completed.stdout}")
    evidence = json.loads(args.output.read_text())
    required = {
        "ownerKey",
        "completedJobID",
        "cancelledJobID",
        "retriedFromJobID",
        "retryJobID",
        "revealedPath",
        "cancelStatus",
        "retryStatus",
        "finalActionChecks",
        "disabledActionChecks",
        "hiddenActionChecks",
        "offscreenActionChecks",
        "finderWindowReacquired",
    }
    if set(evidence) != required:
        raise SystemExit(f"unexpected native export evidence keys: {sorted(evidence)}")
    if evidence["cancelStatus"] != "cancelled" or evidence["retryStatus"] != "cancelled":
        raise SystemExit(f"native export action states are wrong: {evidence}")
    if evidence["retriedFromJobID"] != evidence["cancelledJobID"]:
        raise SystemExit(f"native retry was not bound to the cancelled job: {evidence}")
    if evidence["finalActionChecks"] != 9 or evidence["disabledActionChecks"] != 6:
        raise SystemExit(f"native control coverage is incomplete: {evidence}")
    if evidence["hiddenActionChecks"] != 1 or evidence["offscreenActionChecks"] != 1:
        raise SystemExit(f"native visibility coverage is incomplete: {evidence}")
    if evidence["finderWindowReacquired"] is not True:
        raise SystemExit(f"export window did not reacquire key status: {evidence}")
    job_ids = [
        evidence["completedJobID"],
        evidence["cancelledJobID"],
        evidence["retryJobID"],
    ]
    if len(set(job_ids)) != len(job_ids):
        raise SystemExit(f"native export actions did not bind distinct jobs: {job_ids}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
