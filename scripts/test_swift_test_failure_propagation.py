import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import capture_render_review_test_diagnostic as diagnostic


ROOT = Path(__file__).resolve().parents[1]


def workflow_test_run(workflow, name):
    chunks = re.split(r"(?m)^      - ", workflow.read_text())[1:]
    matches = [chunk for chunk in chunks if chunk.startswith(f"name: {name}\n")]
    if len(matches) != 1:
        raise AssertionError(f"expected one {name!r} step in {workflow}")
    step = matches[0]
    if not re.search(r"(?m)^        shell: bash$", step):
        raise AssertionError("test step must use explicit bash")
    run = re.search(r"(?m)^        run: \|\n((?:          [^\n]*\n|\n)*)", step)
    if not run:
        raise AssertionError("expected a literal test run block")
    return textwrap.dedent(run.group(1))


COMPLETE_OUTPUT = """Test Suite 'All tests' started at 2026-10-20 20:06:53.293.
Test Case '-[NexGenVideoTests.Example testExample]' passed (0.001 seconds).
Test Suite 'All tests' passed at 2026-10-20 20:07:18.692.
Test Suite 'All tests' started at 2026-10-20 20:07:18.843.
Test Suite 'All tests' passed at 2026-10-20 20:07:18.844.
◇ Test run started.
✔ Test sample() passed after 0.001 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.100 seconds.
◇ Test run started.
✔ Test run with 3 tests in 1 suite passed after 0.200 seconds."""


class SwiftTestFailurePropagationTests(unittest.TestCase):
    def test_full_retained_app_capture_rejects_every_filter_and_missing_product_root(self):
        command = ["python3", str(Path(diagnostic.__file__).with_name("run_macos_tests.py")),
                   "--scope", "app-swift-testing", "--app-diagnostic", "app-reproduction",
                   "--bin-root", "/fixture/Debug", "--product-source-sha", "a" * 40]
        diagnostic.validate_framework_selection(1, 0, True, True, command)
        for variant in (command + ["--filter", ""], command + ["--filter", "GlowKernelTests"],
                        command + ["--filter=GlowKernelTests"], command[:6] + command[8:],
                        command[:7] + ["relative"] + command[8:]):
            with self.subTest(command=variant), self.assertRaises(ValueError):
                diagnostic.validate_framework_selection(1, 0, True, True, variant)

    def test_retained_glow_capture_cannot_expand_or_change_the_selected_profile(self):
        command = ["python3", str(Path(diagnostic.__file__).with_name("run_macos_tests.py")),
                   "--scope", "app-swift-testing", "--app-diagnostic", "glow-reproduction",
                   "--filter", "GlowKernelTests", "--bin-root", "/fixture/Debug",
                   "--product-source-sha", "a" * 40]
        diagnostic.validate_framework_selection(1, 0, True, True, command)
        variants = [command + ["--filter", "GlowKernelTests"], command + ["--bin-root", "/other"],
                    command[:7] + ["OtherTests"] + command[8:],
                    command[:9] + ["relative/Debug"] + command[10:],
                    command[:5] + ["zombies"] + command[6:],
                    command + ["--bin-root=/other"], command[:6] + command[8:]]
        for variant in variants:
            with self.subTest(command=variant), self.assertRaises(ValueError):
                diagnostic.validate_framework_selection(1, 0, True, True, variant)

    def test_app_only_selection_is_explicit_and_cannot_reduce_normal_ci_requirements(self):
        command = ["python3", str(Path(diagnostic.__file__).with_name("run_macos_tests.py")),
                   "--scope", "app-swift-testing", "--app-diagnostic", "zombies", "--evidence", "/fixture/evidence",
                   "--product-source-sha", "a" * 40]
        diagnostic.validate_framework_selection(1, 0, True, True, command)
        diagnostic.validate_framework_selection(2, 2, False, True, command)
        cases = [
            (1, 0, False, True, command), (0, 0, True, True, command), (2, 0, True, True, command),
            (1, 1, True, True, command), (1, 0, True, False, command),
            (1, 0, True, True, ["echo", "success"]),
            (1, 0, True, True, [*command, "--filter", "GlowKernelTests"]),
            (1, 0, True, True, [*command, "--filter=GlowKernelTests"]),
            (1, 0, True, True, [*command, "--scope=all"]),
            (1, 0, True, True, [*command, "--scope", "app-swift-testing"]),
            (1, 0, True, True, command[:4] + command[6:]),
            (1, 0, True, True, command[:-2]),
            (1, 0, True, True, command[:-1] + ["invalid"]),
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                diagnostic.validate_framework_selection(*case)

    def test_nonzero_exit_is_final_and_zero_requires_complete_selected_runs(self):
        workflows = (
            ("ci.yml", "Test", "test.log", []),
            (
                "release.yml",
                "Test the exact release configuration",
                "release-test.log",
                ["-c", "release", "--scratch-path", "{runtime}/release-tests"],
            ),
        )
        for filename, name, log, configuration in workflows:
            run = workflow_test_run(ROOT / ".github/workflows" / filename, name)
            cases = (
                (139, "error: Exited with unexpected signal code 11", 139),
                (1, "Test Suite failed", 1),
                (0, COMPLETE_OUTPUT, 0),
                (0, COMPLETE_OUTPUT.replace("All tests", "Selected tests"), 1),
                (0, "All tests passed", 1),
                (0, COMPLETE_OUTPUT.replace(
                    "✔ Test sample() passed after 0.001 seconds.",
                    "✘ Test sample() recorded an issue at Example.swift:1:1: Expectation failed"), 1),
                (0, COMPLETE_OUTPUT.replace("passed after 0.100 seconds.",
                                            "failed after 0.100 seconds with 1 issue."), 1),
                (0, COMPLETE_OUTPUT.replace(
                    "✔ Test run with 2 tests in 1 suite passed after 0.100 seconds.\n", ""), 1),
                (0, COMPLETE_OUTPUT.rsplit("\n", 1)[0], 1),
                (0, COMPLETE_OUTPUT.rsplit("\n", 2)[0], 1),
                (0, COMPLETE_OUTPUT.replace(
                    "Test Suite 'All tests' passed at 2026-10-20 20:07:18.692.\n", ""), 1),
                (0, COMPLETE_OUTPUT.replace(
                    "Test Case '-[NexGenVideoTests.Example testExample]' passed (0.001 seconds).",
                    "Test Case '-[NexGenVideoTests.Example testExample]' failed (0.001 seconds)."), 1),
                (0, COMPLETE_OUTPUT.replace("◇ Test run started.\n", "", 1), 1),
                (0, COMPLETE_OUTPUT + "\n◇ Test run started.", 1),
                (0, COMPLETE_OUTPUT.replace("2 tests in 1 suite", "0 tests in 0 suites"), 1),
                (0, COMPLETE_OUTPUT.replace(
                    "✔ Test run with 2 tests in 1 suite passed after 0.100 seconds.",
                    "━ Test run with 2 tests in 1 suite passed after 0.100 seconds with 1 known issue."), 0),
                (0, "warning: renderer reported an expected error\n" + COMPLETE_OUTPUT, 0),
                (0, "\x1b[32m" + COMPLETE_OUTPUT + "\x1b[0m", 0),
            )
            for code, message, expected_exit in cases:
                with self.subTest(workflow=filename, code=code), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    binary = root / "bin"
                    binary.mkdir()
                    helpers = ["verify_swift_test_output.py"]
                    if filename == "ci.yml":
                        helpers.append("capture_render_review_test_diagnostic.py")
                    (root / "scripts").mkdir()
                    for helper in helpers:
                        (root / "scripts" / helper).write_bytes((ROOT / "scripts" / helper).read_bytes())
                    driver = root / "scripts/run_macos_tests.py"
                    driver.write_text(textwrap.dedent("""\
                        import os
                        from pathlib import Path
                        import sys
                        calls = Path(os.environ["FAKE_SWIFT_CALLS"])
                        count = int(calls.read_text()) if calls.exists() else 0
                        calls.write_text(str(count + 1) + "\\n")
                        Path(os.environ["FAKE_SWIFT_ARGS"]).write_text("\\n".join(sys.argv[1:]) + "\\n")
                        Path(os.environ["FAKE_SWIFT_BACKTRACE"]).write_text(os.environ.get("SWIFT_BACKTRACE", "") + "\\n")
                        print(os.environ["FAKE_SWIFT_MESSAGE"], flush=True)
                        sys.exit(int(os.environ["FAKE_SWIFT_EXIT"]))
                        """))
                    cache = str(root / "dependency cache")
                    runtime = str(root / "runner temp")
                    env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                               NGV_SWIFTPM_CACHE_PATH=cache, RUNNER_TEMP=runtime,
                               FAKE_SWIFT_CALLS=str(root / "calls"),
                               FAKE_SWIFT_ARGS=str(root / "args"),
                               FAKE_SWIFT_BACKTRACE=str(root / "backtrace"),
                               FAKE_SWIFT_EXIT=str(code), FAKE_SWIFT_MESSAGE=message)
                    result = subprocess.run(
                        ["bash", "--noprofile", "--norc", "-c", run], cwd=root, env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, expected_exit, result.stdout)
                    self.assertEqual((root / "calls").read_text(), "1\n")
                    self.assertIn(message, result.stdout)
                    self.assertIn(message, (root / log).read_text())
                    expected = ["--cache-path", cache]
                    expected.extend(value.format(runtime=runtime) for value in configuration)
                    if filename == "release.yml":
                        expected.extend(["--swiftc-flag=-enable-testing", "--evidence", runtime + "/release-test-evidence"])
                    else:
                        expected.extend(["--evidence", runtime + "/render-review-test-diagnostic/hosted-suite"])
                    self.assertEqual((root / "args").read_text().splitlines(), expected)
                    self.assertEqual(
                        (root / "backtrace").read_text(),
                        "enable=yes,interactive=no,demangle=yes,cache=no\n",
                    )

    def test_pricing_selftest_requires_marker_and_successful_app_exit_once(self):
        run = workflow_test_run(
            ROOT / ".github/workflows/ci.yml",
            "Verify generation batch pricing recovery on macOS 26",
        )
        for code, marker, expected in ((0, True, 0), (1, True, 1), (139, True, 139), (0, False, 1)):
            with self.subTest(code=code, marker=marker), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = root / "candidate/NexGenVideo.app/Contents/MacOS/NexGenVideo"
                app.parent.mkdir(parents=True)
                app.write_text(textwrap.dedent("""\
                    #!/bin/bash
                    set -euo pipefail
                    count=0
                    if [ -f "$FAKE_APP_CALLS" ]; then count=$(cat "$FAKE_APP_CALLS"); fi
                    count=$((count + 1))
                    printf '%s\\n' "$count" > "$FAKE_APP_CALLS"
                    printf '%s\\n' "${NGV_SELFTEST_GENERATION_BATCH_RECOVERY:-}" > "$FAKE_APP_GATE"
                    if [ "$FAKE_APP_MARKER" = 1 ]; then
                      printf '%s\\n' SELFTEST_GENERATION_BATCH_RECOVERY_OK
                    fi
                    exit "$FAKE_APP_EXIT"
                    """))
                app.chmod(0o755)
                env = dict(os.environ, FAKE_APP_CALLS=str(root / "calls"),
                           FAKE_APP_GATE=str(root / "gate"), FAKE_APP_MARKER="1" if marker else "0",
                           FAKE_APP_EXIT=str(code))
                result = subprocess.run(
                    ["bash", "--noprofile", "--norc", "-c", run], cwd=root, env=env,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, expected, result.stdout)
                self.assertEqual((root / "calls").read_text(), "1\n")
                self.assertEqual((root / "gate").read_text(), "1\n")


if __name__ == "__main__":
    unittest.main()
