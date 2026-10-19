import importlib.util
import json
import tempfile
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
        with self.assertRaisesRegex(ValueError, "official library release linkage changed"):
            MODULE.validate(self.lock)

    def test_missing_transitive_wheel_is_rejected(self):
        self.lock["wheels"] = [wheel for wheel in self.lock["wheels"] if wheel["name"] != "numpy"]
        with self.assertRaisesRegex(ValueError, "wheel closure mismatch"):
            MODULE.validate(self.lock)

    def test_ready_status_cannot_hide_a_blocker(self):
        self.lock["distributionStatus"] = "ready"
        self.lock["distributionBlockers"] = ["Missing test evidence"]
        with self.assertRaisesRegex(ValueError, "cannot retain blockers"):
            MODULE.validate(self.lock)

    def test_ready_status_requires_distribution_closure(self):
        self.lock["distributionStatus"] = "ready"
        self.lock["distributionBlockers"] = []
        self.lock.pop("distributionClosure", None)
        with self.assertRaisesRegex(ValueError, "source archive closure"):
            MODULE.validate(self.lock)

    def test_invalid_candidate_manifest_hash_is_rejected(self):
        self.lock["bpyWheelLayout"]["candidateSourceFamilies"][0]["manifestHash"] = "0"
        with self.assertRaisesRegex(ValueError, "manifest hash"):
            MODULE.validate(self.lock)

    def test_distribution_mode_fails_closed(self):
        self.lock["distributionStatus"] = "blocked-pending-corresponding-source-evidence"
        self.lock["distributionBlockers"] = ["Missing test evidence"]
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "lock.json"
            lock.write_text(json.dumps(self.lock))
            with mock.patch.object(MODULE, "LOCK", lock), mock.patch(
                "sys.argv", ["verify_bpy_runtime.py", "--distribution"]
            ):
                self.assertEqual(MODULE.main(), 2)

    def test_source_closure_plan_is_versioned(self):
        plan = self.lock["sourceClosurePlan"]
        self.assertEqual(plan["schema"], "nexgenvideo/bpy-source-closure-plan/1")
        self.assertEqual(plan["builder"], "scripts/assemble_bpy_source_closure.py")
        self.assertEqual(plan["validator"], "scripts/verify_bpy_source_closure.py")



if __name__ == "__main__":
    unittest.main()
