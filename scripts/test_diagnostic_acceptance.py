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
from verify_diagnostic_candidate import APP_DIAGNOSTIC_PATHS, BPY_DIAGNOSTIC_PATHS, CI_HARNESS_PATHS, HARNESS_PATHS, verify, verify_app_crash_archive, verify_app_diagnostic, verify_bpy_diagnostic, verify_ci


class AppCrashCandidateTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.digest = "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/ci-batch.yml",
                        event="workflow_dispatch", status="completed", conclusion="failure", run_attempt=1,
                        repository=dict(full_name="iret77/nexgenvideo"))
        prefix = "Compile, unit tests, app and native bpy acceptance / "
        self.jobs = dict(jobs=[dict(name=prefix + name, status="completed", conclusion="success",
                                   run_id=12, run_attempt=1, head_sha=self.source)
                              for name in ("Light Checks", "Agent UI Evidence", "bpy-source / source")])
        self.jobs["jobs"].append(dict(name=prefix + "Build & Test", status="completed", conclusion="failure",
                                     run_id=12, run_attempt=1, head_sha=self.source,
                                     started_at="2026-10-24T00:17:15Z", completed_at="2026-10-24T00:26:52Z",
                                     steps=[dict(name=name, status="completed", conclusion=result) for name, result in (
                                         ("Build", "success"), ("Verify build did not mutate tracked source", "success"),
                                         ("Stage test runtime inputs", "success"), ("Test", "failure"),
                                         ("Upload render review test diagnosis", "success"), ("Upload .app artifact", "skipped"))]))
        self.jobs["total_count"] = len(self.jobs["jobs"])
        self.artifact = dict(id=34, name="render-review-test-diagnostic-12", expired=False,
                             digest="sha256:" + self.digest, workflow_run=dict(id=12, head_sha=self.source),
                             created_at="2026-10-24T00:26:45Z", updated_at="2026-10-24T00:26:46Z",
                             expires_at="2099-01-01T00:00:00Z")

    def check(self, paths=APP_DIAGNOSTIC_PATHS):
        verify_app_diagnostic(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_accepts_exact_failed_test_producer_with_successful_build(self):
        self.check()

    def test_rejects_foreign_or_nonfailed_producer(self):
        for key, bad in (("head_sha", "c" * 40), ("id", 13), ("conclusion", "success"),
                         ("status", "in_progress"), ("event", "push"), ("run_attempt", 0),
                         ("path", ".github/workflows/ci.yml"), ("repository", dict(full_name="other/repo"))):
            old = self.run[key]
            self.run[key] = bad
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check()
            self.run[key] = old

    def test_every_prerequisite_must_belong_to_this_source_and_attempt(self):
        for job in self.jobs["jobs"]:
            for key, bad in (("run_attempt", 2), ("head_sha", "c" * 40), ("run_id", 13), ("status", "in_progress")):
                old = job[key]
                job[key] = bad
                with self.subTest(job=job["name"], field=key), self.assertRaises(ValueError):
                    self.check()
                job[key] = old

    def test_missing_duplicate_or_failed_prerequisites_cannot_be_hidden(self):
        from copy import deepcopy
        original = deepcopy(self.jobs)
        for change in ("missing", "duplicate", "truncated", "failed"):
            self.jobs = deepcopy(original)
            if change == "missing": self.jobs["jobs"].pop(0)
            elif change == "duplicate": self.jobs["jobs"].append(self.jobs["jobs"][0])
            elif change == "failed": self.jobs["jobs"][0]["conclusion"] = "failure"
            if change != "truncated": self.jobs["total_count"] = len(self.jobs["jobs"])
            else: self.jobs["total_count"] += 1
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check()

    def test_a_failed_build_or_additional_failure_cannot_be_reclassified(self):
        steps = self.jobs["jobs"][-1]["steps"]
        for step in steps:
            old = step["conclusion"]
            step["conclusion"] = "success" if old != "success" else "failure"
            with self.subTest(step=step["name"]), self.assertRaises(ValueError):
                self.check()
            step["conclusion"] = old
        steps.append(dict(name="another failure", status="completed", conclusion="failure"))
        with self.assertRaises(ValueError):
            self.check()

    def test_artifact_cannot_come_from_another_attempt_or_be_substituted(self):
        for key, bad in (("created_at", "2026-10-24T00:00:00Z"), ("updated_at", "2026-10-24T00:27:00Z"),
                         ("expires_at", "2020-01-01T00:00:00Z"), ("digest", "sha256:" + "c" * 64),
                         ("expired", True), ("id", 35), ("name", "NexGenVideo-app"),
                         ("workflow_run", dict(id=13, head_sha=self.source))):
            old = self.artifact[key]
            self.artifact[key] = bad
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check()
            self.artifact[key] = old

    def test_original_product_tests_and_capture_code_must_remain_identical(self):
        for path in ("Tests/NexGenVideoTests/Rendering/GlowKernelTests.swift", "Metal/Glow.metal", "Package.swift",
                     "Sources/NexGenVideo/Compositing/Kernels/GlowKernel.swift", "Tests/AppKitTestHost/AppKitTestHost.swift",
                     "scripts/stage_test_runtime.sh", ".github/workflows/ci.yml"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check([*APP_DIAGNOSTIC_PATHS, path])

    def test_original_archive_must_prove_successful_prior_phases_and_owned_signal(self):
        from copy import deepcopy
        import hashlib
        base = {
            "run.json": dict(runID="12", sourceSHA=self.source, testExitCode=139, effectiveExitCode=139),
            "hosted-suite/suite.json": dict(sourceSHA=self.source, completed=False, scope="all", filter="", phases=[
                dict(name=name, exitCode=0, status="verified-execution", framework=dict(passed=True))
                for name in ("xctest", "engine-swift-testing")] + [
                    dict(name="app-swift-testing", exitCode=-11, status="failed", pid=123)]),
            "hosted-suite/app-swift-testing/post-mortem/receipt.json": dict(
                status="bound-report-captured", originalExitCode=-11, ownedChild=dict(pid=123),
                reports=[dict(file="owned-host-0.ips")]),
        }
        changes = ("valid", "wrong-digest", "wrong-run", "wrong-source", "hidden-exit", "filtered", "engine-failed",
                   "missing-phase", "completed", "wrong-signal", "foreign-pid", "unbound-report", "duplicate")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "original.zip"
            for change in changes:
                records = deepcopy(base)
                original = records["run.json"]
                suite = records["hosted-suite/suite.json"]
                receipt = records["hosted-suite/app-swift-testing/post-mortem/receipt.json"]
                if change == "wrong-run": original["runID"] = "13"
                elif change == "wrong-source": suite["sourceSHA"] = "c" * 40
                elif change == "hidden-exit": original["effectiveExitCode"] = 0
                elif change == "filtered": suite["filter"] = "GlowKernelTests"
                elif change == "engine-failed": suite["phases"][1]["framework"]["passed"] = False
                elif change == "missing-phase": suite["phases"].pop(0)
                elif change == "completed": suite["completed"] = True
                elif change == "wrong-signal": suite["phases"][-1]["exitCode"] = -6
                elif change == "foreign-pid": receipt["ownedChild"]["pid"] = 999
                elif change == "unbound-report": receipt["reports"] = []
                with zipfile.ZipFile(path, "w") as archive:
                    for name, value in records.items(): archive.writestr(name, json.dumps(value))
                    if change == "duplicate":
                        import warnings
                        with warnings.catch_warnings():
                            warnings.simplefilter("ignore", UserWarning)
                            archive.writestr("run.json", json.dumps(original))
                digest = hashlib.sha256(path.read_bytes()).hexdigest() if change != "wrong-digest" else "0" * 64
                with self.subTest(change=change):
                    if change == "valid": verify_app_crash_archive(path, 12, self.source, digest)
                    else:
                        with self.assertRaises(ValueError):
                            verify_app_crash_archive(path, 12, self.source, digest)


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


class BpyOpenCandidateTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.digest = "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/ci-batch.yml",
                        event="workflow_dispatch", status="completed", conclusion="failure", run_attempt=2,
                        repository=dict(full_name="iret77/nexgenvideo"))
        prefix = "Compile, unit tests, app and native bpy acceptance / "
        self.jobs = dict(jobs=[dict(name=prefix + name, status="completed", conclusion="success",
                                   run_id=12, run_attempt=2, head_sha=self.source)
                              for name in ("Light Checks", "Agent UI Evidence", "bpy-source / source",
                                           "diagnostic-startup", "Build & Test")])
        self.jobs["jobs"][-1].update(started_at="2026-10-23T19:59:07Z", completed_at="2026-10-23T20:38:40Z")
        self.jobs["jobs"].append(dict(name=prefix + "bpy-runtime / runtime", status="completed",
                                     conclusion="failure", run_id=12, run_attempt=2, head_sha=self.source,
                                     steps=[dict(name=name, status="completed", conclusion=result) for name, result in (
                                         ("Relocate the exact app and prepare denied resources", "success"),
                                         ("Prove pre-lease and post-exec host-crash cleanup", "failure"),
                                         ("Prepare the independent retained Bible YAML parser", "skipped"),
                                         ("Run real bpy acceptance without ambient Blender or Python", "skipped"))]))
        self.jobs["total_count"] = len(self.jobs["jobs"])
        self.artifact = dict(id=34, name="NexGenVideo-app", expired=False, digest="sha256:" + self.digest,
                             workflow_run=dict(id=12, head_sha=self.source), created_at="2026-10-23T20:37:27Z",
                             updated_at="2026-10-23T20:38:00Z", expires_at="2099-01-01T00:00:00Z")

    def check(self, paths=BPY_DIAGNOSTIC_PATHS):
        verify_bpy_diagnostic(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_second_attempt_app_has_successful_core_prerequisites_and_exact_failure(self):
        self.check()

    def test_other_attempt_or_source_cannot_supply_any_prerequisite(self):
        for job in self.jobs["jobs"]:
            for key, bad in (("run_attempt", 1), ("head_sha", "c" * 40), ("run_id", 13)):
                old = job[key]
                job[key] = bad
                with self.subTest(job=job["name"], field=key), self.assertRaises(ValueError):
                    self.check()
                job[key] = old

    def test_artifact_must_be_produced_in_this_attempt_and_unexpired(self):
        for key, bad in (("created_at", "2026-10-23T19:00:00Z"), ("updated_at", "2026-10-23T21:00:00Z"),
                         ("expires_at", "2020-01-01T00:00:00Z"), ("digest", "sha256:" + "c" * 64),
                         ("expired", True), ("id", 35)):
            old = self.artifact[key]
            self.artifact[key] = bad
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.check()
            self.artifact[key] = old

    def test_duplicate_missing_or_failed_prerequisite_is_rejected(self):
        original = list(self.jobs["jobs"])
        for altered in (original[:-1], original + [original[0]]):
            self.jobs = dict(jobs=altered, total_count=len(altered))
            with self.assertRaises(ValueError):
                self.check()
        self.jobs = dict(jobs=original, total_count=len(original))
        self.jobs["jobs"][3]["conclusion"] = "failure"
        with self.assertRaises(ValueError):
            self.check()

    def test_failure_cannot_be_reclassified_or_hidden_by_another_failure(self):
        steps = self.jobs["jobs"][-1]["steps"]
        for step in steps:
            old = step["conclusion"]
            step["conclusion"] = "success" if old != "success" else "failure"
            with self.assertRaises(ValueError):
                self.check()
            step["conclusion"] = old
        steps.append(dict(name="another failure", status="completed", conclusion="failure"))
        with self.assertRaises(ValueError):
            self.check()

    def test_product_or_runtime_harness_changes_cannot_reuse_the_original_app(self):
        for path in ("Sources/BpyRuntimeProtocol/BpyRuntimeStorage.swift", "Runtime/bpy/runtime-lock.json",
                     "scripts/bpy_runtime_acceptance.py", ".github/workflows/bpy-runtime-acceptance.yml",
                     "scripts/verify_bpy_bundle.sh", "Package.swift"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check([*BPY_DIAGNOSTIC_PATHS, path])

    def test_old_runtime_mode_retains_its_original_attempt_requirement(self):
        with self.assertRaisesRegex(ValueError, "completed CI batch"):
            verify_ci(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, CI_HARNESS_PATHS)


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
        step = workflow.split("      - name: Validate original app selectors\n", 1)[1].split("\n      - ", 1)[0]
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

    def test_original_app_transfer_resumes_exact_bytes_and_rejects_changed_metadata(self):
        import hashlib
        import pinned_download as transfer
        import reuse_bpy_binary_evidence as reuse
        from test_pinned_download import Response

        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/bpy-runtime-acceptance.yml").read_text()
        step = workflow.split("      - name: Retrieve the bound original CI app\n", 1)[1].split("\n      - ", 1)[0]
        script = textwrap.dedent(step.split("          python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0])
        payload = b"original immutable App archive"
        digest = hashlib.sha256(payload).hexdigest()
        artifact = dict(id=42, name="NexGenVideo-app", expired=False, size_in_bytes=len(payload),
                        digest="sha256:" + digest, workflow_run=dict(id=12, head_sha=self.source))
        environment = dict(ORIGINAL_ARTIFACT="42", ORIGINAL_NAME="NexGenVideo-app",
                           ORIGINAL_DIGEST=digest, ORIGINAL_RUN="12", ORIGINAL_SOURCE=self.source)
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, {**environment, "RUNNER_TEMP": directory}), \
             patch.object(reuse, "api", return_value=artifact) as metadata, \
             patch.object(reuse, "source_response", side_effect=[
                 Response(payload[:5], failure=TimeoutError()),
                 Response(payload[5:], 206, {"Content-Range": f"bytes 5-{len(payload) - 1}/{len(payload)}",
                                            "Content-Length": str(len(payload) - 5)})]) as response, \
             patch.object(transfer.time, "sleep"):
            exec(script, {})
            self.assertEqual((Path(directory) / "original-app.zip").read_bytes(), payload)
            self.assertEqual([call.args[1] for call in response.call_args_list], [0, 5])
            metadata.assert_called_once_with("/actions/artifacts/42")
        for change in ({"id": 99}, {"name": "foreign"}, {"expired": True},
                       {"digest": "sha256:" + "f" * 64}, {"size_in_bytes": 0},
                       {"workflow_run": dict(id=99, head_sha=self.source)},
                       {"workflow_run": dict(id=12, head_sha="f" * 40)}):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory, \
                 patch.dict(os.environ, {**environment, "RUNNER_TEMP": directory}), \
                 patch.object(reuse, "api", return_value={**artifact, **change}), \
                 patch.object(reuse, "source_response") as response:
                with self.assertRaises(ValueError):
                    exec(script, {})
                response.assert_not_called()
                self.assertFalse((Path(directory) / "original-app.zip").exists())
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, {**environment, "RUNNER_TEMP": directory}), \
             patch.object(reuse, "api", return_value=artifact), \
             patch.object(reuse, "source_response", return_value=Response(b"x" * len(payload))) as response:
            with self.assertRaisesRegex(ValueError, "size or digest mismatch"):
                exec(script, {})
            response.assert_called_once()

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
