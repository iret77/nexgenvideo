import copy
import hashlib
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


class CoreTimeoutResumeTests(unittest.TestCase):
    def test_only_the_exact_original_timeout_can_supply_an_unfinished_backend(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def interrupted(suite, files):
                suite["phases"][2] = {"name": "app-swift-testing", "status": "running"}
            archive_fixture(root, interrupted)
            digest = resume.checksum(root / "original.zip")
            with patch.object(resume, "TIMEOUT_SOURCE", SOURCE), patch.object(resume, "TIMEOUT_DIGEST", digest), \
                 patch.object(resume, "timeout_platform", return_value={"train": "macOS 27.0", "build": "26A428"}) as platform:
                self.assertEqual(len(resume.verify_archive(root, SOURCE)["backends"]), 2)
                platform.assert_called_once()
            for expected_source, expected_digest in ((HEAD, digest), (SOURCE, "f" * 64)):
                with self.subTest(source=expected_source, digest=expected_digest), \
                     patch.object(resume, "TIMEOUT_SOURCE", expected_source), \
                     patch.object(resume, "TIMEOUT_DIGEST", expected_digest), \
                     patch.object(resume, "timeout_platform", return_value={"train": "macOS 27.0", "build": "26A428"}) as platform:
                    with self.assertRaisesRegex(ValueError, "Original App phase did not fail"):
                        resume.verify_archive(root, SOURCE)
                    platform.assert_not_called()

    def test_timeout_platform_requires_owned_sample_snapshot_and_action_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = ["/products/NexGenVideoAppKitTestHost", "--event-stream-version", "0"]
            suite = {"binPath": "/products", "phases": [{}, {}, {"command": command}]}
            target = {"pid": 42, "parentPID": 41, "executable": command[0]}
            sample = ("Process: NexGenVideoAppKitTestHost [42]\nParent Process: Python [41]\n"
                      "OS Version: macOS 27.0 (26A428)\n")
            snapshot = json.dumps(suite)
            capture = {"target": target, "driverPID": 41, "status": "capture-returned", "returnCode": 0,
                       "originalRunningCommand": command, "sampleSHA256": hashlib.sha256(sample.encode()).hexdigest(),
                       "sampleBytes": len(sample)}
            status = {"suiteSHA256": hashlib.sha256(snapshot.encode()).hexdigest(), "target": target,
                      "rootIdentity": {"pid": 41}, "driverPID": 41, "originalRunningCommand": command}
            wrapper = {"runID": str(resume.TIMEOUT_RUN), "sourceSHA": resume.TIMEOUT_SOURCE, "status": "running"}
            files = {"appkit-host-stale/capture-receipt.json": json.dumps(capture),
                     "appkit-host-stale-status.json": json.dumps(status),
                     "appkit-host-stale/suite-original.json": snapshot,
                     "appkit-host-stale/sample.txt": sample, "run.json": json.dumps(wrapper)}
            variants = [None, ("capture", "returnCode", 1), ("capture", "driverPID", 99),
                        ("capture", "status", "capture-unavailable"),
                        ("capture", "originalRunningCommand", ["/other"]),
                        ("status", "originalRunningCommand", ["/other"]),
                        ("capture", "sampleSHA256", "f" * 64), ("capture", "sampleBytes", 1),
                        ("status", "suiteSHA256", "f" * 64), ("status", "target", {**target, "pid": 99}),
                        ("status", "rootIdentity", {"pid": 99}),
                        ("target", "executable", "/other/NexGenVideoAppKitTestHost"),
                        ("snapshot", "binPath", "/other"), ("suite", "binPath", "/other"),
                        ("wrapper", "runID", "999"), ("wrapper", "sourceSHA", HEAD),
                        ("wrapper", "status", "completed"), ("sample", "Process", "WrongHost"),
                        ("sample", "Parent Process", "WrongParent"), ("sample", "OS Version", "missing"),
                        ("log", "timeout", "missing")]
            for variant in variants:
                selected = dict(files)
                selected_suite = copy.deepcopy(suite)
                if variant and variant[0] in {"capture", "status", "wrapper"}:
                    filename = {"capture": "appkit-host-stale/capture-receipt.json", "status": "appkit-host-stale-status.json",
                                "wrapper": "run.json"}[variant[0]]
                    selected[filename] = json.dumps({**json.loads(selected[filename]), variant[1]: variant[2]})
                elif variant and variant[0] == "target":
                    for filename in ("appkit-host-stale/capture-receipt.json", "appkit-host-stale-status.json"):
                        value = json.loads(selected[filename]);value["target"][variant[1]] = variant[2]
                        selected[filename] = json.dumps(value)
                elif variant and variant[0] in {"snapshot", "suite"}:
                    changed_suite = {**suite, variant[1]: variant[2]}
                    selected["appkit-host-stale/suite-original.json"] = json.dumps(changed_suite)
                    selected["appkit-host-stale-status.json"] = json.dumps({**status,
                        "suiteSHA256": hashlib.sha256(json.dumps(changed_suite).encode()).hexdigest()})
                    if variant[0] == "suite": selected_suite = changed_suite
                elif variant and variant[0] == "sample":
                    selected["appkit-host-stale/sample.txt"] = sample.replace(variant[1] + ":", variant[2] + ":", 1)
                    changed = selected["appkit-host-stale/sample.txt"].encode()
                    selected["appkit-host-stale/capture-receipt.json"] = json.dumps({**capture,
                        "sampleSHA256": hashlib.sha256(changed).hexdigest(), "sampleBytes": len(changed)})
                (root / "original-job.log").write_text("missing" if variant and variant[0] == "log" else
                    "2026-11-02T01:17:21Z ##[error]The action 'Test' has timed out after 30 minutes.\n")
                with zipfile.ZipFile(root / "proof.zip", "w") as archive:
                    for name, value in selected.items(): archive.writestr(name, value)
                with self.subTest(variant=variant), zipfile.ZipFile(root / "proof.zip") as archive:
                    if variant is None:
                        self.assertEqual(resume.timeout_platform(archive, selected_suite, root), {"train": "macOS 27.0", "build": "26A428"})
                    else:
                        with self.assertRaises(ValueError): resume.timeout_platform(archive, selected_suite, root)

    def test_context_inventory_producer_rejects_changed_run_job_and_step(self):
        run = {"id": resume.CONTEXT_RUN, "head_sha": resume.CONTEXT_SOURCE, "run_attempt": 1,
               "repository": {"full_name": "iret77/nexgenvideo"}, "path": ".github/workflows/diagnostic-acceptance.yml",
               "event": "workflow_dispatch", "status": "completed", "conclusion": "success"}
        job = {"name": "ci-film-review-context", "run_id": resume.CONTEXT_RUN, "head_sha": resume.CONTEXT_SOURCE,
               "run_attempt": 1, "status": "completed", "conclusion": "success", "steps": [
            {"name": name, "conclusion": "success"} for name in (
                "Restore exact compiled products without rebuilding", "Reproduce the original App process context once",
                "Preserve App context interpretation and unchanged products", "Verify unchanged context product source")]}
        jobs = {"total_count": 1, "jobs": [job]}
        self.assertEqual(resume.inventory_producer(run, jobs)[0], job)
        for key, value in (("head_sha", HEAD), ("run_attempt", 2), ("conclusion", "failure"),
                           ("path", ".github/workflows/ci-batch.yml"), ("event", "push")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                resume.inventory_producer({**run, key: value}, jobs)
        for changed in ({**jobs, "total_count": 2}, {"total_count": 2, "jobs": [job, job]},
                        {**jobs, "jobs": [{**job, "head_sha": HEAD}]}, {**jobs, "jobs": [{**job, "steps": []}]}):
            with self.subTest(jobs=changed), self.assertRaises(ValueError):
                resume.inventory_producer(run, changed)

    def test_context_supplies_only_exact_completed_inventory_not_normal_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            functions = sorted(f"NexGenVideoTests.Example/test{i}()/Example.swift:{i + 1}:1" for i in range(3668))
            skipped, executed = functions[-8:], functions[:-8]
            records = [{"version": 0, "kind": "test", "payload": {"kind": "function", "id": identity,
                        "sourceLocation": {"fileID": "NexGenVideoTests/Example.swift"}}} for identity in functions]
            records += [{"version": 0, "kind": "event", "payload": {"kind": "runStarted"}}]
            records += [{"version": 0, "kind": "event", "payload": {"kind": kind, "testID": identity}}
                        for identity in executed for kind in ("testStarted", "testEnded")]
            records += [{"version": 0, "kind": "event", "payload": {"kind": "testSkipped", "testID": identity}}
                        for identity in skipped]
            records += [{"version": 0, "kind": "event", "payload": {"kind": "runEnded"}}]
            raw = "".join(json.dumps(r) + "\n" for r in records)
            (root / "events.jsonl").write_text(raw)
            events = resume.swift_events(root / "events.jsonl", "NexGenVideoTests")
            original = {"originalFailureRun": resume.TIMEOUT_RUN, "originalFailureDigest": resume.TIMEOUT_DIGEST,
                        "harnessSHA": resume.CONTEXT_SOURCE, "productSHA": resume.CONTEXT_PRODUCT,
                        "coreAcceptance": False, "releaseAcceptance": False,
                        "expectedDiscoveredFunctionIDs": functions, "expectedSkippedFunctionIDs": skipped,
                        "expectedFunctionIDs": executed}
            suite = {"sourceSHA": resume.CONTEXT_SOURCE, "harnessSourceSHA": resume.CONTEXT_SOURCE,
                     "productSourceSHA": resume.CONTEXT_PRODUCT, "completed": True, "scope": "app-swift-testing",
                     "filter": ".*", "phases": [{"status": "verified-execution", "exitCode": 0,
                         "outputCapture": {"eof": True, "originalExitCode": 0}, "events": events}]}
            wrapper = {"sourceSHA": resume.CONTEXT_SOURCE, "runID": str(resume.CONTEXT_RUN),
                       "testExitCode": 0, "effectiveExitCode": 0}
            failure = {"id": 13109352050, "digest": "sha256:" + resume.TIMEOUT_DIGEST}
            binding = {"artifact": {"id": resume.CONTEXT_ARTIFACT}, "run": {"id": resume.CONTEXT_RUN}}
            variants = [None, ("original", "originalFailureRun", 999), ("original", "coreAcceptance", True),
                        ("original", "expectedSkippedFunctionIDs", []), ("suite", "completed", False),
                        ("suite", "sourceSHA", HEAD), ("suite", "productSourceSHA", HEAD),
                        ("suite", "filter", "One"), ("wrapper", "effectiveExitCode", 1),
                        ("wrapper", "runID", "999"), ("binding", "artifact", {"id": 999}),
                        ("failure", "digest", "sha256:" + "f" * 64), ("digest", "value", "f" * 64),
                        ("inventory", "missingExecution", executed[0]), ("inventory", "missingSkip", skipped[0]),
                        ("inventory", "extraDiscovery", "NexGenVideoTests.Example/extra()/Example.swift:99999:1")]
            for variant in variants:
                values = {"original": copy.deepcopy(original), "suite": copy.deepcopy(suite),
                          "wrapper": copy.deepcopy(wrapper), "binding": copy.deepcopy(binding), "failure": copy.deepcopy(failure)}
                if variant and variant[0] in values: values[variant[0]][variant[1]] = variant[2]
                selected_raw = raw
                if variant and variant[0] == "inventory":
                    identity = variant[2]
                    selected_records = copy.deepcopy(records)
                    if variant[1] == "extraDiscovery":
                        selected_records.insert(0, {"version": 0, "kind": "test", "payload": {
                            "kind": "function", "id": identity, "sourceLocation": {"fileID": "NexGenVideoTests/Example.swift"}}})
                        values["original"]["expectedDiscoveredFunctionIDs"] = sorted(functions + [identity])
                    else:
                        kinds = {"testStarted", "testEnded"} if variant[1] == "missingExecution" else {"testSkipped"}
                        selected_records = [r for r in selected_records
                            if not (r["kind"] == "event" and r["payload"].get("testID") == identity
                                    and r["payload"]["kind"] in kinds)]
                        key = "expectedFunctionIDs" if variant[1] == "missingExecution" else "expectedSkippedFunctionIDs"
                        values["original"][key] = [v for v in values["original"][key] if v != identity]
                    selected_raw = "".join(json.dumps(r) + "\n" for r in selected_records)
                    (root / "events.jsonl").write_text(selected_raw)
                    values["suite"]["phases"][0]["events"] = resume.swift_events(root / "events.jsonl", "NexGenVideoTests")
                with zipfile.ZipFile(root / "inventory.zip", "w") as archive:
                    for name, key in (("film-review-context-binding/binding.json", "original"),
                                      ("film-review-context/hosted-suite/suite.json", "suite"),
                                      ("film-review-context/run.json", "wrapper")):
                        archive.writestr(name, json.dumps(values[key]))
                    archive.writestr("film-review-context/hosted-suite/app-swift-testing/events.jsonl", selected_raw)
                digest = "f" * 64 if variant and variant[0] == "digest" else resume.checksum(root / "inventory.zip")
                with self.subTest(variant=variant), patch.object(resume, "CONTEXT_DIGEST", digest), \
                     patch.object(resume, "verify_artifact") as artifact_check:
                    if variant is None:
                        self.assertEqual(resume.context_inventory(root, values["binding"], resume.TIMEOUT_SOURCE,
                            values["failure"], {}, "inventory"), {"functions": functions, "skips": skipped})
                        artifact_check.assert_called_once_with(values["binding"]["artifact"], values["binding"]["run"],
                            {}, resume.CONTEXT_ARTIFACT, digest, "inventory")
                    else:
                        with self.assertRaises(ValueError):
                            resume.context_inventory(root, values["binding"], resume.TIMEOUT_SOURCE,
                                values["failure"], {}, "inventory")


if __name__ == "__main__":
    unittest.main()
