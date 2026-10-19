import os
import re
import subprocess
import tempfile
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
            {
                "ci.yml",
                "release.yml",
                "private-example-analysis.yml",
                "chat-hang-replay.yml",
                "recorded-hang-replay.yml",
                "workspace-ui-acceptance.yml",
                "codex-app-server-acceptance.yml",
                "agent-backend-live-acceptance.yml",
            },
        )

    def test_cache_is_scoped_to_dependencies_and_the_exact_toolchain(self):
        text = ACTION.read_text()
        self.assertIn("$RUNNER_TEMP/", text)
        self.assertIn("NGV_SWIFTPM_CACHE_PATH", text)
        self.assertNotIn(".build/", text)
        for identity in ("runner.os", "runner.arch", "toolchain.outputs.identity"):
            self.assertIn(identity, text)
        for command in ('xcode_identity="$(xcodebuild -version)"', 'swift_identity="$(swift --version)"'):
            self.assertIn(command, text)
        for manifest in ("Package.resolved", "Package.swift", "Engine/Package.swift"):
            self.assertIn(manifest, text)

    def test_cache_path_survives_new_runs_but_stays_in_runner_temp(self):
        step = ACTION.read_text().split("    - name: Isolate dependency cache\n", 1)[1].split("\n    - name:", 1)[0]
        shell = step.split("      run: |\n", 1)[1]
        shell = "\n".join(line[8:] for line in shell.splitlines())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            values = []
            for index, (run_id, job, attempt, directory) in enumerate([
                ("101", "build_test", "1", root / "runner-temp"),
                ("202", "acceptance", "2", root / "runner-temp"),
                ("303", "build_test", "1", root / "other-runner-temp"),
            ]):
                output = root / f"output-{index}"
                environment = root / f"environment-{index}"
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", shell], env={
                    **os.environ, "RUNNER_TEMP": str(directory), "GITHUB_RUN_ID": run_id,
                    "GITHUB_JOB": job, "GITHUB_RUN_ATTEMPT": attempt,
                    "GITHUB_OUTPUT": str(output), "GITHUB_ENV": str(environment),
                }, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                path = Path(dict(line.split("=", 1) for line in output.read_text().splitlines())["path"])
                self.assertTrue(path.is_relative_to(directory))
                self.assertEqual(environment.read_text().strip(), f"NGV_SWIFTPM_CACHE_PATH={path}")
                values.append(path)
            self.assertEqual(values[0], values[1])
            self.assertNotEqual(values[0], values[2])


if __name__ == "__main__":
    unittest.main()
