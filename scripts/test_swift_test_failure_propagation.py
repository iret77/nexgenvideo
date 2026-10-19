import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


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


class SwiftTestFailurePropagationTests(unittest.TestCase):
    def test_first_swift_result_is_final_in_both_workflows(self):
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
            for code, message in (
                (139, "error: Exited with unexpected signal code 11"),
                (0, "All tests passed"),
                (1, "Test Suite failed"),
            ):
                with self.subTest(workflow=filename, code=code), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    binary = root / "bin"
                    binary.mkdir()
                    swift = binary / "swift"
                    swift.write_text(textwrap.dedent("""\
                        #!/bin/bash
                        set -euo pipefail
                        count=0
                        if [ -f "$FAKE_SWIFT_CALLS" ]; then count=$(cat "$FAKE_SWIFT_CALLS"); fi
                        count=$((count + 1))
                        printf '%s\\n' "$count" > "$FAKE_SWIFT_CALLS"
                        printf '%s\\n' "$@" > "$FAKE_SWIFT_ARGS"
                        printf '%s\\n' "${SWIFT_BACKTRACE:-}" > "$FAKE_SWIFT_BACKTRACE"
                        if [ "$count" -eq 1 ]; then
                          echo "$FAKE_SWIFT_MESSAGE" >&2
                          exit "$FAKE_SWIFT_EXIT"
                        fi
                        exit 0
                        """))
                    swift.chmod(0o755)
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
                    self.assertEqual(result.returncode, code, result.stdout)
                    self.assertEqual((root / "calls").read_text(), "1\n")
                    self.assertIn(message, result.stdout)
                    self.assertIn(message, (root / log).read_text())
                    expected = ["test", "--cache-path", cache]
                    expected.extend(value.format(runtime=runtime) for value in configuration)
                    expected.append("--skip-build")
                    if filename == "release.yml":
                        expected.extend(["-Xswiftc", "-enable-testing"])
                    self.assertEqual((root / "args").read_text().splitlines(), expected)
                    self.assertEqual(
                        (root / "backtrace").read_text(),
                        "enable=yes,interactive=no,demangle=yes,cache=no\n",
                    )


if __name__ == "__main__":
    unittest.main()
