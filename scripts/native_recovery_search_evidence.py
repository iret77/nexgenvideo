"""Bind the two native overlap/recovery observations to recorded inputs and saved bytes."""
import hashlib
import json
from pathlib import Path
import uuid


def _state(interactions, label):
    values = [item["evidence"] for item in interactions
              if item.get("kind") == "verified-state" and item.get("label") == label]
    if len(values) != 1:
        raise ValueError("Missing or ambiguous native observation")
    return values[0]


def _local(directory, name):
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise ValueError("Invalid local package")
    path = directory / name
    if path.is_symlink() or not path.is_dir():
        raise ValueError("Missing local package")
    return path


def _hashes(package):
    result = {}
    for path in package.rglob("*"):
        if path.is_symlink():
            raise ValueError("Symlink package member")
        if path.is_file():
            result[path.relative_to(package).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def search_overlap(value, directory, interactions):
    if _state(interactions, "search Save As external overlap") != value:
        return False
    for field in ("originalID", "copyID", "oldGeneration", "newGeneration"):
        uuid.UUID(value[field])
    if (value["originalID"] == value["copyID"] or value["oldGeneration"] == value["newGeneration"]
        or any(value.get(key) is not True for key in ("oldQueryCompletedWhileCurrentHeld", "currentOnlySettled", "isolatedQueryEncoder"))
        or value.get("liveSearchModel") is not False):
        return False
    original, copied = _local(directory, value["original"]), _local(directory, value["copy"])
    if original == copied or _hashes(original) != value["originalHashes"]:
        return False
    if any(json.loads((package / "ngv.json").read_text())["id"] != identity
           for package, identity in ((original, value["originalID"]), (copied, value["copyID"]))):
        return False
    if (original / "project.json").read_bytes() != (copied / "project.json").read_bytes():
        return False
    source = json.loads((original / "media.json").read_text())["entries"]
    target = json.loads((copied / "media.json").read_text())["entries"]
    if len(source) != 2 or len(target) != 2 or {item["id"] for item in source} != {"external-a", "external-b"}:
        return False
    target = {item["id"]: item for item in target}
    if set(value["externalHashes"]) != {"external-a", "external-b"}:
        return False
    for item in source:
        filename = "A.mov" if item["id"] == "external-a" else "B.mov"
        raw = item["source"]["external"]["absolutePath"]
        external = directory / "Incoming" / filename
        if (not Path(raw).is_absolute() or Path(raw).parts[-3:] != (directory.name, "Incoming", filename)
            or item["source"] != target[item["id"]]["source"] or external.is_symlink()
            or hashlib.sha256(external.read_bytes()).hexdigest() != value["externalHashes"][item["id"]]):
            return False
    started = value["startedQueries"]
    by_id = {event["taskID"]: event for event in started}
    if len(by_id) != len(started):
        return False
    for identifier in by_id:
        uuid.UUID(identifier)
    prepared = value["preparedResults"]
    if len({event["taskID"] for event in prepared}) != len(prepared):
        return False
    for event in prepared:
        if (set(event) != {"taskID", "query", "generation", "ready", "hitIDs"}
            or by_id.get(event["taskID"]) != {key: event[key] for key in ("taskID", "query", "generation")}
            or type(event["ready"]) is not bool or not isinstance(event["hitIDs"], list)):
            return False
    completed = value["completedTaskIDs"]
    if len(set(completed)) != len(completed) or not set(completed).issubset(by_id):
        return False
    old_ids = {identifier for identifier, event in by_id.items()
               if event["query"] == "old-cut" and event["generation"] == value["oldGeneration"]}
    held = value["releasedOldTaskIDs"]
    current = value["releasedCurrentTaskIDs"]
    before = value["completionCountBeforeRelease"]
    after_old = value["completionCountBeforeCurrentRelease"]
    if (type(before) is not int or type(after_old) is not int or not 0 <= before < after_old <= len(completed)
        or not held or len(set(held)) != len(held) or not set(held).issubset(old_ids)
        or set(held).intersection(completed[:before])
        or not set(held).issubset(completed[before:after_old])
        or not old_ids.difference(held).issubset(completed[:before])
        or not current or len(set(current)) != len(current)
        or set(current).intersection(completed[:after_old]) or not set(current).issubset(completed[after_old:])):
        return False
    if {event["taskID"] for event in prepared if event["query"] == "old-cut" and event["generation"] == value["oldGeneration"]} != set(held):
        return False
    for identifiers, query, generation, hit in ((held, "old-cut", value["oldGeneration"], "external-b"),
                                               (current, "harbor", value["newGeneration"], "external-a")):
        if any(by_id.get(identifier) != {"taskID": identifier, "query": query, "generation": generation} for identifier in identifiers):
            return False
        if not any(event == {"taskID": identifier, "query": query, "generation": generation, "ready": True, "hitIDs": [hit]}
                   for identifier in identifiers for event in prepared):
            return False
    return True


def reload_retry(value, directory, interactions):
    if _state(interactions, "persistent failed reload and native Retry") != value:
        return False
    for field in ("projectID", "oldGeneration", "newGeneration"):
        uuid.UUID(value[field])
    if (value["oldGeneration"] == value["newGeneration"] or type(value["reloadAttempts"]) is not int
        or value["reloadAttempts"] != 2 or value.get("savedBytesPreserved") is not True
        or value.get("realRetryRestoredSavedState") is not True
        or value["blockedNativeKeys"] != ["s", "z", "Z", "i", "e"]
        or value["faultInjection"] != "The first installed working-copy timeline is deliberately unreadable; the saved package stays intact."):
        return False
    if not {"Saved project could not be loaded", "Editing and saving are paused to protect your saved project. Retry reload, or close and reopen this project."}.issubset(value["pausedTexts"]):
        return False
    package = _local(directory, value["package"])
    if _hashes(package) != value["packageHashes"] or json.loads((package / "ngv.json").read_text())["id"] != value["projectID"]:
        return False
    saved = _local(directory, "Original portrait.ngv")
    if any((package / name).read_bytes() != (saved / name).read_bytes() for name in ("project.json", "media.json")):
        return False
    commands = [item["evidence"] for item in interactions
                if item.get("kind") == "verified-state" and item.get("label") == "paused native command delivered"]
    expected = [{"code": code, "characters": text, "modifiers": (1 << 20) | ((1 << 17) if text == "Z" else 0)}
                for code, text in ((1, "s"), (6, "z"), (6, "Z"), (34, "i"), (14, "e"))]
    return commands == expected
