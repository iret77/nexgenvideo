#!/usr/bin/env python3
"""Validate a released control replay and require the candidate replay to finish."""
import argparse
import json
from pathlib import Path
import sys

FAILURE_WINDOW_FROM_END = 5


def verification_errors(result, expected, maximum_pulse_gap=5.0):
    if expected not in {"baseline", "candidate"}:
        raise ValueError(f"unknown expectation: {expected}")
    errors = []
    progress = result.get("progress")

    if result.get("geometryRequested") is not True:
        errors.append("recorded geometry was not requested")

    if expected == "baseline":
        if not isinstance(progress, dict):
            errors.append("released control never published replay progress")
            return errors
        if result.get("timedOut") is True:
            if progress.get("finished") is not False:
                errors.append("timed-out released control reported a finished replay")
            sequence = progress.get("sequence")
            last_sequence = result.get("lastSequence")
            if type(sequence) is not int or type(last_sequence) is not int:
                errors.append("released control did not identify the stalled sequence")
            elif not last_sequence - FAILURE_WINDOW_FROM_END <= sequence < last_sequence:
                errors.append(
                    f"released control stalled at sequence {sequence}, outside the captured failure window"
                )
        else:
            if result.get("exitCode") != 0:
                errors.append(f"released control exited with {result.get('exitCode')!r}")
            if progress.get("finished") is not True or progress.get("sequence") is not None:
                errors.append("released control did not finish every captured state")
        return errors

    if result.get("timedOut") is not False:
        errors.append("candidate replay timed out")
    if result.get("exitCode") != 0:
        errors.append(f"candidate exited with {result.get('exitCode')!r}")
    if not isinstance(progress, dict):
        errors.append("candidate never published final replay progress")
        return errors
    if progress.get("finished") is not True or progress.get("sequence") is not None:
        errors.append("candidate did not finish every captured state")
    pulse_gap = progress.get("maximumPulseGap")
    if not isinstance(pulse_gap, (int, float)):
        errors.append("candidate did not report main-thread pulse latency")
    elif pulse_gap > maximum_pulse_gap:
        errors.append(
            f"candidate main-thread pulse gap {pulse_gap:.3f}s exceeded {maximum_pulse_gap:.3f}s"
        )
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result", type=Path)
    parser.add_argument("--expect", choices=("baseline", "candidate"), required=True)
    parser.add_argument("--maximum-pulse-gap", type=float, default=5.0)
    args = parser.parse_args()

    result = json.loads(args.result.read_text())
    errors = verification_errors(result, args.expect, args.maximum_pulse_gap)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"{args.expect} replay satisfied its independent acceptance criteria")
    return 0


if __name__ == "__main__":
    sys.exit(main())
