import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/private-example-analysis.yml"
SELFTEST = ROOT / "Sources/NexGenVideo/App/ExampleAudioAnalysisSelfTest.swift"


class PrivateExampleWorkflowTests(unittest.TestCase):
    def test_build_and_runtime_jobs_are_separate(self):
        text = WORKFLOW.read_text()
        build = text[text.index("  build-runtime-harness:") : text.index("  analyze:")]
        analyze = text[text.index("  analyze:") :]

        self.assertIn("runs-on: xcode-27", build)
        self.assertIn("scripts/bundle.sh debug", build)
        self.assertIn("scripts/assemble_ngvpack.sh", build)
        self.assertIn("actions/upload-artifact@v4", build)
        self.assertIn("runs-on: macos-26", analyze)
        self.assertNotIn("NGV_MACOS_27_RUNNER", text)
        self.assertIn("needs: build-runtime-harness", analyze)
        self.assertIn("actions/download-artifact@v4", analyze)
        self.assertNotIn("scripts/bundle.sh", analyze)
        self.assertNotIn("scripts/assemble_ngvpack.sh", analyze)
        self.assertLess(analyze.index("sw_vers -productVersion"), analyze.index("actions/download-artifact@v4"))
        self.assertLess(analyze.index("actions/download-artifact@v4"), analyze.index("oras pull"))

    def test_failure_provenance_publishes_without_a_partial_analysis(self):
        text = WORKFLOW.read_text()
        publish = text[text.index("      - name: Publish private analysis report") :]

        self.assertIn("if: ${{ always() }}", publish)
        self.assertIn("analysis-report.v6", publish)
        self.assertIn("analysis-provenance.v6", publish)
        self.assertIn("if [ ! -s \"$RUNNER_TEMP/analysis-report/provenance.json\" ]", publish)
        self.assertNotIn(
            "[ ! -s \"$RUNNER_TEMP/analysis-report/analysis.json\" ] \\",
            publish,
        )
        self.assertIn("if [ -s analysis.json ]; then", publish)
        self.assertIn("analysis-evidence.v1", publish)
        self.assertIn("jq -e '.analysis != null' provenance.json", publish)
        self.assertIn("if [ -s measurement-proof.json ]; then", publish)
        self.assertIn("analysis-measurement-proof.v1", publish)

    def test_public_selftest_log_is_content_free(self):
        text = SELFTEST.read_text()

        self.assertIn('"SELFTEST_EXAMPLE_ANALYSIS_OK report=private\\n"', text)
        self.assertIn('"SELFTEST_EXAMPLE_ANALYSIS_FAIL \\(destination)\\n"', text)
        self.assertIn('"inspect_private_report"', text)
        self.assertIn('"configuration_failed_before_report_destination"', text)
        self.assertNotIn('"SELFTEST_EXAMPLE_ANALYSIS_OK dataset=', text)


if __name__ == "__main__":
    unittest.main()
