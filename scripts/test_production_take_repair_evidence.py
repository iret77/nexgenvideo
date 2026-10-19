"""Synthetic parser fixtures; not native or provider evidence."""
import json
from pathlib import Path
import tempfile
import unittest

from production_take_repair_evidence import OPERATIONS, LABELS, POLICY, digest, validate


def encoded(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()


def repair_fixture(directory, native):
    root = Path(directory); rows = native["interactions"]
    def write(name, raw):
        path = root / ("take-repair-evidence/" + name)
        path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(raw)
        return digest(raw)
    def state(label, value):
        rows.append({"kind": "verified-state", "label": label, "evidence": value})
    take_id, shot_id = "a" * 64, "actual-shot"
    take = {"schema": "render-take/v1", "id": take_id, "shotID": shot_id, "phase": "final", "output": {"sha256": "c" * 64}}
    review = {"schema": "take-review/v1", "takeID": take_id, "reviewer": "native-user", "outputSHA256": "c" * 64,
        "findings": [{"pass": "identity", "verdict": "rejected"}]}
    review_path = "renders/takes/reviews/" + take_id + "/current.v1.json"
    actual = {"gates.yaml": b"render: pending\n", "lineage.json": encoded({"actual": "same"}),
        "renders/takes/final/" + take_id + ".v1.json": encoded(take), review_path: encoded(review),
        "renders/takes/index-final.v1.json": encoded({"takeIDs": [take_id], "decisions": []})}
    before = {name: write("before/" + name, raw) for name, raw in actual.items()}
    state("native take repair decisions begin", {"takeID": take_id, "shotID": shot_id, "files": before,
        "providerRequestsBefore": 4, "spendEventsBefore": 1})
    choices = []
    for index, (operation, title) in enumerate(zip(OPERATIONS, LABELS)):
        reason = "Actual native reason for " + operation
        rows.append({"kind": "menu", "id": "take.repair.operation", "closed": True, "item": title})
        if index:
            state("native repair choice pending", {"operation": operation, "continueEnabled": False})
        rows.append({"kind": "text", "field": {"id": "take.repair.reason", "actual": reason, "expected": reason}})
        if index == 0:
            rows.extend({"kind": "text", "field": {"id": "take.repair.rolls", "actual": value, "expected": value}}
                        for value in ("0", "5"))
        rows += [{"kind": "pointer", "id": "take.repair." + action} for action in ("save", "continue")]
        plan = {"schema": "take-repair-plan/v1", "takeID": take_id, "reviewSHA256": before[review_path],
            "operation": operation, "reason": reason, "policy": dict(POLICY), "decidedBy": "native-user", "decidedAt": str(index)}
        raw = encoded(plan); identifier = digest(raw)
        message = {"id": "user-" + operation, "role": "user", "hidden": True,
            "userPresentation": {"typedText": reason, "choiceRecord": {"selections": [
                {"label": "Shot", "values": [shot_id]}, {"label": "Decision", "values": [title]}]}},
            "blocks": [{"kind": "text", "text": "Read get_render_manifest for final. Any generation still needs the existing spend approval."}]}
        turn = [message, {"id": "assistant-" + operation, "role": "assistant",
            "blocks": [{"kind": "text", "text": "Acceptance transport received render."}]}]
        files = {identifier + ".json": write(identifier + ".json", raw), operation + "-current.json": write(operation + "-current.json", raw),
                 operation + "-turn.json": write(operation + "-turn.json", encoded(turn))}
        guard = "paused" if operation in ("stop", "simplifyShot", "rescueRange") else "unchanged-reroll-allowed" if operation == "reroll" else "unchanged-request-rejected"
        item = {"id": identifier, "operation": operation, "reason": reason, "files": files, "unchangedRequestGuard": guard}
        choices.append(item); state("native attributed repair decision", item)
        suffix = "limits" if operation == "stop" else "rescue" if operation == "rescueRange" else operation
        image = "unit-take-repair-" + suffix + ".png"
        (root / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"unit-native-parser-image" * 100)
        native["screenshots"].append(image)
    after = {name: write("after/" + name, raw) for name, raw in actual.items()}
    state("native take repair decisions complete", {"takeID": take_id, "shotID": shot_id, "files": after,
        "providerRequestsBefore": 4, "providerRequestsAfter": 4, "spendEventsBefore": 1, "spendEventsAfter": 1})
    legacy = next((row["evidence"] for row in rows if row.get("label") == "native take repair stop and rescue"), None)
    if legacy is None:
        legacy = {}; state("native take repair stop and rescue", legacy)
    legacy.update(stopSHA256=choices[0]["id"], rescueSHA256=choices[-1]["id"], reviewSHA256=before[review_path],
                  invalidLimitBlocked=True, staleContinuationBlocked=True, actualGenerationGuardBlocked=True)
    return choices


class RepairEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.native = {"interactions": [], "screenshots": []}
        self.choices = repair_fixture(self.root, self.native)

    def check(self):
        return validate(self.native, self.root)

    def edit_turn(self, operation, edit):
        path = self.root / ("take-repair-evidence/" + operation + "-turn.json")
        value = json.loads(path.read_bytes()); edit(value)
        raw = encoded(value); path.write_bytes(raw)
        next(row for row in self.choices if row["operation"] == operation)["files"][operation + "-turn.json"] = digest(raw)

    def test_complete_parser_example(self):
        self.assertTrue(self.check())

    def test_missing_decision(self):
        self.native["interactions"] = [row for row in self.native["interactions"] if not (
            row.get("label") == "native attributed repair decision" and row["evidence"]["operation"] == "changeModel")]
        self.assertFalse(self.check())

    def test_changed_history_bytes(self):
        (self.root / ("take-repair-evidence/" + self.choices[0]["id"] + ".json")).write_bytes(b"changed")
        self.assertFalse(self.check())

    def test_current_does_not_equal_archive(self):
        path = self.root / "take-repair-evidence/reroll-current.json"; path.write_bytes(b"{}")
        self.choices[1]["files"]["reroll-current.json"] = digest(b"{}")
        self.assertFalse(self.check())

    def test_reroll_cannot_stand_for_prompt_change(self):
        self.choices[2]["unchangedRequestGuard"] = "unchanged-reroll-allowed"
        self.assertFalse(self.check())

    def test_structured_action_cannot_become_app_authored_user_prose(self):
        self.edit_turn("changeModel", lambda value: value[0].update(hidden=False))
        self.assertFalse(self.check())

    def test_one_turn_cannot_cover_multiple_native_decisions(self):
        self.edit_turn("changeReference", lambda value: value[0].update(id="user-reroll"))
        self.assertFalse(self.check())

    def test_wrong_structured_choice(self):
        self.edit_turn("changeModel", lambda value: value[0]["userPresentation"]["choiceRecord"]["selections"][1].update(values=["Stop"]))
        self.assertFalse(self.check())

    def test_duplicate_structured_selection_is_rejected(self):
        self.edit_turn("changeModel", lambda value: value[0]["userPresentation"]["choiceRecord"]["selections"].append({"label": "Decision", "values": [LABELS[4]]}))
        self.assertFalse(self.check())

    def test_request_counts_are_strict_integers(self):
        next(row for row in self.native["interactions"] if row.get("label") == "native take repair decisions complete")["evidence"]["spendEventsAfter"] = True
        self.assertFalse(self.check())

    def test_stale_continuation_not_enabled(self):
        next(row for row in self.native["interactions"] if row.get("label") == "native repair choice pending")["evidence"]["continueEnabled"] = True
        self.assertFalse(self.check())

    def test_decisions_cannot_mutate_take_index(self):
        (self.root / "take-repair-evidence/after/renders/takes/index-final.v1.json").write_bytes(b"{}")
        self.assertFalse(self.check())

    def test_native_click_cannot_be_replaced_by_saved_json(self):
        rows = self.native["interactions"]
        rows.pop(next(i for i, row in enumerate(rows) if row.get("id") == "take.repair.save"))
        self.assertFalse(self.check())

    def test_decision_actions_must_be_scoped_and_in_order(self):
        rows = self.native["interactions"]
        save = next(i for i, row in enumerate(rows) if row.get("id") == "take.repair.save")
        continued = next(i for i, row in enumerate(rows) if row.get("id") == "take.repair.continue")
        rows[save], rows[continued] = rows[continued], rows[save]
        self.assertFalse(self.check())
        rows[save], rows[continued] = rows[continued], rows[save]
        pending = next(i for i, row in enumerate(rows) if row.get("label") == "native repair choice pending")
        rows[pending - 1], rows[pending] = rows[pending], rows[pending - 1]
        self.assertFalse(self.check())
        rows[pending - 1], rows[pending] = rows[pending], rows[pending - 1]
        decision = next(i for i, row in enumerate(rows) if row.get("label") == "native attributed repair decision")
        rows.insert(0, rows.pop(decision))
        self.assertFalse(self.check())

    def test_retained_files_and_attribution_cannot_be_substituted(self):
        self.edit_turn("stop", lambda value: value[0]["userPresentation"]["choiceRecord"]["selections"][0].update(values=["wrong-shot"]))
        self.assertFalse(self.check())

    def test_changed_provider_count_and_wrong_reason_are_rejected(self):
        completion = next(row["evidence"] for row in self.native["interactions"] if row.get("label") == "native take repair decisions complete")
        completion["providerRequestsAfter"] += 1
        self.assertFalse(self.check())
        completion["providerRequestsAfter"] -= 1
        field = next(row["field"] for row in self.native["interactions"] if row.get("kind") == "text")
        field["expected"] = "different native reason"
        self.assertFalse(self.check())

    def test_each_retained_source_and_legacy_join_is_required(self):
        folder = self.root / "take-repair-evidence/after"
        for path in folder.rglob("*"):
            if not path.is_file(): continue
            raw = path.read_bytes(); path.write_bytes(b"changed")
            self.assertFalse(self.check(), str(path)); path.write_bytes(raw)
        legacy = next(row["evidence"] for row in self.native["interactions"] if row.get("label") == "native take repair stop and rescue")
        for key in ("stopSHA256", "rescueSHA256", "reviewSHA256"):
            value = legacy[key]; legacy[key] = "0" * 64
            self.assertFalse(self.check(), key); legacy[key] = value
        image = self.root / self.native["screenshots"][0]; image.write_bytes(b"not PNG")
        self.assertFalse(self.check())

    def test_invalid_limit_must_be_entered_before_saving(self):
        rows = self.native["interactions"]
        index = next(i for i, row in enumerate(rows) if row.get("field", {}).get("id") == "take.repair.rolls")
        invalid = rows.pop(index)
        self.assertFalse(self.check())
        rows.insert(index, invalid)
        invalid["field"].update(actual="1", expected="1")
        self.assertFalse(self.check())
        invalid["field"].update(actual="0", expected="0")
        valid = rows.pop(index + 1)
        rows.pop(index)
        after_save = next(i for i, row in enumerate(rows) if row.get("id") == "take.repair.save") + 1
        rows[after_save:after_save] = [invalid, valid]
        self.assertFalse(self.check())

    def test_observed_guard_failures_cannot_claim_success(self):
        legacy = next(row["evidence"] for row in self.native["interactions"]
                      if row.get("label") == "native take repair stop and rescue")
        for key in ("invalidLimitBlocked", "staleContinuationBlocked", "actualGenerationGuardBlocked"):
            with self.subTest(key=key):
                legacy[key] = False
                self.assertFalse(self.check())
                legacy[key] = True

    def test_dispatch_before_first_saved_decision_cannot_reset_baseline(self):
        begin = next(row["evidence"] for row in self.native["interactions"]
                     if row.get("label") == "native take repair decisions begin")
        for key in ("providerRequestsBefore", "spendEventsBefore"):
            with self.subTest(key=key):
                begin[key] -= 1
                self.assertFalse(self.check())
                begin[key] += 1
