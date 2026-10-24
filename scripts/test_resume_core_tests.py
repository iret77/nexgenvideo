import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch
import zipfile

import capture_render_review_test_diagnostic as capture
import resume_core_tests as resume
from test_swift_test_failure_propagation import workflow_test_run


ROOT = Path(__file__).resolve().parents[1]
SOURCE, HEAD = "a" * 40, "b" * 40
SWIFT = "◇ Test run started.\n✔ Test run with 1 test in 1 suite passed after 0.01 seconds.\n"
XCTEST = ("Test Suite 'All tests' started at now.\nTest Case '-[Example testOne]' started.\n"
          "Test Suite 'All tests' passed at now.\nTest Suite 'All tests' started at now.\n"
          "Test Suite 'All tests' passed at now.\n")


def framework(swift, xctest):
    return {"passed": True, "expectedRuns": {"swiftTesting": swift, "xctest": xctest},
            "startedRuns": {"swiftTesting": swift, "xctest": xctest},
            "completedRuns": {"swiftTesting": swift, "xctest": xctest}, "failures": []}


def native_events(module):
    identity = module + ".Example/testOne()/Example.swift:1:1"
    records = [{"version": 0, "kind": "test", "payload": {"kind": "function", "id": identity,
                "sourceLocation": {"fileID": module + "/Example.swift"}}}]
    records += [{"version": 0, "kind": "event", "payload": {"kind": kind, "testID": identity}}
                for kind in ("runStarted", "testStarted", "testEnded", "runEnded")]
    proof = {"recordCount": 5, "discoveredFunctionIDs": [identity], "startedFunctionIDs": [identity],
             "endedFunctionIDs": [identity], "skippedFunctionIDs": [], "functionExecutions": 1,
             "runStarted": 1, "runEnded": 1, "emptySelection": False, "skippedSelection": False}
    return "".join(json.dumps(r) + "\n" for r in records), proof


def archive_fixture(root, change=None):
    events, proof = native_events("NexGenEngineTests")
    app, _ = native_events("NexGenVideoTests")
    suite = {"schema": 1, "sourceSHA": SOURCE, "scope": "all", "configuration": "debug", "filter": "",
             "scratchPath": None, "completed": False, "phases": [
        {"name": "xctest", "status": "verified-execution", "exitCode": 0, "command": ["swift", "test"],
         "testCaseExecutions": 1, "framework": framework(0, 2)},
        {"name": "engine-swift-testing", "status": "verified-execution", "exitCode": 0,
         "command": ["swift", "test"], "events": proof, "framework": framework(1, 0)},
        {"name": "app-swift-testing", "status": "failed", "exitCode": -11, "pid": 42}]}
    files = {"hosted-suite/xctest/console.log": XCTEST,
             "hosted-suite/engine-swift-testing/console.log": SWIFT,
             "hosted-suite/engine-swift-testing/events.jsonl": events,
             "hosted-suite/app-swift-testing/events.jsonl": app,
             "hosted-suite/app-swift-testing/post-mortem/owned-host-0.ips":
                 json.dumps({"app_name": "NexGenVideoAppKitTestHost"}) + "\n" +
                 json.dumps({"pid": 42, "osVersion": {"train": "macOS 27.0", "build": "26A428"}})}
    if change:
        change(suite, files)
    files["hosted-suite/suite.json"] = json.dumps(suite)
    with zipfile.ZipFile(root / "original.zip", "w") as archive:
        for name, value in files.items():
            archive.writestr(name, value)
    return suite


def producer():
    run = {"id": 123, "head_sha": SOURCE, "run_attempt": 1, "status": "completed", "conclusion": "failure",
           "repository": {"full_name": "iret77/nexgenvideo"}, "event": "workflow_dispatch",
           "path": ".github/workflows/ci-batch.yml"}
    names = ["Build", "Stage test runtime inputs", "Verify build did not mutate tracked source",
             "Verify native app signing with nested runtime content", "Upload render review test diagnosis"]
    job = {"id": 456, "name": resume.BUILD_JOB, "run_id": 123, "head_sha": SOURCE, "run_attempt": 1,
           "status": "completed", "conclusion": "failure",
           "steps": [{"name": n, "conclusion": "success"} for n in names] + [{"name": "Test", "conclusion": "failure"}]}
    return run, {"total_count": 1, "jobs": [job]}


class CoreResumeTests(unittest.TestCase):
    def test_only_original_core_attempt_and_passed_prerequisites_are_reusable(self):
        run, jobs = producer()
        self.assertEqual(resume.verify_jobs(run, jobs)["id"], 456)
        for key, value in (("run_attempt", 2), ("path", ".github/workflows/diagnostic-acceptance.yml"),
                           ("conclusion", "success"), ("status", "in_progress"),
                           ("repository", {"full_name": "someone/nexgenvideo"})):
            with self.subTest(key=key), self.assertRaises(ValueError):
                resume.verify_jobs({**run, key: value}, jobs)
        for index in range(len(jobs["jobs"][0]["steps"])):
            changed = copy.deepcopy(jobs)
            changed["jobs"][0]["steps"][index]["conclusion"] = "skipped"
            with self.subTest(step=index), self.assertRaises(ValueError):
                resume.verify_jobs(run, changed)
        for changed in ({**jobs, "total_count": 2}, {**jobs, "jobs": jobs["jobs"] * 2},
                        {**jobs, "jobs": [{**jobs["jobs"][0], "head_sha": HEAD}]}):
            with self.assertRaises(ValueError):
                resume.verify_jobs(run, changed)

    def test_source_changes_reject_product_test_runtime_and_build_inputs(self):
        for path in ("Sources/Example.swift", "Tests/Example.swift", "Engine/Package.swift", "Package.resolved",
                     "scripts/bundle.sh", "scripts/stage_test_runtime.sh", "plugins/musicvideo.json",
                     ".github/actions/setup-xcode-27/action.yml", "scripts/sign_app.sh"):
            with self.subTest(path=path), patch.object(resume, "command", side_effect=[HEAD, path]), \
                 patch.object(resume.subprocess, "run"), self.assertRaises(ValueError):
                resume.verify_sources(SOURCE, HEAD)
        with patch.object(resume, "command", side_effect=[HEAD, "scripts/resume_core_tests.py", ""]), \
             patch.object(resume.subprocess, "run"):
            self.assertEqual(resume.verify_sources(SOURCE, HEAD), ["scripts/resume_core_tests.py"])
        with patch.object(resume, "command", side_effect=[HEAD, "", " M Package.swift"]), \
             patch.object(resume.subprocess, "run"), self.assertRaises(ValueError):
            resume.verify_sources(SOURCE, HEAD)
        with patch.object(resume, "command", return_value=HEAD), \
             patch.object(resume.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "git")), \
             self.assertRaises(subprocess.CalledProcessError):
            resume.verify_sources(SOURCE, HEAD)

    def test_archive_requires_both_successful_backends_and_original_full_selection(self):
        changes = [lambda s, f: s.update(sourceSHA=HEAD), lambda s, f: s.update(filter="One"),
                   lambda s, f: s.update(configuration="release"), lambda s, f: s.update(scope="app-swift-testing"),
                   lambda s, f: s["phases"][0].update(exitCode=1),
                   lambda s, f: s["phases"][1].update(status="running"),
                   lambda s, f: s["phases"][1].update(command=["swift", "test", "--filter=One"]),
                   lambda s, f: s["phases"][0].update(testCaseExecutions=2),
                   lambda s, f: f.update({"hosted-suite/xctest/console.log": XCTEST.rsplit("Test Suite", 1)[0]}),
                   lambda s, f: f.update({"hosted-suite/engine-swift-testing/console.log": SWIFT.replace("passed", "failed")}),
                   lambda s, f: f.update({"hosted-suite/engine-swift-testing/events.jsonl": "\n".join(
                       f["hosted-suite/engine-swift-testing/events.jsonl"].splitlines()[:-1])})]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_fixture(root)
            proof = resume.verify_archive(root, SOURCE)
            self.assertEqual([p["name"] for p in proof["backends"]], ["xctest", "engine-swift-testing"])
            self.assertEqual(proof["backends"][0]["testCaseExecutions"], 1)
            for index, change in enumerate(changes):
                archive_fixture(root, change)
                with self.subTest(change=index), self.assertRaises((ValueError, resume.VerificationError)):
                    resume.verify_archive(root, SOURCE)

    def test_original_toolchain_must_be_unique_and_exact(self):
        log = ("2026-10-24T00:00:00Z Xcode Versions: 27.0 (27A266a) [Apple Silicon] (Selected)\n"
               "2026-10-24T00:00:01Z Apple Swift version 6.4 (swiftlang-X clang-Y)\n")
        self.assertEqual(resume.toolchain(log), {"swift": "Apple Swift version 6.4 (swiftlang-X clang-Y)",
                                                "xcode": "Xcode 27.0\nBuild version 27A266a"})
        for invalid in ("", log * 2, log.replace("Apple Silicon", "Intel")):
            with self.assertRaises(ValueError):
                resume.toolchain(invalid)
        for output in ("Apple Swift version 6.4\nTarget: arm64", "swift-driver version: 1\nApple Swift version 6.4"):
            self.assertEqual(resume.swift_identity(output), "Apple Swift version 6.4")
        for output in ("swift-driver version: 1", "Apple Swift version 6.4\nApple Swift version 6.5"):
            with self.assertRaises(ValueError):
                resume.swift_identity(output)

    def test_normal_app_resume_needs_verified_receipt_and_cannot_select_or_instrument(self):
        command = ["python3", str(ROOT / "scripts/run_macos_tests.py"), "--scope", "app-swift-testing",
                   "--cache-path", "/cache", "--evidence", "/evidence"]
        with patch.object(resume, "verify_local") as verify:
            capture.validate_framework_selection(1, 0, False, True, command, Path("/receipt"))
            verify.assert_called_once_with(Path("/receipt"))
        variants = [command + ["--filter", "One"], command + ["--app-diagnostic", "zombies"],
                    command + ["--bin-root", "/old"], command + ["--configuration", "release"],
                    command[:3] + ["all"] + command[4:], command[:4] + ["--scope", "app-swift-testing"] + command[6:]]
        for variant in variants:
            with self.subTest(command=variant), patch.object(resume, "verify_local") as verify, self.assertRaises(ValueError):
                capture.validate_framework_selection(1, 0, False, True, variant, Path("/receipt"))
            verify.assert_not_called()
        with patch.object(resume, "verify_local", side_effect=ValueError("bad receipt")), self.assertRaises(ValueError):
            capture.validate_framework_selection(1, 0, False, True, command, Path("/receipt"))
        with self.assertRaises(ValueError):
            capture.validate_framework_selection(1, 0, False, True, command)

    def test_resume_shell_propagates_native_and_composition_failure_without_fallback(self):
        run = workflow_test_run(ROOT / ".github/workflows/ci.yml", "Test",)
        for native, composition in ((0, 0), (139, 0), (1, 0), (0, 1)):
            with self.subTest(native=native, composition=composition), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "scripts").mkdir()
                for name, variable in (("capture_render_review_test_diagnostic.py", "NATIVE"),
                                       ("resume_core_tests.py", "COMPOSITION")):
                    (root / "scripts" / name).write_text(
                        "import os,sys\nfrom pathlib import Path\n"
                        "with Path(os.environ['CALLS']).open('a') as f: f.write(repr(sys.argv)+'\\n')\n"
                        f"raise SystemExit(int(os.environ['{variable}']))\n")
                result = subprocess.run(["bash", "--noprofile", "--norc", "-c", run], cwd=root,
                    env={**os.environ, "NGV_COMPLETED_BACKENDS": "123", "RUNNER_TEMP": str(root),
                         "NGV_SWIFTPM_CACHE_PATH": "/cache", "CALLS": str(root / "calls"),
                         "NATIVE": str(native), "COMPOSITION": str(composition)}, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, native or composition, result.stderr)
                calls = (root / "calls").read_text().splitlines()
                self.assertEqual(len(calls), 1 if native else 2)
                self.assertIn("'--scope', 'app-swift-testing'", calls[0])
                self.assertNotIn("--app-diagnostic", calls[0])

    def test_dispatch_cannot_reuse_backends_in_other_modes_or_without_inventory(self):
        text = (ROOT / ".github/workflows/ci-batch.yml").read_text()
        code = textwrap.dedent(text.split("          python3 - <<'PYTHON'\n", 1)[1].split("          PYTHON", 1)[0])
        defaults = {"NGV_MODE": "initial", "NGV_FOLLOWUP": "none", "NGV_RUNTIME_RUN": "",
                    "NGV_QUALIFICATION_RUN": "", "NGV_SOURCE_RUN": "", "NGV_SETTINGS_SCOPE": "all",
                    "NGV_INTERFACE_SCALE": "all", "NGV_TEST_BUNDLE_RUN": "", "NGV_COMPLETED_BACKENDS": "123",
                    "NGV_APP_INVENTORY": "456"}
        with tempfile.TemporaryDirectory() as directory:
            for change, good in (({}, True), ({"NGV_APP_INVENTORY": ""}, False),
                                 ({"NGV_COMPLETED_BACKENDS": ""}, False), ({"NGV_COMPLETED_BACKENDS": "0"}, False),
                                 ({"NGV_MODE": "qualification"}, False), ({"NGV_MODE": "followup"}, False)):
                result = subprocess.run(["python3", "-c", code], env={**os.environ, **defaults, **change,
                    "GITHUB_OUTPUT": str(Path(directory) / "output")}, capture_output=True, timeout=10)
                self.assertEqual(result.returncode == 0, good, result.stderr)

    def test_composition_requires_current_complete_uninstrumented_owned_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            suite_root = root / "hosted-suite"
            phase_root = suite_root / "app-swift-testing"
            phase_root.mkdir(parents=True)
            raw, events = native_events("NexGenVideoTests")
            (phase_root / "events.jsonl").write_text(raw)
            (suite_root / "combined.log").write_text(SWIFT)
            host = {"pid": 42, "parentPID": 43, "sourceSHA": HEAD, "eventRecordCount": 5,
                    "hostExecutable": "/Debug/NexGenVideoAppKitTestHost",
                    "bundleBinary": "/Debug/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests",
                    **{key: True for key in ("mainThread", "applicationRunningAtStart", "started", "completed",
                                             "abiSucceeded", "runReturnedAfterCompletion")}}
            phase = {"name": "app-swift-testing", "status": "verified-execution", "exitCode": 0,
                     "pid": 42, "events": events, "originalHostReceipt": host}
            suite = {"sourceSHA": HEAD, "completed": True, "scope": "app-swift-testing", "configuration": "debug",
                     "filter": "", "scratchPath": None, "binPath": "/Debug", "phases": [phase],
                     "combinedFrameworks": framework(1, 0)}
            wrapper = {"sourceSHA": HEAD, "testExitCode": 0, "effectiveExitCode": 0,
                       "status": "test-process-exited", "runLoopProbe": {"swiftTestPID": 43}}
            receipt = {"sourceSHA": HEAD, "originalSourceSHA": SOURCE, "originalRun": {"id": 123},
                       "proof": {"backends": [{"name": "xctest"}, {"name": "engine-swift-testing"}]},
                       "completedAppInventory": {"functions": events["discoveredFunctionIDs"], "skips": []}}
            def save(s, w, h):
                (suite_root / "suite.json").write_text(json.dumps(s))
                (root / "run.json").write_text(json.dumps(w))
                (phase_root / "host-receipt.json").write_text(json.dumps(h))
            save(suite, wrapper, host)
            with patch.object(resume, "verify_local", return_value=receipt):
                resume.finish(root, suite_root, root)
            completed = json.loads((root / "completed.json").read_text())
            self.assertEqual(completed["originalSourceSHA"], SOURCE)
            self.assertEqual(completed["frameworkRuns"], {"swiftTesting": 2, "xctest": 2})
            changes = [lambda s,w,h: s.update(completed=False), lambda s,w,h: s.update(filter="One"),
                       lambda s,w,h: s.update(productSourceSHA=SOURCE), lambda s,w,h: s.update(sourceSHA=SOURCE),
                       lambda s,w,h: w.update(effectiveExitCode=1), lambda s,w,h: w.update(testExitCode=-11),
                       lambda s,w,h: s["phases"][0].update(diagnostic={"status": "verified"}),
                       lambda s,w,h: h.update(abiSucceeded=False), lambda s,w,h: h.update(parentPID=999),
                       lambda s,w,h: s["phases"][0]["events"].update(endedFunctionIDs=[]),
                       lambda s,w,h: s["phases"][0]["events"].update(skippedFunctionIDs=["unexpected"]),
                       lambda s,w,h: s["phases"][0]["events"].update(discoveredFunctionIDs=["unexpected"]),
                       lambda s,w,h: s["phases"][0]["events"].update(functionExecutions=2),
                       lambda s,w,h: s.update(combinedFrameworks=framework(2, 2)),
                       lambda s,w,h: s.update(binPath="/Other"), lambda s,w,h: s.update(scope="all"),
                       lambda s,w,h: s.update(phases=s["phases"] * 2), lambda s,w,h: w.update(sourceSHA=SOURCE)]
            for index, change in enumerate(changes):
                s,w,h = copy.deepcopy(suite), copy.deepcopy(wrapper), copy.deepcopy(host)
                change(s,w,h)
                save(s,w,h)
                with self.subTest(change=index), patch.object(resume, "verify_local", return_value=receipt), self.assertRaises(ValueError):
                    resume.finish(root, suite_root, root)
            save(suite, wrapper, host)
            for expected in ({"functions": events["discoveredFunctionIDs"], "skips": events["discoveredFunctionIDs"]},
                             {"functions": events["discoveredFunctionIDs"] + ["missing"], "skips": []}):
                with self.subTest(expected=expected), patch.object(resume, "verify_local", return_value={
                        **receipt, "completedAppInventory": expected}), self.assertRaises(ValueError):
                    resume.finish(root, suite_root, root)

    def test_local_receipt_rejects_wrong_execution_before_reading_any_original(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            value = {"schema": "core-backend-resume/v1", "sourceSHA": HEAD, "runID": "789", "attempt": "1"}
            for key, other in (("schema", "old"), ("sourceSHA", SOURCE), ("runID", "123"), ("attempt", "2")):
                (root / "receipt.json").write_text(json.dumps({**value, key: other}))
                with self.subTest(key=key), patch.dict(os.environ, GITHUB_SHA=HEAD, GITHUB_RUN_ID="789", GITHUB_RUN_ATTEMPT="1"), \
                     patch.object(resume, "verify_jobs") as jobs, self.assertRaises(ValueError):
                    resume.verify_local(root)
                jobs.assert_not_called()

    def test_local_receipt_checks_exact_platform_under_normal_test_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_fixture(root)
            proof = resume.verify_archive(root, SOURCE)
            run, jobs = producer()
            jobs["jobs"][0].update(started_at="2026-10-24T00:00:00Z", completed_at="2026-10-24T01:00:00Z")
            artifact = {"id": 9, "name": "render-review-test-diagnostic-123", "digest": "sha256:" + resume.checksum(root / "original.zip"),
                        "expired": False, "workflow_run": {"id": 123, "head_sha": SOURCE},
                        "created_at": "2026-10-24T00:30:00Z", "updated_at": "2026-10-24T00:30:00Z", "expires_at": "2099-01-01T00:00:00Z"}
            log = ("2026-10-24T00:00:00Z Xcode Versions: 27.0 (27A266a) [Apple Silicon] (Selected)\n"
                   "2026-10-24T00:00:01Z Apple Swift version 6.4\n")
            (root / "original-job.log").write_text(log)
            receipt = {"schema": "core-backend-resume/v1", "sourceSHA": HEAD, "runID": "789", "attempt": "1",
                       "originalRun": run, "originalJobs": jobs, "originalSourceSHA": SOURCE, "artifact": artifact,
                       "changedPaths": [], "toolchain": {"swift": "Apple Swift version 6.4", "xcode": "Xcode 27.0\nBuild version 27A266a"},
                       "jobLogSHA256": resume.checksum(root / "original-job.log"), "proof": proof,
                       "inventoryBinding": {}, "completedAppInventory": proof["appInventory"]}
            (root / "receipt.json").write_text(json.dumps(receipt))
            outputs = {("swift", "--version"): "swift-driver version: 1\nApple Swift version 6.4\nTarget: arm64",
                       ("xcodebuild", "-version"): "Xcode 27.0\nBuild version 27A266a", ("uname", "-m"): "arm64",
                       ("sw_vers", "-productVersion"): "27.0", ("sw_vers", "-buildVersion"): "26A428"}
            environment = {"GITHUB_SHA": HEAD, "GITHUB_RUN_ID": "789", "GITHUB_RUN_ATTEMPT": "1",
                           "SWIFT_BACKTRACE": "enable=yes,interactive=no,demangle=yes,cache=no",
                           "NGV_COMPLETED_BACKENDS": "123", "NGV_BLOCKOUT_ORIENTATION_EVIDENCE_DIR": "/evidence"}
            variants = [(None, None)] + [(key, "different") for key in outputs]
            for key, value in variants:
                selected = outputs if key is None else {**outputs, key: value}
                with self.subTest(command=key), patch.dict(os.environ, environment, clear=True), \
                     patch.object(resume, "verify_sources", return_value=[]), \
                     patch.object(resume, "verify_inventory", return_value=proof["appInventory"]), \
                     patch.object(resume, "command", side_effect=lambda args: selected[tuple(args)]):
                    if key is None:
                        self.assertEqual(resume.verify_local(root)["originalSourceSHA"], SOURCE)
                    else:
                        with self.assertRaises(ValueError):
                            resume.verify_local(root)
            for variable in ("NSZombieEnabled", "DYLD_PRINT_LIBRARIES", "DYLD_INSERT_LIBRARIES", "MTL_DEBUG_LAYER"):
                with self.subTest(variable=variable), patch.dict(os.environ, {**environment, variable: "1"}, clear=True), \
                     patch.object(resume, "verify_sources", return_value=[]), \
                     patch.object(resume, "verify_inventory", return_value=proof["appInventory"]), \
                     patch.object(resume, "command") as commands, self.assertRaises(ValueError):
                    resume.verify_local(root)
                commands.assert_not_called()

    def test_inventory_requires_exact_original_artifact_string_and_complete_events(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw, events = native_events("NexGenVideoTests")
            run = {"id": 456, "head_sha": HEAD}
            binding = {"run": run, "jobs": {}, "artifact": {"id": 10}}
            failure = {"id": 9, "digest": "sha256:" + "c" * 64}
            for original, digest, complete, valid in (("9", "c" * 64, True, True), (9, "c" * 64, True, False),
                                                      ("9", "d" * 64, True, False), ("9", "c" * 64, False, False)):
                with zipfile.ZipFile(root / "inventory.zip", "w") as archive:
                    archive.writestr("candidate-metadata/compiled-products.json", "{}")
                    archive.writestr("candidate-metadata/diagnostic-execution.json", json.dumps(
                        {"originalArtifactID": original, "originalArtifactSHA256": digest}))
                    archive.writestr("app-zombie-diagnostic/hosted-suite/suite.json", json.dumps({"phases": [{"events": events}]}))
                    archive.writestr("app-zombie-diagnostic/run.json", "{}")
                    archive.writestr("app-zombie-diagnostic/hosted-suite/app-swift-testing/events.jsonl",
                                     raw if complete else "\n".join(raw.splitlines()[:-1]))
                with self.subTest(original=original, digest=digest, complete=complete), \
                     patch.dict(os.environ, GITHUB_SHA=HEAD), patch.object(resume, "verify_producer"), \
                     patch.object(resume, "verify_sources"), patch.object(resume, "verify_artifact"), \
                     patch.object(resume, "verify_execution"):
                    if valid:
                        self.assertEqual(resume.verify_inventory(root, binding, SOURCE, failure)["functions"], events["discoveredFunctionIDs"])
                    else:
                        with self.assertRaises((ValueError, resume.VerificationError)):
                            resume.verify_inventory(root, binding, SOURCE, failure)


if __name__ == "__main__":
    unittest.main()
