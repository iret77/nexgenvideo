import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release.yml"
BUNDLE = ROOT / "scripts/bundle.sh"
ASSEMBLE_PACK = ROOT / "scripts/assemble_ngvpack.sh"


def named_release_steps(text):
    release = text[text.index("\n  release:\n") + 1 :]
    steps = release[release.index("    steps:\n") + len("    steps:\n") :]
    chunks = re.split(r"(?m)^      - ", steps)[1:]
    result = []
    for chunk in chunks:
        match = re.match(r"name: ([^\n]+)", chunk)
        if match:
            result.append((match.group(1), chunk))
    return result


def single_line_run(step):
    match = re.search(r"(?m)^        run: ([^|][^\n]*)$", step)
    if not match:
        raise AssertionError("expected one active single-line run command")
    return match.group(1)


def matching_shell_lines(step, prefix):
    return [line.strip() for line in step.splitlines() if line.strip().startswith(prefix)]


class ReleaseWorkflowTests(unittest.TestCase):
    def test_staged_release_tests_share_the_testable_build_configuration(self):
        text = WORKFLOW.read_text()
        steps = named_release_steps(text)
        names = [name for name, _ in steps]
        by_name = dict(steps)

        build_name = "Build the exact release test configuration"
        stage_name = "Stage release test runtime inputs"
        test_name = "Test the exact release configuration"
        bundle_name = "Build and sign app"
        pack_name = "Assemble format packs (.ngvpack + catalog entry)"
        build = 'swift build -c release --scratch-path "$RUNNER_TEMP/release-tests" --build-tests -Xswiftc -enable-testing'
        stage = 'scripts/stage_test_runtime.sh release "$RUNNER_TEMP/release-tests"'
        test = (
            'swift test -c release --scratch-path "$RUNNER_TEMP/release-tests" '
            '--skip-build -Xswiftc -enable-testing 2>&1 | tee '
            '"release-test-attempt-$i.log"'
        )
        bundle = "scripts/bundle.sh release --sign"
        pack = 'scripts/assemble_ngvpack.sh plugins/musicvideo.json release .build/plugins "${SIGN_IDENTITY:-}"'

        for name in (build_name, stage_name, test_name, bundle_name, pack_name):
            self.assertEqual(names.count(name), 1)
            self.assertNotRegex(by_name[name], r"(?m)^        if:")
            self.assertNotRegex(by_name[name], r"(?m)^        continue-on-error:")
        self.assertEqual(single_line_run(by_name[build_name]), build)
        self.assertEqual(single_line_run(by_name[stage_name]), stage)
        self.assertEqual(matching_shell_lines(by_name[test_name], "swift test "), [test])
        self.assertEqual(single_line_run(by_name[bundle_name]), bundle)
        self.assertEqual(
            matching_shell_lines(by_name[pack_name], "scripts/assemble_ngvpack.sh "),
            [pack],
        )
        self.assertLess(names.index(build_name), names.index(stage_name))
        self.assertLess(names.index(stage_name), names.index(test_name))
        self.assertLess(names.index(test_name), names.index(bundle_name))
        self.assertLess(names.index(bundle_name), names.index(pack_name))
        self.assertNotIn("-enable-testing", BUNDLE.read_text())
        self.assertNotIn("--scratch-path", BUNDLE.read_text())
        self.assertNotIn("-enable-testing", ASSEMBLE_PACK.read_text())
        self.assertNotIn("--scratch-path", ASSEMBLE_PACK.read_text())
        self.assertNotIn("$RUNNER_TEMP", by_name[pack_name])

    def test_all_notary_submissions_use_the_retrying_helper(self):
        workflow = WORKFLOW.read_text()
        bundle = BUNDLE.read_text()

        self.assertNotIn("notarytool submit", workflow)
        self.assertNotIn("notarytool submit", bundle)
        self.assertEqual(workflow.count('scripts/notarize.sh "$PACK_ZIP"'), 1)
        self.assertEqual(bundle.count('"$ROOT/scripts/notarize.sh"'), 2)


if __name__ == "__main__":
    unittest.main()
