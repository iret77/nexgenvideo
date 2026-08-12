import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/private-example-analysis.yml"


class PrivateExampleWorkflowTests(unittest.TestCase):
    def test_build_and_runtime_jobs_are_separate(self):
        text = WORKFLOW.read_text()
        build = text[text.index("  build-runtime-harness:") : text.index("  analyze:")]
        analyze = text[text.index("  analyze:") :]

        self.assertIn("runs-on: xcode-27", build)
        self.assertIn("scripts/bundle.sh debug", build)
        self.assertIn("scripts/assemble_ngvpack.sh", build)
        self.assertIn("actions/upload-artifact@v4", build)
        self.assertIn("runs-on: ${{ vars.NGV_MACOS_27_RUNNER", analyze)
        self.assertIn("needs: build-runtime-harness", analyze)
        self.assertIn("actions/download-artifact@v4", analyze)
        self.assertNotIn("scripts/bundle.sh", analyze)
        self.assertNotIn("scripts/assemble_ngvpack.sh", analyze)
        self.assertLess(analyze.index("sw_vers -productVersion"), analyze.index("actions/download-artifact@v4"))
        self.assertLess(analyze.index("actions/download-artifact@v4"), analyze.index("oras pull"))


if __name__ == "__main__":
    unittest.main()
