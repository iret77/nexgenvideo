import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import resume_core_source_checks as resume


ROOT = Path(__file__).resolve().parents[1]
SOURCE, HEAD = "a" * 40, "b" * 40


def original_log():
    lines = ["python3 -m unittest discover -s scripts -p 'test_*.py'", "....F...",
             "FAIL: test_every_swiftpm_workflow_uses_the_shared_cache_contract (" + resume.FAILED_TEST + ")",
             "AssertionError: diagnostic-acceptance.yml", "Ran 1191 tests in 218.470s", "FAILED (failures=1, skipped=3)"]
    return "\n".join("2026-10-24T05:15:57.3931115Z \x1b[0m" + line for line in lines) + "\n"


def producer():
    run = {"id": 123, "repository": {"full_name": "iret77/nexgenvideo"}, "path": ".github/workflows/ci-batch.yml",
           "event": "workflow_dispatch", "head_branch": "iret77/activity-approval-layout", "run_attempt": 1,
           "head_sha": SOURCE, "status": "completed", "conclusion": "failure"}
    job = {"id": 456, "run_id": 123, "run_attempt": 1, "head_sha": SOURCE, "status": "completed", "conclusion": "failure",
           "name": "Compile, unit tests, app and native bpy acceptance / Light Checks",
           "steps": [{"name": n, "conclusion": "success"} for n in resume.PASSED_STEPS]
                    + [{"name": "Verify CI and fixture tooling", "conclusion": "failure"}]}
    return run, {"total_count": 1, "jobs": [job]}


class CoreSourceResumeTests(unittest.TestCase):
    def test_original_log_accepts_only_complete_full_suite_with_the_one_known_failure(self):
        log = original_log()
        self.assertEqual(resume.original_result(log), {"total": 1191, "passed": 1187, "skipped": 3, "failed": [resume.FAILED_TEST]})
        variants = [log.replace(resume.FAILED_TEST, "other.test"), log + log,
                    log.replace("FAILED (failures=1, skipped=3)", "FAILED (failures=2, skipped=3)"),
                    log.replace("FAILED (failures=1, skipped=3)", "FAILED (failures=1, errors=1, skipped=3)"),
                    log.replace("Ran 1191 tests", "Ran 0 tests"), log.replace("skipped=3", "skipped=4"),
                    log.replace("python3 -m unittest discover -s scripts -p 'test_*.py'", "filtered command"),
                    log + "ERROR: hidden error\n", "\n".join(log.splitlines()[:-1])]
        for value in variants:
            with self.subTest(value=value[-100:]), self.assertRaises(ValueError):
                resume.original_result(value)

    def test_original_job_requires_success_for_every_reused_gate(self):
        run, jobs = producer()
        self.assertEqual(resume.verify_jobs(run, jobs)["id"], 456)
        for field, value in (("run_attempt", 2), ("head_branch", "other"), ("conclusion", "success"),
                             ("path", ".github/workflows/other.yml")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                resume.verify_jobs({**run, field: value}, jobs)
        for index in range(len(jobs["jobs"][0]["steps"])):
            broken = copy.deepcopy(jobs)
            broken["jobs"][0]["steps"][index]["conclusion"] = "skipped"
            with self.subTest(step=index), self.assertRaises(ValueError):
                resume.verify_jobs(run, broken)
        with self.assertRaises(ValueError):
            resume.verify_jobs(run, {**jobs, "total_count": 2})

    def test_source_changes_are_narrow_and_cannot_chain_partial_proofs(self):
        for path in ("Sources/App.swift", "scripts/lint_app_theme.py", "plugins/musicvideo.json", "scripts/test_run_macos_tests.py"):
            with self.subTest(path=path), patch.object(resume, "command", side_effect=[HEAD, path]), \
                 patch.object(resume.subprocess, "run"), self.assertRaises(ValueError):
                resume.verify_source(SOURCE, HEAD)
        with patch.object(resume, "command", side_effect=[HEAD, "scripts/resume_core_source_checks.py", "", "original full workflow"]), \
             patch.object(resume.subprocess, "run"):
            self.assertEqual(resume.verify_source(SOURCE, HEAD), ["scripts/resume_core_source_checks.py"])
        with patch.object(resume, "command", side_effect=[HEAD, "", "", "scripts/resume_core_source_checks.py"]), \
             patch.object(resume.subprocess, "run"), self.assertRaises(ValueError):
            resume.verify_source(SOURCE, HEAD)

    def test_only_cache_membership_and_core_allowlist_can_change_without_repeating_other_tests(self):
        before = "HARNESS_PATHS = {'old'}\ndef check(x):\n    return x > 0\n"
        after = "HARNESS_PATHS = {'old', 'scripts/test_swiftpm_dependency_cache.py', 'scripts/resume_core_source_checks.py', 'scripts/test_resume_core_source_checks.py'}\ndef check(x):\n    return x > 0\n"
        resume.verify_reused_test_inputs("scripts/resume_core_tests.py", before, after)
        for value in (after.replace("x > 0", "True"), after.replace("'old',", ""), after.replace("'old',", "'extra', 'old',")):
            with self.assertRaises(ValueError):
                resume.verify_reused_test_inputs("scripts/resume_core_tests.py", before, value)
        before = "assert workflows == {'ci.yml'}\nassert cache_enabled\n"
        after = "assert workflows == {'ci.yml', 'diagnostic-acceptance.yml'}\nassert cache_enabled\n"
        resume.verify_reused_test_inputs("scripts/test_swiftpm_dependency_cache.py", before, after)
        for value in (after.replace("assert cache_enabled", "pass"), after.replace("'ci.yml',", ""), before):
            with self.assertRaises(ValueError):
                resume.verify_reused_test_inputs("scripts/test_swiftpm_dependency_cache.py", before, value)

    def test_current_test_output_cannot_pass_empty_failed_or_skipped_selections(self):
        self.assertEqual(resume.successful_tests("..\nRan 2 tests in 0.100s\n\nOK\n"), 2)
        for text in ("OK\n", "Ran 0 tests in 0.1s\nOK\n", "Ran 2 tests in 0.1s\nOK (skipped=1)\n",
                     "Ran 2 tests in 0.1s\nFAILED (failures=1)\n", "ERROR: missing\nRan 2 tests in 0.1s\nOK\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                resume.successful_tests(text)

    def test_selected_execution_propagates_failure_and_never_runs_the_full_suite(self):
        for code, output in ((0, "Ran 2 tests in 0.100s\nOK\n"), (1, "Ran 2 tests in 0.1s\nFAILED (failures=1)\n"), (0, "")):
            with self.subTest(code=code, output=output), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                calls = []
                def execute(args, **kwargs):
                    calls.append(args)
                    kwargs["stdout"].write(output.encode())
                    return SimpleNamespace(returncode=code)
                receipt = {"sourceSHA": HEAD, "originalRun": {"id": 123, "head_sha": SOURCE},
                           "originalResult": {"total": 1191, "passed": 1187, "skipped": 3, "failed": [resume.FAILED_TEST]}}
                with patch.object(resume, "verify", return_value=receipt), patch.object(resume.subprocess, "run", side_effect=execute), \
                     contextlib.redirect_stdout(io.StringIO()):
                    if code == 0 and output:
                        resume.run_selected(root)
                        self.assertEqual(len(calls), 2)
                        self.assertEqual(calls[1][3:], list(resume.WORKFLOW_TESTS))
                        self.assertIn("test_ci_workflow", calls[1])
                        self.assertIn("test_resume_core_tests", calls[1])
                        self.assertIn("test_swift_test_failure_propagation", calls[1])
                        self.assertIn(resume.FAILED_TEST, calls[1])
                        self.assertTrue((root / "completed.json").exists())
                    else:
                        with self.assertRaises(ValueError):
                            resume.run_selected(root)
                        self.assertEqual(len(calls), 1)
                        self.assertFalse((root / "completed.json").exists())
                self.assertNotIn("test_*.py", str(calls))

    def test_receipt_cannot_move_to_another_source_run_or_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            good = {"schema": "core-source-resume/v1", "sourceSHA": HEAD, "runID": "789", "attempt": "1"}
            for field, value in (("sourceSHA", SOURCE), ("runID", "123"), ("attempt", "2")):
                (root / "receipt.json").write_text(json.dumps({**good, field: value}))
                with patch.dict(os.environ, GITHUB_SHA=HEAD, GITHUB_RUN_ID="789", GITHUB_RUN_ATTEMPT="1"), \
                     patch.object(resume, "verify_jobs") as jobs, self.assertRaises(ValueError):
                    resume.verify(root)
                jobs.assert_not_called()

    def test_batch_and_workflow_keep_full_default_and_bound_partial_paths(self):
        text = (ROOT / ".github/workflows/ci-batch.yml").read_text()
        code = textwrap.dedent(text.split("          python3 - <<'PYTHON'\n", 1)[1].split("          PYTHON", 1)[0])
        env = {"NGV_MODE": "initial", "NGV_FOLLOWUP": "none", "NGV_RUNTIME_RUN": "", "NGV_QUALIFICATION_RUN": "",
               "NGV_SOURCE_RUN": "", "NGV_SETTINGS_SCOPE": "all", "NGV_INTERFACE_SCALE": "all", "NGV_TEST_BUNDLE_RUN": "",
               "NGV_COMPLETED_BACKENDS": "123", "NGV_APP_INVENTORY": "456", "NGV_SOURCE_CHECKS": "789"}
        with tempfile.TemporaryDirectory() as directory:
            for change, valid in (({}, True), ({"NGV_SOURCE_CHECKS": "0"}, False),
                                  ({"NGV_COMPLETED_BACKENDS": "", "NGV_APP_INVENTORY": "", "NGV_SOURCE_CHECKS": ""}, True),
                                  ({"NGV_COMPLETED_BACKENDS": "", "NGV_APP_INVENTORY": ""}, False),
                                  ({"NGV_MODE": "qualification"}, False)):
                result = subprocess.run(["python3", "-c", code], env={**os.environ, **env, **change,
                    "GITHUB_OUTPUT": str(Path(directory) / "output")}, capture_output=True, timeout=10)
                self.assertEqual(result.returncode == 0, valid, result.stderr)
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertLess(workflow.index("name: Bind successful source checks"), workflow.index("name: Require distributable bpy"))
        step = workflow.split("      - name: Verify CI and fixture tooling\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("inputs.completed_source_checks_run_id == ''", step)
        self.assertIn("run: python3 -m unittest discover -s scripts -p 'test_*.py'", step)
        continued = workflow.split("      - name: Complete changed source and workflow checks\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("inputs.completed_source_checks_run_id != ''", continued)
        self.assertIn("run: python3 scripts/resume_core_source_checks.py run", continued)
        self.assertNotIn("continue-on-error", continued)
        for name in ("Require distributable bpy before app transfer", "Enforce AppTheme", "Validate pack pipeline contracts"):
            chunk = workflow.split("      - name: " + name + "\n", 1)[1].split("      - name:", 1)[0]
            self.assertIn("inputs.completed_source_checks_run_id == ''", chunk)


if __name__ == "__main__":
    unittest.main()
