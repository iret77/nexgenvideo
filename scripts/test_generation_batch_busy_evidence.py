import copy
import json
from pathlib import Path
import tempfile
import unittest

from generation_batch_busy_evidence import validate
from test_production_frames_owner_evidence import fixture


class BatchBusyEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.native = fixture(self.root)["nativeEvidence"]

    def test_exact_queued_bytes_and_native_continuation_are_required(self):
        self.assertTrue(validate(self.native, self.root))
        path = self.root / "batch-busy-evidence/journal-paused.json"
        changed = json.loads(path.read_bytes())
        changed["executions"][0]["state"] = "blocked"
        path.write_text(json.dumps(changed))
        self.assertFalse(validate(self.native, self.root))

    def test_status_flags_do_not_replace_native_click(self):
        changed = copy.deepcopy(self.native)
        changed["interactions"][:] = [row for row in changed["interactions"]
                                      if row.get("id") != "generation-batch.continue.batch"]
        self.assertFalse(validate(changed, self.root))

    def test_duplicate_submission_or_changed_output_is_rejected(self):
        path = self.root / "batch-busy-evidence/requests.json"
        requests = json.loads(path.read_bytes())
        path.write_text(json.dumps(requests + requests))
        self.assertFalse(validate(self.native, self.root))
        path.write_text(json.dumps(requests))
        complete = self.root / "batch-busy-evidence/journal-complete.json"
        journal = json.loads(complete.read_bytes())
        journal["executions"][0]["outputAssetIDs"] = ["different-output"]
        complete.write_text(json.dumps(journal))
        self.assertFalse(validate(self.native, self.root))

    def test_requests_or_enabled_button_during_busy_phase_are_rejected(self):
        for key, value in [("requestCountBeforeContinue", 1), ("continueEnabledWhileBusy", True),
                           ("continueEnabledWhenIdle", False), ("spendEventCountPaused", 1)]:
            changed = copy.deepcopy(self.native)
            evidence = next(row["evidence"] for row in changed["interactions"]
                            if row.get("label") == "approved batch paused by competing host lease")
            evidence[key] = value
            self.assertFalse(validate(changed, self.root))


if __name__ == "__main__":
    unittest.main()
