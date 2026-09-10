import base64
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from update_release_metadata import INFO_PATH, update_release_metadata
from verify_ci_release_metadata import verify_metadata


class CIReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(os.chdir, self.previous)
        self.git("init", "-q")
        self.git("config", "user.name", "CI fixture")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "core.filemode", "true")
        INFO_PATH.parent.mkdir(parents=True)
        INFO_PATH.write_bytes(plistlib.dumps(dict(CFBundleShortVersionString="1.0.0", CFBundleVersion="1", LSMinimumSystemVersion="26.0")))
        Path("appcast.xml").write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n    <channel>\n    </channel>\n</rss>\n')
        self.update("1.0.0", "1")
        Path("source.swift").write_text("original source\n")
        self.source = self.commit()
        self.transaction = dict(schema="release-publication/3", source_sha=self.source, version="1.1.0",
                                build_number="2", dmg_length="1234", ed_signature=base64.b64encode(b"s" * 64).decode(), tag="v1.1.0")
        self.update("1.1.0", "2")

    def git(self, *args):
        return subprocess.check_output(["git", *args], stderr=subprocess.PIPE).decode().strip()

    def update(self, version, build):
        with patch("update_appcast.formatdate", return_value="Thu, 10 Sep 2026 12:00:00 -0000"):
            update_release_metadata(version, build, "1234", base64.b64encode(b"s" * 64).decode(), f"v{version}")

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def verify(self):
        return verify_metadata(self.transaction, "1.1.0", self.commit())

    def test_exact_generated_metadata_skips_compilation(self):
        before = (INFO_PATH.read_bytes(), Path("appcast.xml").read_bytes())
        self.assertTrue(self.verify())
        self.assertEqual(before, (INFO_PATH.read_bytes(), Path("appcast.xml").read_bytes()))

    def test_new_source_since_release_requires_full_ci(self):
        Path("source.swift").write_text("new source\n")
        self.assertFalse(self.verify())

    def test_plist_configuration_change_cannot_use_shortcut(self):
        INFO_PATH.write_text(INFO_PATH.read_text().replace("26.0", "27.0"))
        with self.assertRaisesRegex(ValueError, "Info.plist"):
            self.verify()

    def test_changed_old_appcast_entry_cannot_use_shortcut(self):
        path = Path("appcast.xml")
        path.write_text(path.read_text().replace("Version 1.0.0", "Changed older release"))
        with self.assertRaisesRegex(ValueError, "appcast differs"):
            self.verify()

    def test_wrong_download_signature_cannot_use_shortcut(self):
        self.transaction["ed_signature"] = base64.b64encode(b"x" * 64).decode()
        with self.assertRaisesRegex(ValueError, "appcast differs"):
            self.verify()

    def test_extra_enclosure_attributes_are_rejected(self):
        path = Path("appcast.xml")
        path.write_text(path.read_text().replace('length="1234"', 'length="1234" unsafe="true"'))
        with self.assertRaises(ValueError):
            self.verify()

    def test_mode_changes_require_full_ci(self):
        INFO_PATH.chmod(0o755)
        self.assertFalse(self.verify())

    def test_symlinks_require_full_ci(self):
        INFO_PATH.unlink()
        INFO_PATH.symlink_to("AppResources.txt")
        self.assertFalse(self.verify())

    def test_deleted_source_requires_full_ci(self):
        Path("source.swift").unlink()
        self.assertFalse(self.verify())

    def test_wrong_version_is_rejected(self):
        self.transaction["version"] = "9.0.0"
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
