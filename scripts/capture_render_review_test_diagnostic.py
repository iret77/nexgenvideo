"""Observe owned test processes and render-review stages without stopping them."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
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


def probe_launch_environment(command, executable):
    return {"NGV_CF_RUNLOOP_PROBE_PARENT_PID": str(os.getpid()),
            "NGV_CF_RUNLOOP_PROBE_EXECUTABLE": str(executable),
            "NGV_CF_RUNLOOP_PROBE_ROOT_PID": "",
            "NGV_CF_RUNLOOP_PROBE_ARGC": str(len(command)),
            **{f"NGV_CF_RUNLOOP_PROBE_ARG_{index}": value for index, value in enumerate(command)}}


def stop_manifest_process_group(process):
    records = []
    for signum in (signal.SIGTERM, signal.SIGKILL):
        row = {"processGroup": process.pid, "signal": int(signum)}
        try:
            os.killpg(process.pid, signum)
            row["signalStatus"] = "sent"
        except ProcessLookupError:
            row["signalStatus"] = "group-absent"
        except OSError as error:
            row["signalStatus"] = "unavailable"
            row["error"] = str(error)
        try:
            row["rootExitCode"] = process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            row["rootWait"] = "timed-out"
        records.append(row)
        if row["signalStatus"] == "group-absent":
            break
    return records


def prepare_runloop_probe(evidence, command):
    receipt = {"status": "unavailable", "scope": "owned-swift-test-environment-only",
               "stopLimit": 8, "runLimit": 4, "frameLimit": 24,
               "tailMainStopLimit": 8, "tailFlushLimit": 5,
               "tailMainStopCapture": "all-main-loop-targets-including-background-callers",
               "returnReason": "CFRunLoopRun-is-void-no-reason-inferred"}
    overrides = {}
    try:
        if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
                or os.environ.get("GITHUB_REPOSITORY") != "iret77/nexgenvideo"):
            raise RuntimeError("The runloop probe is limited to this repository's Darwin Actions test job")
        if len(command) < 2 or Path(command[0]).name != "swift" or command[1] != "test":
            raise RuntimeError("The runloop probe requires the existing swift test command")
        if os.environ.get("DYLD_INSERT_LIBRARIES"):
            raise RuntimeError("An existing DYLD_INSERT_LIBRARIES value prevents isolated probe injection")
        bundle = (Path.cwd() / ".build/debug/NexGenVideoTests.xctest").resolve(strict=True)
        binary = (bundle / "Contents/MacOS/NexGenVideoTests").resolve(strict=True)
        if not bundle.is_dir() or not binary.is_file():
            raise RuntimeError("The built App test bundle and executable are unavailable")
        source = Path(__file__).resolve().with_name("capture_swift_test_runloop.c")
        folder = evidence / "runloop-probe"
        folder.mkdir()
        originals = folder / "sources"
        originals.mkdir()
        for original in (source, Path(__file__).resolve(),
                         Path(__file__).resolve().with_name("verify_swift_test_output.py"),
                         Path.cwd() / ".github/workflows/ci.yml"):
            shutil.copyfile(original, originals / original.name)
        sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             timeout=15, check=False)
        receipt["sdkResolutionExitCode"] = sdk.returncode
        if sdk.returncode == 0:
            sdk_path = Path(sdk.stdout.strip())
            receipt["sdkPath"] = str(sdk_path)
            for header in (sdk_path / "System/Library/Frameworks/CoreFoundation.framework/Headers/CFRunLoop.h",
                           sdk_path / "usr/include/mach-o/dyld-interposing.h"):
                try:
                    shutil.copyfile(header, originals / header.name)
                except OSError as error:
                    receipt.setdefault("headerCaptureErrors", []).append({"path": str(header), "error": str(error)})
        copied_source = originals / source.name
        library = folder / "capture_swift_test_runloop.dylib"
        compile_command = ["xcrun", "--sdk", "macosx", "clang", "-dynamiclib", "-std=c11",
                           "-arch", "arm64", "-arch", "arm64e", "-g", "-O0", "-fno-omit-frame-pointer",
                           "-framework", "CoreFoundation", str(copied_source), "-o", str(library)]
        receipt.update(compileCommand=compile_command, compileTimeoutSeconds=120,
                       sourceSHA256=hashlib.sha256(copied_source.read_bytes()).hexdigest(),
                       expectedBundle=str(bundle), expectedBinary=str(binary),
                       commandExecutable=shutil.which(command[0]))
        with (folder / "compile.log").open("wb") as log:
            result = subprocess.run(compile_command, stdin=subprocess.DEVNULL, stdout=log,
                                    stderr=log, timeout=120, check=False)
        receipt["compileExitCode"] = result.returncode
        if result.returncode != 0 or not library.is_file():
            raise RuntimeError("The runloop probe could not be compiled; the original test command will run")
        architecture_command = ["xcrun", "lipo", "-archs", str(library)]
        receipt["architectureVerificationCommand"] = architecture_command
        architecture = subprocess.run(architecture_command, stdin=subprocess.DEVNULL,
                                      capture_output=True, text=True, timeout=15, check=False)
        (folder / "architectures.log").write_text(architecture.stdout + architecture.stderr)
        receipt["architectureVerificationExitCode"] = architecture.returncode
        if architecture.returncode != 0:
            raise RuntimeError("The runloop probe architectures could not be inspected")
        receipt["architectures"] = architecture.stdout.split()
        if set(receipt["architectures"]) != {"arm64", "arm64e"}:
            raise RuntimeError("The runloop probe must contain exactly the arm64 and arm64e slices")
        resolved = subprocess.run(["xcrun", "--find", "swift"], stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=15, check=False)
        (folder / "resolve-swift.log").write_text(resolved.stdout + resolved.stderr)
        if resolved.returncode != 0:
            raise RuntimeError("The selected Xcode Swift executable could not be resolved")
        swift_invocation = Path(resolved.stdout.strip())
        if not swift_invocation.is_absolute() or swift_invocation.name != "swift":
            raise RuntimeError("The selected Xcode Swift invocation path must be absolute and named swift")
        swift_executable = swift_invocation.resolve(strict=True)
        if not swift_executable.is_file() or not os.access(swift_executable, os.X_OK):
            raise RuntimeError("The selected Xcode Swift executable is not executable")
        identity = swift_executable.stat()
        invocation_identity = swift_invocation.lstat()
        receipt.update(swiftInvocationPath=str(swift_invocation),
                       swiftInvocationIdentity={"device": invocation_identity.st_dev,
                                                "inode": invocation_identity.st_ino,
                                                "bytes": invocation_identity.st_size,
                                                "mtimeNS": invocation_identity.st_mtime_ns},
                       actualCommand=[str(swift_invocation), *command[1:]],
                       predictedSwiftTestPath=str(swift_executable.parent / "swift-test"),
                       swiftExecutable=str(swift_executable),
                       swiftExecutableIdentity={"device": identity.st_dev, "inode": identity.st_ino,
                                                "bytes": identity.st_size, "mtimeNS": identity.st_mtime_ns})
        receipt.update(status="prepared-test-helper-load-not-yet-proven",
                       librarySHA256=hashlib.sha256(library.read_bytes()).hexdigest(),
                       libraryBytes=library.stat().st_size)
        overrides = {"DYLD_INSERT_LIBRARIES": str(library.resolve()),
                     "NGV_CF_RUNLOOP_PROBE_BUNDLE": str(bundle),
                     "NGV_CF_RUNLOOP_PROBE_BINARY": str(binary)}
        smoke_command = [str(swift_invocation), "package", "--package-path", str(Path.cwd()),
                         "--manifest-cache", "none", "dump-package"]
        smoke_environment = dict(os.environ, **overrides,
                                 NGV_SWIFT_TEST_PROCESS_EVIDENCE=str(evidence.resolve()))
        smoke_environment.update(probe_launch_environment(smoke_command, swift_executable))
        receipt.update(manifestPreparationCommand=smoke_command, manifestPreparationTimeoutSeconds=120,
                       manifestPreparationScope="root-manifest-only-no-build-or-test-no-all-architecture-claim")
        with (folder / "manifest.stdout").open("wb") as stdout, (folder / "manifest.stderr").open("wb") as stderr:
            smoke = subprocess.Popen(smoke_command, executable=str(swift_executable),
                                     stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                     env=smoke_environment, start_new_session=True)
            receipt["manifestPreparationPID"] = smoke.pid
            try:
                smoke.wait(timeout=120)
            except subprocess.TimeoutExpired:
                receipt["manifestTimeoutCleanup"] = stop_manifest_process_group(smoke)
                raise
            receipt["manifestPreparationExitCode"] = smoke.returncode
        if smoke.returncode != 0:
            raise RuntimeError("The injected root-manifest preparation failed; the original test command will run")
        root_records = evidence / f"runloop-probe-root-{smoke.pid}.jsonl"
        rows = [json.loads(line) for line in root_records.read_text().splitlines() if line]
        matching = [row for row in rows if isinstance(row, dict) and row.get("event") == "probe-root-init"
                    and row.get("pid") == smoke.pid and row.get("parentPID") == os.getpid()
                    and row.get("initialLaunchMatched") is True
                    and row.get("injectionCleanup") == "retained-own-root-library"
                    and row.get("loadedLibrary") == str(library.resolve())
                    and isinstance(row.get("executable"), str) and row["executable"]
                    and Path(row["executable"]).resolve() == swift_executable]
        if len(matching) != 1:
            raise RuntimeError("The injected manifest preparation has no unique matching initial loader/root receipt")
        receipt["manifestPreparationLoaderReceipt"] = matching[0]
        overrides.update(probe_launch_environment(receipt["actualCommand"], swift_executable))
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        overrides.clear()
        for field in ("swiftExecutable", "swiftInvocationPath", "actualCommand"):
            receipt.pop(field, None)
        receipt.update(status="unavailable", error=str(error))
    try:
        (evidence / "runloop-probe-preparation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    except OSError as error:
        receipt["receiptWriteError"] = str(error)
    return receipt, overrides



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


def require_owned_identity(pid_identity, root_pid, root_identity=None):
    rows, owned = process_tree(root_pid)
    if (pid_identity["pid"] not in owned or rows.get(pid_identity["pid"]) != pid_identity
            or root_identity is not None and rows.get(root_pid) != root_identity):
        raise RuntimeError("The owned test process or root identity changed before capture")
    return rows


def capture(pid_identity, root_pid, evidence, request, *, root_identity=None, timeout=CAPTURE_TIMEOUT_SECONDS):
    command = ["/usr/bin/sample", str(pid_identity["pid"]), str(SAMPLE_SECONDS), "-file", str(evidence / "sample.txt")]
    receipt = {**request, "target": pid_identity, "status": "capture-unavailable",
               "requestedSampleCommand": command, "sampleSeconds": SAMPLE_SECONDS,
               "captureTimeoutSeconds": timeout}
    try:
        require_owned_identity(pid_identity, root_pid, root_identity)
        with (evidence / "sample-command.log").open("wb") as log:
            result = subprocess.run(
                command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                timeout=timeout, check=False,
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




def capture_appkit_host(target, root_pid, root_identity, evidence, suite_bytes, events_path, request, record=None):
    receipt = {**request, "status": "capture-started", "target": target, "rootIdentity": root_identity,
               "causality": "No hang or source cause inferred from inactivity"}
    receipt_path = evidence.parent / (evidence.name + "-status.json")

    def persist():
        try:
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        except OSError as error:
            receipt.setdefault("receiptWriteErrors", []).append(str(error))
            if record is not None:
                try:
                    record(event="appkit-host-stale-status-write-unavailable", error=str(error),
                        status=receipt["status"], target=target)
                except OSError:
                    pass

    try:
        evidence.mkdir()
        persist()
        (evidence / "suite-original.json").write_bytes(suite_bytes)
        receipt["suiteSHA256"] = hashlib.sha256(suite_bytes).hexdigest()
        try:
            with events_path.open("rb") as source, (evidence / "events-original.jsonl").open("wb") as destination:
                identity = os.fstat(source.fileno())
                remaining = min(identity.st_size, 64 * 1024 * 1024)
                digest, copied = hashlib.sha256(), 0
                while remaining:
                    block = source.read(min(1024 * 1024, remaining))
                    if not block:
                        break
                    destination.write(block); digest.update(block)
                    copied += len(block); remaining -= len(block)
                receipt["eventsSnapshot"] = {"source": str(events_path), "sourceDevice": identity.st_dev,
                    "sourceInode": identity.st_ino, "sourceBytesAtOpen": identity.st_size,
                    "capturedBytes": copied, "sha256": digest.hexdigest(),
                    "completeAtOpenSize": copied == identity.st_size,
                    "scope": "Immutable raw prefix at open size; concurrent appends are not part of this snapshot"}
        except OSError as error:
            receipt["eventsSnapshotError"] = str(error)
        persist()
        capture(target, root_pid, evidence, request, root_identity=root_identity, timeout=15)
        try:
            require_owned_identity(target, root_pid, root_identity)
            command = ["/usr/bin/vmmap", str(target["pid"])]
            receipt["vmmapCommand"] = command
            persist()
            with (evidence / "vmmap.txt").open("wb") as output:
                result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output,
                    stderr=subprocess.STDOUT, timeout=15, check=False)
            receipt["vmmapExitCode"] = result.returncode
        except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
            receipt["vmmapError"] = str(error)
        image_map = evidence / "vmmap.txt"
        if image_map.is_file():
            receipt["vmmapSHA256"] = hashlib.sha256(image_map.read_bytes()).hexdigest()
        receipt["status"] = "capture-finished-see-individual-command-status"
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        receipt.update(status="capture-unavailable-or-partial", error=str(error))
    finally:
        receipt["finishedMonotonic"] = time.monotonic()
        persist()


class AppKitHostStaleObservation:
    def __init__(self, evidence, root_pid, command, root_identity, record):
        self.record, self.last_error = record, None
        self.evidence, self.root_pid, self.root_identity = evidence, root_pid, root_identity
        self.bound_root_identity = None
        self.suite_path = None
        self.target, self.event_state, self.worker = None, None, None
        self.changed, self.last_scan, self.attempted = time.monotonic(), 0, False
        driver = Path(__file__).resolve().with_name("run_macos_tests.py")
        if (len(command) > 3 and Path(command[1]).resolve() == driver
                and command.count("--evidence") == 1 and command.index("--evidence") < len(command) - 1):
            folder = Path(command[command.index("--evidence") + 1]).resolve()
            if folder.is_relative_to(evidence.resolve()):
                self.suite_path = folder / "suite.json"

    def tick(self):
        now = time.monotonic()
        if self.suite_path is None or self.attempted or now - self.last_scan < 1:
            return
        self.last_scan = now
        try:
            suite_bytes = self.suite_path.read_bytes()
            suite = json.loads(suite_bytes)
            if not isinstance(suite, dict):
                return
            phases = suite.get("phases", [])
            if not isinstance(phases, list) or not phases or not isinstance(phases[-1], dict):
                return
            if phases[-1].get("name") != "app-swift-testing" or phases[-1].get("status") != "running":
                return
            command = phases[-1]["command"]
            if (not isinstance(command, list) or not command or not isinstance(command[0], str)
                    or not Path(command[0]).is_absolute() or Path(command[0]).name != "NexGenVideoAppKitTestHost"):
                return
            rows, owned = process_tree(self.root_pid)
            current_root = rows.get(self.root_pid)
            if (self.root_identity is None or current_root is None
                    or any(current_root[key] != self.root_identity[key] for key in ("pid", "parentPID", "started"))
                    or self.bound_root_identity is not None and current_root != self.bound_root_identity):
                raise RuntimeError("The original driver process identity is unavailable or changed")
            candidates = [rows[pid] for pid in owned if rows[pid]["parentPID"] == self.root_pid
                and Path(rows[pid]["executable"]).resolve() == Path(command[0]).resolve()]
            if len(candidates) != 1 or self.target is not None and candidates[0] != self.target:
                if self.target is not None:
                    raise RuntimeError("The bound AppKit host exited, became unowned or changed identity")
                return
            events_path = self.suite_path.parent / "app-swift-testing/events.jsonl"
            try:
                identity = events_path.stat()
                event_state = (identity.st_dev, identity.st_ino, identity.st_size)
            except FileNotFoundError:
                event_state = None
            if self.target is None:
                self.bound_root_identity = dict(current_root)
                self.target, self.event_state, self.changed = candidates[0], event_state, now
                self.record(event="appkit-host-stale-watch-bound", target=self.target, rootIdentity=self.bound_root_identity,
                    launchRootIdentity=self.root_identity,
                    originalRunningCommand=command, originalSuitePath=str(self.suite_path))
            elif event_state != self.event_state:
                self.event_state, self.changed = event_state, now
            if now - self.changed < 180:
                return
            self.attempted = True
            request = {"status": "capture-requested", "trigger": "180s without native event-file byte progress",
                "requestedMonotonic": now, "lastNativeProgressMonotonic": self.changed,
                "driverPID": self.root_pid, "originalRunningCommand": command,
                "originalSuitePath": str(self.suite_path), "eventFileState": self.event_state,
                "consoleHeartbeatCountsAsProgress": False, "captureLimit": 1}
            (self.evidence / "appkit-host-stale-request.json").write_text(json.dumps(request, indent=2) + "\n")
            self.worker = threading.Thread(target=capture_appkit_host,
                args=(self.target, self.root_pid, self.bound_root_identity, self.evidence / "appkit-host-stale",
                      suite_bytes, events_path, request, self.record))
            self.worker.start()
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, RuntimeError) as error:
            if str(error) != self.last_error:
                self.last_error = str(error)
                self.record(event="appkit-host-stale-observation-unavailable", error=self.last_error)

    def finish(self):
        if self.worker is not None:
            self.worker.join()
        return {"captureAttempted": self.attempted, "target": self.target,
                "boundDriverIdentity": self.bound_root_identity,
                "unavailableReason": self.last_error,
                "nativeProgressScope": "Only native events file bytes; console logs do not reset delay"}


class TestProcessObservation:
    def __init__(self, evidence, root_pid):
        self.evidence, self.root_pid = evidence, root_pid
        self.record_lock = threading.Lock()
        self.events = (evidence / "process-events.jsonl").open("w")
        self.swift_events = (evidence / "swift-testing-events.jsonl").open("w")
        self.children = {}
        self.probe_loads = []
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
        with self.record_lock:
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

    def probe_report(self, row):
        if (not isinstance(row, dict) or row.get("event") != "probe-init"
                or type(row.get("pid")) is not int or row["pid"] < 1
                or type(row.get("parentPID")) is not int or row["parentPID"] < 1
                or type(row.get("guardMatched")) is not bool):
            self.record(event="invalid-runloop-probe-report", selfReport=row)
            return
        receipt = {"selfReport": row, "correlation": "unavailable"}
        try:
            rows, owned = process_tree(self.root_pid)
            identity = rows.get(row["pid"])
            if (row["pid"] not in owned or identity["parentPID"] != row["parentPID"]
                    or Path(identity["executable"]).name != "swiftpm-testing-helper"):
                raise RuntimeError("The probe PID is absent from the owned helper tree or its identity changed")
            self.watch(identity, self_report=row)
            receipt.update(correlation="owned-helper-correlated", target=identity)
        except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
            receipt["error"] = str(error)
        self.probe_loads.append(receipt)
        self.record(event="runloop-probe-init-observation", **receipt)


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
        if line.startswith("[swift-test-runloop-probe] "):
            self.record(event="runloop-probe-native-report", nativeHeader=native_line)
            try:
                self.probe_report(json.loads(line[len("[swift-test-runloop-probe] "):]))
            except ValueError as error:
                self.record(event="invalid-runloop-probe-report", nativeHeader=native_line, error=str(error))
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


def validate_framework_selection(swift_runs, xctest_runs, app_only, without_probe, command, core_resume=None):
    if core_resume is not None:
        driver = Path(__file__).resolve().with_name("run_macos_tests.py")
        allowed = {"--scope": "app-swift-testing", "--cache-path": None, "--evidence": None}
        pairs = list(zip(command[2::2], command[3::2]))
        if (app_only or swift_runs != 1 or xctest_runs != 0 or not without_probe
                or len(command) != 8 or command[0] != "python3"
                or Path(command[1]).resolve() != driver or len(dict(pairs)) != 3
                or set(dict(pairs)) != set(allowed)
                or any(not value or allowed[flag] is not None and value != allowed[flag] for flag, value in pairs)):
            raise ValueError("Core resume requires the complete normal App backend and retained successful backends")
        from resume_core_tests import verify_local
        verify_local(core_resume)
        return
    if not app_only:
        if min(swift_runs, xctest_runs) < 1:
            raise ValueError("Both selected framework run counts must be positive")
        return
    driver = Path(__file__).resolve().with_name("run_macos_tests.py")
    if (swift_runs != 1 or xctest_runs != 0 or not without_probe or len(command) < 4
            or Path(command[1]).resolve() != driver
            or any(value.startswith(("--filter=", "--scope=", "--app-diagnostic=", "--product-source-sha=", "--bin-root=")) for value in command)):
        raise ValueError("App-only capture requires an explicit owned diagnostic")

    def argument(flag):
        if command.count(flag) != 1 or command.index(flag) + 1 >= len(command):
            raise ValueError("Missing or duplicated App diagnostic argument")
        return command[command.index(flag) + 1]

    profile = argument("--app-diagnostic")
    if profile == "zombies":
        if "--filter" in command or "--bin-root" in command:
            raise ValueError("Zombie capture requires the complete original App backend")
    elif profile == "glow-reproduction":
        if argument("--filter") != "GlowKernelTests" or not Path(argument("--bin-root")).is_absolute():
            raise ValueError("Glow capture requires the retained products and exact Glow selection")
    elif profile == "app-reproduction":
        if "--filter" in command or not Path(argument("--bin-root")).is_absolute():
            raise ValueError("Full App capture requires retained products and no filter")
    else:
        raise ValueError("Unknown App-only diagnostic profile")
    for flag, value in (("--scope", "app-swift-testing"),):
        if command.count(flag) != 1 or command.index(flag) + 1 >= len(command) or command[command.index(flag) + 1] != value:
            raise ValueError("App-only capture requires its owned backend")
    flag = "--product-source-sha"
    if (command.count(flag) != 1 or command.index(flag) + 1 >= len(command)
            or not re.fullmatch(r"[a-f0-9]{40}", command[command.index(flag) + 1])):
        raise ValueError("App-only capture requires its exact original product source")


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--swift-testing-runs", required=True, type=int)
    parser.add_argument("--xctest-runs", required=True, type=int)
    parser.add_argument("--without-runloop-probe", action="store_true")
    parser.add_argument("--app-only", action="store_true")
    parser.add_argument("--core-resume", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("The existing swift test command is required")
    try:
        validate_framework_selection(args.swift_testing_runs, args.xctest_runs, args.app_only,
                                     args.without_runloop_probe, command, args.core_resume)
    except ValueError as error:
        parser.error(str(error))
    args.evidence.mkdir(parents=True, exist_ok=False)
    run = {"runID": os.environ.get("GITHUB_RUN_ID"), "sourceSHA": os.environ.get("GITHUB_SHA"),
           "command": command, "status": "running", "captureLimit": 1, "diagnosticDelaySeconds": 180,
           "sampleSeconds": SAMPLE_SECONDS, "captureTimeoutSeconds": CAPTURE_TIMEOUT_SECONDS}
    state = {"test": None, "lastStage": None, "changed": time.monotonic(), "selfPID": None}
    (args.evidence / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    environment = {**os.environ, "NGV_RENDER_REVIEW_TEST_DIAGNOSTIC": "1",
                   "NGV_SWIFT_TEST_PROCESS_EVIDENCE": str(args.evidence.resolve())}
    if args.without_runloop_probe:
        probe_receipt, probe_environment = {"status": "not-requested"}, {}
    else:
        probe_receipt, probe_environment = prepare_runloop_probe(args.evidence, command)
    run["runLoopProbe"] = probe_receipt
    environment.update(probe_environment)
    actual_command = probe_receipt.get("actualCommand", command)
    run.update(originalCommand=command, actualCommand=actual_command)
    (args.evidence / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    process = subprocess.Popen(actual_command, executable=probe_receipt.get("swiftExecutable"),
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=environment)
    run["runLoopProbe"]["swiftTestPID"] = process.pid
    try:
        rows, _ = process_tree(process.pid)
        run["runLoopProbe"]["observedRootIdentity"] = rows.get(process.pid)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        run["runLoopProbe"]["observedRootIdentityError"] = str(error)
    observation = TestProcessObservation(args.evidence, process.pid)
    appkit_stale = AppKitHostStaleObservation(args.evidence, process.pid, actual_command,
        run["runLoopProbe"].get("observedRootIdentity"), observation.record)
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
            appkit_stale.tick()
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
    run["appKitHostStaleObservation"] = appkit_stale.finish()
    observation.finish()
    run["runLoopProbe"]["helperLoads"] = observation.probe_loads
    run["runLoopProbe"]["ownedAppProbeInitCount"] = sum(
        row["correlation"] == "owned-helper-correlated"
        and row["selfReport"]["guardMatched"] and row["selfReport"].get("outputAvailable") is True
        for row in observation.probe_loads)
    run["runLoopProbe"]["loadObservation"] = (
        "not-requested" if args.without_runloop_probe else
        "owned-app-probe-init-observed" if run["runLoopProbe"]["ownedAppProbeInitCount"] else
        "unavailable-no-owned-app-probe-init-observed")
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
