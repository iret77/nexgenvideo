"""Require complete framework results for an explicitly selected SwiftPM test scope."""
import argparse
import json
from pathlib import Path
import re


ANSI = re.compile(r"\x1b\][^\x07]*?(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]", re.S)
SWIFT_END = re.compile(r"^[✔━✘] Test run with (\d+) tests? in \d+ suites? (passed|failed) after .+\.$")
XCTEST = re.compile(r"^Test Suite 'All tests' (started|passed|failed) at .+\.$")
XCTEST_FILTERED = re.compile(r"^Test Suite 'Selected tests' (started|passed|failed) at .+\.$")
XCTEST_FAILURE = re.compile(r"^Test (?:Case|Suite) '.+' failed(?: at | \().+")


def assess_output(path, *, swift_testing_runs, xctest_runs, xctest_filtered=False):
    expected = {"swiftTesting": swift_testing_runs, "xctest": xctest_runs}
    starts = dict.fromkeys(expected, 0)
    ends = dict.fromkeys(expected, 0)
    active = dict.fromkeys(expected, False)
    failures = []
    xctest_pattern = XCTEST_FILTERED if xctest_filtered else XCTEST

    def event(library, state, number):
        if state == "started":
            if active[library]:
                failures.append({"line": number, "reason": library + ".unfinished-before-next-run"})
            starts[library] += 1
            active[library] = True
        else:
            if not active[library]:
                failures.append({"line": number, "reason": library + ".end-without-start"})
            ends[library] += 1
            active[library] = False
            if state == "failed":
                failures.append({"line": number, "reason": library + ".failed-run"})

    with Path(path).open(encoding="utf-8", errors="replace") as stream:
        for number, raw in enumerate(stream, 1):
            line = ANSI.sub("", raw).rstrip("\r\n")
            if line.startswith("✘ "):
                failures.append({"line": number, "reason": "swiftTesting.explicit-failure"})
            if XCTEST_FAILURE.match(line):
                failures.append({"line": number, "reason": "xctest.explicit-failure"})
            if line == "◇ Test run started.":
                event("swiftTesting", "started", number)
            elif match := SWIFT_END.fullmatch(line):
                event("swiftTesting", match[2], number)
                if int(match[1]) == 0:
                    failures.append({"line": number, "reason": "swiftTesting.empty-selected-run"})
            elif match := xctest_pattern.fullmatch(line):
                event("xctest", match[1], number)
    for library, count in expected.items():
        if starts[library] != count or ends[library] != count or active[library]:
            failures.append({"reason": library + ".incomplete-selected-runs"})
    return {"passed": not failures, "expectedRuns": expected,
            "startedRuns": starts, "completedRuns": ends, "failures": failures}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--swift-testing-runs", required=True, type=int)
    parser.add_argument("--xctest-runs", required=True, type=int)
    args = parser.parse_args()
    if min(args.swift_testing_runs, args.xctest_runs) < 1:
        parser.error("Both selected framework run counts must be positive")
    result = assess_output(args.log, swift_testing_runs=args.swift_testing_runs, xctest_runs=args.xctest_runs)
    print("Swift test output completion: " + json.dumps(result, sort_keys=True))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
