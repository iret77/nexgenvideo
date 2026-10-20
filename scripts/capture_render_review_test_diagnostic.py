"""Observe owned test processes and render-review stages without stopping them."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import select
import subprocess
import sys
import threading
import time

from verify_swift_test_output import ANSI, SWIFT_END, assess_output


TARGETS = {
    "PipelineRenderReviewManifestTests.testActualCanonicalSnapshotPreparePublishAndVerify",
    "PipelineRenderReviewRunVerificationTests.testCanonicalGraphPreservesEveryPageReductionAndFinding",
}
CASE = re.compile(r"Test Case '-\[NexGenVideoTests\.(\w+) (\w+)\]' (started|passed|failed)")
STAGE_PREFIX = "[render-review-test-stage] "
SAMPLE_SECONDS = 3
CAPTURE_TIMEOUT_SECONDS = 120


def process_tree(root_pid):
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,lstart=,comm="],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5, check=True,
    )
    rows = {}
    for line in result.stdout.splitlines():
        values = line.split(None, 7)
        if len(values) == 8:
            pid, parent = map(int, values[:2])
            rows[pid] = {"pid": pid, "parentPID": parent,
                         "started": " ".join(values[2:7]), "executable": values[7]}
    descendants = set()
    frontier = {root_pid}
    while frontier:
        frontier = {pid for pid, row in rows.items()
                    if row["parentPID"] in frontier and pid not in descendants}
        descendants.update(frontier)
    return rows, descendants


def capture(pid_identity, root_pid, evidence, request):
    command = ["/usr/bin/sample", str(pid_identity["pid"]), str(SAMPLE_SECONDS), "-file", str(evidence / "sample.txt")]
    receipt = {**request, "target": pid_identity, "status": "capture-unavailable",
               "requestedSampleCommand": command, "sampleSeconds": SAMPLE_SECONDS,
               "captureTimeoutSeconds": CAPTURE_TIMEOUT_SECONDS}
    try:
        rows, owned = process_tree(root_pid)
        if pid_identity["pid"] not in owned or rows.get(pid_identity["pid"]) != pid_identity:
            raise RuntimeError("The owned XCTest process identity changed before capture")
        with (evidence / "sample-command.log").open("wb") as log:
            result = subprocess.run(
                command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                timeout=CAPTURE_TIMEOUT_SECONDS, check=False,
            )
        receipt.update(status="capture-returned", returnCode=result.returncode)
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        receipt["error"] = str(error)
    sample = evidence / "sample.txt"
    if sample.is_file():
        receipt["sampleSHA256"] = hashlib.sha256(sample.read_bytes()).hexdigest()
        receipt["sampleBytes"] = sample.stat().st_size
    receipt["finishedMonotonic"] = time.monotonic()
    (evidence / "capture-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")



class TestProcessObservation:
    def __init__(self, evidence, root_pid):
        self.evidence, self.root_pid = evidence, root_pid
        self.events = (evidence / "process-events.jsonl").open("w")
        self.swift_events = (evidence / "swift-testing-events.jsonl").open("w")
        self.children = {}
        self.last_scan = 0
        self.run = 0
        self.active = False
        self.unfinished = Counter()
        self.summaries = []
        self.queue = None
        try:
            if sys.platform == "darwin":
                self.queue = select.kqueue()
        except OSError as error:
            self.record(event="observer-unavailable", error=str(error))

    def record(self, **row):
        self.events.write(json.dumps({"observedMonotonic": time.monotonic(), **row}) + "\n")
        self.events.flush()

    def watch(self, identity, *, self_report=None):
        pid = identity["pid"]
        if pid in self.children:
            if self.children[pid] == identity:
                if self_report is not None:
                    self.record(event="child-self-report-correlated", target=identity, selfReport=self_report)
            else:
                self.record(event="child-watch-unavailable", target=identity, selfReport=self_report,
                            error="The previously watched PID now has a different process identity")
            return
        if self.queue is None:
            self.record(event="child-watch-unavailable", target=identity, selfReport=self_report,
                        error="Darwin kqueue is unavailable")
            return
        # Darwin exposes NOTE_EXITSTATUS even when Python omits its name.
        note = select.kevent(pid, filter=select.KQ_FILTER_PROC,
            flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
            fflags=select.KQ_NOTE_EXIT | 0x04000000)
        try:
            self.queue.control([note], 0, 0)
            self.children[pid] = identity
            self.record(event="child-watch-registered", target=identity, selfReport=self_report)
        except OSError as error:
            self.record(event="child-watch-unavailable", target=identity, selfReport=self_report, error=str(error))

    def self_report(self, row):
        if (not isinstance(row, dict) or row.get("event") != "atexit-registration"
                or type(row.get("pid")) is not int or row["pid"] < 1
                or type(row.get("parentPID")) is not int or row["parentPID"] < 1):
            self.record(event="invalid-test-self-report", selfReport=row)
            return
        try:
            rows, owned = process_tree(self.root_pid)
            identity = rows.get(row["pid"])
            if row["pid"] not in owned or identity["parentPID"] != row["parentPID"]:
                self.record(event="self-report-watch-unavailable", selfReport=row,
                            error="The self-reported PID is absent from the owned tree or its parent changed")
                return
            self.watch(identity, self_report=row)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.record(event="self-report-watch-unavailable", selfReport=row, error=str(error))

    def tick(self, *, scan=False):
        if self.queue is None:
            return
        if scan or time.monotonic() - self.last_scan >= 1:
            self.last_scan = time.monotonic()
            try:
                rows, owned = process_tree(self.root_pid)
                for pid in owned:
                    identity = rows[pid]
                    executable = Path(identity["executable"])
                    if pid in self.children or not (identity["parentPID"] == self.root_pid or executable.name == "xctest" or ".xctest/" in str(executable)):
                        continue
                    self.watch(identity)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                self.record(event="process-scan-unavailable", error=str(error))
        try:
            for event in self.queue.control(None, max(1, len(self.children)), 0):
                row = {"event": "child-kernel-event", "target": self.children.get(event.ident),
                       "pid": event.ident, "flags": event.flags, "filterFlags": event.fflags,
                       "rawStatus": event.data}
                if event.fflags & select.KQ_NOTE_EXIT and event.fflags & 0x04000000:
                    row["exitCode"] = os.waitstatus_to_exitcode(event.data & 0xffff)
                self.record(**row)
        except (OSError, ValueError) as error:
            self.record(event="child-exit-observation-unavailable", error=str(error))

    def summary(self, reason):
        self.summaries.append({"run": self.run, "reason": reason,
            "unfinishedDisplayNames": dict(self.unfinished), "identity": "console-display-name-multiset"})

    def line(self, native_line):
        line = ANSI.sub("", native_line).rstrip("\r")
        if line.startswith("[swift-test-process] "):
            self.record(event="test-self-report", nativeHeader=native_line)
            try:
                self.self_report(json.loads(line[len("[swift-test-process] "):]))
            except ValueError as error:
                self.record(event="invalid-test-self-report", nativeHeader=native_line, error=str(error))
        if line == "◇ Test run started.":
            if self.active:
                self.summary("next-run-before-end")
            self.run += 1
            self.active = True
            self.unfinished.clear()
            self.tick(scan=True)
        if self.run and line[:1] in {"◇", "✔", "✘", "➜", "━"}:
            self.swift_events.write(json.dumps({"run": self.run, "nativeHeader": native_line}) + "\n")
            self.swift_events.flush()
        if match := re.fullmatch(r"◇ Test (.+) started\.", line):
            self.unfinished[match[1]] += 1
        elif match := re.fullmatch(r"[✔✘━] Test (.+) (?:passed|failed) after .+\.", line):
            name = match[1]
            if self.unfinished[name] > 0:
                self.unfinished[name] -= 1
                if not self.unfinished[name]:
                    del self.unfinished[name]
        if SWIFT_END.fullmatch(line):
            self.summary("framework-end")
            self.active = False

    def finish(self):
        self.tick()
        if self.active:
            self.summary("swiftpm-process-exited-before-end")
        (self.evidence / "swift-testing-observation.json").write_text(json.dumps(
            {"runs": self.summaries, "caveat": "Display names can collide; raw events remain authoritative. "
             "An atexit callback may also run on image unload; only kernel events establish process exit."},
            indent=2) + "\n")
        if self.queue is not None:
            self.queue.close()
        self.events.close()
        self.swift_events.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--swift-testing-runs", required=True, type=int)
    parser.add_argument("--xctest-runs", required=True, type=int)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if min(args.swift_testing_runs, args.xctest_runs) < 1:
        parser.error("Both selected framework run counts must be positive")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("The existing swift test command is required")
    args.evidence.mkdir(parents=True, exist_ok=False)
    run = {"runID": os.environ.get("GITHUB_RUN_ID"), "sourceSHA": os.environ.get("GITHUB_SHA"),
           "command": command, "status": "running", "captureLimit": 1, "diagnosticDelaySeconds": 180,
           "sampleSeconds": SAMPLE_SECONDS, "captureTimeoutSeconds": CAPTURE_TIMEOUT_SECONDS}
    state = {"test": None, "lastStage": None, "changed": time.monotonic(), "selfPID": None}
    (args.evidence / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    environment = {**os.environ, "NGV_RENDER_REVIEW_TEST_DIAGNOSTIC": "1",
                   "NGV_SWIFT_TEST_PROCESS_EVIDENCE": str(args.evidence.resolve())}
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=environment)
    observation = TestProcessObservation(args.evidence, process.pid)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = b""
    attempted = False
    sampler = None
    with args.log.open("wb") as log, (args.evidence / "stages.jsonl").open("w") as stages:
        def record(row):
            stages.write(json.dumps({"observedMonotonic": time.monotonic(), **row}) + "\n")
            stages.flush()

        def line_received(raw):
            native_line = raw.decode("utf-8", errors="replace")
            line = ANSI.sub("", native_line).rstrip("\r")
            observation.line(native_line)
            case = CASE.search(line)
            if case:
                name = case[1] + "." + case[2]
                if name in TARGETS:
                    record({"test": name, "event": case[3], "nativeHeader": native_line})
                    if case[3] == "started":
                        state.update(test=name, lastStage="xctest.started", selfPID=None, changed=time.monotonic())
                    elif state["test"] == name:
                        state.update(test=None, lastStage=case[3], changed=time.monotonic())
            if line.startswith(STAGE_PREFIX):
                try:
                    row = json.loads(line[len(STAGE_PREFIX):])
                    if row.get("test") in TARGETS:
                        record({"event": "fixture-stage", **row})
                        if state["test"] == row["test"]:
                            state.update(lastStage=row["stage"], selfPID=row["pid"], changed=time.monotonic())
                except (ValueError, KeyError, TypeError) as error:
                    record({"event": "invalid-stage", "error": str(error)})

        while selector.get_map() or process.poll() is None:
            observation.tick()
            for key, _ in selector.select(timeout=1):
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                log.write(data)
                log.flush()
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    line_received(line)
            if (not attempted and state["test"] and process.poll() is None
                    and time.monotonic() - state["changed"] >= 180):
                attempted = True
                request = {**run, "status": "capture-requested", "test": state["test"],
                           "lastStage": state["lastStage"], "requestedMonotonic": time.monotonic(),
                           "swiftTestPID": process.pid, "selfReportedPID": state["selfPID"]}
                (args.evidence / "capture-request.json").write_text(json.dumps(request, indent=2) + "\n")
                try:
                    rows, owned = process_tree(process.pid)
                    candidates = [rows[pid] for pid in owned if Path(rows[pid]["executable"]).name == "xctest"]
                    if len(candidates) != 1:
                        raise RuntimeError("Expected exactly one owned xctest descendant")
                    target = candidates[0]
                    if state["selfPID"] is not None and state["selfPID"] != target["pid"]:
                        raise RuntimeError("The self-reported PID differs from the owned xctest process")
                    sampler = threading.Thread(target=capture, args=(target, process.pid, args.evidence, request))
                    sampler.start()
                except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
                    (args.evidence / "capture-receipt.json").write_text(json.dumps(
                        {**request, "status": "capture-unavailable", "error": str(error)}, indent=2) + "\n")
        if pending:
            line_received(pending)
    selector.close()
    process.stdout.close()
    exit_code = process.wait()
    observation.finish()
    if sampler is not None:
        # Retain the one owned worker through its bounded ps/sample waits.
        sampler.join()
    effective_exit = exit_code if exit_code >= 0 else 128 - exit_code
    if exit_code == 0:
        output_result = assess_output(args.log, swift_testing_runs=args.swift_testing_runs,
                                      xctest_runs=args.xctest_runs)
        run["outputCompletion"] = output_result
        print("Swift test output completion: " + json.dumps(output_result, sort_keys=True), flush=True)
        if not output_result["passed"]:
            effective_exit = 1
    run.update(status="test-process-exited", testExitCode=exit_code,
               effectiveExitCode=effective_exit, captureAttempted=attempted)
    (args.evidence / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    return effective_exit


if __name__ == "__main__":
    sys.exit(main())
