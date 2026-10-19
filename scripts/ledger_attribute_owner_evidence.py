"""Independent actual native Ledger object/lock/source/reconcile/Undo evidence checks."""
import hashlib
import json
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path):
    require(path.is_file() and not path.is_symlink(), "missing regular Ledger JSON evidence")
    return json.loads(path.read_text())


def digest(path):
    require(path.is_file() and not path.is_symlink(), "missing regular Ledger evidence")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local(root, name):
    path = Path(name)
    require(name and not path.is_absolute() and all(part not in (".", "..") for part in path.parts), "unsafe Ledger artifact")
    result = root / path
    require(result.resolve().is_relative_to(root.resolve()), "Ledger artifact escape")
    return result


def validate(directory, expected_scale=None):
    directory = Path(directory)
    result = read(directory / "ledger-owner-result.json")
    scale = result.get("scale")
    require(scale in (1.0, 1.25, 1.5) and (expected_scale is None or scale == expected_scale)
            and result.get("viewport") == [960, 640], "actual Ledger presentation differs")
    require(result.get("liveAgent") is False and result.get("savedAndReopened") is True and result.get("nativeUndoRedo") is True,
            "native Ledger/reopen observations missing")
    address, key = result.get("objectKey", ""), result.get("attributeKey", "")
    require(address.startswith("location:") and address[len("location:"):] and key, "actual entity/key missing")
    identity = address[len("location:"):]
    native = result.get("native", {})
    progress = read(local(directory, native.get("progress", "")))
    actions = native.get("interactions", [])
    require(progress.get("failure") is None and progress.get("interactions") == actions and progress.get("screenshots") == native.get("screenshots"), "actual Ledger driver log differs")
    require(native.get("screenshots"), "Ledger screenshots missing")
    for name in native["screenshots"]:
        image = local(directory, name)
        require(image.stat().st_size > 1000 and image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "actual Ledger PNG missing")
    pointers = [row.get("id") for row in actions if row.get("kind") == "pointer"]
    require("bible.entity.select.location." + identity in pointers and pointers.count("ledger.attribute." + address + "." + key) >= 7
            and pointers.count("ledger.revise") == 5 and pointers.count("agent.task.run") == 5, "actual bounded Ledger decisions missing")
    fields = [row.get("field", {}) for row in actions if row.get("kind") == "text" and row.get("field", {}).get("id") == "agent.composer.input"]
    require(len(fields) == 5 and result.get("renderedFontPointSize") == fields[-1].get("fontPointSize")
            and abs(fields[-1].get("fontPointSize", 0) - 13 * scale) < 0.5, "actual Ledger task font differs")
    bible = read(directory / "bible-before.json")
    require(bible == read(directory / "bible-after.json") and any(location.get("id") == identity for location in bible.get("locations", [])), "Ledger edited another entity or rewrote Bible truth")
    bible_sha = digest(directory / "bible-before.yaml")
    require(result.get("bibleSHA256Before") == result.get("bibleSHA256After") == bible_sha
            == digest(directory / "bible-after.yaml"), "actual retained Bible bytes differ")
    steps = result.get("steps", [])
    expected = [("lock", "lock_ledger_attribute", True), ("locked-removal-refused", "remove_ledger_attribute", True),
                ("unlock", "lock_ledger_attribute", False), ("edit", "set_ledger_attribute", False), ("relock", "lock_ledger_attribute", True)]
    require(len(steps) == len(expected), "complete actual Ledger sequence required")
    previous = read(directory / "ledger-initial.json")
    require(previous.get("objects", {}).get(address, {}).get(key, {}).get("locked") is False, "initial fixture must be unlocked")
    retained = {obj: value for obj, value in previous["objects"].items() if obj != address}
    require(retained and any(attribute.get("locked") is True and attribute.get("source")
            for attributes in retained.values() for attribute in attributes.values()), "actual other-object preservation fixture missing")
    previous_sha = digest(directory / "ledger-initial.yaml")
    last_step_index = -1
    for step, field, (name, tool, locked) in zip(steps, fields, expected):
        require(field.get("expected") == field.get("actual") == step.get("direction")
                and field.get("commitInput") == "Pointer:pipeline.overview.select.bible" and field.get("requiresFocusExit") is True
                and field.get("focusLeftTarget") is True, "actual Ledger direction or composer focus exit differs")
        field_index = next(i for i, row in enumerate(actions) if row.get("kind") == "text" and row.get("field") == field)
        require(field_index > 0 and actions[field_index - 1].get("kind") == "pointer"
                and actions[field_index - 1].get("id") == "pipeline.overview.select.bible", "actual composer focus-exit pointer missing")
        require(read(directory / ("step-" + name + ".json")) == step and step.get("name") == name and step.get("tool") == tool, "actual Ledger tool result differs")
        observations = [row.get("evidence") for row in actions if row.get("kind") == "verified-state" and row.get("label") == "actual Ledger " + name]
        require(observations == [step], "actual Ledger observation missing")
        arguments = step.get("arguments", {})
        require(arguments.get("kind") == "location" and arguments.get("object_id") == identity and arguments.get("key") == key, "tool targeted another entity/key")
        raw = step.get("requestContext", "")
        require(raw.startswith("<app-context>") and raw.endswith("</app-context>") and "{" in raw, "actual task context missing")
        captured, _ = json.JSONDecoder().raw_decode(raw[raw.index("{"):])
        require(captured.get("target") == "Bible location ID " + identity and captured.get("workspace") == "production"
                and captured.get("timelineRange") is None and captured.get("source") is None, "hidden range replaced the actual entity scope")
        require(step.get("ledger") == "ledger-" + name + ".json", "wrong actual Ledger revision file")
        ledger = read(local(directory, step["ledger"]))
        step_index = next(index for index, row in enumerate(actions) if row.get("label") == "actual Ledger " + name)
        require(step_index > last_step_index, "native Ledger decisions are out of order")
        last_step_index = step_index
        require(step.get("sha256Before") == previous_sha
                and step.get("sha256After") == digest(directory / ("ledger-" + name + ".yaml")), "actual canonical Ledger byte chain differs")
        require(ledger.get("schema") == "ledger/v1" and set(ledger.get("objects", {})) == set(previous.get("objects", {}))
                and set(ledger["objects"][address]) == {key}
                and {obj: value for obj, value in ledger["objects"].items() if obj != address}
                    == {obj: value for obj, value in previous["objects"].items() if obj != address},
                "reconciliation changed another object or duplicated the attribute")
        attribute = ledger["objects"][address][key]
        require(attribute.get("locked") is locked, "actual lock state differs")
        if name == "locked-removal-refused":
            require(step.get("isError") is True and "attributeLocked" in step.get("result", "") and ledger == previous
                    and step.get("sha256Before") == step.get("sha256After"), "locked removal did not fail without mutation")
        else:
            require(step.get("isError") is False, "expected actual Ledger mutation failed")
        if name == "edit":
            require(attribute.get("tag") == arguments.get("tag") and attribute.get("directive") == arguments.get("directive")
                    and attribute.get("source") == arguments.get("source") == step.get("direction"), "revision lost its exact user direction or origin")
        elif name != "locked-removal-refused":
            require(all(attribute.get(field) == previous["objects"][address][key].get(field) for field in ("tag", "directive", "source")), "lock action changed creative intent")
        previous, previous_sha = ledger, step["sha256After"]
    require(read(directory / "ledger-reopened.json") == previous, "native save/reopen lost the final Ledger")
    saved_sha = digest(directory / "ledger-before-save.yaml")
    require(result.get("ledgerSHA256BeforeSave") == result.get("ledgerSHA256Reopened") == saved_sha
            == digest(directory / "ledger-redo-relock.yaml") == digest(directory / "ledger-reopened.yaml"), "actual saved/reopened Ledger bytes differ")
    for name, expected_name in [("undo-relock", "edit"), ("undo-edit", "unlock"), ("redo-edit", "edit"), ("redo-relock", "relock")]:
        require(read(directory / ("ledger-" + name + ".json")) == read(directory / ("ledger-" + expected_name + ".json")), "native Undo/Redo did not restore the complete intended revision")
        expected_sha = next(step["sha256After"] for step in steps if step["name"] == expected_name)
        actual_sha = digest(directory / ("ledger-" + name + ".yaml"))
        observed = [row.get("evidence") for row in actions if row.get("kind") == "verified-state" and row.get("label") == "native Ledger " + name]
        require(observed == [{"ledgerSHA256": actual_sha, "expectedRevisionSHA256": expected_sha}], "native Undo/Redo canonical bytes or expected revision differ")
    keys = [(index, row) for index, row in enumerate(actions) if row.get("kind") == "keyboard" and row.get("code") == 6]
    command, shift = 1 << 20, 1 << 17
    require(len(keys) == 4 and [row.get("characters") for _, row in keys] == ["z", "z", "Z", "Z"]
            and [row.get("modifiers") for _, row in keys] == [command, command, command | shift, command | shift], "actual native Ledger Undo/Redo keys missing")
    undo_start = last_step_index
    for (index, _), name in zip(keys, ["undo-relock", "undo-edit", "redo-edit", "redo-relock"]):
        observation = next(i for i, row in enumerate(actions) if row.get("label") == "native Ledger " + name)
        before = [(i, row.get("evidence", {})) for i, row in enumerate(actions)
                  if row.get("kind") == "verified-state" and row.get("label") == "before native Ledger " + name]
        require(len(before) == 1 and before[0][1] == {"actionName": "Revise Intent Ledger", "redo": name.startswith("redo"),
                "expectedRevisionSHA256": actions[observation]["evidence"]["expectedRevisionSHA256"], "documentOwnsUndo": True}
                and last_step_index < before[0][0] < index < observation, "native Ledger Undo/Redo action identity or order differs")
        last_step_index = observation
    require(not any(row.get("kind") == "keyboard" and row.get("code") == 48
                    for row in actions[undo_start:last_step_index + 1]), "Tab mutated the composer during native Undo/Redo")
    details = [row.get("evidence", {}) for row in actions if row.get("kind") == "verified-state" and row.get("label") == "actual Ledger detail"]
    detail_sources = ["initial", "initial", "lock", "locked-removal-refused", "unlock", "edit", "relock", "reopened"]
    require(len(details) == len(detail_sources), "actual Ledger detail inspections missing")
    for detail, source in zip(details, detail_sources):
        attribute = read(directory / ("ledger-" + source + ".json"))["objects"][address][key]
        require(detail.get("identifier") == address + "." + key
                and all(detail.get(field) == attribute.get(field) for field in ("directive", "source", "locked"))
                and type(detail.get("window")) is int and detail["window"] > 0, "inspected Ledger detail belongs to another object or revision")
    before_save = [(index, row.get("evidence", {})) for index, row in enumerate(actions) if row.get("label") == "before native Ledger Save"]
    require(len(before_save) == 1 and before_save[0][1] == {"documentDirty": True, "ledgerSHA256": saved_sha}, "dirty actual document before Save missing")
    saves = [index for index, row in enumerate(actions) if row.get("kind") == "keyboard" and row.get("code") == 1
             and row.get("characters") == "s" and row.get("modifiers") == command]
    reopened = [(index, row.get("evidence")) for index, row in enumerate(actions) if row.get("label") == "actual reopened Ledger details"]
    require(len(saves) == len(reopened) == 1 and last_step_index < before_save[0][0] < saves[0] < reopened[0][0]
            and reopened[0][1] == {"ledgerSHA256": saved_sha, "bibleSHA256": bible_sha}, "native Save/reopen detail order or bytes differ")
    return result


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--scale", type=float)
    args = parser.parse_args()
    validate(args.directory, args.scale)
