import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from retained_spatial_evidence import validate
from test_retained_spatial_evidence import fixture, put


class BlockoutRecoveryBindingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        fixture(self.root)

    def edit_events(self, change):
        path = self.root / "native-blockout-plan-result.json"
        entries = json.loads(path.read_bytes())
        change(entries[0]["interactions"])
        put(path, entries)
        for entry in entries:
            put(self.root / entry["progress"], {"interactions": entry["interactions"],
                "screenshots": entry["screenshots"], "failure": None})

    def test_actual_refusals_and_ordered_removal_plan_are_required(self):
        validate(self.root)

    def test_unrelated_failures_cannot_attest_expected_refusal(self):
        for state in ("missing", "tampered"):
            for field in ("staleError", "leaseError"):
                with self.subTest(state=state, field=field):
                    fixture(self.root)
                    path = self.root / "blockout-recovery-100" / (state + "-refusals.json")
                    refusals = json.loads(path.read_bytes())
                    refusals[field] = "The exact pack is unavailable."
                    put(path, refusals)
                    with self.assertRaisesRegex(ValueError, "actual stale snapshot and competing mutation lease"):
                        validate(self.root)

    def test_plan_click_is_required_after_single_removal(self):
        def change(actions):
            plan = next(action for action in actions if action.get("id") == "shot.blockout.plan")
            actions.remove(plan)
        self.edit_events(change)
        with self.assertRaisesRegex(ValueError, "single removal must precede"):
            validate(self.root)

    def test_earlier_unrelated_plan_cannot_attest_reattachment(self):
        def change(actions):
            plan = next(action for action in actions if action.get("id") == "shot.blockout.plan")
            actions.remove(plan)
            actions.insert(0, plan)
        self.edit_events(change)
        with self.assertRaisesRegex(ValueError, "single removal must precede"):
            validate(self.root)

    def test_single_removal_cannot_be_from_before_tampered_recovery(self):
        def change(actions):
            single = next(action for action in actions if action.get("id") == "shot.blockout.remove")
            actions.remove(single)
            actions.insert(0, single)
        self.edit_events(change)
        with self.assertRaisesRegex(ValueError, "single removal must precede"):
            validate(self.root)

    def test_plan_before_remove_or_after_completion_is_rejected(self):
        for where in ("before-remove", "after-record"):
            with self.subTest(where=where):
                fixture(self.root)
                def change(actions):
                    plan = next(action for action in actions if action.get("id") == "shot.blockout.plan")
                    actions.remove(plan)
                    position = next(index for index, action in enumerate(actions) if action.get("id") == "shot.blockout.remove") if where == "before-remove" else len(actions)
                    actions.insert(position, plan)
                self.edit_events(change)
                with self.assertRaisesRegex(ValueError, "single removal must precede"):
                    validate(self.root)

    def test_legacy_foreign_process_claim_does_not_replace_competing_lease(self):
        def change(actions):
            value = next(action["evidence"] for action in actions if action.get("label") == "native blockout recovery")
            value["foreignLeaseRejected"] = value.pop("competingLeaseRejected")
        self.edit_events(change)
        with self.assertRaisesRegex(ValueError, "competingLeaseRejected"):
            validate(self.root)


if __name__ == "__main__":
    unittest.main()
