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

        self.assertIn("needs: source-gate", build)
        self.assertIn("if: inputs.runtime_artifact == ''", build)
        self.assertIn("runs-on: macrunner", build)
        self.assertIn("scripts/bundle.sh debug", build)
        self.assertIn("scripts/assemble_ngvpack.sh", build)
        self.assertIn("actions/upload-artifact@v4", build)
        self.assertIn("runs-on: macos-26", analyze)
        self.assertNotIn("NGV_MACOS_27_RUNNER", text)
        self.assertIn("needs: [source-gate, build-runtime-harness]", analyze)
        self.assertIn(
            "if: ${{ !cancelled() && needs.source-gate.result == 'success' && "
            "(needs.build-runtime-harness.result == 'success' || "
            "(needs.build-runtime-harness.result == 'skipped' && inputs.runtime_artifact != '')) }}",
            analyze,
        )
        self.assertIn("actions/download-artifact@v4", analyze)
        self.assertIn(
            "name: ${{ inputs.runtime_artifact || "
            "format('private-analysis-runtime-{0}-{1}', github.run_id, github.run_attempt) }}",
            analyze,
        )
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
        self.assertIn('tar -czf "$RUNNER_TEMP/musicvideo-acceptance.tar.gz" .', publish)
        self.assertIn("musicvideo-acceptance.tar.gz:application/vnd.nexgenvideo.musicvideo-acceptance.v1+tar+gzip", publish)
        self.assertNotIn("if [ -s hostflow/fullflow.json", publish)

    def test_private_reports_never_use_public_actions_artifacts(self):
        text = WORKFLOW.read_text()
        source_gate = text.split("  source-gate:\n", 1)[1].split("  build-runtime-harness:\n", 1)[0]
        build = text.split("  build-runtime-harness:\n", 1)[1].split("  analyze:\n", 1)[0]
        analyze = text.split("  analyze:\n", 1)[1]

        self.assertIn("gh api /users/iret77/packages/container/nexgenvideo-analysis-reports", source_gate)
        self.assertIn('[ "$(jq -r \'.visibility\' <<<"$REPORT_PACKAGE_JSON")" = "private" ]', source_gate)
        self.assertIn('[ "$(jq -r \'.repository // empty\' <<<"$REPORT_PACKAGE_JSON")" = "" ]', source_gate)
        self.assertNotIn("actions/upload-artifact", source_gate)
        self.assertNotIn("actions/upload-artifact", analyze)
        self.assertEqual(text.count("uses: actions/upload-artifact@v4"), 1)
        self.assertIn("path: ${{ runner.temp }}/runtime-harness.tar.gz", build)
        self.assertIn("REPORT_REFERENCE: ghcr.io/iret77/nexgenvideo-analysis-reports:", analyze)
        self.assertIn('REPORT_DIGEST="$(oras push', analyze)
        self.assertIn('"$REPORT_REFERENCE" \\', analyze)

    def test_public_selftest_log_is_content_free(self):
        text = SELFTEST.read_text()

        self.assertIn('"SELFTEST_EXAMPLE_ANALYSIS_OK report=private\\n"', text)
        self.assertIn('"SELFTEST_EXAMPLE_ANALYSIS_FAIL \\(destination)\\n"', text)
        self.assertIn('"inspect_private_report"', text)
        self.assertIn('"configuration_failed_before_report_destination"', text)
        self.assertNotIn('"SELFTEST_EXAMPLE_ANALYSIS_OK dataset=', text)


if __name__ == "__main__":
    unittest.main()
