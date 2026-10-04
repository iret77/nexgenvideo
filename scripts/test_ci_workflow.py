import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
CI = WORKFLOWS / "ci.yml"
DIAGNOSTIC_ACCEPTANCE = WORKFLOWS / "diagnostic-acceptance.yml"
PR_CHECKS = WORKFLOWS / "pr-checks.yml"
CI_BATCH = WORKFLOWS / "ci-batch.yml"
AUTOMATIC_TRIGGERS = {"push", "pull_request", "pull_request_target", "schedule", "merge_group"}


def triggers(path):
    lines = path.read_text().splitlines()
    keys = []
    for line in lines[lines.index("on:") + 1:]:
        if line and not line.startswith(" "):
            break
        stripped = line.strip()
        if line.startswith("  ") and not line.startswith("   ") and stripped and not stripped.startswith("#"):
            keys.append(stripped.split(":", 1)[0])
    return keys


def run_commands(text):
    commands = []
    for block in text.split("run: ")[1:]:
        first = block.split("\n", 1)[0]
        if first.strip() == "|":
            body = []
            for line in block.split("\n")[1:]:
                if line.strip() and not line.startswith("            "):
                    break
                body.append(line.strip())
            commands.append("\n".join(line for line in body if line))
        else:
            commands.append(first.strip())
    return commands


class CIWorkflowTests(unittest.TestCase):
    def test_merge_gate_requires_every_selected_job(self):
        text = CI.read_text().split("  merge_gate:\n", 1)[1]
        code = text.split("          python3 - <<'PYTHON'\n", 1)[1].split("          PYTHON", 1)[0]
        code = "\n".join(line[10:] for line in code.splitlines())
        for required in (True, False):
            needs = {
                "source_gate": {"result": "success", "outputs": {
                    key: str(required).lower() for key in ("build_required", "bundle_required", "ui_required")
                }},
                **{job: {"result": "success" if required else "skipped"}
                   for job in ("build_test", "ui_render", "diagnostic-startup")},
            }
            def check():
                return subprocess.run([sys.executable, "-c", code], env={**os.environ, "NEEDS_JSON": json.dumps(needs)}, capture_output=True)
            self.assertEqual(check().returncode, 0)
            for job in needs:
                previous = needs[job]["result"]
                unexpected = "skipped" if required or job == "source_gate" else "success"
                for result in ("failure", "cancelled", unexpected):
                    with self.subTest(required=required, job=job, result=result):
                        needs[job]["result"] = result
                        self.assertNotEqual(check().returncode, 0)
                needs[job]["result"] = previous
            needs["source_gate"]["outputs"].pop("bundle_required")
            self.assertNotEqual(check().returncode, 0)

    def test_debug_bundle_reuses_the_build_job_and_keeps_load_checks(self):
        text = CI.read_text()
        build = text.split("  build_test:\n", 1)[1].split("  diagnostic-startup:\n", 1)[0]
        self.assertIn("--build-tests", build)
        self.assertIn("scripts/bundle.sh debug", build)
        self.assertIn("scripts/assemble_ngvpack.sh", build)
        self.assertIn("NGV_SELFTEST_PACK=", build)
        self.assertIn("NGV_SELFTEST_EXPECT_ENGINE_INCOMPATIBLE=1", build)
        self.assertIn("scripts/relaunch_selftest.sh", build)
        self.assertNotIn("render_agent_chat_spec.py", build)
        self.assertNotIn("pull_request:", (ROOT / ".github/workflows/bundle.yml").read_text())

    def test_native_export_actions_run_for_pr_bundle_and_signed_release(self):
        ci = CI.read_text()
        startup = ci.split("  diagnostic-startup:\n", 1)[1].split("  merge_gate:\n", 1)[0]
        self.assertIn("runs-on: macos-26", startup)
        self.assertIn("name: NexGenVideo-app", startup)
        self.assertIn("scripts/export_actions_acceptance.py candidate/NexGenVideo.app", startup)
        self.assertIn("evidence/export-actions.json", startup)
        self.assertIn("if: always()", startup)

        release = DIAGNOSTIC_ACCEPTANCE.read_text()
        self.assertIn("runs-on: macos-26", release)
        self.assertIn("scripts/export_actions_acceptance.py NexGenVideo.app", release)
        self.assertIn("evidence/export-actions.json", release)

    def test_only_the_light_pull_request_check_starts_automatically(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            automatic = set(triggers(path)) & AUTOMATIC_TRIGGERS
            with self.subTest(workflow=path.name):
                if path == PR_CHECKS:
                    self.assertEqual(automatic, {"pull_request"})
                else:
                    self.assertEqual(automatic, set())
        text = PR_CHECKS.read_text()
        header = text.split("jobs:", 1)[0].splitlines()
        self.assertFalse(any(line.strip().startswith(("paths:", "paths-ignore:")) for line in header))
        self.assertNotIn("runs-on: macos", text)
        self.assertNotIn("runs-on: xcode", text)
        self.assertNotIn("uses: ./.github/workflows/", text)

    def test_pull_request_check_mirrors_the_ci_light_job(self):
        light = CI.read_text().split("  source_gate:\n", 1)[1].split("\n  ui_render:\n", 1)[0]
        pr = PR_CHECKS.read_text().split("jobs:", 1)[1]
        self.assertIn("    name: Light Checks\n", light)
        self.assertIn("    name: Light Checks\n", pr)
        commands = run_commands(pr)
        self.assertTrue(commands)
        for command in commands:
            with self.subTest(command=command):
                self.assertIn(command, run_commands(light))

    def test_ci_batch_is_the_manual_heavy_entry_point(self):
        text = CI_BATCH.read_text()
        self.assertEqual(triggers(CI_BATCH), ["workflow_dispatch"])
        self.assertIn("cancel-in-progress: true", text)
        called = [line.split("./.github/workflows/", 1)[1].strip()
                  for line in text.splitlines() if "uses: ./.github/workflows/" in line]
        self.assertIn("ci.yml", called)
        for name in called:
            with self.subTest(workflow=name):
                self.assertIn("workflow_call", triggers(WORKFLOWS / name))


if __name__ == "__main__":
    unittest.main()
