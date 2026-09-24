import importlib.util
import json
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verify_bpy_runtime", ROOT / "scripts/verify_bpy_runtime.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BpyRuntimeLockTests(unittest.TestCase):
    def setUp(self):
        self.lock = json.loads(MODULE.LOCK.read_text())

    def test_committed_lock_is_complete(self):
        MODULE.validate(self.lock)

    def test_bpy_hash_drift_is_rejected(self):
        bpy = next(item for item in self.lock["wheels"] if item["name"] == "bpy")
        bpy["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "bpy version/hash drift"):
            MODULE.validate(self.lock)

    def test_missing_transitive_wheel_is_rejected(self):
        self.lock["wheels"] = self.lock["wheels"][:-1]
        with self.assertRaisesRegex(ValueError, "wheel closure mismatch"):
            MODULE.validate(self.lock)

    def test_ready_status_cannot_hide_a_blocker(self):
        self.lock["distributionStatus"] = "ready"
        with self.assertRaisesRegex(ValueError, "cannot retain blockers"):
            MODULE.validate(self.lock)

    def test_distribution_mode_fails_closed(self):
        with mock.patch.object(MODULE, "LOCK", MODULE.LOCK), mock.patch(
            "sys.argv", ["verify_bpy_runtime.py", "--distribution"]
        ):
            self.assertEqual(MODULE.main(), 2)


if __name__ == "__main__":
    unittest.main()
