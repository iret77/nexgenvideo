from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, mock_open, patch
import zipfile

from hang_diagnostic_acceptance import capture_helper_failure, verify_helper_recovery, verify_retained_key
from verify_diagnostic_candidate import CI_HARNESS_PATHS, HARNESS_PATHS, verify, verify_ci


class CandidateProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.digest = "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/release.yml",
                        event="workflow_dispatch", head_branch="main", status="completed",
                        repository=dict(full_name="iret77/nexgenvideo"), conclusion="failure")
        self.jobs = dict(total_count=2, jobs=[dict(name="release", conclusion="success"),
                                            dict(name="diagnostic-acceptance", conclusion="failure")])
        self.artifact = dict(id=34, name="diagnostic-release-evidence", expired=False,
                             digest=f"sha256:{self.digest}",
                             workflow_run=dict(id=12, head_sha=self.source))

    def check(self, paths=HARNESS_PATHS):
        verify(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_accepts_failed_runtime_job_only_when_signed_release_succeeded(self):
        self.check()
        self.jobs["jobs"][0]["conclusion"] = "failure"
        with self.assertRaisesRegex(ValueError, "release job"):
            self.check()

    def test_rejects_foreign_or_incomplete_source_runs(self):
        for field, value in dict(id=13, head_sha="c" * 40, path=".github/workflows/ci.yml",
                                 event="pull_request", head_branch="feature", status="in_progress",
                                 repository=dict(full_name="another/repository")).items():
            with self.subTest(field=field):
                original = self.run
                self.run = {**original, field: value}
                with self.assertRaises(ValueError):
                    self.check()
                self.run = original

    def test_rejects_missing_duplicate_or_truncated_release_jobs(self):
        for jobs in (dict(total_count=1, jobs=[]), dict(total_count=0, jobs=[]),
                     dict(total_count=2, jobs=[self.jobs["jobs"][0]] * 2)):
            with self.subTest(jobs=jobs):
                self.jobs = jobs
                with self.assertRaises(ValueError):
                    self.check()

    def test_rejects_substituted_expired_or_modified_artifacts(self):
        for field, value in dict(id=35, name="other", expired=True, digest="sha256:" + "c" * 64,
                                 workflow_run=dict(id=13, head_sha=self.source)).items():
            with self.subTest(field=field):
                original = self.artifact
                self.artifact = {**original, field: value}
                with self.assertRaises(ValueError):
                    self.check()
                self.artifact = original
        self.artifact["workflow_run"]["head_sha"] = "c" * 40
        with self.assertRaises(ValueError):
            self.check()

    def test_rejects_any_app_build_or_pack_change(self):
        for path in ("Sources/NexGenVideo/App/NexGenVideoApp.swift", "Package.resolved",
                     "scripts/bundle.sh", ".github/workflows/release.yml", "Info.plist",
                     "musicvideo/manifest.json"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "new signed build"):
                self.check([*HARNESS_PATHS, path])


class CICandidateProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.digest = "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/ci-batch.yml",
                        event="workflow_dispatch", status="completed", run_attempt=1,
                        repository=dict(full_name="iret77/nexgenvideo"), conclusion="failure")
        self.jobs = dict(total_count=4, jobs=[
            dict(name="Compile, unit tests, app and native bpy acceptance / " + name,
                 conclusion="success", status="completed", run_id=12, run_attempt=1, head_sha=self.source)
            for name in ("Light Checks", "Build & Test", "bpy-source / source", "Agent UI Evidence")])
        self.jobs["jobs"].append(dict(
            name="Compile, unit tests, app and native bpy acceptance / diagnostic-startup",
            conclusion="failure", status="completed", run_id=12, run_attempt=1, head_sha=self.source,
            steps=[dict(name=name, status="completed", conclusion="failure" if index == 4 else "success")
                   for index, name in enumerate([
                       "Prove shipped build 97 misses normal recorder startup",
                       "Verify normal startup and disabled preference",
                       "Exercise native Export Cancel, Retry and Reveal actions",
                       "Verify generation batch pricing recovery on macOS 26",
                       "Verify helper recovery during active work"])]))
        self.jobs["total_count"] = len(self.jobs["jobs"])
        self.artifact = dict(id=34, name="NexGenVideo-app", expired=False,
                             digest=f"sha256:{self.digest}", workflow_run=dict(id=12, head_sha=self.source))

    def check(self, paths=CI_HARNESS_PATHS):
        verify_ci(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_failed_runtime_batch_can_reuse_successful_exact_build(self):
        self.check()

    def test_rejects_failed_missing_duplicate_or_other_attempt_build(self):
        from copy import deepcopy
        original = deepcopy(self.jobs)
        for field, value in (("conclusion", "failure"), ("run_id", 13),
                             ("run_attempt", 2), ("head_sha", "c" * 40)):
            self.jobs = deepcopy(original)
            self.jobs["jobs"][1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()
        self.jobs = deepcopy(original)
        self.jobs["jobs"].append(self.jobs["jobs"][1])
        self.jobs["total_count"] = len(self.jobs["jobs"])
        with self.assertRaises(ValueError):
            self.check()
        self.jobs = deepcopy(original)
        self.jobs["jobs"].pop()
        with self.assertRaises(ValueError):
            self.check()

    def test_rejects_other_producer_expired_or_substituted_archive(self):
        for field, value in (("path", ".github/workflows/release.yml"), ("status", "in_progress"),
                             ("head_sha", "c" * 40), ("event", "pull_request"), ("run_attempt", 0), ("run_attempt", 2),
                             ("repository", {"full_name": "other/repo"})):
            original = self.run
            self.run = {**original, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()
            self.run = original
        for field, value in (("expired", True), ("digest", "sha256:" + "c" * 64),
                             ("id", 35), ("name", "workspace-ui-app"),
                             ("workflow_run", {"id": 13, "head_sha": self.source})):
            original = self.artifact
            self.artifact = {**original, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()
            self.artifact = original

    def test_product_pack_runtime_and_build_input_changes_require_new_build(self):
        for path in ("Sources/NexGenVideo/App/AppDelegate.swift", "Package.swift", "Package.resolved",
                     "Runtime/bpy/runtime-lock.json", "scripts/bundle.sh", "scripts/stage_bpy_runtime.sh",
                     "Info.plist", "musicvideo/manifest.json", ".github/workflows/release.yml"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check([*CI_HARNESS_PATHS, path])

    def test_helper_continuation_cannot_hide_another_diagnostic_failure(self):
        from copy import deepcopy
        original = deepcopy(self.jobs)
        for index in range(4):
            for conclusion in ("failure", "skipped", "cancelled"):
                self.jobs = deepcopy(original)
                self.jobs["jobs"][-1]["steps"][index]["conclusion"] = conclusion
                with self.subTest(index=index, conclusion=conclusion), self.assertRaises(ValueError):
                    self.check()
        for change in ("missing", "duplicate", "passed", "missing-prior", "reordered"):
            self.jobs = deepcopy(original)
            steps = self.jobs["jobs"][-1]["steps"]
            if change == "missing": steps.pop()
            elif change == "duplicate": steps.append(deepcopy(steps[-1]))
            elif change == "passed": steps[-1]["conclusion"] = "success"
            elif change == "missing-prior": steps.pop(0)
            elif change == "reordered": steps[0], steps[1] = steps[1], steps[0]
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check()

    def test_runtime_selectors_cannot_override_normal_or_signed_source(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/bpy-runtime-acceptance.yml").read_text()
        step = workflow.split("      - name: Validate original app selectors\n", 1)[1].split("      - uses:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        empty = dict(ORIGINAL_RUN="", ORIGINAL_SOURCE="", ORIGINAL_ARTIFACT="", ORIGINAL_DIGEST="", DISTRIBUTION="false")
        complete = {**empty, "ORIGINAL_RUN": "12", "ORIGINAL_SOURCE": self.source,
                    "ORIGINAL_ARTIFACT": "34", "ORIGINAL_DIGEST": self.digest}
        cases = [(empty, True), ({**empty, "DISTRIBUTION": "true"}, True), (complete, True),
                 ({**complete, "DISTRIBUTION": "true"}, False)]
        for key in ("ORIGINAL_RUN", "ORIGINAL_SOURCE", "ORIGINAL_ARTIFACT", "ORIGINAL_DIGEST"):
            cases.append(({**complete, key: ""}, False))
            cases.append(({**complete, key: "invalid"}, False))
        for environment, valid in cases:
            with self.subTest(environment=environment):
                result = subprocess.run(["bash", "-c", script], env={**os.environ, **environment},
                                        stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
                self.assertEqual(result.returncode == 0, valid, result.stderr.decode())

    def test_resumed_source_preparation_passes_the_original_receipt_identity(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/bpy-runtime-acceptance.yml").read_text()
        step = workflow.split("      - name: Prepare qualified source for the original CI app\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: inputs.runtime_run_id != ''", step)
        self.assertIn("ORIGINAL_SOURCE: ${{ inputs.expected_source_sha }}", step)
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            interpreter = root / "python3"
            interpreter.write_text(f"#!{sys.executable}\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n")
            interpreter.chmod(0o755)
            result = subprocess.run(["bash", "-c", script],
                                    env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                                         "RUNNER_TEMP": temporary, "ORIGINAL_SOURCE": self.source,
                                         "GITHUB_SHA": "c" * 40},
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5, check=True)
            self.assertEqual(json.loads(result.stdout), ["scripts/consume_bpy_distributable_source.py",
                             "--output-directory", str(root / "source"), "--source-sha", self.source,
                             "--receipt", str(root / "download/bpy-source/bpy-source-receipt.json")])
        normal = workflow.split("      - uses: ./.github/actions/prepare-bpy-source\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("if: inputs.runtime_run_id == ''", normal)


class HelperRecoveryEvidenceTests(unittest.TestCase):
    def test_timeout_preserves_capture_and_still_fails_and_reaps_own_process(self):
        process = Mock(pid=123, returncode=None)
        failure = subprocess.TimeoutExpired(["app"], 65)
        process.wait.side_effect = [failure, 0]
        process.poll.return_value = None
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch("hang_diagnostic_acceptance.Path.home", return_value=root), patch(
                "hang_diagnostic_acceptance.subprocess.Popen", return_value=process,
            ) as launch, patch("hang_diagnostic_acceptance.capture_helper_failure") as capture:
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    verify_helper_recovery(Path("app"), output=root / "evidence")
                self.assertIs(caught.exception, failure)
                self.assertEqual(capture.call_args.args[0], process)
                self.assertIs(capture.call_args.args[-1], failure)
                self.assertEqual(process.wait.call_args_list[0].kwargs, {"timeout": 65})
                self.assertEqual(process.wait.call_args_list[-1].kwargs, {"timeout": 5})
                process.kill.assert_called_once()
                self.assertNotEqual(launch.call_args.kwargs["stdout"], subprocess.DEVNULL)
                self.assertEqual(launch.call_args.kwargs["stderr"], subprocess.STDOUT)

    def test_capture_failure_cannot_replace_original_timeout(self):
        process = Mock(pid=123)
        process.poll.return_value = None
        failure = subprocess.TimeoutExpired(["app"], 65)
        process.wait.side_effect = [failure, 0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch("hang_diagnostic_acceptance.Path.home", return_value=root), patch(
                "hang_diagnostic_acceptance.subprocess.Popen", return_value=process,
            ), patch("hang_diagnostic_acceptance.capture_helper_failure", side_effect=OSError("full")), patch(
                "hang_diagnostic_acceptance.Path.open", mock_open(),
            ) as opened:
                opened.return_value.write.side_effect = OSError("disk full")
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    verify_helper_recovery(Path("app"), output=root / "evidence")
                self.assertIs(caught.exception, failure)
                process.kill.assert_called_once()

    def test_capture_keeps_only_new_recordings_bound_to_launched_pid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "recordings"
            root.mkdir()
            output = Path(temporary) / "evidence"
            output.mkdir()
            for name, pid in (("old", 123), ("own", 123), ("other", 456)):
                folder = root / name
                folder.mkdir()
                (folder / "heartbeat.json").write_text(json.dumps({"processID": pid}))
                (folder / "sample.stacks").write_text("stack")
            (root / "linked").symlink_to(root / "own", target_is_directory=True)
            process = Mock(pid=123)
            process.poll.return_value = None
            with patch("hang_diagnostic_acceptance.subprocess.run", side_effect=OSError("no sample")):
                capture_helper_failure(process, root, {root / "old"}, output, RuntimeError("failed"))
            receipt = json.loads((output / "helper-recovery-failure.json").read_text())
            self.assertEqual(receipt["recordings"], ["own"])
            self.assertEqual(receipt["captureErrors"], ["OSError"])
            with zipfile.ZipFile(output / "helper-recovery-recordings.zip") as archive:
                self.assertEqual(set(archive.namelist()), {"own/heartbeat.json", "own/sample.stacks"})
                self.assertEqual(archive.read("own/sample.stacks"), b"stack")
            process.kill.assert_not_called()

    def test_sample_is_bounded_and_bad_heartbeat_does_not_hide_other_recordings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "recordings"
            root.mkdir()
            output = Path(temporary) / "evidence"
            output.mkdir()
            for name, value in (("a-bad", []), ("b-valid", {"processID": 123})):
                folder = root / name
                folder.mkdir()
                (folder / "heartbeat.json").write_text(json.dumps(value))
            process = Mock(pid=123)
            process.poll.return_value = None
            result = SimpleNamespace(returncode=0, stdout=b"sample complete", stderr=b"")
            with patch("hang_diagnostic_acceptance.subprocess.run", return_value=result) as sample:
                capture_helper_failure(process, root, set(), output, RuntimeError("failed"))
            self.assertEqual(sample.call_args.args[0], ["/usr/bin/sample", "123", "1", "-file",
                                                      str(output / "helper-recovery-sample.log")])
            self.assertEqual(sample.call_args.kwargs["timeout"], 10)
            self.assertEqual(sample.call_args.kwargs["stdin"], subprocess.DEVNULL)
            receipt = json.loads((output / "helper-recovery-failure.json").read_text())
            self.assertEqual(receipt["sampleExitCode"], 0)
            self.assertEqual(receipt["recordings"], ["b-valid"])
            self.assertEqual(receipt["unmatched"], [{"folder": "a-bad", "reason": "invalid-heartbeat"}])
            self.assertEqual((output / "helper-recovery-sample-tool.log").read_bytes(), b"sample complete")


class RetainedKeyAcceptanceTests(unittest.TestCase):
    def verify(self, codes):
        with patch("hang_diagnostic_acceptance.subprocess.run",
                   side_effect=[SimpleNamespace(returncode=code) for code in codes]):
            verify_retained_key(Path("NexGenVideo.app"),
                                "hang-diagnostic-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "synthetic-key")

    def test_accepts_real_key_and_rejects_changed_key_and_missing_recording(self):
        self.verify([0, 70, 70, 0])

    def test_rejects_an_app_that_always_succeeds_or_cannot_read_its_key(self):
        for codes in ([0, 0, 0, 0], [70, 70, 70, 70], [0, 70, 0, 0], [0, 70, 70, 70]):
            with self.subTest(codes=codes), self.assertRaises(AssertionError):
                self.verify(codes)


if __name__ == "__main__":
    unittest.main()
