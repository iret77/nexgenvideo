import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / ".github/workflows/ci.yml"


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


if __name__ == "__main__":
    unittest.main()
