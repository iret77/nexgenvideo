#!/usr/bin/env python3
"""Validate a released control replay and require the candidate replay to finish."""
import argparse
import json
import math
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
        errors.extend(geometry_errors(result, progress))
        if result.get("timedOut") is True:
            if progress.get("finished") is not False:
                errors.append("timed-out released control reported a finished replay")
            sequence = progress.get("sequence")
            last_sequence = result.get("lastSequence")
            if type(sequence) is not int or type(last_sequence) is not int:
                errors.append("released control did not identify the stalled sequence")
            elif not last_sequence - FAILURE_WINDOW_FROM_END <= sequence <= last_sequence:
                errors.append(
                    f"released control stalled at sequence {sequence}, outside the captured failure window"
                )
        else:
            if result.get("exitCode") != 0:
                errors.append(f"released control exited with {result.get('exitCode')!r}")
            if progress.get("finished") is not True or progress.get("sequence") is not None:
                errors.append("released control did not finish every captured state")
        return errors

    if isinstance(progress, dict):
        errors.extend(geometry_errors(result, progress))
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
    if type(pulse_gap) not in (int, float) or not math.isfinite(pulse_gap) or pulse_gap < 0:
        errors.append("candidate did not report main-thread pulse latency")
    elif pulse_gap > maximum_pulse_gap:
        errors.append(
            f"candidate main-thread pulse gap {pulse_gap:.3f}s exceeded {maximum_pulse_gap:.3f}s"
        )
    return errors


def geometry_errors(result, progress, tolerance=1.0):
    if result.get("geometryRequested") is not True:
        return []
    errors = []
    source = result.get("transcriptGeometrySource")
    if source not in ("recorded", "comparison"):
        errors.append("transcript geometry source is unavailable")
    if progress.get("transcriptGeometrySource") != source:
        errors.append("replay transcript geometry source does not match the declared source")
    if source == "comparison" and any(f"recordedTranscript{dimension}" in result for dimension in ("Width", "Height")):
        errors.append("comparison geometry must not replace recorded transcript geometry")
    if source == "recorded" and any(f"comparisonTranscript{dimension}" in result for dimension in ("Width", "Height")):
        errors.append("recorded geometry must not declare a comparison viewport")
    fields = [("WindowWidth", "window width", "recorded"), ("WindowHeight", "window height", "recorded")]
    if source in ("recorded", "comparison"):
        fields.extend((field, label, source) for field, label in
                      (("TranscriptWidth", "transcript width"), ("TranscriptHeight", "transcript height")))
    for field, label, origin in fields:
        expected = result.get(f"{origin}{field}")
        actual = progress.get(field[0].lower() + field[1:])
        if (
            isinstance(expected, bool)
            or not isinstance(expected, (int, float))
            or not math.isfinite(expected)
            or expected <= 0
        ):
            errors.append(f"{origin} {label} is unavailable")
        elif (
            isinstance(actual, bool)
            or not isinstance(actual, (int, float))
            or not math.isfinite(actual)
            or actual <= 0
        ):
            errors.append(f"replay {label} is unavailable")
        elif abs(actual - expected) > tolerance:
            errors.append(
                f"replay {label} {actual:.1f} does not match {origin} {expected:.1f}"
            )
    target = progress.get("transcriptScrollTarget")
    if not isinstance(target, str) or not target or progress.get("scrollTarget") != target:
        errors.append("scroll target was not the full diagnostic transcript")
    events = progress.get("scrollEventsSent")
    if type(events) is not int or events < 3:
        errors.append("no complete scroll gesture was sent to the transcript")
    motion = progress.get("scrollMotion")
    if not isinstance(motion, dict) or motion.get("target") != target:
        errors.append("no scroll movement was measured on the transcript")
    else:
        fields = [motion.get(key) for key in ("before", "after", "contentHeight", "viewportHeight")]
        if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
               for value in fields):
            errors.append("transcript scroll movement has invalid geometry")
        else:
            before, after, content, viewport = fields
            if not (viewport > 0 and 0 < before < content - viewport and 0 <= after <= before - 1):
                errors.append("scroll gesture did not move the transcript away from its interior offset")
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
