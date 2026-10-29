import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from ledger_attribute_owner_evidence import validate


def put(path, value):
    path.write_text(json.dumps(value, sort_keys=True))


def ledger_fixture(directory, scale=1.0):
    """Synthetic parser fixture; this is never native acceptance evidence."""
    directory.mkdir(parents=True, exist_ok=True)
    address, key, identity = "location:room", "lighting", "room"
    attribute = {"tag": "Hard side lighting", "directive": "Keep a dark opposite wall.", "source": "Initial fixture", "locked": False, "updated": "initial"}
    state = {"schema": "ledger/v1", "objects": {address: {key: attribute}, "look": {"palette": {"tag": "Pale", "directive": "Keep pale walls", "source": "Other direction", "locked": True}}}}
    def ledger_file(name, value):
        put(directory / ("ledger-" + name + ".json"), value)
        # JSON is a valid YAML 1.2 fixture; production retains the actual YAML writer bytes.
        data = json.dumps(value, sort_keys=True).encode()
        (directory / ("ledger-" + name + ".yaml")).write_bytes(data)
        return hashlib.sha256(data).hexdigest()
    previous_sha = ledger_file("initial", state)
    def detail(name):
        attribute = json.loads((directory / ("ledger-" + name + ".json")).read_text())["objects"][address][key]
        return {"kind": "verified-state", "label": "actual Ledger detail", "evidence": {
            "identifier": address + "." + key, "directive": attribute["directive"], "source": attribute["source"],
            "locked": attribute["locked"], "window": 42}}
    actions = [{"kind": "pointer", "id": "bible.entity.select.location." + identity}]
    actions.extend([{"kind": "pointer", "id": "ledger.attribute." + address + "." + key}, detail("initial")])
    steps = []
    directions = ["Lock this lighting", "Remove without unlocking", "Unlock this lighting", "Keep warm side light.", "Lock the revised lighting"]
    expected = [("lock", "lock_ledger_attribute", True), ("locked-removal-refused", "remove_ledger_attribute", True),
                ("unlock", "lock_ledger_attribute", False), ("edit", "set_ledger_attribute", False), ("relock", "lock_ledger_attribute", True)]
    for step_number, ((name, tool, locked), direction) in enumerate(zip(expected, directions)):
        arguments = {"kind": "location", "object_id": identity, "key": key}
        if tool != "remove_ledger_attribute": arguments["locked"] = locked
        if name == "edit": arguments.update(tag="Warm side lighting", directive=direction, source=direction)
        if name != "locked-removal-refused":
            state = copy.deepcopy(state)
            state["objects"][address][key]["locked"] = locked
            state["objects"][address][key]["updated"] = name
            if name == "edit": state["objects"][address][key].update(tag=arguments["tag"], directive=direction, source=direction)
        current_sha = ledger_file(name, state)
        selection = {"target": "Bible location ID " + identity, "workspace": "production"}
        step = {"name": name, "tool": tool, "arguments": arguments, "direction": direction,
                "isError": name == "locked-removal-refused", "result": "Ledger update rejected: attributeLocked" if name == "locked-removal-refused" else "Actual tool result fixture",
                "requestContext": "<app-context>Captured selection: " + json.dumps(selection) + "</app-context>",
                "sha256Before": previous_sha, "sha256After": current_sha, "ledger": "ledger-" + name + ".json"}
        put(directory / ("step-" + name + ".json"), step)
        actions.extend([{"kind": "pointer", "id": "ledger.attribute." + address + "." + key},
                        detail("initial" if step_number == 0 else expected[step_number - 1][0]),
                        {"kind": "pointer", "id": "ledger.revise"},
                        {"kind": "pointer", "id": "pipeline.overview.select.bible"},
                        {"kind": "text", "field": {"id": "agent.composer.input", "fontPointSize": 13 * scale,
                            "expected": direction, "actual": direction, "commitInput": "Pointer:pipeline.overview.select.bible", "requiresFocusExit": True, "focusLeftTarget": True}},
                        {"kind": "pointer", "id": "agent.task.run"},
                        {"kind": "verified-state", "label": "actual Ledger " + name, "evidence": step}])
        steps.append(step); previous_sha = current_sha
    actions.extend([{"kind": "pointer", "id": "ledger.attribute." + address + "." + key}, detail("relock")])
    put(directory / "ledger-reopened.json", state)
    for name in ("before-save", "reopened"):
        (directory / ("ledger-" + name + ".yaml")).write_bytes((directory / "ledger-relock.yaml").read_bytes())
    busy = {}
    for name, source in [("undo-relock", "edit"), ("undo-edit", "unlock"), ("redo-edit", "edit"), ("redo-relock", "relock")]:
        put(directory / ("ledger-" + name + ".json"), json.loads((directory / ("ledger-" + source + ".json")).read_text()))
        actual_bytes = (directory / ("ledger-" + source + ".yaml")).read_bytes()
        actual_sha = hashlib.sha256(actual_bytes).hexdigest()
        (directory / ("ledger-" + name + ".yaml")).write_bytes(actual_bytes)
        actions.extend([{"kind": "verified-state", "label": "before native Ledger " + name, "evidence": {
                            "actionName": "Revise Attribute", "redo": name.startswith("redo"),
                            "expectedRevisionSHA256": actual_sha, "documentOwnsUndo": True}},
                        {"kind": "keyboard", "code": 6, "characters": "Z" if name.startswith("redo") else "z",
                         "modifiers": (1 << 20) | ((1 << 17) if name.startswith("redo") else 0)},
                        {"kind": "verified-state", "label": "native Ledger " + name, "evidence": {
                            "ledgerSHA256": actual_sha, "expectedRevisionSHA256": actual_sha}}])
        if name == "undo-relock":
            finish = actions.pop()
            held = (directory / "ledger-relock.yaml").read_bytes()
            (directory / "ledger-busy-before.yaml").write_bytes(held)
            (directory / "ledger-busy-after.yaml").write_bytes(held)
            held_sha = hashlib.sha256(held).hexdigest()
            modifiers = [1 << 20, (1 << 20) | (1 << 17)]
            busy = {"beforeSHA256": held_sha, "afterRapidSHA256": held_sha,
                    "deliveredModifiers": modifiers, "stopReleasedAgent": True}
            actions.extend([
                {"kind": "verified-state", "label": "Ledger busy rapid begin", "evidence": {
                    "ledgerSHA256": held_sha, "undoEnabled": False, "redoEnabled": False, "streaming": True,
                    "message": "Waiting for the agent. Let the agent finish, or choose Show Agent to stop it. Current attributes remain unchanged."}},
                {"kind": "keyboard", "code": 6, "characters": "z", "modifiers": modifiers[0]},
                {"kind": "keyboard", "code": 6, "characters": "Z", "modifiers": modifiers[1]},
                {"kind": "verified-state", "label": "Ledger busy rapid end", "evidence": {"ledgerSHA256": held_sha, "deliveredModifiers": modifiers}},
                {"kind": "pointer", "id": "ledger.restore.show-agent"}, {"kind": "pointer", "id": "agent.stop"},
                {"kind": "verified-state", "label": "Ledger busy native Stop completed", "evidence": busy}, finish])
    bible = {"locations": [{"id": identity, "name": "Ledger room"}]}
    put(directory / "bible-before.json", bible); put(directory / "bible-after.json", bible)
    for name in ("before", "after"): put(directory / ("bible-" + name + ".yaml"), bible)
    bible_sha = hashlib.sha256((directory / "bible-before.yaml").read_bytes()).hexdigest()
    actions.extend([{"kind": "verified-state", "label": "before native Ledger Save", "evidence": {"documentDirty": True, "ledgerSHA256": previous_sha}},
                    {"kind": "keyboard", "code": 1, "characters": "s", "modifiers": 1 << 20},
                    {"kind": "pointer", "id": "ledger.attribute." + address + "." + key}, detail("reopened"),
                    {"kind": "verified-state", "label": "actual reopened Ledger details", "evidence": {"ledgerSHA256": previous_sha, "bibleSHA256": bible_sha}}])
    (directory / "native.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"Synthetic parser image fixture" * 40)
    images = ["native.png", "native-ledger-busy-waiting.png", "native-ledger-busy-agent-stop.png"]
    for name in images[1:]: (directory / name).write_bytes((directory / "native.png").read_bytes())
    native = {"interactions": actions, "screenshots": images, "progress": "native-ledger.json"}
    put(directory / native["progress"], {**native, "failure": None})
    result = {"objectKey": address, "attributeKey": key, "scale": scale, "viewport": [960, 640], "liveAgent": False,
              "savedAndReopened": True, "nativeUndoRedo": True, "busyUndo": busy, "renderedFontPointSize": 13 * scale, "steps": steps, "native": native,
              "bibleSHA256Before": bible_sha, "bibleSHA256After": bible_sha,
              "ledgerSHA256BeforeSave": previous_sha, "ledgerSHA256Reopened": previous_sha}
    put(directory / "ledger-owner-result.json", result)
    return result


class LedgerAttributeOwnerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory(); self.root = Path(self.temp.name)
        ledger_fixture(self.root)

    def tearDown(self): self.temp.cleanup()

    def edit_step(self, name, mutation):
        result = json.loads((self.root / "ledger-owner-result.json").read_text())
        step = next(value for value in result["steps"] if value["name"] == name)
        mutation(step)
        put(self.root / ("step-" + name + ".json"), step)
        for row in result["native"]["interactions"]:
            if row.get("label") == "actual Ledger " + name: row["evidence"] = step
        put(self.root / result["native"]["progress"], {**result["native"], "failure": None})
        put(self.root / "ledger-owner-result.json", result)

    def edit_actions(self, mutation):
        result = json.loads((self.root / "ledger-owner-result.json").read_text())
        mutation(result["native"]["interactions"])
        put(self.root / result["native"]["progress"], {**result["native"], "failure": None})
        put(self.root / "ledger-owner-result.json", result)

    def test_complete_synthetic_validator_fixture(self):
        self.assertEqual(validate(self.root, 1.0)["attributeKey"], "lighting")

    def test_busy_native_sequence_is_required(self):
        for fault in ("missing-stop", "menu-enabled", "delivery", "busy-bytes", "missing-image", "missing-subpath", "missing-begin-marker"):
            with self.subTest(fault=fault):
                result = ledger_fixture(self.root)
                if fault == "busy-bytes": (self.root / "ledger-busy-after.yaml").write_bytes(b"another revision")
                elif fault == "missing-image":
                    result["native"]["screenshots"].remove("native-ledger-busy-waiting.png")
                    put(self.root / result["native"]["progress"], {**result["native"], "failure": None})
                    put(self.root / "ledger-owner-result.json", result)
                elif fault == "missing-subpath":
                    result.pop("busyUndo")
                    put(self.root / result["native"]["progress"], {**result["native"], "failure": None})
                    put(self.root / "ledger-owner-result.json", result)
                elif fault == "missing-begin-marker":
                    self.edit_actions(lambda rows: rows.__setitem__(slice(None), [row for row in rows if row.get("label") != "Ledger busy rapid begin"]))
                elif fault == "missing-stop":
                    self.edit_actions(lambda rows: rows.__setitem__(slice(None), [row for row in rows if row.get("id") != "agent.stop"]))
                elif fault == "menu-enabled":
                    self.edit_actions(lambda rows: next(row for row in rows if row.get("label") == "Ledger busy rapid begin")["evidence"].update(undoEnabled=True))
                else:
                    self.edit_actions(lambda rows: next(row for row in rows if row.get("label") == "Ledger busy rapid end")["evidence"].update(deliveredModifiers=[]))
                with self.assertRaises(ValueError): validate(self.root)

    def test_wrong_outer_scale_rejected(self):
        with self.assertRaises(ValueError): validate(self.root, 1.5)

    def test_actual_yaml_tampering_rejected(self):
        (self.root / "ledger-edit.yaml").write_bytes(b"changed actual bytes")
        with self.assertRaises(ValueError): validate(self.root)

    def test_disconnected_byte_chain_rejected(self):
        self.edit_step("unlock", lambda step: step.update(sha256Before="foreign"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_wrong_object_scope_rejected(self):
        self.edit_step("edit", lambda step: step.update(requestContext='<app-context>{"target":"Bible location ID other","workspace":"production"}</app-context>'))
        with self.assertRaises(ValueError): validate(self.root)
        ledger_fixture(self.root)
        self.edit_actions(lambda rows: next(row for row in rows if row.get("label") == "actual Ledger detail")["evidence"].update(identifier="location:other.lighting"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_hidden_source_range_rejected(self):
        self.edit_step("edit", lambda step: step.update(requestContext='<app-context>{"target":"Bible location ID room","workspace":"production","source":{"assetID":"old"}}</app-context>'))
        with self.assertRaises(ValueError): validate(self.root)

    def test_wrong_lock_refusal_rejected(self):
        self.edit_step("locked-removal-refused", lambda step: step.update(result="unrelated network error"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_source_direction_loss_rejected(self):
        self.edit_step("edit", lambda step: step.update(direction="Different actual user request"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_other_object_mutation_rejected(self):
        path = self.root / "ledger-edit.json"; value = json.loads(path.read_text())
        value["objects"]["look"]["palette"]["tag"] = "Unexpected"; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_duplicate_attribute_rejected(self):
        path = self.root / "ledger-edit.json"; value = json.loads(path.read_text())
        value["objects"]["location:room"]["lighting_duplicate"] = value["objects"]["location:room"]["lighting"]; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_partial_undo_rejected(self):
        path = self.root / "ledger-undo-edit.json"; value = json.loads(path.read_text())
        value["objects"]["location:room"]["lighting"]["locked"] = True; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)
        for field in ("ledgerSHA256", "expectedRevisionSHA256"):
            with self.subTest(field=field):
                ledger_fixture(self.root)
                self.edit_actions(lambda rows: next(row for row in rows if row.get("label") == "native Ledger undo-edit")["evidence"].update({field: "foreign"}))
                with self.assertRaises(ValueError): validate(self.root)
        ledger_fixture(self.root)
        (self.root / "ledger-undo-edit.yaml").write_bytes(b"changed actual Undo bytes")
        with self.assertRaises(ValueError): validate(self.root)
        ledger_fixture(self.root)
        path = self.root / "ledger-undo-edit.yaml"
        path.write_bytes(path.read_bytes() + b"\n")
        actual_sha = hashlib.sha256(path.read_bytes()).hexdigest()
        self.edit_actions(lambda rows: next(row for row in rows if row.get("label") == "native Ledger undo-edit")["evidence"].update(ledgerSHA256=actual_sha))
        self.assertEqual(validate(self.root)["attributeKey"], "lighting")
        result = json.loads((self.root / "ledger-owner-result.json").read_text())
        actual_bytes = (self.root / "ledger-redo-relock.yaml").read_bytes() + b"\n"
        actual_sha = hashlib.sha256(actual_bytes).hexdigest()
        for name in ("redo-relock", "before-save", "reopened"):
            (self.root / ("ledger-" + name + ".yaml")).write_bytes(actual_bytes)
        for row in result["native"]["interactions"]:
            if row.get("label") in ("native Ledger redo-relock", "before native Ledger Save", "actual reopened Ledger details"):
                row["evidence"]["ledgerSHA256"] = actual_sha
        result.update(ledgerSHA256BeforeSave=actual_sha, ledgerSHA256Reopened=actual_sha)
        put(self.root / result["native"]["progress"], {**result["native"], "failure": None})
        put(self.root / "ledger-owner-result.json", result)
        self.assertEqual(validate(self.root)["attributeKey"], "lighting")

    def test_reopened_value_loss_rejected(self):
        put(self.root / "ledger-reopened.json", {"schema": "ledger/v1", "objects": {}})
        with self.assertRaises(ValueError): validate(self.root)

    def test_pointer_claim_cannot_replace_real_task_action(self):
        result = json.loads((self.root / "ledger-owner-result.json").read_text())
        result["native"]["interactions"] = [row for row in result["native"]["interactions"] if row.get("id") != "ledger.revise"]
        put(self.root / result["native"]["progress"], {**result["native"], "failure": None}); put(self.root / "ledger-owner-result.json", result)
        with self.assertRaises(ValueError): validate(self.root)
        ledger_fixture(self.root)
        self.edit_actions(lambda rows: rows.__setitem__(slice(None), [row for row in rows if row.get("id") != "pipeline.overview.select.bible"]))
        with self.assertRaises(ValueError): validate(self.root)

    def test_plain_z_cannot_replace_document_undo(self):
        self.edit_actions(lambda rows: next(row for row in rows if row.get("code") == 6).update(modifiers=0))
        with self.assertRaises(ValueError): validate(self.root)
        for update in ({"actionName": "Type"}, {"documentOwnsUndo": False}, {"redo": True}, {"expectedRevisionSHA256": "foreign"}):
            with self.subTest(update=update):
                ledger_fixture(self.root)
                self.edit_actions(lambda rows: next(row for row in rows if row.get("label") == "before native Ledger undo-edit")["evidence"].update(update))
                with self.assertRaises(ValueError): validate(self.root)

    def test_missing_native_undo_key_rejected(self):
        def remove(rows):
            index = next(i for i, row in enumerate(rows) if row.get("code") == 6)
            rows.pop(index)
        self.edit_actions(remove)
        with self.assertRaises(ValueError): validate(self.root)

    def test_save_before_undo_redo_rejected(self):
        def move(rows):
            index = next(i for i, row in enumerate(rows) if row.get("code") == 1)
            rows.insert(0, rows.pop(index))
        self.edit_actions(move)
        with self.assertRaises(ValueError): validate(self.root)

    def test_missing_save_rejected(self):
        self.edit_actions(lambda rows: rows.__setitem__(slice(None), [row for row in rows if row.get("code") != 1]))
        with self.assertRaises(ValueError): validate(self.root)

    def test_actual_direction_mismatch_rejected(self):
        self.edit_actions(lambda rows: next(row for row in rows if row.get("kind") == "text")["field"].update(actual="Different text"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_composer_focus_not_released_rejected(self):
        self.edit_actions(lambda rows: next(row for row in rows if row.get("kind") == "text")["field"].update(focusLeftTarget=False))
        with self.assertRaises(ValueError): validate(self.root)

    def test_pointer_commit_and_required_focus_exit_cannot_be_substituted(self):
        for update in ({"commitInput": "Tab"}, {"requiresFocusExit": False}):
            with self.subTest(update=update):
                ledger_fixture(self.root)
                self.edit_actions(lambda rows: next(row for row in rows if row.get("kind") == "text")["field"].update(update))
                with self.assertRaises(ValueError): validate(self.root)

    def test_tab_between_native_undo_check_and_key_rejected(self):
        def insert(rows):
            index = next(i for i, row in enumerate(rows) if row.get("label") == "before native Ledger undo-edit")
            rows.insert(index + 1, {"kind": "keyboard", "code": 48, "characters": "\t", "modifiers": 0})
        self.edit_actions(insert)
        with self.assertRaises(ValueError): validate(self.root)

    def test_unchanged_document_save_claim_rejected(self):
        self.edit_actions(lambda rows: next(row for row in rows if row.get("label") == "before native Ledger Save")["evidence"].update(documentDirty=False))
        with self.assertRaises(ValueError): validate(self.root)

    def test_reopened_actual_bytes_changed_rejected(self):
        (self.root / "ledger-reopened.yaml").write_bytes(b"changed actual bytes")
        with self.assertRaises(ValueError): validate(self.root)

    def test_retained_bible_actual_bytes_changed_rejected(self):
        (self.root / "bible-after.yaml").write_bytes(b"changed actual bytes")
        with self.assertRaises(ValueError): validate(self.root)

    def test_revision_filename_alias_rejected(self):
        self.edit_step("edit", lambda step: step.update(ledger="ledger-reopened.json"))
        with self.assertRaises(ValueError): validate(self.root)


if __name__ == "__main__": unittest.main()
