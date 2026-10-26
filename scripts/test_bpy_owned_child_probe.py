from copy import deepcopy
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import run_bpy_owned_child_probe as probe


def completed_cases():
    records = []
    for iteration in range(3):
        for mode in range(4):
            records.extend([{"stage": "case-result", "mode": mode, "iteration": iteration, "error": 0,
                             "exitStatus": 143 if mode == 0 else 137, "terminationSignal": 15 if mode == 0 else 9},
                            {"stage": "destroy", "error": 0}])
            if mode == 3:
                records.append({"stage": "stopped-owned", "pid": 100 + iteration, "waitPID": 100 + iteration,
                                "result": 0, "pollError": 0, "running": 1,
                                "waitCode": os.CLD_STOPPED, "waitStatus": signal.SIGSTOP})
    return records + [{"stage": "complete", "cases": 12}]


class OwnedChildProbeCompletionTests(unittest.TestCase):
    def finish(self, records=None, status=None, kill_error=None, wait_error=None, inventory_error=None,
               processes="PID PPID PGID STAT %CPU ELAPSED COMM\n1 0 1 Ss 0.0 00:10 /sbin/launchd\n"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = completed_cases() if records is None else records
            (root / "events.jsonl").write_text("\n".join(json.dumps(item) for item in records))
            (root / "after-processes.log").write_text(processes)
            receipt = {"timedOut": False, "completed": False,
                       "kernelExit": {"code": os.CLD_EXITED, "status": 0} if status is None else status}
            process = SimpleNamespace(pid=500, wait=Mock(return_value=0, side_effect=wait_error))
            with patch.object(probe.os, "killpg", side_effect=kill_error) as kill, \
                    patch.object(probe, "inventory", return_value=[{"exitCode": 0}], side_effect=inventory_error) as inventory:
                probe.finish_process(process, receipt, root, root / "receipt.json")
            persisted = json.loads((root / "receipt.json").read_text())
            self.assertEqual(persisted, receipt)
            process.wait.assert_called_once_with(timeout=5)
            inventory.assert_called_once_with(root, "after")
            return receipt, kill

    def test_completed_children_and_normal_exit_are_reaped_without_group_signal(self):
        receipt, kill = self.finish()
        kill.assert_not_called()
        self.assertEqual(receipt["ownedGroupCleanup"], "controlled-children-reaped")
        self.assertTrue(receipt["ownedGroupEmpty"])
        self.assertTrue(probe.completed(receipt, True))
        self.assertEqual(receipt["exitCode"], 0)
        self.assertIn("after", receipt)

    def test_incomplete_case_evidence_requires_owned_group_cleanup(self):
        _, kill = self.finish(records=completed_cases()[:-1])
        kill.assert_called_once_with(500, signal.SIGKILL)

    def test_nonzero_or_nonterminal_observation_cannot_skip_cleanup(self):
        for status in ({"code": os.CLD_EXITED, "status": 1}, {"code": os.CLD_STOPPED, "status": signal.SIGSTOP}):
            with self.subTest(status=status):
                _, kill = self.finish(status=status)
                kill.assert_called_once_with(500, signal.SIGKILL)

    def test_permission_error_still_reaps_and_records_inventory(self):
        receipt, _ = self.finish(records=[], kill_error=PermissionError(1, "denied"))
        self.assertEqual(receipt["cleanupError"]["errno"], 1)
        self.assertEqual(receipt["exitCode"], 0)
        self.assertIn("after", receipt)
        self.assertFalse(receipt["completed"])

    def test_reap_timeout_preserves_receipt_and_inventory(self):
        receipt, _ = self.finish(records=[], wait_error=subprocess.TimeoutExpired("owned", 5))
        self.assertEqual(receipt["reapError"], "TimeoutExpired")
        self.assertNotIn("exitCode", receipt)
        self.assertIn("after", receipt)

    def test_inventory_failure_preserves_exit_and_error(self):
        receipt, _ = self.finish(inventory_error=OSError("inventory unavailable"))
        self.assertEqual(receipt["exitCode"], 0)
        self.assertIn("inventoryError", receipt)
        self.assertNotIn("after", receipt)

    def test_owned_group_residue_is_signalled_and_fails(self):
        receipt, kill = self.finish(processes="PID PPID PGID STAT %CPU ELAPSED COMM\n501 1 500 S 0.0 00:01 child\n")
        kill.assert_called_once_with(500, signal.SIGKILL)
        self.assertFalse(receipt["ownedGroupEmpty"])
        self.assertIn("groupResidueError", receipt)
        self.assertFalse(probe.completed(receipt, True))

    def test_reused_leader_pid_after_successful_reap_is_never_signalled(self):
        for rows in ("500 1 500 S 0.0 00:01 foreign\n",
                     "500 1 500 S 0.0 00:01 foreign\n501 500 500 S 0.0 00:01 foreign-child\n"):
            receipt, kill = self.finish(processes="PID PPID PGID STAT %CPU ELAPSED COMM\n" + rows)
            kill.assert_not_called()
            self.assertEqual(receipt["ownedGroupCleanup"], "refused-reused-leader")
            self.assertFalse(probe.completed(receipt, True))

    def test_unreaped_owned_leader_remains_eligible_for_cleanup(self):
        receipt, kill = self.finish(wait_error=subprocess.TimeoutExpired("owned", 5),
            processes="PID PPID PGID STAT %CPU ELAPSED COMM\n500 1 500 S 0.0 00:01 probe\n")
        kill.assert_called_once_with(500, signal.SIGKILL)
        self.assertFalse(probe.completed(receipt, True))

    def test_unparseable_inventory_cannot_prove_completion(self):
        for text in ("", "ps: failed\n", "PID PPID PGID STAT %CPU ELAPSED COMM\nbroken row\n",
                     "PID PPID PGID STAT %CPU ELAPSED COMM\n500 1 unknown S 0.0 00:01 probe\n"):
            with self.subTest(text=text):
                receipt, _ = self.finish(processes=text)
                self.assertIn("inventoryError", receipt)
                self.assertFalse(probe.completed(receipt, True))

    def test_each_completion_error_or_missing_proof_is_fatal(self):
        original = {"ownedGroupEmpty": True, "after": [], "timedOut": False, "exitCode": 0}
        self.assertTrue(probe.completed(original, True))
        for key in ("cleanupError", "reapError", "inventoryError", "caseEvidenceError", "groupResidueError"):
            with self.subTest(key=key):
                self.assertFalse(probe.completed(dict(original, **{key: "failure"}), True))
        for key, value in (("ownedGroupEmpty", False), ("timedOut", True), ("exitCode", 1)):
            with self.subTest(key=key):
                self.assertFalse(probe.completed(dict(original, **{key: value}), True))
        self.assertFalse(probe.completed(original, False))
        for key in ("ownedGroupEmpty", "after", "exitCode"):
            changed = dict(original)
            del changed[key]
            self.assertFalse(probe.completed(changed, True))

    def test_every_case_exit_destroy_and_stopped_identity_is_required(self):
        original = completed_cases()
        self.assertTrue(probe.cases_complete(original))
        for index, item in enumerate(original):
            keys = ({"case-result": ("error", "mode", "iteration", "exitStatus", "terminationSignal"),
                     "destroy": ("error",), "stopped-owned": ("result", "pollError", "pid", "running", "waitPID", "waitCode", "waitStatus"),
                     "complete": ("cases",)})[item["stage"]]
            for key in keys:
                with self.subTest(index=index, key=key):
                    changed = deepcopy(original)
                    changed[index][key] = -1
                    self.assertFalse(probe.cases_complete(changed))
        self.assertFalse(probe.cases_complete(original + [original[0]]))
        self.assertFalse(probe.cases_complete([None]))


if __name__ == "__main__":
    unittest.main()
