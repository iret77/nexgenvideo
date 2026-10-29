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
    actions = [{"kind": "pointer", "id": "bible.entity.select.location." + identity}]
    for _ in range(2): actions.append({"kind": "pointer", "id": "ledger.attribute." + address + "." + key})
    steps = []
    directions = ["Lock this lighting", "Remove without unlocking", "Unlock this lighting", "Keep warm side light.", "Lock the revised lighting"]
    expected = [("lock", "lock_ledger_attribute", True), ("locked-removal-refused", "remove_ledger_attribute", True),
                ("unlock", "lock_ledger_attribute", False), ("edit", "set_ledger_attribute", False), ("relock", "lock_ledger_attribute", True)]
    for (name, tool, locked), direction in zip(expected, directions):
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
                        {"kind": "pointer", "id": "ledger.revise"},
                        {"kind": "text", "field": {"id": "agent.composer.input", "fontPointSize": 13 * scale}},
                        {"kind": "pointer", "id": "agent.task.run"},
                        {"kind": "verified-state", "label": "actual Ledger " + name, "evidence": step}])
        steps.append(step); previous_sha = current_sha
    put(directory / "ledger-reopened.json", state)
    for name, source in [("undo-relock", "edit"), ("undo-edit", "unlock"), ("redo-edit", "edit"), ("redo-relock", "relock")]:
        put(directory / ("ledger-" + name + ".json"), json.loads((directory / ("ledger-" + source + ".json")).read_text()))
        actions.extend([{"kind": "keyboard", "code": 6, "characters": "Z" if name.startswith("redo") else "z"},
                        {"kind": "verified-state", "label": "native Ledger " + name, "evidence": {"ledgerSHA256": "fixture"}}])
    actions.append({"kind": "keyboard", "code": 1, "characters": "s"})
    bible = {"locations": [{"id": identity, "name": "Ledger room"}]}
    put(directory / "bible-before.json", bible); put(directory / "bible-after.json", bible)
    (directory / "native.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"Synthetic parser image fixture" * 40)
    native = {"interactions": actions, "screenshots": ["native.png"], "progress": "native-ledger.json"}
    put(directory / native["progress"], {**native, "failure": None})
    result = {"objectKey": address, "attributeKey": key, "scale": scale, "viewport": [960, 640], "liveAgent": False,
              "savedAndReopened": True, "nativeUndoRedo": True, "renderedFontPointSize": 13 * scale, "steps": steps, "native": native}
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

    def test_complete_synthetic_validator_fixture(self):
        self.assertEqual(validate(self.root, 1.0)["attributeKey"], "lighting")

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

    def test_reopened_value_loss_rejected(self):
        put(self.root / "ledger-reopened.json", {"schema": "ledger/v1", "objects": {}})
        with self.assertRaises(ValueError): validate(self.root)

    def test_pointer_claim_cannot_replace_real_task_action(self):
        result = json.loads((self.root / "ledger-owner-result.json").read_text())
        result["native"]["interactions"] = [row for row in result["native"]["interactions"] if row.get("id") != "ledger.revise"]
        put(self.root / result["native"]["progress"], {**result["native"], "failure": None}); put(self.root / "ledger-owner-result.json", result)
        with self.assertRaises(ValueError): validate(self.root)


if __name__ == "__main__": unittest.main()
