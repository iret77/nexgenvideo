"""Observe the two render-review XCTest methods without stopping their process."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import threading
import time


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("The existing swift test command is required")
    args.evidence.mkdir(parents=True, exist_ok=False)
    run = {"runID": os.environ.get("GITHUB_RUN_ID"), "sourceSHA": os.environ.get("GITHUB_SHA"),
           "command": command, "status": "running", "captureLimit": 1, "diagnosticDelaySeconds": 180,
           "sampleSeconds": SAMPLE_SECONDS, "captureTimeoutSeconds": CAPTURE_TIMEOUT_SECONDS}
    state = {"test": None, "lastStage": None, "changed": time.monotonic(), "selfPID": None}
    (args.evidence / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    environment = {**os.environ, "NGV_RENDER_REVIEW_TEST_DIAGNOSTIC": "1"}
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=environment)
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
            line = raw.decode("utf-8", errors="replace")
            case = CASE.search(line)
            if case:
                name = case[1] + "." + case[2]
                if name in TARGETS:
                    record({"test": name, "event": case[3], "nativeHeader": line})
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
    if sampler is not None:
        # Retain the one owned worker through its bounded ps/sample waits.
        sampler.join()
    run.update(status="test-process-exited", testExitCode=exit_code, captureAttempted=attempted)
    (args.evidence / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    return exit_code if exit_code >= 0 else 128 - exit_code


if __name__ == "__main__":
    sys.exit(main())
