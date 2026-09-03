import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("update_appcast.py")


class UpdateAppcastTests(unittest.TestCase):
    def test_uses_shipping_minimum_system_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info = root / "Sources/NexGenVideo/Resources/Info.plist"
            info.parent.mkdir(parents=True)
            with info.open("wb") as handle:
                plistlib.dump({"LSMinimumSystemVersion": "27.0"}, handle)
            (root / "appcast.xml").write_text("<channel>\n    </channel>\n")

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "1.1.1", "80", "123", "signature", "v1.1.1"],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            appcast = (root / "appcast.xml").read_text()
            self.assertIn(
                "<sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>",
                appcast,
            )

    def test_rejects_missing_shipping_minimum_system_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info = root / "Sources/NexGenVideo/Resources/Info.plist"
            info.parent.mkdir(parents=True)
            with info.open("wb") as handle:
                plistlib.dump({}, handle)
            (root / "appcast.xml").write_text("<channel>\n    </channel>\n")

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "1.1.1", "80", "123", "signature", "v1.1.1"],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("LSMinimumSystemVersion must be a non-empty string", result.stderr)

    def test_accepts_an_identical_existing_entry_without_duplicating_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info = root / "Sources/NexGenVideo/Resources/Info.plist"
            info.parent.mkdir(parents=True)
            with info.open("wb") as handle:
                plistlib.dump({"LSMinimumSystemVersion": "26.0"}, handle)
            (root / "appcast.xml").write_text(
                '<?xml version="1.0"?>\n'
                '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
                "  <channel>\n"
                "    </channel>\n"
                "</rss>\n"
            )
            command = [
                sys.executable,
                str(SCRIPT),
                "1.5.0",
                "88",
                "123",
                "signature",
                "v1.5.0",
            ]

            first = subprocess.run(
                command, cwd=root, capture_output=True, text=True, check=False
            )
            after_first = (root / "appcast.xml").read_text()
            second = subprocess.run(
                command, cwd=root, capture_output=True, text=True, check=False
            )

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual((root / "appcast.xml").read_text(), after_first)
            self.assertEqual(after_first.count("<item>"), 1)


if __name__ == "__main__":
    unittest.main()
