import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import capture_render_review_test_diagnostic as capture
import resume_core_app_assertions as resume
from test_resume_core_tests import producer, native_events, framework, SWIFT
from test_swift_test_failure_propagation import workflow_test_run


ROOT = Path(__file__).resolve().parents[1]
HEAD = "b" * 40


def assertion_archive(root, mutation=None):
    names = list(resume.FAILURES) + [f"NexGenVideoTests.Other/test{i}()/Other.swift:{i + 1}:1" for i in range(3526)]
    records = [{"version": "6.4.0", "kind": "test", "payload": {"kind": "function", "id": name,
                "sourceLocation": {"fileID": "NexGenVideoTests/" + name.rsplit("/", 1)[1].split(":")[0]}}} for name in names]
    def event(kind, **values):
        return {"version": "6.4.0", "kind": "event", "payload": {"kind": kind, **values}}
    records.append(event("runStarted"))
    for name in names:
        if name in names[-8:]:
            records.append(event("testSkipped", testID=name))
            continue
        records.append(event("testStarted", testID=name))
        for _ in range(resume.FAILURES[name]):
            records.append(event("issueRecorded", testID=name,
                                 issue={"isFailure": True, "isKnown": False, "severity": "error"}))
        records.append(event("testEnded", testID=name))
    records.append(event("runEnded"))
    host = {"abiSucceeded": False, "sourceSHA": resume.SOURCE, "pid": 42, "parentPID": 43,
            "eventRecordCount": len(records), **{key: True for key in
            ("mainThread", "applicationRunningAtStart", "started", "completed", "runReturnedAfterCompletion")}}
    wrapper = {"sourceSHA": resume.SOURCE, "testExitCode": 1, "effectiveExitCode": 1,
               "status": "test-process-exited", "runLoopProbe": {"swiftTestPID": 43}}
    suite = {"phases": [{}, {}, {"exitCode": 1, "pid": 42}]}
    if mutation:
        mutation(records, host, wrapper, suite)
    with zipfile.ZipFile(root / "original.zip", "w") as archive:
        archive.writestr("hosted-suite/app-swift-testing/events.jsonl", "".join(json.dumps(r) + "\n" for r in records))
        archive.writestr("hosted-suite/app-swift-testing/host-receipt.json", json.dumps(host))
        archive.writestr("run.json", json.dumps(wrapper))
    proofs = [{"testCaseExecutions": 47}, {"events": {"functionExecutions": 896,
              "discoveredFunctionIDs": list(range(910)), "skippedFunctionIDs": list(range(14))}}]
    return suite, proofs


class AppAssertionResumeTests(unittest.TestCase):
    def test_only_exact_reviewed_test_bytes_and_harness_paths_are_allowed(self):
        files = "\n".join(sorted(resume.TESTS | dict.fromkeys(resume.HARNESS)))
        def digest(path):
            return resume.TESTS[str(path)]
        with patch.object(resume, "command", side_effect=[HEAD, files, ""]), \
             patch.object(resume.subprocess, "run"), patch.object(resume, "checksum", side_effect=digest):
            self.assertEqual(set(resume.verify_sources(HEAD)), set(files.splitlines()))
        for extra in ("Sources/Anything.swift", "Engine/Tests/Example.swift", "Package.swift",
                      "scripts/run_macos_tests.py", "scripts/retained_app_test_products.py",
                      "Runtime/bpy/runtime-lock.json", "Tests/NexGenVideoTests/Other.swift"):
            with self.subTest(path=extra), patch.object(resume, "command", side_effect=[HEAD, files + "\n" + extra]), \
                 patch.object(resume.subprocess, "run"), self.assertRaises(ValueError):
                resume.verify_sources(HEAD)
        with patch.object(resume, "command", side_effect=[HEAD, files]), patch.object(resume.subprocess, "run"), \
             patch.object(resume, "checksum", return_value="f" * 64), self.assertRaises(ValueError):
            resume.verify_sources(HEAD)
        with patch.object(resume, "command", side_effect=[HEAD, files, " M Package.swift"]), \
             patch.object(resume.subprocess, "run"), patch.object(resume, "checksum", side_effect=digest), self.assertRaises(ValueError):
            resume.verify_sources(HEAD)
        with patch.object(resume, "command", side_effect=[HEAD, "scripts/resume_core_app_assertions.py"]), \
             patch.object(resume.subprocess, "run"), self.assertRaises(ValueError):
            resume.verify_sources(HEAD)

    def test_failed_original_can_prove_completion_but_never_become_app_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backends = assertion_archive(root)
            with patch.object(resume, "DIGEST", hashlib.sha256((root / "original.zip").read_bytes()).hexdigest()), \
                 patch.object(resume, "verify_backends", return_value=backends):
                proof = resume.verify_original(root)
            self.assertEqual(proof["originalAppStatus"], "failed")
            self.assertEqual(proof["originalIssues"], resume.FAILURES)
            self.assertEqual(proof["lifecycleOnly"]["functionExecutions"], 3520)
            def extra_issue(records, host, wrapper, suite):
                records.insert(-1, {"version": "6.4.0", "kind": "event", "payload": {
                    "kind": "issueRecorded", "testID": next(iter(resume.FAILURES)), "issue": {
                        "isFailure": True, "isKnown": False, "severity": "error"}}})
                host["eventRecordCount"] = len(records)
            changes = [lambda r,h,w,s: r.pop(), lambda r,h,w,s: h.update(completed=False),
                       lambda r,h,w,s: h.update(abiSucceeded=True), lambda r,h,w,s: h.update(pid=99),
                       lambda r,h,w,s: h.update(parentPID=99), lambda r,h,w,s: h.update(eventRecordCount=0),
                       lambda r,h,w,s: w.update(testExitCode=0), lambda r,h,w,s: w.update(effectiveExitCode=0),
                       lambda r,h,w,s: w.update(sourceSHA=HEAD), lambda r,h,w,s: s["phases"][2].update(exitCode=-11), extra_issue]
            def change_issue(records, host, wrapper, suite, **values):
                next(r["payload"]["issue"] for r in records if r.get("payload", {}).get("kind") == "issueRecorded").update(values)
            changes += [lambda r,h,w,s: change_issue(r,h,w,s, isKnown=True),
                        lambda r,h,w,s: change_issue(r,h,w,s, severity="warning")]
            for index, change in enumerate(changes):
                backends = assertion_archive(root, change)
                with self.subTest(change=index), \
                     patch.object(resume, "DIGEST", hashlib.sha256((root / "original.zip").read_bytes()).hexdigest()), \
                     patch.object(resume, "verify_backends", return_value=backends), \
                     self.assertRaises((ValueError, resume.VerificationError)):
                    resume.verify_original(root)
            backends = assertion_archive(root)
            with patch.object(resume, "verify_backends", return_value=backends), self.assertRaises(ValueError):
                resume.verify_original(root)

    def test_line_offsets_are_ignored_only_in_the_two_pinned_test_files(self):
        for name in resume.FAILURES:
            moved = name.rsplit(":", 2)[0] + ":999:8"
            self.assertEqual(resume.test_identity(name), resume.test_identity(moved))
            self.assertNotEqual(resume.test_identity(name), resume.test_identity(moved.replace("()/", "Other()/")))
        name = "NexGenVideoTests.Other/test()/Other.swift:1:1"
        self.assertNotEqual(resume.test_identity(name), resume.test_identity(name.replace(":1:1", ":2:1")))

    def test_capture_requires_one_verified_receipt_and_full_normal_app(self):
        command = ["python3", str(ROOT / "scripts/run_macos_tests.py"), "--scope", "app-swift-testing",
                   "--cache-path", "/cache", "--evidence", "/evidence"]
        with patch.object(resume, "verify_local") as verify:
            capture.validate_framework_selection(1, 0, False, True, command, app_assertion_resume=Path("/receipt"))
            verify.assert_called_once_with(Path("/receipt"))
        for variant in (command + ["--filter", "One"], command + ["--app-diagnostic", "zombies"],
                        command + ["--bin-root", "/old"], command[:3] + ["all"] + command[4:]):
            with self.subTest(command=variant), patch.object(resume, "verify_local") as verify, self.assertRaises(ValueError):
                capture.validate_framework_selection(1, 0, False, True, variant, app_assertion_resume=Path("/receipt"))
            verify.assert_not_called()
        with self.assertRaises(ValueError):
            capture.validate_framework_selection(1, 0, False, True, command, Path("/old"), Path("/new"))
        with patch.object(resume, "verify_local", side_effect=ValueError("bad receipt")), self.assertRaises(ValueError):
            capture.validate_framework_selection(1, 0, False, True, command, app_assertion_resume=Path("/receipt"))

    def test_wrong_execution_is_rejected_before_proof_reuse(self):
        value = {"schema": "core-app-assertion-resume/v1", "sourceSHA": HEAD, "runID": "789", "attempt": "1",
                 "originalSourceSHA": resume.SOURCE}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for key in value:
                (root / "receipt.json").write_text(json.dumps({**value, key: "wrong"}))
                with self.subTest(key=key), patch.dict(os.environ, GITHUB_SHA=HEAD, GITHUB_RUN_ID="789", GITHUB_RUN_ATTEMPT="1"), \
                     patch.object(resume, "verify_sources") as sources, self.assertRaises(ValueError):
                    resume.verify_local(root)
                sources.assert_not_called()

    def test_binding_requires_original_run_artifact_and_exact_platform_log(self):
        run, jobs = producer()
        run.update(id=resume.RUN, head_sha=resume.SOURCE)
        job = jobs["jobs"][0]
        job.update(run_id=resume.RUN, head_sha=resume.SOURCE,
                   started_at="2026-10-26T01:47:00Z", completed_at="2026-10-26T02:06:30Z")
        artifact = {"id": resume.ARTIFACT, "name": f"render-review-test-diagnostic-{resume.RUN}",
                    "digest": "sha256:" + resume.DIGEST, "expired": False,
                    "workflow_run": {"id": resume.RUN, "head_sha": resume.SOURCE},
                    "created_at": "2026-10-26T02:06:15Z", "updated_at": "2026-10-26T02:06:15Z",
                    "expires_at": "2099-01-01T00:00:00Z"}
        log = ("2026-10-26T01:47:01.0835480Z OS Information: macOS 27.0 (26A428)\n"
               "2026-10-26T01:47:01.0836670Z Xcode Versions: 27.0 (27A266a) [Apple Silicon] (Selected)\n"
               "2026-10-26T01:48:00.0000000Z Apple Swift version 6.4 (swiftlang-X clang-Y)\n")
        receipt = {"originalRun": run, "originalJobs": jobs, "artifact": artifact,
                   "toolchain": {"swift": "Apple Swift version 6.4 (swiftlang-X clang-Y)",
                                 "xcode": "Xcode 27.0\nBuild version 27A266a"}, "proof": {"originalAppStatus": "failed"}}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for actual, valid in ((log, True), (log.replace("26A428", "26A999"), False),
                                  (log.replace("OS Information", "No platform"), False),
                                  (log + log.splitlines()[0] + "\n", False),
                                  (log.replace("27A266a", "27A999"), False)):
                (root / "original-job.log").write_text(actual)
                with self.subTest(log=actual), patch.object(resume, "LOG_DIGEST", hashlib.sha256(actual.encode()).hexdigest()), \
                     patch.object(resume, "verify_original", return_value=receipt["proof"]):
                    if valid:
                        resume.verify_binding(root, receipt)
                    else:
                        with self.assertRaises(ValueError):
                            resume.verify_binding(root, receipt)
            (root / "original-job.log").write_text(log)
            with patch.object(resume, "verify_original", return_value=receipt["proof"]), self.assertRaises(ValueError):
                resume.verify_binding(root, receipt)
            for field, value in (("id", 123), ("run_attempt", 2), ("head_sha", HEAD)):
                with self.subTest(field=field), self.assertRaises(ValueError):
                    resume.verify_binding(root, {**receipt, "originalRun": {**run, field: value}})
            for field, value in (("id", 123), ("expired", True), ("digest", "sha256:" + "a" * 64)):
                with self.subTest(field=field), self.assertRaises(ValueError):
                    resume.verify_binding(root, {**receipt, "artifact": {**artifact, field: value}})

    def test_finish_keeps_normal_app_checks_and_records_exact_normalization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            suite_root = root / "hosted-suite"
            phase_root = suite_root / "app-swift-testing"
            phase_root.mkdir(parents=True)
            original = next(iter(resume.FAILURES))
            current = original.rsplit(":", 2)[0] + ":999:8"
            raw, _ = native_events("NexGenVideoTests")
            raw = raw.replace("NexGenVideoTests.Example/testOne()/Example.swift:1:1", current)
            raw = raw.replace('"version": 0', '"version": "6.4.0"')
            (phase_root / "events.jsonl").write_text(raw)
            events = resume.swift_events(phase_root / "events.jsonl", "NexGenVideoTests")
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
            receipt = {"sourceSHA": HEAD, "originalSourceSHA": resume.SOURCE, "originalRun": {"id": resume.RUN},
                       "proof": {"backends": [], "originalIssues": dict(resume.FAILURES)},
                       "completedAppInventory": {"functions": [original], "skips": []}}
            (suite_root / "suite.json").write_text(json.dumps(suite))
            (phase_root / "host-receipt.json").write_text(json.dumps(host))
            (root / "run.json").write_text(json.dumps(wrapper))
            (suite_root / "combined.log").write_text(SWIFT)
            with patch.object(resume, "verify_local", return_value=receipt):
                resume.finish(root, suite_root, root)
            completed = json.loads((root / "completed.json").read_text())
            self.assertEqual(completed["schema"], "core-app-assertion-completion/v1")
            self.assertEqual(completed["originalAppStatus"], "failed")
            self.assertEqual(completed["correctedTests"], resume.TESTS)
            for candidate in (original.replace("Indicator()", "IndicatorChanged()"), "other"):
                bad = {**receipt, "completedAppInventory": {"functions": [candidate], "skips": []}}
                with patch.object(resume, "verify_local", return_value=bad), self.assertRaises(ValueError):
                    resume.finish(root, suite_root, root)
            for modified in (raw.replace('"6.4.0"', '"6.5.0"'), "\n".join(raw.splitlines()[:-1])):
                (phase_root / "events.jsonl").write_text(modified)
                with patch.object(resume, "verify_local", return_value=receipt), self.assertRaises((ValueError, resume.VerificationError)):
                    resume.finish(root, suite_root, root)

    def test_prepare_rejects_other_producer_before_allocating_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "evidence"
            with patch.object(resume, "api") as api, self.assertRaises(ValueError):
                resume.prepare(123, root)
            api.assert_not_called()
            self.assertFalse(root.exists())

    def test_dispatch_rejects_other_incidents_and_conflicting_modes(self):
        run = workflow_test_run(ROOT / ".github/workflows/ci-batch.yml", "Reject incomplete or incompatible dispatch inputs")
        env = dict(os.environ, NGV_MODE="initial", NGV_FOLLOWUP="none", NGV_RUNTIME_RUN="",
                   NGV_QUALIFICATION_RUN="", NGV_SOURCE_RUN="", NGV_SETTINGS_SCOPE="all", NGV_INTERFACE_SCALE="all",
                   NGV_APP_ASSERTIONS=str(resume.RUN), NGV_COMPLETED_BACKENDS="", NGV_APP_INVENTORY="",
                   NGV_COMPLETED_FULL="", NGV_SOURCE_CHECKS="", NGV_TEST_BUNDLE_RUN="")
        with tempfile.TemporaryDirectory() as directory:
            for changed, expected in (({}, True), ({"NGV_APP_ASSERTIONS": "123"}, False),
                                      ({"NGV_COMPLETED_BACKENDS": "123", "NGV_APP_INVENTORY": "456"}, False),
                                      ({"NGV_COMPLETED_FULL": "123"}, False), ({"NGV_MODE": "followup"}, False)):
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", run],
                                        env={**env, **changed, "GITHUB_OUTPUT": str(Path(directory) / "output")},
                                        capture_output=True, timeout=10)
                self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_failed_app_or_composition_stops_workflow_without_full_test_fallback(self):
        run = workflow_test_run(ROOT / ".github/workflows/ci.yml", "Test")
        for native, composition in ((0, 0), (139, 0), (1, 0), (0, 1)):
            with self.subTest(native=native, composition=composition), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "scripts").mkdir()
                for name, variable in (("capture_render_review_test_diagnostic.py", "NATIVE"),
                                       ("resume_core_app_assertions.py", "COMPOSITION")):
                    (root / "scripts" / name).write_text(
                        "import os,sys\nfrom pathlib import Path\n"
                        "import json\n"
                        "with Path('calls').open('a') as f: f.write(json.dumps([Path(__file__).name,*sys.argv[1:]])+'\\n')\n"
                        f"sys.exit(int(os.environ['{variable}']))\n")
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", run], cwd=root, capture_output=True,
                                        env={**os.environ, "RUNNER_TEMP": directory, "NGV_SWIFTPM_CACHE_PATH": "/cache",
                                             "NGV_APP_ASSERTIONS": str(resume.RUN), "NGV_COMPLETED_BACKENDS": "",
                                             "NATIVE": str(native), "COMPOSITION": str(composition)}, timeout=10)
                self.assertEqual(result.returncode, native or composition, result.stderr)
                calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
                self.assertEqual([call[0] for call in calls], ["capture_render_review_test_diagnostic.py"] +
                                 ([] if native else ["resume_core_app_assertions.py"]))
                self.assertEqual(calls[0][calls[0].index("--app-assertion-resume") + 1], directory + "/core-app-assertion-resume")
                self.assertEqual(calls[0][calls[0].index("--scope") + 1], "app-swift-testing")
                self.assertEqual(calls[0][calls[0].index("--swift-testing-runs") + 1], "1")
                self.assertEqual(calls[0][calls[0].index("--xctest-runs") + 1], "0")
                if not native:
                    self.assertEqual(calls[1][1], "finish")
                    self.assertEqual(calls[1][calls[1].index("--suite") + 1], directory + "/render-review-test-diagnostic/hosted-suite")
                    self.assertEqual(calls[1][calls[1].index("--capture") + 1], directory + "/render-review-test-diagnostic")


if __name__ == "__main__":
    unittest.main()
