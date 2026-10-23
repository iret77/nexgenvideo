"""Exercise the real AppKit termination loop and production delegate on macOS."""
import argparse
from contextlib import suppress
import json
import os
from pathlib import Path
import subprocess
import time


MODES = ("raw-control", "task", "gcd", "modal", "duplicate", "cancel", "relaunch-cancel", "relaunch")
LIFECYCLE = ("cleanup-start", "cleanup-resumed", "cleanup-done", "will-terminate", "process-exit")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def read_events(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def verify(mode, events, pid, source_sha, returncode, timed_out=False):
    require(events and all(event.get("sourceSHA") == source_sha for event in events), "missing or foreign-source events")
    own = [event for event in events if event["pid"] == pid]
    names = [event["event"] for event in own]
    require(names.count("boot") == 1, "missing or duplicate original boot")
    require(not any(event["event"] == "reopener-failed" for event in events), "restart preparation failed")
    if mode == "raw-control":
        require(timed_out and returncode is None, "direct MainActor control did not reproduce the hang")
        require(names.count("should-terminate") == 1, "control never reached termination")
        require(not set(names).intersection(LIFECYCLE), "control entered async cleanup or exited")
        require({event["pid"] for event in events} == {pid}, "foreign process in control")
        return
    require(not timed_out and returncode == 0, "app did not exit normally")
    require(all(names.count(name) == 1 for name in LIFECYCLE), "incomplete or repeated cleanup/normal-exit proof")
    positions = [names.index(name) for name in LIFECYCLE]
    require(positions == sorted(positions), "cleanup and exit are out of order")
    expected_replies = 2 if mode in ("cancel", "relaunch-cancel") else 1
    require(names.count("reply-later") == expected_replies, "unexpected asynchronous delegate reply count")
    require(names.count("should-terminate") == expected_replies + names.count("reply-cancel"), "unaccounted delegate request")
    require("reply-now" not in names and "reply-unknown" not in names, "unexpected delegate reply")
    if mode != "duplicate":
        require("reply-cancel" not in names, "unexpected duplicate delegate cancellation")
    if mode in ("task", "gcd", "modal", "duplicate", "cancel"):
        require(names.count("request-accepted") == 1 and "request-rejected" not in names, "shared termination path was not accepted once")
    require("duplicate-accepted" not in names, "duplicate programmatic quit was accepted")
    if mode == "duplicate":
        require(names.count("duplicate-rejected") == 2, "duplicates were not coalesced")
        require(names.count("native-duplicate-returned") == 1, "native re-entry did not return")
        require(names.index("native-duplicate-returned") < names.index("cleanup-done"), "native re-entry missed pending cleanup")
    if mode == "modal":
        require(names.count("modal-start") == names.count("modal-returned") == 1, "modal control did not return")
        require(names.count("modal-active") == 1 and names.index("modal-active") < names.index("modal-returned"), "native modal was not exercised")
        require(names.index("modal-returned") < names.index("should-terminate"), "quit entered a nested modal loop")
    if mode in ("cancel", "relaunch-cancel"):
        cancelled = next(event for event in own if event["event"] == "cancelled")
        alive = next(event for event in own if event["event"] == "alive-after-cancel")
        require(alive["uptime"] - cancelled["uptime"] >= 3.4, "cancel was not observed past the former forced-exit deadline")
        require(names.index("alive-after-cancel") < names.index("cleanup-start"), "cancellation did not preserve the app")
    if mode != "relaunch":
        require(not any(event["event"] in ("relaunch-commit", "reopener-started", "reopened") for event in events), "unapproved restart occurred")
        require({event["pid"] for event in events} == {pid}, "unexpected second application instance")
    else:
        require(names.count("relaunch-commit") == names.count("reopener-started") == 1, "restart was not committed exactly once")
        require(names.index("will-terminate") < names.index("relaunch-commit") < names.index("reopener-started") < names.index("process-exit"), "restart preceded confirmed cleanup")
        child = next(event["childPID"] for event in own if event["event"] == "reopener-started")
        require(child != pid and {event["pid"] for event in events} == {pid, child}, "restart process identity mismatch")
        reopened = [event["event"] for event in events if event["pid"] == child]
        require(reopened.count("reopened") == 1, "missing or duplicate reopened instance")
        require(all(reopened.count(name) == 1 for name in LIFECYCLE), "reopened app did not clean up and exit normally")
        require([reopened.index(name) for name in LIFECYCLE] == sorted(reopened.index(name) for name in LIFECYCLE), "reopened cleanup order changed")
        require(next(event["uptime"] for event in events if event["event"] == "reopened") > own[names.index("process-exit")]["uptime"], "new app started before the old app's normal exit")


def process_command(pid):
    result = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
    require(result.returncode in (0, 1), "cannot inspect owned process")
    return result.stdout.strip()


def owned_reopener_command(command, binary):
    return (command == str(binary) or command.startswith(str(binary) + " ")
            or (command.startswith("/bin/sh -c ") and "nexgenvideo-relaunch" in command and str(binary) in command))


def capture(process, directory):
    if process.poll() is None:
        capture_pid(process.pid, directory, "sample")


def capture_pid(pid, directory, name):
    with (directory / (name + "-tool.log")).open("wb") as log:
        subprocess.run(["/usr/bin/sample", str(pid), "3", "-mayDie", "-file", str(directory / (name + ".log"))],
                       stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=30, check=True)


def run_case(binary, root, mode, source_sha):
    directory = root / mode
    directory.mkdir()
    path = directory / "events.jsonl"
    environment = dict(os.environ, NGV_TERMINATION_SELFTEST=mode, NGV_TERMINATION_EVIDENCE=str(path))
    with (directory / "console.log").open("wb") as console:
        process = subprocess.Popen([str(binary)], env=environment, stdin=subprocess.DEVNULL,
                                   stdout=console, stderr=subprocess.STDOUT)
        timed_out = False
        capture_attempted = False
        try:
            try:
                process.wait(timeout=10 if mode == "raw-control" else 25)
            except subprocess.TimeoutExpired:
                timed_out = True
                capture_attempted = True
                capture(process, directory)
            if mode == "relaunch" and not timed_out:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if sum(event["event"] == "process-exit" for event in read_events(path)) == 2:
                        break
                    time.sleep(0.05)
            events = read_events(path)
            verify(mode, events, process.pid, source_sha, process.returncode, timed_out)
            if mode == "raw-control":
                sample = (directory / "sample.log").read_text()
                require("NSApplication terminate:" in sample and "_shouldTerminate" in sample, "control sample does not prove the same termination wait")
            report = dict(mode=mode, pid=process.pid, sourceSHA=source_sha, returncode=process.returncode,
                          timedOut=timed_out, events=events, passed=True)
        except BaseException as error:
            (directory / "failure.json").write_text(json.dumps(dict(error=str(error), pid=process.pid)) + "\n")
            if process.poll() is None and not capture_attempted:
                try:
                    capture(process, directory)
                except Exception as capture_error:
                    (directory / "capture-error.json").write_text(json.dumps(dict(error=str(capture_error))) + "\n")
            raise
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            for event in read_events(path):
                if event["event"] != "reopener-started" or event["pid"] != process.pid:
                    continue
                child = event["childPID"]
                deadline = time.monotonic() + 2
                while process_command(child) and time.monotonic() < deadline:
                    time.sleep(0.05)
                command = process_command(child)
                if command:
                    require(owned_reopener_command(command, binary), "refusing to stop an unrelated process")
                    try:
                        capture_pid(child, directory, "reopened-sample")
                    except Exception as error:
                        with suppress(OSError):
                            (directory / "reopened-sample-error.json").write_text(json.dumps(dict(error=str(error))) + "\n")
                    command = process_command(child)
                    if command:
                        require(owned_reopener_command(command, binary), "refusing to stop a reused unrelated PID")
                        with suppress(ProcessLookupError):
                            os.kill(child, 9)
                    raise AssertionError("owned reopener or reopened app survived its acceptance case")
        report["reapedOriginalReturncode"] = process.returncode
        (directory / "result.json").write_text(json.dumps(report, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    require(os.environ.get("GITHUB_ACTIONS") == "true", "native acceptance runs only in Actions")
    source_sha = os.environ.get("GITHUB_SHA", "")
    require(len(source_sha) == 40 and all(char in "0123456789abcdef" for char in source_sha), "missing source binding")
    binary = args.app.resolve() / "Contents/MacOS/NexGenVideo"
    require(binary.is_file(), "missing app executable")
    args.output.mkdir(parents=True, exist_ok=False)
    failures = {}
    for mode in MODES:
        try:
            run_case(binary, args.output.resolve(), mode, source_sha)
        except Exception as error:
            failures[mode] = str(error)
    (args.output / "result.json").write_text(json.dumps(dict(sourceSHA=source_sha, modes=list(MODES),
                                                            passed=not failures, failures=failures)) + "\n")
    require(not failures, "Native termination failures: " + json.dumps(failures))
    print("Native termination: all eight cases passed")


if __name__ == "__main__":
    main()
