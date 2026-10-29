"""Run XCTest, Engine Swift Testing and hosted App Swift Testing once each."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from verify_swift_test_output import ANSI, assess_output


NO_MATCH = "warning: No matching test cases were run"
XCTEST_START = re.compile(r"^Test Case '.+' started\.$")


class VerificationError(Exception):
    def __init__(self, message, exit_code=1):
        super().__init__(message)
        self.exit_code = exit_code if exit_code > 0 else 128 - exit_code if exit_code < 0 else 1


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".pending")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def swift_events(path, module):
    records = []
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise VerificationError("A native event record is not an object")
            version = record.get("version")
            if not (type(version) is int and version == 0
                    or isinstance(version, str) and version in {"6.3.0", "6.4.0", "6.5.0"}):
                raise VerificationError("Unsupported native event stream version")
            if records and version != records[0]["version"]:
                raise VerificationError("Native event stream changes schema version")
            records.append(record)
    tests = {}
    for record in records:
        if record.get("kind") != "test":
            continue
        test = record.get("payload")
        if not isinstance(test, dict) or test.get("kind") not in {"function", "suite"}:
            raise VerificationError("Invalid native discovery record")
        identity = test.get("id")
        if not isinstance(identity, str) or not identity or identity in tests:
            raise VerificationError("Missing or duplicate native discovery identity")
        tests[identity] = test
    active = Counter()
    cases = Counter()
    started = Counter()
    ended = Counter()
    skipped = set()
    run_starts = run_ends = 0
    running = False
    for record in records:
        if record.get("kind") != "event":
            continue
        event = record.get("payload")
        if not isinstance(event, dict):
            raise VerificationError("Invalid native event payload")
        kind = event.get("kind")
        if not isinstance(kind, str):
            raise VerificationError("Native event kind is not a string")
        if kind == "runStarted":
            run_starts += 1
            if running or run_ends:
                raise VerificationError("Native event stream starts another run")
            running = True
        elif kind == "runEnded":
            run_ends += 1
            if not running or any(active.values()) or any(cases.values()):
                raise VerificationError("Native run ended with unfinished tests")
            running = False
        elif kind in {"testCancelled", "testCaseCancelled"}:
            raise VerificationError("Native event stream contains cancellation")
        elif kind == "issueRecorded":
            issue = event.get("issue")
            if not isinstance(issue, dict):
                raise VerificationError("Malformed native issue record")
            legacy = record["version"] == 0
            known_value = issue.get("isKnown")
            modern_known = record["version"] == "6.5.0"
            valid_known = (known_value is None or type(known_value) is bool or isinstance(known_value, str)
                           if modern_known else type(known_value) is bool)
            if not valid_known or not legacy and type(issue.get("isFailure")) is not bool:
                raise VerificationError("Malformed native issue state")
            known = known_value is True or modern_known and isinstance(known_value, str)
            if (legacy or issue["isFailure"]) and not known:
                raise VerificationError("Native event stream contains a failing issue")
        elif kind in {"testStarted", "testEnded", "testSkipped", "testCaseStarted", "testCaseEnded"}:
            identity = event.get("testID")
            if not running or not isinstance(identity, str) or identity not in tests:
                raise VerificationError("Native test event has no active run or discovery identity")
            test = tests[identity]
            if test["kind"] == "function":
                location = test.get("sourceLocation", {})
                file_id = location.get("fileID") if isinstance(location, dict) else None
                if not isinstance(file_id, str) or file_id.partition("/")[0] != module:
                    raise VerificationError("Executed test does not belong to the selected test module")
            if kind == "testStarted":
                active[identity] += 1
                started[identity] += 1
            elif kind == "testEnded":
                if active[identity] != 1:
                    raise VerificationError("Native test end does not match one start")
                active[identity] -= 1
                ended[identity] += 1
            elif kind == "testSkipped":
                skipped.add(identity)
            elif kind == "testCaseStarted":
                cases[identity] += 1
            else:
                if cases[identity] < 1:
                    raise VerificationError("Native case end has no matching start")
                cases[identity] -= 1
    if run_starts != 1 or run_ends != 1 or running or started != ended:
        raise VerificationError("Native event stream has no single complete run")
    functions = {identity for identity, test in tests.items() if test["kind"] == "function"}
    executions = sum(started[identity] for identity in functions)
    return {"recordCount": len(records), "discoveredFunctionIDs": sorted(functions),
            "startedFunctionIDs": sorted(functions & started.keys()),
            "endedFunctionIDs": sorted(functions & ended.keys()),
            "skippedFunctionIDs": sorted(functions & skipped), "functionExecutions": executions,
            "runStarted": run_starts, "runEnded": run_ends,
            "emptySelection": not functions and executions == 0,
            "skippedSelection": bool(functions) and executions == 0 and bool(skipped)}


def host_receipt(path, events, *, pid, bundle, host, source_sha):
    receipt = json.loads(path.read_text())
    if (not isinstance(receipt, dict) or type(receipt.get("schema")) is not int
            or receipt["schema"] != 1 or receipt.get("pid") != pid
            or receipt.get("parentPID") != os.getpid()
            or receipt.get("bundleBinary") != str(bundle.resolve())
            or receipt.get("hostExecutable") != str(host.resolve())
            or receipt.get("sourceSHA") != source_sha
            or any(receipt.get(key) is not True for key in (
                "mainThread", "applicationRunningAtStart", "started", "completed",
                "abiSucceeded", "runReturnedAfterCompletion"))
            or receipt.get("recordingError") is not None or receipt.get("error") is not None
            or type(receipt.get("eventRecordCount")) is not int
            or receipt["eventRecordCount"] != events["recordCount"]):
        raise VerificationError("AppKit host receipt does not prove the owned ABI execution")
    return receipt


def framework_output(path, swift_runs, xctest_runs, *, xctest_filtered=False):
    result = assess_output(path, swift_testing_runs=swift_runs, xctest_runs=xctest_runs,
                           xctest_filtered=xctest_filtered)
    if not result["passed"]:
        raise VerificationError("Incomplete selected framework output: " + json.dumps(result, sort_keys=True))
    return result


def empty_swift_output(path):
    result = assess_output(path, swift_testing_runs=1, xctest_runs=0)
    counts = (result["startedRuns"]["swiftTesting"], result["completedRuns"]["swiftTesting"])
    reasons = {failure["reason"] for failure in result["failures"]}
    expected = {(0, 0): {"swiftTesting.incomplete-selected-runs"},
                (1, 1): {"swiftTesting.empty-selected-run"}}
    if (counts not in expected or reasons != expected[counts]
            or result["startedRuns"]["xctest"] or result["completedRuns"]["xctest"]):
        raise VerificationError("Empty native selection has inconsistent console output")
    return {"status": "empty-selection", "originalAssessment": result}


def run_process(command, path, environment):
    with path.open("w") as log:
        with subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, env=environment) as process:
            last_line = ""
            for line in process.stdout:
                log.write(line)
                print(line, end="", flush=True)
                last_line = line
            if last_line and not last_line.endswith("\n"):
                print(flush=True)
            code = process.wait()
            return code, process.pid


def app_environment(environment, binary_root, bundle, folder):
    environment = dict(environment)
    queries = []

    def selected_path(command, name):
        query = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, env=environment, timeout=60)
        (folder / (name + ".stdout")).write_text(query.stdout)
        (folder / (name + ".stderr")).write_text(query.stderr)
        queries.append({"command": command, "exitCode": query.returncode})
        value = query.stdout.strip()
        if query.returncode or "\n" in value or not Path(value).is_absolute():
            raise VerificationError("Could not resolve the selected " + name, query.returncode)
        return Path(value).resolve(strict=True)

    def append(key, path):
        current = [value for value in environment.get(key, "").split(os.pathsep) if value]
        current.append(str(path))
        environment[key] = os.pathsep.join(current)

    append("DYLD_LIBRARY_PATH", binary_root)
    compiler = selected_path(["xcrun", "--find", "swiftc"], "swiftc-path")
    frameworks = (compiler.parent / "../../Library/Developer/Frameworks").resolve()
    testing_libraries = compiler.parent.parent / "lib/swift/macosx/testing"
    if (frameworks / "Testing.framework").exists():
        append("DYLD_FRAMEWORK_PATH", frameworks)
        append("DYLD_LIBRARY_PATH", frameworks.parent / "usr/lib")
    elif testing_libraries.exists():
        append("DYLD_LIBRARY_PATH", testing_libraries)
    override = environment.get("SWIFTPM_PLATFORM_PATH_macosx")
    if override:
        if not Path(override).is_absolute():
            raise VerificationError("The selected macOS platform override must be absolute")
        platform = Path(override).resolve(strict=True)
    else:
        platform = selected_path(["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], "platform-path")
    append("DYLD_FRAMEWORK_PATH", platform / "Developer/Library/Frameworks")
    append("DYLD_FRAMEWORK_PATH", platform / "Developer/Library/PrivateFrameworks")
    append("DYLD_LIBRARY_PATH", platform / "Developer/usr/lib")
    staged = bundle.parent.parent / "Frameworks"
    if staged.is_dir():
        append("DYLD_FRAMEWORK_PATH", staged)
        append("DYLD_LIBRARY_PATH", staged)
    environment["NO_COLOR"] = "1"
    write_json(folder / "loader-paths.json", {
        "queries": queries, "swiftCompiler": str(compiler), "platform": str(platform),
        "platformOverride": bool(override),
        "DYLD_FRAMEWORK_PATH": environment.get("DYLD_FRAMEWORK_PATH", ""),
        "DYLD_LIBRARY_PATH": environment["DYLD_LIBRARY_PATH"], "NO_COLOR": "1"})
    return environment


def run(args):
    source_sha = os.environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[a-f0-9]{40}", source_sha):
        raise VerificationError("The actual Actions source SHA is required")
    args.evidence.mkdir(parents=True, exist_ok=False)
    result_path = args.evidence / "suite.json"
    result = {"schema": 1, "sourceSHA": source_sha, "scope": args.scope,
              "filter": args.filter, "completed": False, "phases": [],
              "configuration": args.configuration, "scratchPath": args.scratch_path}
    common = ["--cache-path", args.cache_path, "-c", args.configuration]
    if args.scratch_path:
        common += ["--scratch-path", args.scratch_path]
    for flag in args.swiftc_flag:
        common += ["-Xswiftc", flag]
    try:
        query = ["swift", "build", *common, "--show-bin-path"]
        query_result = subprocess.run(query, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True, timeout=60)
        (args.evidence / "bin-path.stdout").write_text(query_result.stdout)
        (args.evidence / "bin-path.stderr").write_text(query_result.stderr)
        result["binPathCommand"] = query
        result["binPathExitCode"] = query_result.returncode
        if query_result.returncode:
            raise VerificationError("Could not resolve the exact built products", query_result.returncode)
        path_lines = query_result.stdout.strip().split("\n")
        if len(path_lines) != 1 or not Path(path_lines[0]).is_absolute():
            raise VerificationError("SwiftPM did not return one absolute bin path")
        binary_root = Path(path_lines[0]).resolve(strict=True)
        host = binary_root / "NexGenVideoAppKitTestHost"
        bundle = binary_root / "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"
        if not host.is_file() or not os.access(host, os.X_OK) or not bundle.is_file():
            raise VerificationError("The built AppKit host or App test bundle is absent")
        result["binPath"] = str(binary_root)
        filters = ["--filter", args.filter] if args.filter else []
        phases = (["xctest", "engine-swift-testing"] if args.scope == "all" else []) + ["app-swift-testing"]
        executions = 0
        combined = args.evidence / "combined.log"
        combined.write_text("")
        for name in phases:
            folder = args.evidence / name
            folder.mkdir()
            log = folder / "console.log"
            events_path = folder / "events.jsonl"
            receipt_path = folder / "host-receipt.json"
            environment = dict(os.environ)
            if name == "xctest":
                command = ["swift", "test", *common, "--skip-build", "--disable-swift-testing", *filters]
            elif name == "engine-swift-testing":
                command = ["swift", "test", *common, "--skip-build", "--test-product", "NexGenEngineTests",
                           "--disable-xctest", "--enable-swift-testing", "--event-stream-version", "0",
                           "--event-stream-output-path", str(events_path.resolve()), *filters]
            else:
                command = [str(host), "--event-stream-version", "0", *filters]
                environment = app_environment(environment, binary_root, bundle, folder)
                environment.update(NGV_APPKIT_TEST_BUNDLE=str(bundle.resolve()),
                                   NGV_APPKIT_TEST_EVENTS=str(events_path.resolve()),
                                   NGV_APPKIT_TEST_RECEIPT=str(receipt_path.resolve()))
            phase = {"name": name, "command": command, "status": "running", "log": str(log)}
            result["phases"].append(phase)
            write_json(result_path, result)
            code, pid = run_process(command, log, environment)
            phase.update(exitCode=code, pid=pid)
            with combined.open("a") as destination:
                text = log.read_text()
                destination.write(text)
                if text and not text.endswith("\n"):
                    destination.write("\n")
            if code:
                raise VerificationError(name + " returned a nonzero original exit", code)
            if name == "xctest":
                lines = [ANSI.sub("", line).rstrip("\r\n") for line in log.read_text().split("\n")]
                count = sum(bool(XCTEST_START.fullmatch(line)) for line in lines)
                if args.filter and count == 0 and NO_MATCH in lines:
                    phase.update(status="empty-selection", framework=framework_output(log, 0, 0))
                    continue
                phase["framework"] = framework_output(log, 0, 2, xctest_filtered=bool(args.filter))
                if count == 0:
                    raise VerificationError("XCTest completed without executing a selected test")
                phase["testCaseExecutions"] = count
                executions += count
            else:
                module = "NexGenEngineTests" if name == "engine-swift-testing" else "NexGenVideoTests"
                events = swift_events(events_path, module)
                phase["events"] = events
                if name == "app-swift-testing":
                    phase["originalHostReceipt"] = host_receipt(
                        receipt_path, events, pid=pid, bundle=bundle, host=host, source_sha=source_sha)
                if args.filter and (events["emptySelection"] or events["skippedSelection"]):
                    original = assess_output(log, swift_testing_runs=1, xctest_runs=0)
                    phase.update(status="empty-selection" if events["emptySelection"] else "skipped-selection",
                                 framework=original if original["passed"] else empty_swift_output(log))
                    continue
                phase["framework"] = framework_output(log, 1, 0)
                if not events["functionExecutions"]:
                    raise VerificationError(name + " executed no selected test function")
                executions += events["functionExecutions"]
            phase["status"] = "verified-execution"
        if executions == 0:
            raise VerificationError("The filter selected no executable test in any backend")
        if not args.filter:
            result["combinedFrameworks"] = framework_output(combined, 2 if args.scope == "all" else 1,
                                                             2 if args.scope == "all" else 0)
        result.update(completed=True, testExecutions=executions)
        write_json(result_path, result)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError, VerificationError) as error:
        result["error"] = str(error)
        if result["phases"] and result["phases"][-1]["status"] == "running":
            result["phases"][-1]["status"] = "failed"
        write_json(result_path, result)
        print("macOS test verification failed: " + str(error), file=sys.stderr, flush=True)
        return error.exit_code if isinstance(error, VerificationError) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-path", required=True)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("-c", "--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--scratch-path")
    parser.add_argument("--swiftc-flag", action="append", default=[])
    parser.add_argument("--filter", default="")
    parser.add_argument("--scope", choices=("all", "app-swift-testing"), default="all")
    args = parser.parse_args()
    if args.filter and not args.filter.strip():
        parser.error("An explicit filter cannot be whitespace only")
    try:
        return run(args)
    except (OSError, VerificationError) as error:
        print("macOS test verification failed: " + str(error), file=sys.stderr)
        return error.exit_code if isinstance(error, VerificationError) else 1


if __name__ == "__main__":
    sys.exit(main())
