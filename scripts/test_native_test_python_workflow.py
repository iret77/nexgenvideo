from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
SELECTION = "./.github/actions/setup-native-test-python"


class NativeTestPythonWorkflowTests(unittest.TestCase):
    def test_every_native_driver_caller_selects_python_before_using_or_replacing_source(self):
        callers = set()
        for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            for name, job in yaml.safe_load(path.read_text())["jobs"].items():
                steps = job.get("steps", [])
                calls = [index for index, step in enumerate(steps)
                         if any(name in step.get("run", "")
                                for name in ("run_macos_tests.py", "run_bpy_owned_child_probe.py"))]
                if not calls:
                    continue
                runner = job.get("runs-on")
                self.assertIn(runner, ("ubuntu-24.04", "macrunner", "macos-26"),
                              f"Unreviewed native-driver runner in {path.name}/{name}: {runner}")
                if runner == "ubuntu-24.04":
                    continue
                callers.add((path.name, name))
                with self.subTest(workflow=path.name, job=name):
                    selected = [index for index, step in enumerate(steps) if step.get("uses") == SELECTION]
                    self.assertEqual(len(selected), 1)
                    checkout = next(index for index, step in enumerate(steps)
                                    if step.get("uses", "").startswith("actions/checkout@"))
                    self.assertLess(checkout, selected[0])
                    self.assertLess(selected[0], min(calls))
                    for index, step in enumerate(steps):
                        if "git checkout --detach" in step.get("run", ""):
                            self.assertLess(selected[0], index)
                        if index > selected[0]:
                            self.assertFalse(step.get("uses", "").startswith("actions/setup-python@"))
                            if step.get("uses", "").startswith("./.github/actions/"):
                                action = ROOT / step["uses"]
                                sources = list(action.glob("action.y*ml"))
                                self.assertEqual(len(sources), 1)
                                content = sources[0].read_text()
                                self.assertNotIn("GITHUB_PATH", content)
                                self.assertNotIn("actions/setup-python", content)
        self.assertEqual(callers, {
            ("ci.yml", "build_test"), ("release.yml", "release"),
            ("workspace-ui-acceptance.yml", "build"), ("codex-app-server-acceptance.yml", "acceptance"),
            ("diagnostic-acceptance.yml", "ci-app-test"),
            ("diagnostic-acceptance.yml", "ci-app-retained-replay"),
            ("native-acceptance-probes.yml", "owned-child"),
        })

    def test_composite_native_wait_consumers_have_an_explicit_selection_contract(self):
        for path in (ROOT / ".github/actions").glob("*/action.y*ml"):
            text = path.read_text()
            if any(name in text for name in ("run_macos_tests", "run_process", "os.waitid", "WNOWAIT")):
                self.assertEqual(path.parent.name, "setup-native-test-python",
                                 f"New composite native wait consumer needs caller coverage: {path}")

    def test_native_python_selection_supports_nonreaping_waitid(self):
        action = yaml.safe_load((ROOT / ".github/actions/setup-native-test-python/action.yml").read_text())
        steps = action["runs"]["steps"]
        self.assertTrue(steps[0]["uses"].startswith("actions/setup-python@"))
        self.assertEqual(steps[0]["with"]["python-version"], "3.13")
        self.assertEqual(steps[0]["with"]["architecture"], "arm64")
        self.assertIn("os.waitid(", steps[1]["run"])
        self.assertIn("os.WNOWAIT", steps[1]["run"])
        self.assertIn("process.wait(timeout=1)", steps[1]["run"])

    def test_native_probe_preserves_failures_before_compilation(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/native-acceptance-probes.yml").read_text())
        steps = workflow["jobs"]["owned-child"]["steps"]
        selection = next(i for i, step in enumerate(steps) if step.get("uses") == SELECTION)
        original = next(i for i, step in enumerate(steps) if "original-python.json" in step.get("run", ""))
        capture = next(i for i, step in enumerate(steps) if "test_run_macos_tests.py" in step.get("run", ""))
        compile_step = next(i for i, step in enumerate(steps) if "xcrun clang" in step.get("run", ""))
        self.assertLess(original, selection)
        self.assertLess(selection, capture)
        self.assertLess(capture, compile_step)
        self.assertIn('mkdir -p "$RUNNER_TEMP/owned-child"', steps[original]["run"])
        self.assertIn("set -euo pipefail", steps[capture]["run"])
        self.assertIn('tee "$RUNNER_TEMP/owned-child/capture-tests.log"', steps[capture]["run"])
        self.assertFalse(steps[capture].get("continue-on-error", False))
        upload = next(step for step in steps if step.get("uses", "").startswith("actions/upload-artifact@"))
        self.assertEqual(upload["if"], "always()")
        self.assertIn("native-test-python.json", upload["with"]["path"])
        self.assertIn("/owned-child", upload["with"]["path"])


if __name__ == "__main__":
    unittest.main()
