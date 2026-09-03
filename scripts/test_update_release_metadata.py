import base64
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("update_release_metadata.py")
SIGNATURE = base64.b64encode(b"x" * 64).decode()


class UpdateReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        info = self.root / "Sources/NexGenVideo/Resources/Info.plist"
        info.parent.mkdir(parents=True)
        with info.open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleShortVersionString": "1.4.0",
                    "CFBundleVersion": "87",
                    "LSMinimumSystemVersion": "26.0",
                },
                handle,
            )
        (self.root / "appcast.xml").write_text(
            '<?xml version="1.0"?>\n'
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            "  <channel>\n"
            "    </channel>\n"
            "</rss>\n"
        )

    def tearDown(self):
        self.directory.cleanup()

    def run_script(self, *extra):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "1.5.0",
                "88",
                "1234",
                SIGNATURE,
                "v1.5.0",
                *extra,
            ],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_updates_and_then_validates_metadata_idempotently(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        appcast_after_first = (self.root / "appcast.xml").read_text()

        second = self.run_script()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(
            (self.root / "appcast.xml").read_text(), appcast_after_first
        )
        checked = self.run_script("--check")
        self.assertEqual(checked.returncode, 0, checked.stderr)

        with (self.root / "Sources/NexGenVideo/Resources/Info.plist").open(
            "rb"
        ) as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["CFBundleShortVersionString"], "1.5.0")
        self.assertEqual(info["CFBundleVersion"], "88")
        self.assertEqual(appcast_after_first.count("<item>"), 1)

    def test_check_rejects_missing_metadata_without_writing(self):
        before = (self.root / "appcast.xml").read_text()
        result = self.run_script("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "appcast.xml").read_text(), before)

    def test_existing_version_with_different_signature_fails_closed(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        appcast = self.root / "appcast.xml"
        appcast.write_text(appcast.read_text().replace(SIGNATURE, "different"))

        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mismatched", result.stderr)

    def test_rejects_tag_that_does_not_match_version(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "1.5.0",
                "88",
                "1234",
                SIGNATURE,
                "v1.5.1",
            ],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tag must be v1.5.0", result.stderr)

    def test_rejects_invalid_eddsa_signature(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "1.5.0",
                "88",
                "1234",
                "not-base64",
                "v1.5.0",
            ],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("valid base64", result.stderr)


if __name__ == "__main__":
    unittest.main()
