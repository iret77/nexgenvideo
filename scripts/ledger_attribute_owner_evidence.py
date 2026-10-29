"""Independent actual native Ledger object/lock/source/reconcile/Undo evidence checks."""
import hashlib
import json
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path):
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
    steps = result.get("steps", [])
    expected = [("lock", "lock_ledger_attribute", True), ("locked-removal-refused", "remove_ledger_attribute", True),
                ("unlock", "lock_ledger_attribute", False), ("edit", "set_ledger_attribute", False), ("relock", "lock_ledger_attribute", True)]
    require(len(steps) == len(expected), "complete actual Ledger sequence required")
    previous = read(directory / "ledger-initial.json")
    require(previous.get("objects", {}).get(address, {}).get(key, {}).get("locked") is False, "initial fixture must be unlocked")
    previous_sha = digest(directory / "ledger-initial.yaml")
    for step, (name, tool, locked) in zip(steps, expected):
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
        ledger = read(local(directory, step.get("ledger", "")))
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
    for name, expected_name in [("undo-relock", "edit"), ("undo-edit", "unlock"), ("redo-edit", "edit"), ("redo-relock", "relock")]:
        require(read(directory / ("ledger-" + name + ".json")) == read(directory / ("ledger-" + expected_name + ".json")), "native Undo/Redo did not restore the complete intended revision")
        require(any(row.get("kind") == "verified-state" and row.get("label") == "native Ledger " + name for row in actions), "native Undo/Redo observation missing")
    keys = [row for row in actions if row.get("kind") == "keyboard" and row.get("code") == 6]
    require(len(keys) == 4 and [row.get("characters") for row in keys] == ["z", "z", "Z", "Z"], "actual native Ledger Undo/Redo keys missing")
    require(any(row.get("kind") == "keyboard" and row.get("code") == 1 and row.get("characters") == "s" for row in actions), "actual native Ledger Save missing")
    return result


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--scale", type=float)
    args = parser.parse_args()
    validate(args.directory, args.scale)
