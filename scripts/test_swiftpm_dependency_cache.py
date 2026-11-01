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
                "diagnostic-acceptance.yml",
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

    def test_git_maintenance_is_foreground_without_clobbering_existing_config(self):
        step = ACTION.read_text().split("    - name: Complete Git maintenance before copying dependencies\n", 1)[1].split("\n    - name:", 1)[0]
        shell = "\n".join(line[8:] for line in step.split("      run: |\n", 1)[1].splitlines())
        for inherited_count in (None, "", "0", "2", "02"):
            with self.subTest(inherited_count=inherited_count), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                environment_file = root / "environment"
                environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_CONFIG")}
                environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GITHUB_ENV=str(environment_file))
                if inherited_count is not None:
                    environment["GIT_CONFIG_COUNT"] = inherited_count
                if inherited_count in ("2", "02"):
                    environment.update(GIT_CONFIG_KEY_0="test.preserved", GIT_CONFIG_VALUE_0="original",
                                       GIT_CONFIG_KEY_1="maintenance.autoDetach", GIT_CONFIG_VALUE_1="true")
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", shell], cwd=root, env=environment,
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                environment.update(dict(line.split("=", 1) for line in environment_file.read_text().splitlines()))
                for key in ("maintenance.autoDetach", "gc.autoDetach"):
                    actual = subprocess.run(["git", "config", "--type=bool", "--get", key], cwd=root, env=environment,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual((actual.returncode, actual.stdout.strip()), (0, "false"), actual.stderr)
                if inherited_count in ("2", "02"):
                    actual = subprocess.run(["git", "config", "--get", "test.preserved"], cwd=root, env=environment,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual((actual.returncode, actual.stdout.strip()), (0, "original"), actual.stderr)
                self.assertEqual(result.stdout, "")

    def test_invalid_inherited_git_configuration_fails_before_environment_mutation(self):
        step = ACTION.read_text().split("    - name: Complete Git maintenance before copying dependencies\n", 1)[1].split("\n    - name:", 1)[0]
        shell = "\n".join(line[8:] for line in step.split("      run: |\n", 1)[1].splitlines())
        for inherited in ({"GIT_CONFIG_COUNT": "invalid"}, {"GIT_CONFIG_COUNT": "-1"},
                          {"GIT_CONFIG_COUNT": "1"}, {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "test.missing"}):
            with self.subTest(inherited=inherited), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                environment_file = root / "environment"
                environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_CONFIG")}
                environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GITHUB_ENV=str(environment_file), **inherited)
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", shell], cwd=root, env=environment,
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(environment_file.exists())


if __name__ == "__main__":
    unittest.main()
