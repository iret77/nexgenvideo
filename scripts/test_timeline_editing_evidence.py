import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from timeline_editing_evidence import timeline_editing_evidence


def fixture(root):
    # Synthetic validator fixtures are never native acceptance evidence.
    directory = root / "timeline-editing-150"
    package = directory / "Timeline editing.ngv"
    (package / "media").mkdir(parents=True)
    movie = b"synthetic validator media" * 100
    (package / "media/Moving picture and tone.mov").write_bytes(movie)
    (package / "media.json").write_text(json.dumps({"entries": [{"id": "source", "hasAudio": True,
        "source": {"project": {"relativePath": "media/Moving picture and tone.mov"}}}]}))
    def clip(key, start, duration=60, group=None, audio=False):
        value = {"id": key, "startFrame": start, "durationFrames": duration, "trimStartFrame": 30,
                 "trimEndFrame": 210 - duration, "speed": 1, "mediaRef": "source",
                 "fadeInFrames": 0, "fadeOutFrames": 0, "mediaType": "audio" if audio else "video"}
        if group:
            value["linkGroupId"] = group
        return value
    initial = {"fps": 30, "width": 160, "height": 90, "tracks": [
        {"id": "picture", "type": "video", "syncLocked": True, "clips": [clip("a", 30, group="pair-a"), clip("b", 150, group="pair-b"), clip("target", 300)]},
        {"id": "sound", "type": "audio", "syncLocked": True, "clips": [clip("a-audio", 30, group="pair-a", audio=True), clip("b-audio", 150, group="pair-b", audio=True)]},
        {"id": "sync", "type": "audio", "syncLocked": True, "clips": [clip("obstacle", 0, 120, audio=True), clip("follower", 150, audio=True)]}]}
    def write(name, value):
        (directory / (name + ".json")).write_text(json.dumps(value))
    def get(value, key):
        return next(c for t in value["tracks"] for c in t["clips"] if c["id"] == key)
    def uid(number):
        return "00000000-0000-4000-8000-" + str(number).zfill(12)
    def envelope(value, offset):
        definition = {"start": -offset, "end": 60 - offset,
            "head": {"anchor": -offset, "length": 0, "interpolation": "linear"},
            "tail": {"anchor": 60 - offset, "length": 0, "interpolation": "linear"}}
        value["effects"] = [{"id": uid(99), "type": "core.clip-envelope.v1", "enabled": True,
                             "params": {"definition": {"string": json.dumps(definition)}}}]
    write("initial", initial)
    moved = copy.deepcopy(initial)
    for key, start in (("a", 60), ("a-audio", 60), ("b", 180), ("b-audio", 180)):
        get(moved, key)["startFrame"] = start
    write("group-move", moved)
    duplicate = copy.deepcopy(initial)
    for ti, key, number, group in ((0, "a", 1, 11), (0, "b", 2, 12), (1, "a-audio", 3, 11), (1, "b-audio", 4, 12)):
        clone = copy.deepcopy(get(initial, key)); clone["startFrame"] += 60
        clone.update(id=uid(number), linkGroupId=uid(group)); duplicate["tracks"][ti]["clips"].append(clone)
    write("duplicate", duplicate)
    razor = copy.deepcopy(initial)
    for ti, key in ((0, "a"), (1, "a-audio")):
        left = get(razor, key); left.update(durationFrames=30, trimEndFrame=180); envelope(left, 0)
        right = copy.deepcopy(get(initial, key)); right.update(id=uid(20 + ti), startFrame=60, durationFrames=30, trimStartFrame=60, linkGroupId=uid(30))
        envelope(right, 30); razor["tracks"][ti]["clips"].append(right)
    write("razor", razor)
    for edge in ("left", "right"):
        trimmed = copy.deepcopy(initial)
        for key in ("a", "a-audio"):
            value = get(trimmed, key); value["durationFrames"] = 45
            if edge == "left":
                value.update(startFrame=45, trimStartFrame=45); envelope(value, 15)
            else:
                value["trimEndFrame"] = 165; envelope(value, 0)
        write("trim-" + edge, trimmed)
    write("ripple-refused", initial)
    unlocked = copy.deepcopy(initial); unlocked["tracks"][2]["syncLocked"] = False
    ripple_trim = copy.deepcopy(unlocked)
    for key in ("a", "a-audio"):
        get(ripple_trim, key).update(durationFrames=45, trimEndFrame=165); envelope(get(ripple_trim, key), 0)
    for key, start in (("b", 135), ("b-audio", 135), ("target", 285)):
        get(ripple_trim, key)["startFrame"] = start
    write("ripple-trim", ripple_trim)
    closed = copy.deepcopy(unlocked)
    for key, start in (("b", 90), ("b-audio", 90), ("target", 240)):
        get(closed, key)["startFrame"] = start
    write("gap-close", closed)
    deleted = copy.deepcopy(closed)
    for track in deleted["tracks"]:
        track["clips"] = [c for c in track["clips"] if c["id"] not in ("a", "a-audio")]
    write("ripple-delete", deleted)
    snapped = copy.deepcopy(unlocked)
    get(snapped, "a")["startFrame"] = 240; get(snapped, "a-audio")["startFrame"] = 240
    write("snap", snapped)
    before_scroll = copy.deepcopy(unlocked)
    before_scroll["tracks"][0]["clips"].pop()
    write("before-scroll", before_scroll); write("scroll-cancel", before_scroll)
    final = copy.deepcopy(before_scroll)
    get(final, "a")["startFrame"] = 224; get(final, "a-audio")["startFrame"] = 224
    write("scroll-move", final)
    (package / "project.json").write_text(json.dumps(final))
    scroll = {"initialX": 0, "initialWidth": 600, "pixelsPerFrame": 4, "firstX": 28, "heldX": 360,
              "stoppedX": 360, "afterStopX": 360, "deltaFrames": 194, "cancelled": False, "dragEvents": 1}
    cancelled = {**scroll, "cancelled": True, "deltaFrames": 0}
    row = {"event": "timeline-editing-owner", "scale": 1.5, "effectiveScale": 1.5, "viewport": [960, 640],
           "directory": directory.name, "project": package.name, "sourceSHA256": hashlib.sha256(movie).hexdigest(),
           "scroll": scroll, "cancelledScroll": cancelled}
    actions = []
    for target in ("marquee-pairs", "marquee-pairs", "shift-remove-pair-a", "shift-add-pair-a", "ripple-trim-right", "group-move", "option-duplicate", "razor-60", "trim-left", "trim-right", "select-gap-90-150", "snap-raw-239-to-240"):
        actions.append({"kind": "verified-state", "label": "timeline-gesture", "evidence": {
            "target": target, "delivered": True, "modifiers": 524288 if target == "option-duplicate" else 131072 if target in ("shift-remove-pair-a", "shift-add-pair-a", "ripple-trim-right") else 0}})
    actions.append({"kind": "verified-state", "label": "timeline-marquee-selection", "evidence": {"ids": ["a", "a-audio", "b", "b-audio"]}})
    actions += [{"kind": "verified-state", "label": "timeline-shift-selection", "evidence": {"ids": ids}} for ids in (["b", "b-audio"], ["a", "a-audio", "b", "b-audio"])]
    actions += [{"kind": "verified-state", "label": "timeline-held-edge", "evidence": value} for value in (scroll, cancelled)]
    actions.append({"kind": "verified-state", "label": "native-pointer", "evidence": {"target": "sync-track-unlock"}})
    for code, mods, count in ((8, 0, 1), (9, 0, 1), (51, 131072, 3), (51, 0, 1), (6, 1048576, 12), (6, 1179648, 3), (1, 1048576, 1)):
        actions += [{"kind": "keyboard", "code": code, "modifiers": mods} for _ in range(count)]
    row["interactions"] = actions
    row["screenshots"] = [directory.name + "-" + label + ".png" for label in (
        "marquee", "group-move", "duplicate", "razor", "trim-left", "trim-right", "ripple-refused", "ripple-trim", "ripple-delete", "gap-close", "snap", "scroll-move", "scroll-cancel")]
    for image in row["screenshots"]:
        (root / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"synthetic pixels" * 100)
    return [row, {"event": "completed", "case": "timelineediting", "scale": 1.5}], directory, package


class TimelineEditingEvidenceTests(unittest.TestCase):
    def test_complete_shape_and_every_required_native_action(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rows, _, _ = fixture(root)
            self.assertTrue(timeline_editing_evidence(rows, root, 1.5)[0])
            for index in range(len(rows[0]["interactions"])):
                changed = copy.deepcopy(rows); changed[0]["interactions"].pop(index)
                self.assertFalse(timeline_editing_evidence(changed, root, 1.5)[0], index)
            self.assertFalse(timeline_editing_evidence(rows, root, 1.25)[0])

    def test_wrong_source_ranges_links_sync_lock_or_saved_state_fail(self):
        cases = (("group-move", "a-audio", "startFrame", 30), ("duplicate", "a", "startFrame", 31),
                 ("razor", "a", "durationFrames", 29), ("trim-left", "a", "trimStartFrame", 30),
                 ("trim-right", "a-audio", "trimEndFrame", 150), ("ripple-refused", "follower", "startFrame", 90),
                 ("ripple-trim", "b-audio", "startFrame", 150), ("ripple-delete", "follower", "startFrame", 90), ("gap-close", "a", "startFrame", 0),
                 ("snap", "a", "startFrame", 239), ("scroll-cancel", "a", "startFrame", 224))
        for name, key, field, value in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); rows, directory, _ = fixture(root)
                path = directory / (name + ".json"); timeline = json.loads(path.read_text())
                next(c for t in timeline["tracks"] for c in t["clips"] if c["id"] == key)[field] = value
                path.write_text(json.dumps(timeline))
                self.assertFalse(timeline_editing_evidence(rows, root, 1.5)[0])

    def test_autoscroll_requires_stationary_progress_beyond_viewport_and_stop(self):
        for field, value in (("dragEvents", 9), ("heldX", 28), ("afterStopX", 388), ("deltaFrames", 190), ("initialWidth", 1200)):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); rows, _, _ = fixture(root)
                rows[0]["scroll"][field] = value
                self.assertFalse(timeline_editing_evidence(rows, root, 1.5)[0])

    def test_envelope_original_clock_and_media_bytes_are_required(self):
        for defect in ("envelope", "media", "save", "screenshot", "path"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); rows, directory, package = fixture(root)
                if defect == "envelope":
                    path = directory / "trim-left.json"; timeline = json.loads(path.read_text())
                    value = timeline["tracks"][0]["clips"][0]["effects"][0]["params"]["definition"]
                    envelope = json.loads(value["string"]); envelope["tail"]["anchor"] = 60
                    value["string"] = json.dumps(envelope); path.write_text(json.dumps(timeline))
                elif defect == "media":
                    (package / "media/Moving picture and tone.mov").write_bytes(b"changed" * 1000)
                elif defect == "save":
                    (package / "project.json").write_bytes((directory / "initial.json").read_bytes())
                elif defect == "screenshot":
                    (root / rows[0]["screenshots"][0]).write_bytes(b"not PNG" * 1000)
                else:
                    rows[0]["directory"] = "../escaped"
                self.assertFalse(timeline_editing_evidence(rows, root, 1.5)[0])
