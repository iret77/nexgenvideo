import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ACTION = ROOT / ".github/actions/cache-swiftpm-dependencies/action.yml"
SWIFTPM_COMMAND = re.compile(
    r"(?m)^[ \t]*(?:run:[ \t]*)?(?:swift (?:build|test)|scripts/(?:bundle|assemble_ngvpack)\.sh)"
)


class SwiftPMDependencyCacheTests(unittest.TestCase):
    def test_build_products_are_never_cached(self):
        candidates = [
            *(ROOT / ".github/workflows").glob("*.y*ml"),
            *(ROOT / ".github/actions").glob("**/action.y*ml"),
        ]
        cache_users = []
        for path in candidates:
            count = path.read_text().count("uses: actions/cache@")
            cache_users.extend([path] * count)
        self.assertEqual(cache_users, [ACTION])
        text = ACTION.read_text()
        self.assertIn("path: ${{ steps.cache-path.outputs.path }}", text)
        self.assertIn("NGV_SWIFTPM_CACHE_PATH=$path", text)
        self.assertIn("$GITHUB_RUN_ID-$GITHUB_JOB-$GITHUB_RUN_ATTEMPT", text)
        self.assertNotIn("~/Library/Caches/org.swift.swiftpm", text)
        self.assertNotIn(".build", text)

    def test_every_swiftpm_workflow_uses_the_shared_cache_contract(self):
        workflows = []
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            text = path.read_text()
            if not SWIFTPM_COMMAND.search(text):
                continue
            workflows.append(path.name)
            self.assertIn("uses: ./.github/actions/cache-swiftpm-dependencies", text)
            self.assertLess(
                text.index("uses: ./.github/actions/setup-xcode-27"),
                text.index("uses: ./.github/actions/cache-swiftpm-dependencies"),
            )
        self.assertEqual(
            set(workflows),
            {"ci.yml", "bundle.yml", "release.yml", "private-example-analysis.yml"},
        )

    def test_cache_is_scoped_to_dependencies_and_the_exact_toolchain(self):
        text = ACTION.read_text()
        self.assertIn("$RUNNER_TEMP/swiftpm-cache-", text)
        self.assertIn("NGV_SWIFTPM_CACHE_PATH", text)
        self.assertNotIn(".build/", text)
        for identity in ("runner.os", "runner.arch", "toolchain.outputs.identity"):
            self.assertIn(identity, text)
        for command in ('xcode_identity="$(xcodebuild -version)"', 'swift_identity="$(swift --version)"'):
            self.assertIn(command, text)
        for manifest in ("Package.resolved", "Package.swift", "Engine/Package.swift"):
            self.assertIn(manifest, text)


if __name__ == "__main__":
    unittest.main()
