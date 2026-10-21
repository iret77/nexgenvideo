import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_macos_tests as driver


SWIFT = "◇ Test run started.\n✔ Test run with 1 test in 1 suite passed after 0.001 seconds.\n"
XCTEST = ("Test Suite 'All tests' started at now.\n"
          "Test Case '-[Example testExample]' started.\n"
          "Test Suite 'All tests' passed at now.\n"
          "Test Suite 'All tests' started at now.\n"
          "Test Suite 'All tests' passed at now.\n")


def events(module, *, empty=False, version=0):
    records = []
    if not empty:
        records.append({"kind": "test", "payload": {"kind": "function", "id": "opaque identity",
                        "sourceLocation": {"fileID": module + "/Example.swift"}}})
    kinds = ["runStarted"] + ([] if empty else ["testStarted", "testEnded"]) + ["runEnded"]
    for kind in kinds:
        payload = {"kind": kind}
        if kind.startswith("test"):
            payload["testID"] = "opaque identity"
        records.append({"kind": "event", "payload": payload})
    return [dict(record, version=version) for record in records]


def write_events(path, records):
    path.write_text("".join(json.dumps(record) + "\n" for record in records))


class HostedTestDriverTests(unittest.TestCase):
    def invoke(self, root, *, filter="", scope="all", exits=None, empty=(), console=None,
               receipt_change=None, query_error=None, capture_error=None, watchdog_error=None):
        binary_root = root / "built products"
        binary_root.mkdir(exist_ok=True)
        host = binary_root / "NexGenVideoAppKitTestHost"
        host.write_text("")
        host.chmod(0o755)
        bundle = binary_root / "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"
        bundle.parent.mkdir(parents=True, exist_ok=True)
        bundle.write_text("")
        compiler = root / "selected toolchain/usr/bin/swiftc"
        compiler.parent.mkdir(parents=True, exist_ok=True)
        compiler.touch()
        platform = root / "selected macOS.platform"
        platform.mkdir(exist_ok=True)
        args = argparse.Namespace(cache_path="dependency cache", configuration="release",
                                  scratch_path="release scratch", swiftc_flag=["-enable-testing"],
                                  evidence=root / "evidence", filter=filter, scope=scope)
        calls = []
        queries = []

        def query(command, **kwargs):
            queries.append(command)
            if query_error is not None:
                raise query_error
            selected = binary_root if command[0] == "swift" else compiler if "--find" in command else platform
            return subprocess.CompletedProcess(command, 0, str(selected) + "\n", "")

        def process(command, log, environment, observation=None):
            name = log.parent.name
            calls.append((name, command, environment))
            if observation is not None:
                observation.update(pid=123, launchLatest=100, exitObserved=101)
            default = XCTEST.replace("All tests", "Selected tests") if filter else XCTEST
            output = (console or {}).get(name, default if name == "xctest" else SWIFT)
            if name in empty:
                output = driver.NO_MATCH + "\n" if name == "xctest" else ""
            log.write_text(output)
            if name != "xctest":
                module = "NexGenEngineTests" if name == "engine-swift-testing" else "NexGenVideoTests"
                records = events(module, empty=name in empty)
                write_events(log.parent / "events.jsonl", records)
                if name == "app-swift-testing":
                    receipt = {"schema": 1, "pid": 123, "parentPID": os.getpid(),
                               "bundleBinary": str(bundle.resolve()), "hostExecutable": str(host.resolve()),
                               "sourceSHA": "a" * 40, "eventRecordCount": len(records)}
                    receipt.update(dict.fromkeys(("mainThread", "applicationRunningAtStart", "started",
                                                   "completed", "abiSucceeded", "runReturnedAfterCompletion"), True))
                    receipt.update(receipt_change or {})
                    (log.parent / "host-receipt.json").write_text(json.dumps(receipt))
            return (exits or {}).get(name, 0), 123

        with patch.dict(os.environ, {"GITHUB_SHA": "a" * 40}, clear=True), \
                patch.object(driver.subprocess, "run", side_effect=query), \
                patch.object(driver, "run_process", side_effect=process), \
                patch.object(driver, "watchdog_report_directory", return_value=root / "watchdog-source"), \
                patch.object(driver, "capture_watchdog_reports", side_effect=watchdog_error,
                             return_value={"status": "captured"}) as watchdog, \
                patch.object(driver, "capture_post_mortem", side_effect=capture_error,
                             return_value={"status": "captured"}) as capture, \
                contextlib.redirect_stderr(io.StringIO()):
            code = driver.run(args)
        self.post_mortem_calls = capture.call_args_list
        self.watchdog_calls = watchdog.call_args_list
        return code, json.loads((args.evidence / "suite.json").read_text()), calls, queries

    def test_exact_release_products_run_once_and_preserve_framework_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code, receipt, calls, queries = self.invoke(root)
            self.assertEqual(code, 0, receipt)
            self.assertTrue(receipt["completed"])
            self.assertEqual([call[0] for call in calls], ["xctest", "engine-swift-testing", "app-swift-testing"])
            common = ["--cache-path", "dependency cache", "-c", "release", "--scratch-path", "release scratch",
                      "-Xswiftc", "-enable-testing"]
            self.assertEqual(queries[0], ["swift", "build", *common, "--show-bin-path"])
            self.assertEqual(calls[0][1], ["swift", "test", *common, "--skip-build", "--disable-swift-testing"])
            self.assertEqual(calls[1][1][:len(common) + 2], ["swift", "test", *common])
            self.assertIn("NexGenEngineTests", calls[1][1])
            self.assertIn("--disable-xctest", calls[1][1])
            self.assertEqual(receipt["combinedFrameworks"]["completedRuns"], {"swiftTesting": 2, "xctest": 2})
            self.assertEqual((root / "evidence/app-swift-testing/console.log").read_text(), SWIFT)

    def test_each_original_failure_stops_without_retry_or_next_phase(self):
        for name, count in (("xctest", 1), ("engine-swift-testing", 2), ("app-swift-testing", 3)):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                code, receipt, calls, _ = self.invoke(Path(directory), exits={name: 139})
                self.assertEqual(code, 139)
                self.assertFalse(receipt["completed"])
                self.assertEqual(len(calls), count)
                self.assertEqual(receipt["phases"][-1]["exitCode"], 139)

    def test_zero_exit_with_missing_app_completion_is_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            code, receipt, _, _ = self.invoke(Path(directory), console={"app-swift-testing": "◇ Test run started.\n"})
            self.assertEqual(code, 1)
            self.assertFalse(receipt["completed"])

    def test_owned_app_signal_is_preserved_when_post_mortem_capture_fails(self):
        for failure in (OSError("unavailable"), ValueError("malformed report"),
                        subprocess.TimeoutExpired(["/usr/bin/log", "show"], 10)):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                code, receipt, calls, _ = self.invoke(Path(directory), scope="app-swift-testing",
                    exits={"app-swift-testing": -5}, capture_error=failure)
                self.assertEqual(code, 133)
                self.assertFalse(receipt["completed"])
                self.assertEqual(len(calls), 1)
                phase = receipt["phases"][0]
                self.assertEqual(phase["exitCode"], -5)
                self.assertEqual(phase["postMortem"]["originalExitCode"], -5)
                self.assertEqual(len(self.post_mortem_calls), 1)

    def test_post_mortem_runs_only_for_original_negative_app_exit(self):
        for name, code in (("app-swift-testing", 0), ("app-swift-testing", 133),
                           ("engine-swift-testing", -5), ("xctest", -5)):
            with self.subTest(name=name, code=code), tempfile.TemporaryDirectory() as directory:
                _, _, calls, _ = self.invoke(Path(directory), exits={name: code})
                self.assertEqual(self.post_mortem_calls, [])
                if name == "app-swift-testing":
                    evidence = Path(calls[-1][2]["NGV_APPKIT_EXCEPTION_EVIDENCE"])
                    self.assertEqual(evidence, Path(directory) / "evidence/app-swift-testing/exception.jsonl")
                    self.assertFalse(evidence.exists())

    def crash_context(self):
        launch = driver.report_timestamp("2026-10-21 09:25:18.100 +0000")
        return {"pid": 123, "parentPID": os.getpid(), "launchEarliest": launch - .05,
                "launchLatest": launch + .05, "exitObserved": launch + 2,
                "hostExecutable": "/original/products/NexGenVideoAppKitTestHost",
                "hostUUID": "01efa441-68f3-3882-ac42-b9ceeeb6051d", "baseline": {}, "directories": []}

    def watchdog_context(self, directory):
        return dict(self.crash_context(), watchdogDirectory=str(directory), watchdogBaseline={})

    def watchdog_bytes(self, context, **changes):
        report = {"schemaVersion": 1, "processID": context["pid"], "detectedAt": "2026-10-21T09:25:19Z",
                  "sampleFilenameIfAvailable": "NexGenVideo-2026-10-21T092519Z-main-thread-hang.sample.txt",
                  "sampleStatus": "timedOut", "recentContexts": []}
        report.update(changes)
        return (json.dumps(report, indent=3) + "\r\n").encode()

    def test_watchdog_retention_runs_for_every_app_exit_without_changing_original_outcomes(self):
        for original, expected in ((0, 0), (1, 1), (-5, 133)):
            for error in (None, OSError("watchdog retention unavailable")):
                with self.subTest(original=original, error=error), tempfile.TemporaryDirectory() as directory:
                    code, receipt, calls, _ = self.invoke(Path(directory), scope="app-swift-testing",
                        exits={"app-swift-testing": original}, watchdog_error=error)
                    self.assertEqual(code, expected)
                    self.assertEqual(receipt["completed"], original == 0)
                    self.assertEqual(len(calls), 1)
                    phase = receipt["phases"][0]
                    self.assertEqual(phase["exitCode"], original)
                    self.assertEqual(len(self.watchdog_calls), 1)
                    self.assertEqual(self.watchdog_calls[0].args[-1], original)
                    if error:
                        self.assertEqual(phase["watchdogReports"]["originalExitCode"], original)
                        self.assertEqual(phase["watchdogReports"]["status"], "diagnostic-unavailable")

    def test_watchdog_retains_exact_report_and_sample_bytes_without_completeness_claim(self):
        for status, present in (("completed", True), ("timedOut", True), ("timedOut", False)):
            with self.subTest(status=status, present=present), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                context = self.watchdog_context(root)
                name = "NexGenVideo-2026-10-21T092519Z-main-thread-hang.json"
                raw = self.watchdog_bytes(context, sampleStatus=status)
                (root / name).write_bytes(raw)
                sample_name = json.loads(raw)["sampleFilenameIfAvailable"]
                sample = b"original possibly partial stack\xff\r\n"
                if present:
                    (root / sample_name).write_bytes(sample)
                captured = driver.capture_watchdog_reports(root / "captured", context, -5)
                self.assertEqual(captured["originalExitCode"], -5)
                self.assertEqual(len(captured["reports"]), 1)
                report = captured["reports"][0]
                self.assertEqual((root / "captured" / name).read_bytes(), raw)
                self.assertEqual(report["sha256"], driver.hashlib.sha256(raw).hexdigest())
                self.assertEqual(report["producerSampleStatus"], status)
                self.assertEqual(report["sample"]["status"], "captured-unverified" if present else "absent")
                if present:
                    self.assertEqual((root / "captured" / sample_name).read_bytes(), sample)
                    self.assertEqual(report["sample"]["sha256"], driver.hashlib.sha256(sample).hexdigest())

    def test_watchdog_rejects_foreign_schema_time_and_unsafe_sample_bindings(self):
        changes = ({"processID": 999}, {"processID": True}, {"schemaVersion": True}, {"schemaVersion": 2},
                   {"detectedAt": "2026-10-21T09:25:17Z"}, {"detectedAt": "2026-10-21T09:25:21Z"},
                   {"detectedAt": "2026-10-21T09:25:19"}, {"sampleFilenameIfAvailable": "../private.sample.txt"},
                   {"sampleFilenameIfAvailable": "/private.sample.txt"}, {"sampleFilenameIfAvailable": "other.sample.txt"})
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                context = self.watchdog_context(root)
                name = "NexGenVideo-2026-10-21T092519Z-main-thread-hang.json"
                (root / name).write_bytes(self.watchdog_bytes(context, **change))
                captured = driver.capture_watchdog_reports(root / "captured", context, 1)
                self.assertEqual(captured["reports"], [])
                self.assertNotEqual(captured["candidateStatus"][name], "Bound original watchdog report copied")
                self.assertEqual(list((root / "captured").glob("*.json")), [root / "captured/receipt.json"])

    def test_watchdog_baseline_rejects_old_report_even_when_rewritten_in_place(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "watchdog"
            source.mkdir()
            name = "NexGenVideo-2026-10-21T092519Z-main-thread-hang.json"
            (source / name).write_bytes(self.watchdog_bytes(self.crash_context()))
            host = root / "host"
            host.touch()
            with patch.object(driver, "watchdog_report_directory", return_value=source), \
                    patch.object(driver, "report_directories", return_value=[]):
                context = driver.prepare_post_mortem(host)
            context.update(self.crash_context())
            (source / name).write_bytes(self.watchdog_bytes(context, sampleStatus="completed"))
            captured = driver.capture_watchdog_reports(root / "captured", context, 0)
            self.assertEqual(captured["reports"], [])
            self.assertIn("Stale watchdog baseline", captured["candidateStatus"][name])

    def test_watchdog_does_not_follow_report_sample_or_directory_symlinks(self):
        for kind in ("report", "sample", "directory"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "source"
                source.mkdir()
                context = self.watchdog_context(source)
                raw = self.watchdog_bytes(context)
                name = "NexGenVideo-2026-10-21T092519Z-main-thread-hang.json"
                sample_name = json.loads(raw)["sampleFilenameIfAvailable"]
                outside = root / "outside"
                outside.write_bytes(raw if kind == "report" else b"foreign sample")
                if kind == "report":
                    (source / name).symlink_to(outside)
                else:
                    (source / name).write_bytes(raw)
                    (source / sample_name).symlink_to(outside)
                if kind == "directory":
                    alias = root / "alias"
                    alias.symlink_to(source, target_is_directory=True)
                    context["watchdogDirectory"] = str(alias)
                captured = driver.capture_watchdog_reports(root / "captured", context, 1)
                if kind == "sample":
                    self.assertEqual(len(captured["reports"]), 1)
                    self.assertEqual(captured["reports"][0]["sample"]["status"], "unavailable")
                else:
                    self.assertEqual(captured["reports"], [])
                self.assertFalse((root / "captured" / sample_name).exists())

    def test_watchdog_incomplete_baseline_does_not_claim_a_report_is_fresh(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            context = self.watchdog_context(root)
            context["watchdogBaselineError"] = "candidate inspection unavailable"
            name = "NexGenVideo-2026-10-21T092519Z-main-thread-hang.json"
            (root / name).write_bytes(self.watchdog_bytes(context))
            captured = driver.capture_watchdog_reports(root / "captured", context, 1)
            self.assertEqual(captured["reports"], [])
            self.assertEqual(captured["status"], "diagnostic-unavailable")
            self.assertEqual(captured["originalExitCode"], 1)

    def test_watchdog_does_not_attach_a_prelaunch_sample_to_a_fresh_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            context = self.watchdog_context(root)
            raw = self.watchdog_bytes(context)
            sample_name = json.loads(raw)["sampleFilenameIfAvailable"]
            (root / sample_name).write_bytes(b"old process stack")
            context["watchdogBaseline"] = driver.watchdog_candidates(root)
            name = "NexGenVideo-2026-10-21T092519Z-main-thread-hang.json"
            (root / name).write_bytes(raw)
            captured = driver.capture_watchdog_reports(root / "captured", context, 0)
            self.assertEqual(len(captured["reports"]), 1)
            self.assertIn("Stale watchdog baseline sample", captured["reports"][0]["sample"]["error"])
            self.assertFalse((root / "captured" / sample_name).exists())

    def test_watchdog_rejects_changed_report_and_bounds_report_and_sample_bytes(self):
        for kind in ("changed", "oversized-report", "sample-budget"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                context = self.watchdog_context(root)
                name = "NexGenVideo-2026-10-21T092519Z-main-thread-hang.json"
                raw = self.watchdog_bytes(context)
                report = root / name
                report.write_bytes(raw)
                if kind == "changed":
                    info = report.stat()
                    fields = dict(st_dev=info.st_dev, st_ino=info.st_ino, st_size=info.st_size,
                                  st_mtime_ns=info.st_mtime_ns, st_mode=info.st_mode)
                    changed = dict(fields, st_mtime_ns=info.st_mtime_ns + 1)
                    with patch.object(driver.os, "fstat", side_effect=[SimpleNamespace(**fields), SimpleNamespace(**changed)]):
                        captured = driver.capture_watchdog_reports(root / "captured", context, 1)
                    self.assertIn("changed while", captured["candidateStatus"][name])
                    self.assertEqual(captured["reports"], [])
                elif kind == "oversized-report":
                    report.write_bytes(b"x" * (driver.WATCHDOG_REPORT_BYTES + 1))
                    captured = driver.capture_watchdog_reports(root / "captured", context, 1)
                    self.assertIn("capture byte limit", captured["candidateStatus"][name])
                    self.assertEqual(captured["reports"], [])
                else:
                    sample_name = json.loads(raw)["sampleFilenameIfAvailable"]
                    (root / sample_name).write_bytes(b"stack")
                    with patch.object(driver, "WATCHDOG_TOTAL_BYTES", len(raw) + 1):
                        captured = driver.capture_watchdog_reports(root / "captured", context, 1)
                    self.assertEqual((root / "captured" / name).read_bytes(), raw)
                    self.assertIn("capture byte limit", captured["reports"][0]["sample"]["error"])
                    self.assertFalse((root / "captured" / sample_name).exists())

    def crash_bytes(self, context, **changes):
        report = {"pid": context["pid"], "parentPid": context["parentPID"],
                  "procLaunch": "2026-10-21 09:25:18.100 +0000",
                  "captureTime": "2026-10-21 09:25:19.100 +0000",
                  "procPath": "/Users/USER/redacted/NexGenVideoAppKitTestHost",
                  "usedImages": [{"uuid": context["hostUUID"]}],
                  "lastExceptionBacktrace": [{"imageOffset": 123}]}
        report.update(changes)
        return (json.dumps({"bug_type": "309"}) + "\n" + json.dumps(report) + "\n").encode()

    def test_os_report_requires_owned_process_lifetime_and_original_host_image(self):
        context = self.crash_context()
        valid = self.crash_bytes(context)
        self.assertTrue(driver.owned_crash_report(valid, context)["hasLastExceptionBacktrace"])
        for change in ({"pid": 999}, {"parentPid": 999},
                       {"procLaunch": "2026-10-20 09:25:18.100 +0000"},
                       {"captureTime": "2026-10-21 09:30:18.100 +0000"},
                       {"usedImages": [{"uuid": "another-image"}]}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                driver.owned_crash_report(self.crash_bytes(context, **change), context)
        no_uuid = dict(context, hostUUID=None)
        with self.assertRaises(ValueError):
            driver.owned_crash_report(valid, no_uuid)
        exact = self.crash_bytes(context, procPath=context["hostExecutable"])
        self.assertIn("exact original executable path", driver.owned_crash_report(exact, no_uuid)["binding"])

    def test_post_mortem_preserves_raw_report_when_only_access_time_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "NexGenVideoAppKitTestHost-original.ips"
            context = self.crash_context()
            context["directories"] = [str(root)]
            raw = self.crash_bytes(context)
            report.write_bytes(raw)
            info = report.stat()
            stable = dict(st_dev=info.st_dev, st_ino=info.st_ino, st_size=info.st_size,
                          st_mtime_ns=info.st_mtime_ns, st_mode=info.st_mode)
            before = SimpleNamespace(**stable, st_atime=100)
            after = SimpleNamespace(**stable, st_atime=200)

            def log_query(command, **kwargs):
                self.assertEqual(command[:4], ["/usr/bin/log", "show", "--style", "json"])
                self.assertIn("--process", command)
                self.assertEqual(command[command.index("--process") + 1], "123")
                self.assertIn(context["hostExecutable"], command[-1])
                self.assertLessEqual(kwargs["timeout"], 10)
                kwargs["stdout"].write(b"[]\n")
                return subprocess.CompletedProcess(command, 0)

            with patch.object(driver.subprocess, "run", side_effect=log_query), \
                    patch.object(driver.os, "fstat", side_effect=[before, after]), \
                    patch.object(driver.time, "sleep"):
                captured = driver.capture_post_mortem(root / "post-mortem", context, -5)
            self.assertEqual(captured["status"], "bound-report-captured")
            self.assertEqual(len(captured["reports"]), 1)
            self.assertEqual((root / "post-mortem/owned-host-0.ips").read_bytes(), raw)
            self.assertEqual(captured["originalExitCode"], -5)

    def test_post_mortem_unavailable_log_and_foreign_report_do_not_extend_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            context = self.crash_context()
            context["directories"] = [str(root)]
            (root / "NexGenVideoAppKitTestHost-foreign.ips").write_bytes(self.crash_bytes(context, pid=999))
            clock = [0.0]
            def advance(seconds):
                clock[0] += seconds
            with patch.object(driver.subprocess, "run", side_effect=OSError("log unavailable")), \
                    patch.object(driver.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(driver.time, "sleep", side_effect=advance) as sleep:
                captured = driver.capture_post_mortem(root / "post-mortem", context, -5)
            self.assertEqual(captured["status"], "no-bound-report-before-deadline")
            self.assertEqual(captured["reports"], [])
            self.assertIn("unavailable", captured["unifiedLog"]["error"])
            self.assertTrue(all(call.args[0] <= 1 for call in sleep.call_args_list))
            self.assertEqual(clock[0], 30)
            self.assertEqual(list((root / "post-mortem").glob("*.ips")), [])

    def test_bounded_product_query_timeout_records_failure_without_starting_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            code, receipt, calls, _ = self.invoke(Path(directory), query_error=subprocess.TimeoutExpired(
                ["swift", "build", "--show-bin-path"], 60))
            self.assertEqual(code, 1)
            self.assertFalse(receipt["completed"])
            self.assertIn("timed out", receipt["error"])
            self.assertEqual(calls, [])

    def test_bad_owned_host_receipt_is_failure(self):
        for change in ({"abiSucceeded": False}, {"recordingError": "disk full"}, {"pid": 456},
                       {"sourceSHA": "b" * 40}, {"eventRecordCount": 0}, {"completed": False},
                       {"bundleBinary": "/another/bundle"}, {"runReturnedAfterCompletion": False}):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                code, receipt, _, _ = self.invoke(Path(directory), receipt_change=change)
                self.assertEqual(code, 1)
                self.assertFalse(receipt["completed"])

    def test_native_filtered_empty_backends_do_not_become_passed_suites(self):
        with tempfile.TemporaryDirectory() as directory:
            code, receipt, calls, _ = self.invoke(Path(directory), filter="App.*", empty=("xctest", "engine-swift-testing"))
            self.assertEqual(code, 0, receipt)
            self.assertEqual([phase["status"] for phase in receipt["phases"]],
                             ["empty-selection", "empty-selection", "verified-execution"])
            for _, command, _ in calls:
                self.assertEqual(command[-2:], ["--filter", "App.*"])
            self.assertNotIn("combinedFrameworks", receipt)

    def test_all_native_backends_empty_is_failure_even_with_successful_abi(self):
        with tempfile.TemporaryDirectory() as directory:
            code, receipt, calls, _ = self.invoke(Path(directory), filter="absent", empty=(
                "xctest", "engine-swift-testing", "app-swift-testing"))
            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 3)
            self.assertFalse(receipt["completed"])
            self.assertTrue(receipt["phases"][-1]["originalHostReceipt"]["abiSucceeded"])

    def test_positive_native_xctest_filter_requires_both_selected_product_completions(self):
        selected = XCTEST.replace("All tests", "Selected tests")
        for output, expected in ((selected, 0),
                                 (selected.replace("Test Suite 'Selected tests' passed at now.\n", "", 1), 1),
                                 (selected.replace("passed at now.", "failed at now.", 1), 1),
                                 (XCTEST, 1)):
            with self.subTest(output=output), tempfile.TemporaryDirectory() as directory:
                code, receipt, calls, _ = self.invoke(Path(directory), filter="Example/testExample",
                    empty=("engine-swift-testing", "app-swift-testing"), console={"xctest": output})
                self.assertEqual(code, expected, receipt)
                self.assertEqual(receipt["completed"], expected == 0)
                self.assertEqual(len(calls), 3 if expected == 0 else 1)

    def test_full_scope_rejects_selected_roots_and_requires_all_tests_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            code, receipt, calls, _ = self.invoke(Path(directory), console={
                "xctest": XCTEST.replace("All tests", "Selected tests")})
            self.assertEqual(code, 1)
            self.assertFalse(receipt["completed"])
            self.assertEqual(len(calls), 1)

    def test_zero_xctest_exit_without_native_empty_evidence_is_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            code, _, calls, _ = self.invoke(Path(directory), filter="App", console={"xctest": ""})
            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 1)

    def test_hdr_app_scope_executes_only_host_and_one_real_swift_run(self):
        with tempfile.TemporaryDirectory() as directory:
            code, receipt, calls, _ = self.invoke(Path(directory), scope="app-swift-testing", filter="HDRExportTests")
            self.assertEqual(code, 0, receipt)
            self.assertEqual([call[0] for call in calls], ["app-swift-testing"])
            self.assertEqual(receipt["testExecutions"], 1)

    def test_incomplete_foreign_cancelled_or_failing_native_events_reject(self):
        variants = []
        variants.append(events("NexGenVideoTests")[:-1])
        variants.append(events("AnotherModule"))
        bad_end = events("NexGenVideoTests")
        bad_end[3]["payload"]["testID"] = "undiscovered"
        variants.append(bad_end)
        for kind, extra in (("testCancelled", {}), ("issueRecorded", {"issue": {"isKnown": False}})):
            records = events("NexGenVideoTests")
            records.insert(-1, {"version": 0, "kind": "event", "payload": {"kind": kind, **extra}})
            variants.append(records)
        for records in variants:
            with self.subTest(records=records), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "events.jsonl"
                write_events(path, records)
                with self.assertRaises(driver.VerificationError):
                    driver.swift_events(path, "NexGenVideoTests")

    def test_default_schema_and_opaque_ids_are_not_module_names(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            write_events(path, events("NexGenVideoTests", version="6.4.0"))
            result = driver.swift_events(path, "NexGenVideoTests")
            self.assertEqual(result["startedFunctionIDs"], ["opaque identity"])
            self.assertEqual(result["functionExecutions"], 1)

    def test_unknown_or_mixed_schema_is_not_assumed_supported(self):
        for version in ("6.4", "7.0.0", True):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "events.jsonl"
                write_events(path, events("NexGenVideoTests", version=version))
                with self.assertRaises(driver.VerificationError):
                    driver.swift_events(path, "NexGenVideoTests")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            records = events("NexGenVideoTests")
            records[-1]["version"] = "6.4.0"
            write_events(path, records)
            with self.assertRaises(driver.VerificationError):
                driver.swift_events(path, "NexGenVideoTests")

    def test_legacy_known_issue_without_new_isfailure_field_is_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            records = events("NexGenVideoTests")
            records.insert(-1, {"version": 0, "kind": "event", "payload": {
                "kind": "issueRecorded", "issue": {"isKnown": True}}})
            write_events(path, records)
            self.assertEqual(driver.swift_events(path, "NexGenVideoTests")["functionExecutions"], 1)

    def test_loader_paths_preserve_selection_and_staged_dependencies_only_in_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            compiler = root / "toolchain/usr/bin/swiftc"
            compiler.parent.mkdir(parents=True)
            compiler.touch()
            testing = root / "toolchain/usr/lib/swift/macosx/testing"
            testing.mkdir(parents=True)
            platform = root / "macOS.platform"
            platform.mkdir()
            bundle = root / "products/App.xctest/Contents/MacOS/App"
            bundle.parent.mkdir(parents=True)
            staged = bundle.parent.parent / "Frameworks"
            staged.mkdir()
            folder = root / "evidence"
            folder.mkdir()
            original = {"DYLD_LIBRARY_PATH": "/inherited/library", "DYLD_FRAMEWORK_PATH": "/inherited/framework",
                        "DEVELOPER_DIR": "/selected/developer", "TOOLCHAINS": "selected",
                        "SWIFTPM_PLATFORM_PATH_macosx": str(platform)}
            def query(command, **kwargs):
                self.assertEqual(command, ["xcrun", "--find", "swiftc"])
                self.assertEqual(kwargs["env"]["DEVELOPER_DIR"], "/selected/developer")
                self.assertEqual(kwargs["env"]["TOOLCHAINS"], "selected")
                self.assertEqual(kwargs["timeout"], 60)
                return subprocess.CompletedProcess(command, 0, str(compiler) + "\n", "")
            with patch.object(driver.subprocess, "run", side_effect=query):
                child = driver.app_environment(original, bundle.parents[3], bundle, folder)
            self.assertEqual(original["DYLD_LIBRARY_PATH"], "/inherited/library")
            self.assertEqual(child["DYLD_LIBRARY_PATH"].split(os.pathsep), ["/inherited/library",
                             str(bundle.parents[3]), str(testing), str(platform / "Developer/usr/lib"), str(staged)])
            self.assertEqual(child["DYLD_FRAMEWORK_PATH"].split(os.pathsep), ["/inherited/framework",
                             str(platform / "Developer/Library/Frameworks"),
                             str(platform / "Developer/Library/PrivateFrameworks"), str(staged)])
            self.assertEqual(child["NO_COLOR"], "1")
            self.assertNotIn("DYLD_INSERT_LIBRARIES", child)


if __name__ == "__main__":
    unittest.main()
