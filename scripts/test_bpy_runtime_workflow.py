import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BpyRuntimeWorkflowTests(unittest.TestCase):
    def test_acceptance_is_manual_and_uses_existing_runner_split(self):
        text = (ROOT / ".github/workflows/bpy-runtime-acceptance.yml").read_text()
        trigger = text.split("permissions:", 1)[0]
        self.assertIn("workflow_dispatch:", trigger)
        self.assertNotIn("pull_request:", trigger)
        self.assertNotIn("push:", trigger)
        self.assertIn("runs-on: xcode-27", text)
        self.assertIn("runs-on: macos-26", text)
        self.assertIn("scripts/stage_bpy_runtime.sh", text)
        self.assertIn("scripts/bundle.sh release --sign", text)
        self.assertIn("scripts/notarize.sh", text)
        self.assertIn("NGV_SELFTEST_BPY", text)
        self.assertIn(".crossSessionDenied == true", text)

    def test_release_fails_closed_on_distribution_review(self):
        release = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("verify_bpy_runtime.py --distribution", release)
        self.assertIn("if: ${{ inputs.dry_run == false }}", release)

    def test_worker_has_no_network_entitlement(self):
        for filename in (
            "NexGenVideoBpyService.entitlements",
            "PythonChild.entitlements",
        ):
            text = (ROOT / "Runtime/bpy" / filename).read_text()
            self.assertIn("com.apple.security.app-sandbox", text)
            self.assertNotIn("com.apple.security.network.client", text)
            self.assertNotIn("com.apple.security.files", text)

    def test_bundle_creates_two_distinct_xpc_containers(self):
        text = (ROOT / "scripts/bundle_bpy_runtime.sh").read_text()
        self.assertIn("for slot in 0 1", text)
        self.assertIn("bpy-service-$slot", text)


if __name__ == "__main__":
    unittest.main()
