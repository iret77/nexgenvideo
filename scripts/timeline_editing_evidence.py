import copy
import hashlib
import json
import math
from pathlib import Path
from uuid import UUID


def local(root, relative):
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError("Missing local timeline evidence")
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError("Timeline evidence escapes its directory")
    return path


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def clips(timeline):
    values = [clip for track in timeline["tracks"] for clip in track["clips"]]
    result = {clip["id"]: clip for clip in values}
    if len(result) != len(values):
        raise ValueError("Duplicate clip IDs")
    return result


def canonical(timeline):
    result = copy.deepcopy(timeline)
    for track in result["tracks"]:
        track["clips"].sort(key=lambda clip: clip["id"])
    return result


def same(actual, expected):
    if canonical(actual) != canonical(expected):
        raise ValueError("Actual timeline differs from the independent edit expectation")


def shifted(timeline, ids, delta):
    result = copy.deepcopy(timeline)
    for key, clip in clips(result).items():
        if key in ids:
            clip["startFrame"] += delta
    return result


def without(timeline, ids):
    result = copy.deepcopy(timeline)
    for track in result["tracks"]:
        track["clips"] = [clip for clip in track["clips"] if clip["id"] not in ids]
    return result


def windowed(timeline, offsets):
    result = copy.deepcopy(timeline)
    for key, clip in clips(result).items():
        if key not in offsets:
            continue
        effects = clip.pop("effects")
        if len(effects) != 1:
            raise ValueError("Unexpected trim effects")
        effect = effects[0]
        UUID(effect["id"])
        offset = offsets[key]
        expected = {"start": -offset, "end": 60 - offset,
                    "head": {"anchor": -offset, "length": 0, "interpolation": "linear"},
                    "tail": {"anchor": 60 - offset, "length": 0, "interpolation": "linear"}}
        if (set(effect) != {"id", "type", "enabled", "params"} or effect["type"] != "core.clip-envelope.v1"
            or effect["enabled"] is not True or set(effect["params"]) != {"definition"}
            or set(effect["params"]["definition"]) != {"string"}
            or json.loads(effect["params"]["definition"]["string"]) != expected):
            raise ValueError("Trim changed the original fade clock")
    return result


def timeline_editing_evidence(rows, output, scale):
    try:
        records = [row for row in rows if row.get("event") == "timeline-editing-owner"]
        complete = [row for row in rows if row.get("event") == "completed" and row.get("case") == "timelineediting"]
        if (len(records) != 1 or len(complete) != 1 or any(row.get("event") == "failed" for row in rows)
            or any(row.get("scale") != scale for row in records + complete)):
            return False, []
        row = records[0]
        if row.get("viewport") != [960, 640] or row.get("effectiveScale") != scale:
            return False, []
        directory = local(output, row["directory"])
        package = local(directory, row["project"])
        def read(name):
            return json.loads(local(directory, name + ".json").read_text())
        initial = read("initial")
        source = local(package, "media/Moving picture and tone.mov")
        manifest = json.loads(local(package, "media.json").read_text())
        entry = next(item for item in manifest["entries"] if item["id"] == "source")
        actual = local(package, entry["source"]["project"]["relativePath"])
        if (source.stat().st_size < 1000 or hashlib.sha256(source.read_bytes()).hexdigest() != row["sourceSHA256"]
            or source.read_bytes() != actual.read_bytes() or entry.get("hasAudio") is not True
            or initial["fps"] != 30 or initial["width"] != 160 or initial["height"] != 90
            or [t["id"] for t in initial["tracks"]] != ["picture", "sound", "sync"]
            or [t["type"] for t in initial["tracks"]] != ["video", "audio", "audio"]
            or any(t["syncLocked"] is not True for t in initial["tracks"])):
            return False, []
        expected_initial = {"a": (30, 60, "pair-a"), "b": (150, 60, "pair-b"), "target": (300, 60, None),
                            "a-audio": (30, 60, "pair-a"), "b-audio": (150, 60, "pair-b"),
                            "obstacle": (0, 120, None), "follower": (150, 60, None)}
        original = clips(initial)
        if set(original) != set(expected_initial):
            return False, []
        for key, (start, duration, group) in expected_initial.items():
            clip = original[key]
            if (clip["startFrame"] != start or clip["durationFrames"] != duration or clip.get("linkGroupId") != group
                or clip["trimStartFrame"] != 30 or clip["trimEndFrame"] != 210 - duration or clip["speed"] != 1
                or clip["mediaRef"] != "source" or clip.get("effects") or clip["fadeInFrames"] != 0 or clip["fadeOutFrames"] != 0):
                return False, []
        pairs = {"a", "b", "a-audio", "b-audio"}
        same(read("group-move"), shifted(initial, pairs, 30))
        duplicate = read("duplicate")
        clone_ids = set(clips(duplicate)) - set(original)
        if len(clone_ids) != 4:
            return False, []
        same(without(duplicate, clone_ids), initial)
        by_group = {}
        for track in duplicate["tracks"]:
            for clone in track["clips"]:
                if clone["id"] not in clone_ids:
                    continue
                UUID(clone["id"]); UUID(clone["linkGroupId"])
                old = next(c for c in initial["tracks"][[t["id"] for t in initial["tracks"]].index(track["id"])]["clips"]
                           if c["startFrame"] + 60 == clone["startFrame"])
                expected = copy.deepcopy(old); expected.update(id=clone["id"], startFrame=old["startFrame"] + 60, linkGroupId=clone["linkGroupId"])
                if clone != expected or clone["linkGroupId"] in ("pair-a", "pair-b"):
                    return False, []
                by_group.setdefault(clone["linkGroupId"], []).append(old["id"])
        if sorted(sorted(value) for value in by_group.values()) != [["a", "a-audio"], ["b", "b-audio"]]:
            return False, []
        razor = read("razor")
        right_ids = set(clips(razor)) - set(original)
        if len(right_ids) != 2:
            return False, []
        offsets = {"a": 0, "a-audio": 0, **{key: 30 for key in right_ids}}
        razor = windowed(razor, offsets)
        expected = copy.deepcopy(initial)
        right_groups = set()
        for ti, key in ((0, "a"), (1, "a-audio")):
            left = clips(expected)[key]; left["durationFrames"] = 30; left["trimEndFrame"] = 180
            right = next(c for c in razor["tracks"][ti]["clips"] if c["id"] in right_ids)
            UUID(right["id"]); UUID(right["linkGroupId"]); right_groups.add(right["linkGroupId"])
            new = copy.deepcopy(original[key]); new.update(id=right["id"], startFrame=60, durationFrames=30,
                trimStartFrame=60, linkGroupId=right["linkGroupId"])
            expected["tracks"][ti]["clips"].append(new)
        if len(right_groups) != 1 or right_groups & {"pair-a", "pair-b"}:
            return False, []
        same(razor, expected)
        for edge, offset in (("left", 15), ("right", 0)):
            expected = copy.deepcopy(initial)
            for key in ("a", "a-audio"):
                clip = clips(expected)[key]; clip["durationFrames"] = 45
                if edge == "left":
                    clip.update(startFrame=45, trimStartFrame=45)
                else:
                    clip["trimEndFrame"] = 165
            same(windowed(read("trim-" + edge), {"a": offset, "a-audio": offset}), expected)
        same(read("ripple-refused"), initial)
        unlocked = copy.deepcopy(initial); unlocked["tracks"][2]["syncLocked"] = False
        ripple_trim = shifted(unlocked, {"b", "b-audio", "target"}, -15)
        for key in ("a", "a-audio"):
            clips(ripple_trim)[key].update(durationFrames=45, trimEndFrame=165)
        same(windowed(read("ripple-trim"), {"a": 0, "a-audio": 0}), ripple_trim)
        same(read("ripple-delete"), shifted(without(unlocked, {"a", "a-audio"}), {"b", "b-audio", "target"}, -60))
        same(read("gap-close"), shifted(unlocked, {"b", "b-audio", "target"}, -60))
        same(read("snap"), shifted(unlocked, {"a", "a-audio"}, 210))
        before_scroll = without(unlocked, {"target"})
        same(read("before-scroll"), before_scroll)
        for key, cancelled in (("scroll", False), ("cancelledScroll", True)):
            item = row[key]
            numeric = ("initialX", "initialWidth", "pixelsPerFrame", "firstX", "heldX", "stoppedX", "afterStopX", "deltaFrames")
            if (not all(finite(item.get(field)) for field in numeric) or item["cancelled"] is not cancelled or item["dragEvents"] != 1
                or item["pixelsPerFrame"] <= 0 or item["initialWidth"] <= 0 or item["heldX"] <= item["firstX"] + 20
                or item["firstX"] < item["initialX"] or item["afterStopX"] != item["stoppedX"]):
                return False, []
            if cancelled:
                if item["deltaFrames"] != 0:
                    return False, []
            else:
                raw_start = math.floor((item["stoppedX"] + item["initialWidth"] - 2) / item["pixelsPerFrame"]) - 15
                if (item["deltaFrames"] != raw_start - 30 or raw_start <= 215
                    or raw_start <= (item["initialX"] + item["initialWidth"]) / item["pixelsPerFrame"]):
                    return False, []
        final = shifted(before_scroll, {"a", "a-audio"}, row["scroll"]["deltaFrames"])
        same(read("scroll-move"), final); same(read("scroll-cancel"), before_scroll)
        same(json.loads(local(package, "project.json").read_text()), final)
        actions = row["interactions"]
        states = [a for a in actions if a.get("kind") == "verified-state"]
        gestures = [a["evidence"]["target"] for a in states if a.get("label") == "timeline-gesture" and a["evidence"].get("delivered") is True]
        for target, count in (("marquee-pairs", 2), ("shift-remove-pair-a", 1), ("shift-add-pair-a", 1), ("ripple-trim-right", 1), ("group-move", 1), ("option-duplicate", 1), ("razor-60", 1),
                              ("trim-left", 1), ("trim-right", 1), ("select-gap-90-150", 1), ("snap-raw-239-to-240", 1)):
            if gestures.count(target) != count:
                return False, []
        duplicate_input = next(a["evidence"] for a in states if a.get("label") == "timeline-gesture" and a["evidence"].get("target") == "option-duplicate")
        if duplicate_input["modifiers"] != 524288:
            return False, []
        for target in ("shift-remove-pair-a", "shift-add-pair-a", "ripple-trim-right"):
            if next(a["evidence"]["modifiers"] for a in states if a.get("label") == "timeline-gesture" and a["evidence"].get("target") == target) != 131072:
                return False, []
        selections = [a["evidence"].get("ids") for a in states if a.get("label") == "timeline-marquee-selection"]
        edges = [a["evidence"] for a in states if a.get("label") == "timeline-held-edge"]
        shifts = [a["evidence"].get("ids") for a in states if a.get("label") == "timeline-shift-selection"]
        if selections != [sorted(pairs)] or shifts != [["b", "b-audio"], sorted(pairs)] or edges != [row["scroll"], row["cancelledScroll"]]:
            return False, []
        keys = [(a.get("code"), a.get("modifiers")) for a in actions if a.get("kind") == "keyboard"]
        for expected_key, count in (((8, 0), 1), ((9, 0), 1), ((51, 131072), 3), ((51, 0), 1),
                                    ((6, 1048576), 12), ((6, 1179648), 3), ((1, 1048576), 1)):
            if keys.count(expected_key) != count:
                return False, []
        if not any(a.get("label") == "native-pointer" and a["evidence"].get("target") == "sync-track-unlock" for a in states):
            return False, []
        images = row["screenshots"]
        labels = ("marquee", "group-move", "duplicate", "razor", "trim-left", "trim-right", "ripple-refused",
                  "ripple-trim", "ripple-delete", "gap-close", "snap", "scroll-move", "scroll-cancel")
        if len(images) != len(labels) or len(set(images)) != len(labels):
            return False, []
        for label in labels:
            paths = [local(output, image) for image in images if image.endswith("-" + label + ".png")]
            if len(paths) != 1 or paths[0].stat().st_size < 1000 or not paths[0].read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
                return False, []
        return True, images
    except (OSError, ValueError, KeyError, TypeError, IndexError, StopIteration):
        return False, []
