import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
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
               receipt_change=None, query_error=None):
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

        def process(command, log, environment):
            name = log.parent.name
            calls.append((name, command, environment))
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
                contextlib.redirect_stderr(io.StringIO()):
            code = driver.run(args)
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
        for kind, extra in (("testCancelled", {}), ("issueRecorded", {"issue": {"isFailure": True}})):
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
            root = Path(directory)
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
