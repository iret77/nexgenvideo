import copy
import hashlib
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import bpy_binary_inputs as inputs
import reuse_bpy_binary_evidence as reuse
import verify_bpy_binary_evidence as verifier


class RuntimeInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.lock = json.loads((inputs.ROOT / "Runtime/bpy/runtime-lock.json").read_text())
        self.lock_path = self.root / "Runtime/bpy/runtime-lock.json"
        paths = ["Runtime/bpy/runtime-lock.json", *inputs.PRODUCER_FILES]
        paths += [item["path"] for item in self.lock["bpyWheelLayout"]["officialLibraryEvidence"].values()]
        for relative in paths:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(inputs.ROOT / relative, target)
        self.original = inputs.runtime_inputs(self.root)

    def test_final_source_pins_do_not_require_another_binary_measurement(self):
        self.lock.update(distributionStatus="ready", distributionBlockers=[],
                         distributionClosure={"publicSourceAsset": {"sha256": "a" * 64}})
        self.lock_path.write_text(json.dumps(self.lock))
        self.assertEqual(inputs.runtime_inputs(self.root), self.original)

    def test_python_wheel_and_native_layout_changes_require_new_measurement(self):
        for key in ("runtime", "wheels", "bpyWheelLayout"):
            with self.subTest(key=key):
                changed = copy.deepcopy(self.lock)
                changed[key] = {"changed": True} if key != "bpyWheelLayout" else {
                    **changed[key], "entryPoint": "bpy/replaced.so"}
                self.lock_path.write_text(json.dumps(changed))
                self.assertNotEqual(inputs.runtime_inputs(self.root), self.original)

    def test_changed_collector_or_primary_library_evidence_requires_measurement(self):
        self.lock_path.write_text(json.dumps(self.lock))
        paths = ["scripts/collect_bpy_binary_evidence.py",
                 self.lock["bpyWheelLayout"]["officialLibraryEvidence"]["correspondence"]["path"]]
        for relative in paths:
            with self.subTest(path=relative):
                path = self.root / relative
                original = path.read_bytes()
                path.write_bytes(original + b"\nchanged")
                self.assertNotEqual(inputs.runtime_inputs(self.root), self.original)
                path.write_bytes(original)


class BinaryReuseTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.run = {"id": 42, "repository": {"full_name": reuse.REPOSITORY},
                    "head_repository": {"full_name": reuse.REPOSITORY}, "head_sha": self.sha,
                    "path": reuse.WORKFLOW, "event": "workflow_dispatch", "status": "completed"}
        self.job = {"id": 7, "run_id": 42, "run_attempt": 1, "name": "binary-evidence",
                    "head_sha": self.sha, "status": "completed", "conclusion": "success",
                    "labels": ["macos-26"], "started_at": "2026-10-19T10:00:00Z",
                    "completed_at": "2026-10-19T10:01:00Z"}
        self.artifact = {"id": 9, "name": "managed-bpy-binary-evidence-" + self.sha,
                         "workflow_run": {"id": 42, "head_sha": self.sha}, "expired": False,
                         "digest": "sha256:" + "b" * 64, "size_in_bytes": 1000,
                         "created_at": "2026-10-19T10:00:30Z", "updated_at": "2026-10-19T10:00:30Z"}
        lock = json.loads(verifier.LOCK.read_text())
        bpy = next(item for item in lock["wheels"] if item["name"] == "bpy")
        expected = lock["bpyWheelLayout"]["expectedRuntimeBinaryEvidence"]
        libraries = {name: {"supported": True, "version": value, "versionString": str(value)}
                     for name, value in expected["libraryVersions"].items()}
        libraries["sdl"] = {"supported": True, "version": [3, 4, 2], "versionString": "3.4.2"}
        self.evidence = {"schema": "nexgenvideo/bpy-binary-evidence-candidate/1",
                         "classification": "candidate-only", "publicDistributionAuthorized": False,
                         "sourceSHA": self.sha, "runtimeInputsSHA256": inputs.runtime_inputs(),
                         "wheel": {"filename": bpy["filename"], "sha256": bpy["sha256"],
                                   "entryPoint": lock["bpyWheelLayout"]["entryPoint"],
                                   "entryPointSHA256": "c" * 64, "entryPointSize": 100},
                         "officialReleaseCommit": lock["bpyWheelLayout"]["officialReleaseCommit"],
                         "blenderBuildHash": expected["buildHash"], "libraryVersions": libraries,
                         "evidenceLimitations": "These values do not identify every native source archive"}

    def producer(self):
        return reuse.require_producer(42, self.run, [self.artifact], [self.job])

    def test_successful_binary_can_survive_an_unrelated_failed_source_job(self):
        self.run["conclusion"] = "failure"
        self.assertEqual(self.producer(), (self.artifact, self.job))

    def test_foreign_source_repository_or_workflow_is_rejected(self):
        original = copy.deepcopy(self.run)
        for key, value in (("path", ".github/workflows/other.yml"),
                           ("repository", {"full_name": "other/repository"}),
                           ("head_repository", {"full_name": "other/repository"}),
                           ("head_sha", "d" * 40), ("status", "in_progress")):
            with self.subTest(key=key):
                self.run = {**original, key: value}
                with self.assertRaises(ValueError):
                    self.producer()

    def test_failed_later_attempt_cannot_fall_back_to_an_old_pass(self):
        failed = {**self.job, "id": 8, "run_attempt": 2, "conclusion": "failure"}
        with self.assertRaisesRegex(ValueError, "latest binary"):
            reuse.require_producer(42, self.run, [self.artifact], [self.job, failed])

    def test_old_artifact_cannot_be_attributed_to_a_new_passing_attempt(self):
        self.job.update(run_attempt=2, started_at="2026-10-19T11:00:00Z", completed_at="2026-10-19T11:01:00Z")
        with self.assertRaisesRegex(ValueError, "artifact does not belong"):
            self.producer()

    def test_expired_or_other_commit_artifact_is_rejected(self):
        for key, value in (("expired", True), ("workflow_run", {"id": 42, "head_sha": "e" * 40})):
            with self.subTest(key=key):
                changed = {**self.artifact, key: value}
                with self.assertRaises(ValueError):
                    reuse.require_producer(42, self.run, [changed], [self.job])

    def test_runtime_hash_and_original_commit_are_independently_required(self):
        verifier.validate(self.evidence, self.sha)
        for key, value in (("sourceSHA", "b" * 40), ("runtimeInputsSHA256", "0" * 64)):
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    verifier.validate({**self.evidence, key: value}, self.sha)

    def archive(self, extra=None):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr("binary-evidence.json", json.dumps(self.evidence))
            archive.writestr("validation.json", "{}")
            if extra:
                archive.writestr(extra, "unexpected")
        return stream.getvalue()

    def test_unexpected_archive_member_is_rejected_without_extraction(self):
        for extra in ("../escape", "nested/file", "binary-evidence.json"):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                reuse.read_evidence(self.archive(extra))

    def test_download_requires_the_actual_github_archive_digest(self):
        data = self.archive()
        with patch.object(reuse.urllib.request, "build_opener") as opener, patch.dict("os.environ", GH_TOKEN="test"):
            opener.return_value.open.return_value = io.BytesIO(data)
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                reuse.download(self.artifact)
            opener.return_value.open.return_value = io.BytesIO(data)
            self.assertEqual(reuse.download({**self.artifact, "digest": "sha256:" + hashlib.sha256(data).hexdigest()}), data)

    def test_reuse_preserves_original_bytes_and_declares_both_commits(self):
        data = self.archive()
        with tempfile.TemporaryDirectory() as directory, patch.object(reuse, "api", return_value=self.run), \
                patch.object(reuse, "pages", side_effect=[[self.artifact], [self.job], [self.artifact], [self.job]]), \
                patch.object(reuse, "download", return_value=data):
            output = Path(directory)
            reuse.reuse(42, "f" * 40, output)
            self.assertEqual((output / "reused-binary-evidence.json").read_bytes(), reuse.read_evidence(data))
            record = json.loads((output / "binary-evidence-reuse.json").read_text())
            self.assertEqual(record["originalSourceSHA"], self.sha)
            self.assertEqual(record["sourceSHA"], "f" * 40)
            self.assertFalse(record["publicDistributionAuthorized"])

    def test_rerun_started_during_download_prevents_publication(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(reuse, "api", side_effect=[self.run, {**self.run, "status": "in_progress"}]), \
                patch.object(reuse, "pages", side_effect=[[self.artifact], [self.job], [self.artifact], [self.job]]), \
                patch.object(reuse, "download", return_value=self.archive()):
            output = Path(directory)
            with self.assertRaises(ValueError):
                reuse.reuse(42, "f" * 40, output)
            self.assertEqual(list(output.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
