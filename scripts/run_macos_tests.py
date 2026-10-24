"""Run XCTest, Engine Swift Testing and hosted App Swift Testing once each."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import time
import uuid

from verify_swift_test_output import ANSI, assess_output
from app_host_zombie_diagnostic import ZombieCapture, diagnostic_environment


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


def run_process(command, path, environment, observation=None):
    with path.open("w") as log:
        with subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, env=environment) as process:
            if observation is not None:
                observation.update(pid=process.pid, launchLatest=time.time())
            diagnostic = None
            if observation is not None and observation.get("diagnosticProfile") in ("zombies", "glow-reproduction"):
                try:
                    diagnostic = ZombieCapture(process.pid, command, observation, path.parent,
                                               environment["GITHUB_SHA"], profile=observation["diagnosticProfile"])
                    diagnostic.start()
                except Exception as error:
                    observation["diagnostic"] = {"status": "unavailable", "errorType": type(error).__name__}
            last_line = ""
            try:
                for line in process.stdout:
                    log.write(line)
                    print(line, end="", flush=True)
                    last_line = line
            finally:
                if diagnostic is not None:
                    try:
                        observation["diagnostic"] = diagnostic.finish()
                    except Exception as error:
                        observation["diagnostic"] = {"status": "unavailable", "errorType": type(error).__name__}
            if last_line and not last_line.endswith("\n"):
                print(flush=True)
            code = process.wait()
            if observation is not None:
                observation["exitObserved"] = time.time()
            return code, process.pid


def host_binary_identity(host):
    digest = hashlib.sha256()
    with host.open("rb") as stream:
        header = stream.read(32)
        commands = b""
        if len(header) == 32 and struct.unpack_from("<I", header)[0] == 0xFEEDFACF:
            size = struct.unpack_from("<I", header, 20)[0]
            if size <= 1024 * 1024:
                commands = stream.read(size)
        stream.seek(0)
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    image_uuid = None
    offset = 0
    while offset + 8 <= len(commands):
        kind, size = struct.unpack_from("<II", commands, offset)
        if size < 8 or offset + size > len(commands):
            break
        if kind == 0x1B and size == 24:
            image_uuid = str(uuid.UUID(bytes=commands[offset + 8:offset + 24]))
            break
        offset += size
    return {"hostExecutable": str(host.resolve()), "hostSHA256": digest.hexdigest(), "hostUUID": image_uuid}


def report_directories():
    return [Path.home() / "Library/Logs/DiagnosticReports", Path("/Library/Logs/DiagnosticReports")]


WATCHDOG_NAME = re.compile(r"NexGenVideo-\d{4}-\d{2}-\d{2}T\d{6}Z-main-thread-hang(?:\.json|\.sample\.txt)")
WATCHDOG_REPORT_BYTES = 1024 * 1024
WATCHDOG_TOTAL_BYTES = 32 * 1024 * 1024


def watchdog_report_directory():
    return Path.home() / "Library/Logs/NexGenVideo"


def watchdog_identity(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns]


def watchdog_candidates(directory):
    candidates = {}
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with os.scandir(fd) as entries:
            for entry in entries:
                if not WATCHDOG_NAME.fullmatch(entry.name):
                    continue
                if len(candidates) >= 128:
                    raise ValueError("Watchdog candidate limit reached")
                try:
                    candidates[entry.name] = watchdog_identity(entry.stat(follow_symlinks=False))
                except OSError as error:
                    raise ValueError("Watchdog candidate inspection failed: " + str(error)) from error
    finally:
        os.close(fd)
    return candidates


def read_watchdog_file(directory_fd, name, identity, limit):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise ValueError("Watchdog file is not regular or exceeds the capture byte limit")
        raw = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
    named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (not stat.S_ISREG(named.st_mode) or watchdog_identity(before) != identity
            or watchdog_identity(after) != identity or watchdog_identity(named) != identity
            or len(raw) != after.st_size):
        raise ValueError("Watchdog file changed while being read")
    return raw


def capture_watchdog_reports(folder, context, original_exit):
    folder.mkdir()
    result = {"schema": 1, "originalExitCode": original_exit, "reports": [], "candidateStatus": {},
              "causality": "Retained diagnostics do not prove a stall cause or test success"}
    directory = Path(context["watchdogDirectory"])
    result["originalDirectory"] = str(directory)
    try:
        if context.get("watchdogBaselineError"):
            raise ValueError("Watchdog baseline unavailable: " + context["watchdogBaselineError"])
        baseline = context["watchdogBaseline"]
        candidates = watchdog_candidates(directory)
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        remaining = WATCHDOG_TOTAL_BYTES
        try:
            for name, identity in sorted(candidates.items()):
                if not name.endswith(".json"):
                    continue
                try:
                    if name in baseline and identity[:2] == baseline[name][:2]:
                        raise ValueError("Stale watchdog baseline file")
                    raw = read_watchdog_file(fd, name, identity, min(WATCHDOG_REPORT_BYTES, remaining))
                    report = json.loads(raw)
                    if (not isinstance(report, dict) or type(report.get("schemaVersion")) is not int
                            or report["schemaVersion"] != 1 or type(report.get("processID")) is not int
                            or type(context.get("pid")) is not int or report["processID"] != context["pid"]):
                        raise ValueError("Watchdog schema or owned PID does not match")
                    detected = report_timestamp(report.get("detectedAt"))
                    if not context["launchEarliest"] <= detected <= context["exitObserved"]:
                        raise ValueError("Watchdog detection is outside the owned launch/exit interval")
                    sample_name = report.get("sampleFilenameIfAvailable")
                    if sample_name != name.removesuffix(".json") + ".sample.txt":
                        raise ValueError("Watchdog sample is not the matching report basename")
                    destination = folder / name
                    destination.write_bytes(raw)
                    remaining -= len(raw)
                    entry = {"originalPath": str(directory / name), "file": name, "bytes": len(raw),
                             "sha256": hashlib.sha256(raw).hexdigest(), "processID": report["processID"],
                             "detectedAt": report["detectedAt"], "producerSampleStatus": report.get("sampleStatus")}
                    result["reports"].append(entry)
                    result["candidateStatus"][name] = "Bound original watchdog report copied"
                    try:
                        identity = watchdog_identity(os.stat(sample_name, dir_fd=fd, follow_symlinks=False))
                        if sample_name in baseline and identity[:2] == baseline[sample_name][:2]:
                            raise ValueError("Stale watchdog baseline sample")
                        sample = read_watchdog_file(fd, sample_name, identity, remaining)
                        (folder / sample_name).write_bytes(sample)
                        remaining -= len(sample)
                        entry["sample"] = {"status": "captured-unverified", "file": sample_name,
                            "bytes": len(sample), "sha256": hashlib.sha256(sample).hexdigest(),
                            "completeness": "Raw bytes only; producer status is not a complete-stack attestation"}
                    except FileNotFoundError:
                        entry["sample"] = {"status": "absent"}
                    except (OSError, ValueError) as error:
                        entry["sample"] = {"status": "unavailable", "error": str(error)}
                except (OSError, ValueError, TypeError, KeyError, OverflowError) as error:
                    result["candidateStatus"][name] = str(error)
        finally:
            os.close(fd)
        result["status"] = "captured" if result["reports"] else "no-bound-watchdog-report"
    except FileNotFoundError:
        result["status"] = "directory-absent"
    except (OSError, ValueError, TypeError, KeyError) as error:
        result.update(status="diagnostic-unavailable", error=str(error))
    write_json(folder / "receipt.json", result)
    return result


def report_candidates(directories, name):
    result, errors = {}, []
    for directory in directories:
        try:
            for path in directory.iterdir():
                if not path.name.lstrip(".").startswith(name) or path.suffix not in {".ips", ".crash"}:
                    continue
                info = path.lstat()
                if stat.S_ISREG(info.st_mode):
                    result[str(path)] = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                if len(result) >= 128:
                    errors.append("Candidate limit reached")
                    return result, errors
        except OSError as error:
            errors.append(str(error))
    return result, errors


def prepare_post_mortem(host):
    context = {"parentPID": os.getpid(), "directories": [str(path) for path in report_directories()]}
    directory = watchdog_report_directory()
    context["watchdogDirectory"] = str(directory)
    try:
        context["watchdogBaseline"] = watchdog_candidates(directory)
    except FileNotFoundError:
        context["watchdogBaseline"] = {}
    except (OSError, ValueError) as error:
        context["watchdogBaselineError"] = str(error)
    try:
        context.update(host_binary_identity(host))
        context["baseline"], context["baselineErrors"] = report_candidates(
            [Path(path) for path in context["directories"]], host.name)
    except Exception as error:
        context["preparationError"] = str(error)
    return context


def report_timestamp(value):
    if not isinstance(value, str):
        raise ValueError("Missing report timestamp")
    for pattern in ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z"):
        try:
            return datetime.strptime(value, pattern).timestamp()
        except ValueError:
            pass
    stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise ValueError("Report timestamp has no timezone")
    return stamp.timestamp()


def owned_crash_report(raw, context):
    metadata, separator, body = raw.partition(b"\n")
    metadata, report = json.loads(metadata), json.loads(body)
    if not separator or not isinstance(metadata, dict) or not isinstance(report, dict):
        raise ValueError("Not a two-object native IPS report")
    if str(metadata.get("bug_type")) != "309":
        raise ValueError("Not a native crash report")
    if (type(report.get("pid")) is not int or report["pid"] != context["pid"]
            or type(report.get("parentPid")) is not int or report["parentPid"] != context["parentPID"]):
        raise ValueError("Report PID or parent does not match the owned child")
    launch, captured = report_timestamp(report.get("procLaunch")), report_timestamp(report.get("captureTime"))
    if (not context["launchEarliest"] - 1 <= launch <= context["launchLatest"] + 1
            or not launch <= captured <= context["exitObserved"] + 1):
        raise ValueError("Report launch or crash time does not match the owned child")
    image_uuid = context.get("hostUUID")
    if image_uuid:
        images = report.get("usedImages")
        if not isinstance(images, list) or not any(isinstance(image, dict)
                and str(image.get("uuid", "")).lower() == image_uuid for image in images):
            raise ValueError("Report does not contain the original host image UUID")
        binding = "pid+parent+launch/crash interval+original host image UUID"
    else:
        if report.get("procPath") != context["hostExecutable"]:
            raise ValueError("Report executable path cannot be bound without a host UUID")
        binding = "pid+parent+launch/crash interval+exact original executable path"
    return {"binding": binding, "incident": report.get("incident"), "procPath": report.get("procPath"),
            "hasLastExceptionBacktrace": bool(report.get("lastExceptionBacktrace")), "hasASI": bool(report.get("asi"))}


def capture_post_mortem(folder, context, original_exit):
    deadline = time.monotonic() + 30
    folder.mkdir()
    result = {"schema": 1, "originalExitCode": original_exit, "ownedChild": context,
              "status": "diagnostic-partial", "reports": [], "candidateStatus": {},
              "causality": "Signal exit does not prove a language exception"}
    try:
        start = datetime.fromtimestamp(context["launchEarliest"] - 1, timezone.utc).strftime("%Y-%m-%d %H:%M:%S%z")
        end = datetime.fromtimestamp(context["exitObserved"] + 1, timezone.utc).strftime("%Y-%m-%d %H:%M:%S%z")
        predicate = "processImagePath == " + json.dumps(context["hostExecutable"])
        command = ["/usr/bin/log", "show", "--style", "json", "--no-pager", "--info", "--debug",
                   "--process", str(context["pid"]), "--start", start, "--end", end, "--predicate", predicate]
        result["unifiedLog"] = {"command": command}
        try:
            with (folder / "unified-log.json").open("wb") as output, (folder / "unified-log.stderr").open("wb") as error:
                query = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output, stderr=error,
                                       timeout=min(10, max(0.1, deadline - time.monotonic())), check=False)
            result["unifiedLog"]["exitCode"] = query.returncode
        except (OSError, subprocess.SubprocessError) as error:
            result["unifiedLog"]["error"] = str(error)
        directories = [Path(path) for path in context["directories"]]
        previous = {}
        while time.monotonic() < deadline:
            candidates, result["scanErrors"] = report_candidates(directories, Path(context["hostExecutable"]).name)
            for name, identity in candidates.items():
                if time.monotonic() >= deadline:
                    break
                if list(identity) == list(context.get("baseline", {}).get(name, [])):
                    continue
                if previous.get(name) != identity:
                    result["candidateStatus"][name] = "Waiting for stable report bytes"
                    continue
                try:
                    if Path(name).suffix != ".ips":
                        raise ValueError("Legacy .crash format not bound; no foreign or unbound bytes copied")
                    if identity[2] > 32 * 1024 * 1024:
                        raise ValueError("Report exceeds 32 MiB; no truncated report copied")
                    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(fd, "rb") as stream:
                        before = os.fstat(stream.fileno())
                        if not stat.S_ISREG(before.st_mode):
                            raise ValueError("Report is no longer a regular file")
                        raw = stream.read(32 * 1024 * 1024 + 1)
                        after = os.fstat(stream.fileno())
                    current = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                    initial = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                    if current != identity or initial != current or len(raw) != after.st_size:
                        raise ValueError("Report changed while being read")
                    binding = owned_crash_report(raw, context)
                    destination = folder / ("owned-host-" + str(len(result["reports"])) + ".ips")
                    destination.write_bytes(raw)
                    result["reports"].append({"originalPath": name, "file": destination.name,
                        "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(), **binding})
                    result["candidateStatus"][name] = "Bound original report copied"
                    break
                except (OSError, ValueError, TypeError, KeyError) as error:
                    result["candidateStatus"][name] = str(error)
            if result["reports"]:
                break
            previous = candidates
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        result["status"] = "bound-report-captured" if result["reports"] else "no-bound-report-before-deadline"
    except Exception as error:
        result["error"] = str(error)
    result["finishedAt"] = datetime.now(timezone.utc).isoformat()
    for path in (folder / "unified-log.json", folder / "unified-log.stderr"):
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            result.setdefault("rawFiles", []).append({"file": path.name, "bytes": path.stat().st_size,
                                                     "sha256": digest.hexdigest()})
    write_json(folder / "receipt.json", result)
    return result


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
    profile = getattr(args, "app_diagnostic", None)
    product_source = getattr(args, "product_source_sha", None)
    retained_root = getattr(args, "bin_root", None)
    if profile and (profile not in ("zombies", "glow-reproduction") or args.scope != "app-swift-testing"):
        raise VerificationError("The diagnostic requires its owned App SwiftTesting backend")
    if profile == "zombies" and (args.filter or retained_root):
        raise VerificationError("The zombie diagnostic requires the full original App build")
    if profile == "glow-reproduction" and (args.filter != "GlowKernelTests" or not retained_root
            or args.configuration != "debug" or args.scratch_path or args.swiftc_flag):
        raise VerificationError("The Glow diagnostic requires the exact retained debug products and Glow selection")
    if retained_root and profile != "glow-reproduction":
        raise VerificationError("An explicit product path is restricted to the retained Glow diagnostic")
    if bool(profile) != bool(product_source) or product_source and not re.fullmatch(r"[a-f0-9]{40}", product_source):
        raise VerificationError("The App diagnostic requires its explicit original product source")
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
        if profile:
            checkout = subprocess.run(["git", "rev-parse", "HEAD"], stdin=subprocess.DEVNULL,
                                      capture_output=True, text=True, timeout=15)
            if checkout.returncode or checkout.stdout.strip() != product_source:
                raise VerificationError("The actual product checkout differs from the diagnostic source")
            result.update(productSourceSHA=product_source, harnessSourceSHA=source_sha)
        if retained_root:
            if not Path(retained_root).is_absolute():
                raise VerificationError("The retained product path must be absolute")
            binary_root = Path(retained_root).resolve(strict=True)
            result["binPathSource"] = "explicit-retained-products; no SwiftPM invocation"
        else:
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
                                   NGV_APPKIT_TEST_RECEIPT=str(receipt_path.resolve()),
                                   NGV_APPKIT_EXCEPTION_EVIDENCE=str((folder / "exception.jsonl").absolute()))
                if profile:
                    try:
                        environment = diagnostic_environment(environment, profile)
                    except ValueError as error:
                        raise VerificationError(str(error)) from error
            phase = {"name": name, "command": command, "status": "running", "log": str(log)}
            result["phases"].append(phase)
            write_json(result_path, result)
            observation = prepare_post_mortem(host) if name == "app-swift-testing" else None
            if observation is not None:
                observation["launchEarliest"] = time.time()
                if profile:
                    observation["diagnosticProfile"] = profile
                    observation["productSourceSHA"] = product_source
            code, pid = run_process(command, log, environment, observation)
            phase.update(exitCode=code, pid=pid)
            if profile:
                phase["diagnostic"] = observation.get("diagnostic", {"status": "unavailable"})
            if name == "app-swift-testing":
                try:
                    phase["watchdogReports"] = capture_watchdog_reports(folder / "watchdog", observation, code)
                except Exception as error:
                    phase["watchdogReports"] = {"status": "diagnostic-unavailable", "error": str(error),
                                                "originalExitCode": code}
            if name == "app-swift-testing" and code < 0:
                try:
                    phase["postMortem"] = capture_post_mortem(folder / "post-mortem", observation, code)
                except Exception as error:
                    phase["postMortem"] = {"status": "diagnostic-unavailable", "error": str(error),
                                           "originalExitCode": code}
            with combined.open("a") as destination:
                text = log.read_text()
                destination.write(text)
                if text and not text.endswith("\n"):
                    destination.write("\n")
            if code:
                raise VerificationError(name + " returned a nonzero original exit", code)
            if profile and phase["diagnostic"].get("status") != "verified":
                raise VerificationError("The owned App diagnostic activation or process identity was not verified")
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
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--cache-path", required=True)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("-c", "--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--scratch-path")
    parser.add_argument("--swiftc-flag", action="append", default=[])
    parser.add_argument("--filter", default="")
    parser.add_argument("--scope", choices=("all", "app-swift-testing"), default="all")
    parser.add_argument("--app-diagnostic", choices=("zombies", "glow-reproduction"))
    parser.add_argument("--product-source-sha")
    parser.add_argument("--bin-root", type=Path)
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
