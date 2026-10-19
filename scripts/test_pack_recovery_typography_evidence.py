import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from pack_recovery_owner_acceptance import require_composer_typography, require_saved_draft, require_session_edit


class RecoveryTypographyEvidenceTests(unittest.TestCase):
    def fixture(self, scale):
        return {"interactions": [
            {"kind": "pointer", "id": "agent.task.choose", "window": 21},
            {"kind": "menu", "id": "agent.task.choose", "item": "Apply a project change", "closed": True},
            {"kind": "pointer", "id": "agent.composer.input", "window": 21},
            {"kind": "keyboard", "code": 125, "characters": "\uf701", "modifiers": 1 << 20, "window": 21},
            {"kind": "keyboard", "code": 15, "characters": "R", "modifiers": 0, "window": 21},
            {"kind": "verified-state", "label": "native Recovery composer input", "evidence": {
                "id": "agent.composer.input", "before": "Synthetic draft", "after": "Synthetic draftR", "added": "R",
                "task": "Apply a project change", "controlKind": "text-view", "window": 21}},
            {"kind": "verified-state", "label": "rendered typography", "evidence": {
                "id": "agent.composer.input", "pointSize": 13 * scale, "baseSize": 13, "scale": scale,
                "controlKind": "text-view", "window": 21}},
            {"kind": "verified-state", "label": "viewport", "evidence": {"renderedFontPointSize": 13 * scale}},
        ]}

    def test_synthetic_record_requires_every_ordered_native_step(self):
        for scale in (1, 1.25, 1.5):
            record = self.fixture(scale)
            require_composer_typography(record, "viewport", scale)
            for index in range(len(record["interactions"])):
                changed = copy.deepcopy(record)
                changed["interactions"].pop(index)
                with self.subTest(scale=scale, missing=index), self.assertRaises(AssertionError):
                    require_composer_typography(changed, "viewport", scale)
            starter = self.fixture(scale)
            starter["interactions"][:2] = [{"kind": "verified-state", "label": "native-pointer", "evidence": {
                "target": "button.Apply a project change", "window": 21}}]
            require_composer_typography(starter, "viewport", scale)
            starter["interactions"][0]["evidence"]["window"] = 22
            with self.assertRaises(AssertionError):
                require_composer_typography(starter, "viewport", scale)

    def test_forged_font_window_text_and_keyboard_cannot_replace_native_input(self):
        for defect in ("foreign-window", "wrong-text", "field-editor", "wrong-size", "non-number", "no-command", "wrong-order", "wrong-task", "wrong-task-window"):
            record = self.fixture(1.25)
            rows = record["interactions"]
            if defect == "foreign-window": rows[3]["window"] = 22
            elif defect == "wrong-text": rows[5]["evidence"]["after"] = "R"
            elif defect == "field-editor": rows[6]["evidence"]["controlKind"] = "text-field"
            elif defect == "wrong-size": rows[6]["evidence"]["pointSize"] = 13
            elif defect == "non-number": rows[6]["evidence"]["pointSize"] = "sixteen"
            elif defect == "no-command": rows[3]["modifiers"] = 0
            elif defect == "wrong-task": rows[1]["item"] = "Generate an AI video"
            elif defect == "wrong-task-window": rows[0]["window"] = 22
            else: rows[4], rows[6] = rows[6], rows[4]
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                require_composer_typography(record, "viewport", 1.25)

    def test_saved_draft_and_later_native_session_edit_keep_migration_bytes_bound(self):
        identifier = "2564BA87-9222-4B5E-BA40-000000000001"
        relative = "chat/" + identifier + ".json"
        session = {"id": identifier, "updatedAt": "2026-01-01T00:00:00Z", "messages": [], "isOpen": True,
                   "draft": {"text": "Synthetic draftR", "mentions": [], "task": {
                       "title": "Apply a project change", "prompt": "Synthetic staged task", "originContext": "before"}}}
        with TemporaryDirectory() as directory:
            output = Path(directory); saved = output / "saved"; recovery = output / "recovery"
            (saved / "chat").mkdir(parents=True); (recovery / "chat").mkdir(parents=True)
            raw = json.dumps(session).encode(); (saved / relative).write_bytes(raw)
            before = self.fixture(1)
            before["interactions"] += [
                {"kind": "verified-state", "label": "application-menu", "evidence": {"path": ["File", "Save"], "window": 21}},
                {"kind": "verified-state", "label": "native Recovery draft saved", "evidence": {
                    "sessionID": identifier, "draft": "Synthetic draftR", "wasEdited": True, "isEdited": False, "window": 21}}]
            self.assertEqual(require_saved_draft(before, saved), identifier)
            missing_save = copy.deepcopy(before); missing_save["interactions"].pop(-2)
            with self.assertRaisesRegex(AssertionError, "native Save"):
                require_saved_draft(missing_save, saved)
            originals = [{"path": relative, "sha256": hashlib.sha256(raw).hexdigest()}]
            (output / "pack-recovery-session-before-input.json").write_bytes(raw)
            for defect in (None, "restored-bytes", "unrelated-message", "wrong-draft", "wrong-current-file"):
                edited = copy.deepcopy(session); edited["updatedAt"] = "2026-01-01T00:00:01Z"
                edited["draft"]["text"] += "R"; edited["draft"]["task"]["originContext"] = "after"
                if defect == "unrelated-message": edited["messages"] = [{"role": "assistant", "content": "Unexpected"}]
                if defect == "wrong-draft": edited["draft"]["text"] = "Not the native edit"
                changed = json.dumps(edited).encode()
                (output / "pack-recovery-session-after-input.json").write_bytes(changed)
                (recovery / relative).write_bytes(b"{}" if defect == "wrong-current-file" else changed)
                after = self.fixture(1)
                after["interactions"][5]["evidence"].update(before="Synthetic draftR", after="Synthetic draftRR")
                after["interactions"].append({"kind": "verified-state", "label": "native Recovery session edit", "evidence": {
                    "sessionID": identifier, "path": relative, "beforeSHA256": hashlib.sha256(raw).hexdigest(),
                    "afterSHA256": hashlib.sha256(changed).hexdigest()}})
                references = [{"path": relative, "sha256": "0" * 64}] if defect == "restored-bytes" else originals
                with self.subTest(defect=defect):
                    if defect is None:
                        self.assertEqual(require_session_edit(after, output, recovery, references, identifier), relative)
                    else:
                        with self.assertRaises(AssertionError):
                            require_session_edit(after, output, recovery, references, identifier)
