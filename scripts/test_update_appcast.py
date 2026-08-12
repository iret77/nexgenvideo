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
                [sys.executable, str(SCRIPT), "2.0.0", "80", "123", "signature", "v2.0.0"],
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
                [sys.executable, str(SCRIPT), "2.0.0", "80", "123", "signature", "v2.0.0"],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("LSMinimumSystemVersion must be a non-empty string", result.stderr)


if __name__ == "__main__":
    unittest.main()
