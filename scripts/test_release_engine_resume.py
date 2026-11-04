import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

import release_engine_resume as resume
import release_checkpoint as checkpoint


SOURCE = "a" * 40
RUN = 123


class AfterOriginalRetention(datetime):
    @classmethod
    def now(cls, tz=None):
        return datetime(2026, 11, 12, tzinfo=timezone.utc).astimezone(tz)


class ReleaseEngineResumeTests(unittest.TestCase):
    def receipt(self):
        run = {"id": resume.RUN, "head_sha": resume.SOURCE, "repository": {"full_name": "iret77/nexgenvideo"},
               "path": ".github/workflows/release.yml", "run_attempt": 1, "actor": {"login": "iret77"},
               "event": "workflow_dispatch", "status": "completed", "conclusion": "failure"}
        names = ["Record release compiler configuration", "Build the exact release test configuration",
                 "Verify release build did not mutate tracked source", "Stage release test runtime inputs",
                 "Test the exact release configuration", "Upload release test evidence"]
        job = {"id": resume.JOB, "name": "release-build", "run_id": resume.RUN, "head_sha": resume.SOURCE,
               "run_attempt": 1, "labels": ["macrunner"], "status": "completed", "conclusion": "failure",
               "started_at": "2026-11-04T12:37:39Z", "completed_at": "2026-11-04T13:09:24Z",
               "steps": [{"name": name, "conclusion": "failure" if name == names[4] else "success"} for name in names]}
        phase = {"name": resume.NAME, "status": "verified-execution", "exitCode": 0,
                 "outputCapture": {"originalExitCode": 0, "eof": True}, "command": ["swift", "test"],
                 "framework": {"passed": True}, "events": {"functionExecutions": 896}, "log": "/original/console.log"}
        artifact = {"id": resume.ARTIFACT, "name": "release-test-evidence", "digest": "sha256:" + resume.DIGEST,
                    "expired": False, "workflow_run": {"id": resume.RUN, "head_sha": resume.SOURCE},
                    "created_at": "2026-11-04T13:09:19Z", "updated_at": "2026-11-04T13:09:20Z",
                    "expires_at": "2099-01-01T00:00:00Z"}
        return {"schema": "release-engine-resume/v1", "sourceSHA": SOURCE, "runID": RUN, "attempt": 1,
                "originalSourceSHA": resume.SOURCE, "originalRun": run,
                "originalJobs": {"total_count": 1, "jobs": [job]}, "artifact": artifact,
                "artifactSHA256": resume.DIGEST, "originalLogSHA256": resume.LOG_DIGEST,
                "changedPaths": [resume.FIXTURE], "acquiredAt": "2026-11-04T13:10:00Z", "proof": {"phase": phase,
                "eventsSHA256": resume.EVENT_DIGEST, "logSHA256": resume.CONSOLE_DIGEST}}

    def phase_pin(self, receipt):
        value = json.dumps(receipt["proof"]["phase"], sort_keys=True, separators=(",", ":")).encode()
        return patch.object(resume, "PHASE_DIGEST", hashlib.sha256(value).hexdigest())

    def suite(self, receipt):
        phase = {"status": "verified-execution", "exitCode": 0, "outputCapture": {"originalExitCode": 0, "eof": True},
                 "framework": {"passed": True}, "command": ["current-host"]}
        xctest = dict(phase, name="xctest", testCaseExecutions=48)
        engine = copy.deepcopy(receipt["proof"]["phase"])
        engine.update(log="/current/console.log", reusedFrom={"runID": resume.RUN, "sourceSHA": resume.SOURCE,
                      "jobID": resume.JOB, "artifactID": resume.ARTIFACT, "artifactSHA256": resume.DIGEST})
        host = {"sourceSHA": SOURCE, **dict.fromkeys(("mainThread", "applicationRunningAtStart", "started",
                "completed", "abiSucceeded", "runReturnedAfterCompletion"), True)}
        app = dict(phase, name="app-swift-testing", events={"functionExecutions": 3676}, originalHostReceipt=host)
        return {"schema": 1, "sourceSHA": SOURCE, "completed": True, "scope": "all", "configuration": "release",
                "filter": "", "testExecutions": 4620, "freshTestExecutions": 3724, "reusedTestExecutions": 896,
                "combinedFrameworks": {"passed": True}, "retainedBackends": [receipt], "phases": [xctest, engine, app]}

    def test_receipt_rejects_other_source_attempt_producer_and_expired_artifact(self):
        valid = self.receipt()
        with self.phase_pin(valid):
            resume.verify_receipt(valid, SOURCE, RUN)
            mutations = [("sourceSHA", "b" * 40), ("attempt", 2), ("runID", 456),
                         ("originalSourceSHA", SOURCE), ("artifactSHA256", "0" * 64)]
            for key, value in mutations:
                with self.subTest(key=key):
                    changed = copy.deepcopy(valid)
                    changed[key] = value
                    with self.assertRaises(ValueError): resume.verify_receipt(changed, SOURCE, RUN)
            for key, value in (("expired", True), ("expires_at", "2000-01-01T00:00:00Z"),
                               ("created_at", "2026-11-04T12:00:00Z")):
                with self.subTest(artifact=key):
                    changed = copy.deepcopy(valid)
                    changed["artifact"][key] = value
                    with self.assertRaises(ValueError): resume.verify_receipt(changed, SOURCE, RUN)
            changed = copy.deepcopy(valid)
            changed["originalRun"]["repository"]["full_name"] = "foreign/repo"
            with self.assertRaises(ValueError): resume.verify_receipt(changed, SOURCE, RUN)
            for acquired in ("2026-11-04T12:00:00Z", "2100-01-01T00:00:00Z"):
                changed = copy.deepcopy(valid)
                changed["acquiredAt"] = acquired
                with self.subTest(acquired=acquired), self.assertRaises(ValueError):
                    resume.verify_receipt(changed, SOURCE, RUN)

    def test_retained_phase_and_complete_bytes_cannot_be_rewritten(self):
        valid = self.receipt()
        with self.phase_pin(valid):
            for field, value in (("exitCode", 1), ("status", "running"), ("command", ["swift", "test", "--filter=One"])):
                changed = copy.deepcopy(valid)
                changed["proof"]["phase"][field] = value
                with self.subTest(field=field), self.assertRaises(ValueError): resume.verify_receipt(changed, SOURCE, RUN)
            for field in ("eventsSHA256", "logSHA256"):
                changed = copy.deepcopy(valid)
                changed["proof"][field] = "0" * 64
                with self.subTest(field=field), self.assertRaises(ValueError): resume.verify_receipt(changed, SOURCE, RUN)
            changed = copy.deepcopy(valid)
            changed["changedPaths"].append("Engine/Sources/NexGenEngine/Changed.swift")
            with self.assertRaises(ValueError): resume.verify_receipt(changed, SOURCE, RUN)

        with tempfile.TemporaryDirectory() as directory, self.phase_pin(valid):
            root = Path(directory)
            valid["toolchain"] = {"swift": "Swift fixture", "xcode": "Xcode fixture", "python": "3.14.0",
                                  "osVersion": "27.2", "osBuild": "26B123"}
            (root / "receipt.json").write_text(json.dumps(valid))
            (root / "original-job.log").write_bytes(b"bound original log")
            hashes = {"original.zip": resume.DIGEST, "original-job.log": resume.LOG_DIGEST,
                      "events.jsonl": resume.EVENT_DIGEST, "console.log": resume.CONSOLE_DIGEST}
            outputs = {("swift", "--version"): "Swift fixture", ("xcodebuild", "-version"): "Xcode fixture",
                       ("sw_vers", "-productVersion"): "27.2", ("sw_vers", "-buildVersion"): "26B123"}
            with patch.dict(os.environ, {"GITHUB_REPOSITORY": "iret77/nexgenvideo", "GITHUB_SHA": SOURCE,
                            "GITHUB_RUN_ID": str(RUN), "GITHUB_RUN_ATTEMPT": "1"}), \
                    patch.object(resume, "verify_sources", return_value=[resume.FIXTURE]), \
                    patch.object(resume, "toolchain", return_value=valid["toolchain"]), \
                    patch.object(resume.platform, "machine", return_value="arm64"), \
                    patch.object(resume.platform, "python_version", return_value="3.14.0"), \
                    patch.object(resume, "checksum", side_effect=lambda path: hashes[path.name]) as digest, \
                    patch.object(resume, "command", side_effect=lambda *args: outputs[args]) as command:
                resume.verify(root)
                for name in hashes:
                    command.reset_mock()
                    with self.subTest(changedBytes=name), \
                            patch.object(resume, "checksum", side_effect=lambda path: "0" * 64 if path.name == name else hashes[path.name]):
                        with self.assertRaises(ValueError): resume.verify(root)
                        command.assert_not_called()
                for selector in outputs:
                    with self.subTest(environment=selector), \
                            patch.object(resume, "command", side_effect=lambda *args: "changed" if args == selector else outputs[args]):
                        with self.assertRaises(ValueError): resume.verify(root)
                command.reset_mock()
                with patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "2"}):
                    with self.assertRaises(ValueError): resume.verify(root)
                    command.assert_not_called()
                    with self.assertRaises(ValueError): resume.prepare(resume.RUN, root / "never-acquired")
                    self.assertFalse((root / "never-acquired").exists())
                for attribute in ("machine", "python_version"):
                    with self.subTest(environment=attribute), patch.object(resume.platform, attribute, return_value="changed"):
                        with self.assertRaises(ValueError): resume.verify(root)

    def test_composition_keeps_original_engine_and_requires_fresh_complete_app(self):
        receipt = self.receipt()
        suite = self.suite(receipt)
        with self.phase_pin(receipt):
            resume.verify_completed_suite(suite, SOURCE, RUN)
            for key, value in (("completed", False), ("freshTestExecutions", 4620), ("reusedTestExecutions", 0),
                               ("testExecutions", 4619), ("filter", "NativeSegmentInteractionTests")):
                changed = copy.deepcopy(suite)
                changed[key] = value
                with self.subTest(key=key), self.assertRaises(ValueError):
                    resume.verify_completed_suite(changed, SOURCE, RUN)
            for index in (0, 2):
                changed = copy.deepcopy(suite)
                changed["phases"][index]["reusedFrom"] = changed["phases"][1]["reusedFrom"]
                with self.subTest(index=index), self.assertRaises(ValueError):
                    resume.verify_completed_suite(changed, SOURCE, RUN)
            changed = copy.deepcopy(suite)
            changed["phases"][2]["originalHostReceipt"]["abiSucceeded"] = False
            with self.assertRaises(ValueError): resume.verify_completed_suite(changed, SOURCE, RUN)
            changed = copy.deepcopy(suite)
            changed["phases"][1]["reusedFrom"]["sourceSHA"] = SOURCE
            with self.assertRaises(ValueError): resume.verify_completed_suite(changed, SOURCE, RUN)

    def test_source_closure_rejects_engine_dependency_runtime_and_dirty_inputs(self):
        parser = "def swift_events(path, module):\n    return {}\n"
        def invoke(changed, dirty="", after=parser):
            with patch.object(resume, "command", side_effect=[SOURCE, changed, dirty, parser]), \
                    patch.object(resume.subprocess, "run"), patch.object(Path, "read_text", return_value=after):
                return resume.verify_sources(SOURCE)
        self.assertEqual(invoke(resume.FIXTURE), [resume.FIXTURE])
        for path in ("Engine/Package.swift", "Package.resolved", "Runtime/bpy/runtime-lock.json",
                     "Sources/MusicvideoPlugin/Pack.swift", "Sources/NexGenVideo/App/AppViewOwnerAcceptance.swift"):
            with self.subTest(path=path), self.assertRaises(ValueError): invoke(resume.FIXTURE + "\n" + path)
        with self.assertRaises(ValueError): invoke(resume.FIXTURE, resume.FIXTURE)
        with self.assertRaises(ValueError): invoke(resume.FIXTURE, after=parser.replace("{}", "{'changed': True}"))

    def test_signed_input_cannot_disguise_retained_tests_as_fresh(self):
        receipt = self.receipt()
        receipt["artifact"]["expires_at"] = "2026-11-11T13:09:18Z"
        suite = self.suite(receipt)
        manifest = {"schema": "release-signed-input/v1", "repository": "iret77/nexgenvideo",
                    "sourceSHA": SOURCE, "runID": RUN, "attempt": 1,
                    "identity": {"sourceSHA": SOURCE, "version": "1.8.0", "build": "105", "catalogURL": "https://example.invalid/catalog"},
                    "appTreeSHA256": "a" * 64, "nativeEvidence": {"schema": "resumed-release-tests/v1", "suite": suite},
                    "files": {name: {"bytes": 1, "sha256": "b" * 64} for name in checkpoint.FILES}}
        with self.phase_pin(receipt), patch.object(resume, "datetime", AfterOriginalRetention), \
                patch("retained_app_test_products.datetime", AfterOriginalRetention):
            original_job = receipt["originalJobs"]["jobs"][0]
            with self.assertRaises(ValueError):
                resume.verify_artifact(receipt["artifact"], receipt["originalRun"], original_job,
                                       resume.ARTIFACT, resume.DIGEST, "release-test-evidence")
            checkpoint.verify_manifest(manifest, SOURCE, RUN)
            manifest["nativeEvidence"]["schema"] = "fresh-release-tests/v1"
            with self.assertRaises(ValueError): checkpoint.verify_manifest(manifest, SOURCE, RUN)
            manifest["nativeEvidence"]["suite"].pop("retainedBackends")
            with self.assertRaises(ValueError): checkpoint.verify_manifest(manifest, SOURCE, RUN)


if __name__ == "__main__":
    unittest.main()
