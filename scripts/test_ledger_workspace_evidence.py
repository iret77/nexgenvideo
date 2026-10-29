import copy
import json
from pathlib import Path
import tempfile
import unittest

from test_ledger_attribute_owner_evidence import ledger_fixture
from workspace_ui_acceptance import ledger_owner_evidence


class LedgerWorkspaceEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.name = "scale-125-ledger"
        self.directory = self.root / self.name
        ledger_fixture(self.directory, scale=1.25)
        result = json.loads((self.directory / "ledger-owner-result.json").read_text())
        self.rows = [
            {"event": "started", "case": "ledger", "scale": 1.25, "restorationIgnored": True},
            {**result, "event": "ledger-owner", "evidenceDirectory": self.name},
            {"event": "completed", "case": "ledger", "scale": 1.25},
        ]

    def test_full_native_evidence_is_required_at_the_requested_scale(self):
        accepted, images = ledger_owner_evidence(self.rows, self.root, 1.25)
        self.assertTrue(accepted)
        self.assertEqual(images, [
            self.name + "/native.png",
            self.name + "/native-ledger-busy-waiting.png",
            self.name + "/native-ledger-busy-agent-stop.png",
        ])
        self.assertFalse(ledger_owner_evidence(self.rows, self.root, 1)[0])

    def test_incomplete_duplicate_and_failed_runs_are_rejected(self):
        for rows in (self.rows[:-1], self.rows[1:], self.rows + [self.rows[1]],
                     self.rows + [{"event": "failed", "case": "ledger"}]):
            with self.subTest(rows=rows):
                self.assertFalse(ledger_owner_evidence(rows, self.root, 1.25)[0])

    def test_report_cannot_replace_actual_native_or_canonical_evidence(self):
        wrong = copy.deepcopy(self.rows)
        wrong[1]["nativeUndoRedo"] = False
        self.assertFalse(ledger_owner_evidence(wrong, self.root, 1.25)[0])
        (self.directory / "ledger-edit.yaml").write_bytes(b"altered canonical ledger")
        self.assertFalse(ledger_owner_evidence(self.rows, self.root, 1.25)[0])


if __name__ == "__main__":
    unittest.main()
