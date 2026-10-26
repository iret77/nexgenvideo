import shutil
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from bpy_bundle_layout import inventory, paired, seal, verify


class BpyBundleLayoutTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name) / "Fixture.app"
        self.roots = [self.app / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc/Contents/Resources/BpyRuntime"
                      for slot in range(2)]
        for root in self.roots:
            (root / "python/bin").mkdir(parents=True)
            binary = root / "python/bin/python3.13"
            binary.write_bytes(b"fixed native fixture")
            binary.chmod(0o755)
            (root / "python/bin/python3").symlink_to("python3.13")

    def test_slot_bytes_modes_and_extra_files_cannot_diverge(self):
        original = paired(self.app)
        target = self.roots[1] / "python/bin/python3.13"
        target.write_bytes(b"different")
        with self.assertRaisesRegex(ValueError, "copies differ"):
            paired(self.app)
        shutil.copy2(self.roots[0] / "python/bin/python3.13", target)
        target.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "copies differ"):
            paired(self.app)
        target.chmod(0o755)
        self.assertEqual(paired(self.app), original)
        (self.roots[1] / "extra.py").write_text("unexpected")
        with self.assertRaisesRegex(ValueError, "copies differ"):
            paired(self.app)

    def test_symlink_to_outer_host_payload_is_rejected(self):
        outer = self.app / "payload"
        outer.write_text("outside the service")
        (self.roots[0] / "escape").symlink_to(outer)
        with self.assertRaisesRegex(ValueError, "escapes"):
            inventory(self.roots[0])

    def test_old_host_runtime_is_not_an_accepted_fallback(self):
        legacy = self.app / "Contents/Resources/BpyRuntime"
        legacy.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "legacy"):
            paired(self.app)

    def test_missing_and_empty_slot_fail(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            inventory(self.app / "missing")
        empty = self.app / "empty"
        empty.mkdir()
        with self.assertRaisesRegex(ValueError, "empty"):
            inventory(empty)

    def test_bundle_ancestor_cannot_redirect_both_slots_outside_app(self):
        services = self.app / "Contents/XPCServices"
        outside = self.app.parent / "outside"
        services.rename(outside)
        services.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "ancestor"):
            paired(self.app)

    def test_enumeration_error_cannot_become_partial_inventory(self):
        def unreadable(root, *, onerror, followlinks):
            onerror(PermissionError("unreadable subtree"))
            return iter(())
        with patch("bpy_bundle_layout.os.walk", side_effect=unreadable):
            with self.assertRaises(PermissionError):
                inventory(self.roots[0])

    def test_resigning_reseals_both_copies_but_verification_rejects_tamper(self):
        compliance = self.app / "Contents/Resources/BpyRuntimeCompliance"
        compliance.mkdir(parents=True)
        seal(self.app)
        verify(self.app)
        seal(self.app)
        verify(self.app)
        for root in self.roots:
            (root / "python/bin/python3.13").write_bytes(b"new signed bytes")
        with self.assertRaisesRegex(ValueError, "sealed inventory"):
            verify(self.app)
        seal(self.app)
        verify(self.app)
        (self.roots[0] / "python/bin/python3.13").write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "copies differ"):
            seal(self.app)

    def test_hidden_runtime_files_participate_in_inventory(self):
        for root in self.roots:
            (root / ".metadata").mkdir()
            (root / ".metadata/source").write_text("identity")
        self.assertIn(".metadata/source", paired(self.app)["entries"])
        (self.roots[1] / ".metadata/source").write_text("changed")
        with self.assertRaisesRegex(ValueError, "copies differ"):
            paired(self.app)
