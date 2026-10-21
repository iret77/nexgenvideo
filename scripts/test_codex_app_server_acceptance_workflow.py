import re
import shlex
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/codex-app-server-acceptance.yml"


def steps(text):
    chunks = re.split(r"(?m)^      - name: ", text)[1:]
    return dict(chunk.split("\n", 1) for chunk in chunks)


def hosted_commands(step):
    shell = step.replace("\\\n", " ")
    return [
        shlex.split(line.strip())
        for line in shell.splitlines()
        if line.strip().startswith("python3 scripts/run_macos_tests.py ")
    ]


class CodexAppServerAcceptanceWorkflowTests(unittest.TestCase):
    def test_every_app_filter_uses_the_host_with_separate_completion_evidence(self):
        text = WORKFLOW.read_text()
        named = steps(text)
        expected = {
            "Exercise real dialog and spend consumers deterministically": [
                ("productConsumer", "product-consumers"),
            ],
            "Prove emitted configuration parses and starts a clean App Server": [
                ("isolatedConfigurationStartsCleanRuntime", "clean-configuration"),
            ],
            "Prove hostile system configuration is rejected before side effects": [
                ("hostileSystemConfigurationFailsBeforeSideEffects", "hostile-configuration"),
            ],
            "Run real Codex consumer smoke": [
                ("productConsumerOwnsSpendSuspension", "spend-consumer"),
                ("CodexAppServerLiveAcceptanceTests", "live-consumers"),
            ],
        }
        self.assertNotRegex(text, r"(?m)^\s+swift test(?:\s|$)")
        self.assertEqual(text.count("python3 scripts/run_macos_tests.py"), 5)
        directories = []
        for name, selections in expected.items():
            commands = hosted_commands(named[name])
            self.assertEqual(len(commands), len(selections), name)
            for command, (selection, suffix) in zip(commands, selections):
                evidence = f"$RUNNER_TEMP/codex-test-host-{suffix}"
                self.assertEqual(command, [
                    "python3", "scripts/run_macos_tests.py",
                    "--cache-path", "$NGV_SWIFTPM_CACHE_PATH",
                    "--scope", "app-swift-testing", "--filter", selection,
                    "--evidence", evidence,
                ])
                directories.append(evidence)
                self.assertNotIn("continue-on-error:", named[name])
                self.assertNotIn("|| true", named[name])
        self.assertEqual(len(set(directories)), 5)
        upload = named["Upload redacted evidence"]
        self.assertIn("          path: ${{ runner.temp }}/codex-app-server-evidence.json\n", upload)
        self.assertNotIn("codex-test-host-", upload)

    def test_configuration_checks_keep_their_step_environment_and_order(self):
        text = WORKFLOW.read_text()
        named = steps(text)
        clean = named["Prove emitted configuration parses and starts a clean App Server"]
        hostile = named["Prove hostile system configuration is rejected before side effects"]
        self.assertIn('NGV_CODEX_CLEAN_CONFIGURATION: "1"', clean)
        self.assertIn('NGV_CODEX_HOSTILE_SYSTEM_CONFIG: "1"', hostile)
        self.assertLess(clean.index("scripts/run_macos_tests.py"), clean.index('python3 - "$CODEX_HOME/config.toml"'))
        self.assertLess(hostile.index("scripts/run_macos_tests.py"), hostile.index('test ! -e "$NGV_CODEX_HOSTILE_MCP_MARKER"'))
        self.assertIn("if: always()", named["Remove adversarial system configuration fixture"])
        self.assertLess(text.index("Stage test runtime inputs"), text.index("Exercise real dialog and spend consumers deterministically"))
        self.assertLess(text.index("Remove adversarial system configuration fixture"), text.index("Run real Codex consumer smoke"))

    def test_host_routing_preserves_owner_approval_and_source_binding(self):
        text = WORKFLOW.read_text()
        self.assertIn("cancel-in-progress: false", text)
        self.assertIn("    needs: gate\n", text)
        for condition in (
            "github.event_name == 'workflow_dispatch'",
            "github.actor == github.repository_owner",
            "github.triggering_actor == github.repository_owner",
            "github.run_attempt == 1",
            "inputs.run_paid_llm_smoke == true",
            "inputs.approval == 'APPROVE-CODEX-LLM-SMOKE'",
        ):
            self.assertIn(condition, text)
        self.assertIn('test "$ACTUAL_SOURCE_SHA" != "$EXPECTED_SOURCE_SHA"', text)
        self.assertIn('test "$ACTUAL_ACCEPTANCE_WORKFLOW_SHA" != "$EXPECTED_SOURCE_SHA"', text)
        self.assertIn("ref: ${{ inputs.source_sha }}", text)


if __name__ == "__main__":
    unittest.main()
