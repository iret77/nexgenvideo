import copy
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from media_browser_owner_evidence import FLAGS, CAPTURES, media_browser_owner_evidence, validate


class MediaBrowserOwnerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)
        self.name = "media-browser-150"
        self.directory = self.output / self.name
        self.project = self.directory / "Browser.ngv"
        (self.project / "media").mkdir(parents=True)
        self.identity = "00000000-0000-4000-8000-000000000001"
        self.write(self.project / "ngv.json", {"id": self.identity})
        self.sources = []
        self.manifest = {"entries": [], "folders": [
            {"id": "incoming", "name": "Incoming"}, {"id": "selected", "name": "Selected", "parentFolderId": "incoming"}]}
        self.caches = {}
        for identifier, name, kind, duration in (("a", "A.mov", "video", 4), ("b", "B.mov", "video", 3),
                                                ("c", "C.wav", "audio", 2), ("d", "D.png", "image", 5)):
            data = ("synthetic validator source " + name).encode()
            file = self.project / "media" / name
            file.write_bytes(data)
            digest = self.digest(file)
            self.sources.append({"id": identifier, "filename": name, "type": kind, "duration": duration, "sha256": digest})
            self.manifest["entries"].append({"id": identifier, "originalFilename": name, "type": kind, "duration": duration,
                "folderId": "incoming", "source": {"project": {"relativePath": "media/" + name}}})
            if identifier == "c":
                cache = self.directory / "isolated-transcript.json"
                self.write(cache, {"text": "The harbor lights.", "language": "en-US", "words": [],
                                   "segments": [{"text": "The harbor lights.", "start": 0.5, "end": 1.5}]})
            else:
                cache = self.directory / (name + ".embed")
                header = json.dumps({"model": "native-search-fixture", "modelVersion": 1, "samplerVersion": 1, "dim": 2, "count": 1}).encode()
                values = (0, 0, 0, -1, 0) if identifier == "d" else (1.5, 1, 2, 1 if identifier == "a" else -1, 0)
                cache.write_bytes(b"PALMEMB1" + struct.pack("<I", len(header)) + header + struct.pack("<dddee", *values))
            self.caches[identifier] = {"file": cache.name, "sha256": self.digest(cache), "sourceSHA256": digest}
        self.timeline = {"width": 320, "height": 180, "fps": 30, "settingsConfigured": True, "tracks": [
            {"id": "vt", "type": "video", "clips": [{"id": "v", "mediaRef": "a", "startFrame": 0, "trimStartFrame": 30, "durationFrames": 30}]},
            {"id": "at", "type": "audio", "clips": [{"id": "s", "mediaRef": "c", "startFrame": 45, "trimStartFrame": 15, "durationFrames": 30}]}]}
        self.write(self.project / "project.json", self.timeline)
        self.write(self.project / "media.json", self.manifest)
        clips = [{"id": clip["id"], "trackID": track["id"], "type": track["type"], "sourceID": clip["mediaRef"],
                  "startFrame": clip["startFrame"], "trimStartFrame": clip["trimStartFrame"], "durationFrames": clip["durationFrames"]}
                 for track in self.timeline["tracks"] for clip in track["clips"]]
        saved = {"timelineSHA256": self.digest(self.project / "project.json"), "manifestSHA256": self.digest(self.project / "media.json")}
        interactions = [{"kind": "pointer", "id": value} for value in (
            "editor.workspace.media", "editor.workspace.edit", "media.action.Import", "media.action.New Folder",
            "media.asset.a", "media.moment.a.1.0", "media.spoken.c.0.5")]
        interactions += [{"kind": "modified-pointer", "id": "media.asset." + asset, "command": command, "shift": shift}
                         for asset, command, shift in (("c", True, False), ("a", True, False), ("c", False, True), ("b", True, False))]
        interactions += [{"kind": "menu", "id": "media.menu." + menu, "item": title, "closed": True} for menu, title in (
            ("View", "List"), ("View", "Grid"), ("View", "Folders"), ("View", "Small"), ("View", "Extra Large"),
            ("Sort", "Name"), ("Filter", "AI Generated"), ("Filter", "Clear Filters"))]
        interactions += [{"kind": "cross-view-drag", "id": source, "destination": target, "queuedEvents": 14,
                          "sourcePoint": [10, 10], "destinationPoint": [50, 50]} for source, target in (
            ("media.selection-surface", "marquee"), ("media.asset.a", "Selected folder"),
            ("media.moment.a.1.0", "timeline frame 0"), ("media.spoken.c.0.5", "timeline frame 45"))]
        interactions += [{"kind": "keyboard", "characters": key, "modifiers": (1 << 20) | ((1 << 17) if key == "Z" else 0)}
                         for key in ("z", "z", "Z", "s")]
        interactions += [{"kind": "text", "field": {"id": identifier, "actual": value, "expected": value, "editorText": value,
            "commitInput": "Tab", "fontPointSize": 19.5, "stage": "commit-requested", "owner": "NSTextField",
            "ownsEditor": False, "focusLeftTarget": True, "requiresFocusExit": identifier.startswith("media.folder-rename.")}} for identifier, value in (("media.search", "harbor"), ("media.folder-rename.selected", "Selected"))]
        interactions += [{"kind": "visible-group", "ids": ["media.menu.View", "media.menu.Sort", "media.menu.Filter"],
                          "viewport": [0, 0, 960, 640], "frames": [[10, 10, 60, 20], [80, 10, 60, 20], [150, 10, 60, 20]]}]
        states = {
            "command selection": {"ids": ["a", "c"], "filenames": ["A.mov", "C.wav"]},
            "command deselection": {"ids": ["c"], "filenames": ["C.wav"]},
            "shift range": {"ids": ["a", "b", "c"], "filenames": ["A.mov", "B.mov", "C.wav"]},
            "filtered select all": {"ids": ["d"], "filenames": ["D.png"]},
            "marquee selection": {"ids": ["a", "b"], "filenames": ["A.mov", "B.mov"]},
            "name order": {"ids": ["a", "b", "c", "d"]}, "duration order": {"ids": ["d", "a", "b", "c"]},
            "filtered selection pruned": {"visibleIDs": ["d"], "selectedIDs": []},
            "AI filter excludes imported files": {"visibleIDs": [], "selectedIDs": []},
            "marquee geometry": {"ids": ["a", "b"], "emptyStart": True, "first": [8, 40, 100, 20], "last": [8, 64, 100, 20],
                "surface": [0, 0, 200, 150], "start": [4, 41], "end": [58, 83], "selection": [4, 41, 54, 42]},
            "thumbnail dimensions": {"id": "a", "small": [0, 0, 80, 60], "large": [0, 0, 160, 120]},
            "group folder drop": {"ids": ["a", "b"], "from": "incoming", "to": "selected", "folder": "Selected"},
            "group folder drop undo": {"ids": ["a", "b"], "restoredFolder": "incoming", "destinationRetained": True},
            "moment source time": {"filename": "A.mov", "frame": 30}, "spoken source time": {"filename": "C.wav", "frame": 15},
            "moment drop binding": {"clips": clips[:1]}, "spoken drop binding": {"clips": clips},
            "segment undo redo": {"undoClips": clips[:1], "redoClips": clips, "unsaved": True},
            "native browser save": {"projectID": self.identity, "clips": clips, "hashes": saved},
        }
        filtered_all = states.pop("filtered select all")
        filtered_pruned = states.pop("filtered selection pruned")
        interactions += [{"kind": "verified-state", "label": label, "evidence": evidence} for label, evidence in states.items()]
        interactions += [
            {"kind": "menu", "id": "media.menu.Filter", "item": "Image", "closed": True},
            {"kind": "verified-state", "label": "filtered selection pruned", "evidence": filtered_pruned},
            {"kind": "pointer", "id": "media.asset.d"},
            {"kind": "keyboard", "characters": "a", "modifiers": 1 << 20},
            {"kind": "verified-state", "label": "filtered select all", "evidence": filtered_all},
            {"kind": "menu", "id": "media.menu.Filter", "item": "Video", "closed": True},
            {"kind": "verified-state", "label": "filtered name order", "evidence": {"ids": ["a", "b", "d"]}},
            {"kind": "menu", "id": "media.menu.Sort", "item": "Duration", "closed": True},
            {"kind": "verified-state", "label": "filtered duration order", "evidence": {"ids": ["d", "a", "b"]}},
            {"kind": "pointer", "id": "media.asset.d"},
            {"kind": "modified-pointer", "id": "media.asset.a", "command": False, "shift": True},
            {"kind": "verified-state", "label": "filtered sorted shift range", "evidence": {
                "ids": ["a", "d"], "filenames": ["A.mov", "D.png"]}},
            {"kind": "verified-state", "label": "filtered range context", "evidence": {
                "beforeOrder": ["a", "b", "d"], "visibleIDs": ["d", "a", "b"], "selectedIDs": ["a", "d"],
                "anchorID": "d", "targetID": "a", "hiddenIDs": ["c"]}},
        ]
        interactions += [{"kind": "verified-state", "label": "segment drop geometry", "evidence": {
            "id": identifier, "frame": frame, "newTrackIndex": track, "pixelsPerFrame": 4,
            "point": [frame * 4 + 2, 30], "viewport": [0, 0, 500, 100]}}
            for identifier, frame, track in (("media.moment.a.1.0", 0, 0), ("media.spoken.c.0.5", 45, 1))]
        images = [self.name + "-" + label + ".png" for label in sorted(CAPTURES)]
        for name in images:
            (self.output / name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"synthetic-validator-image" * 100)
        self.row = {"event": "media-browser-owner", "scale": 1.5, "effectiveScale": 1.5, "backingScale": 2,
            "viewport": [960, 640], **dict.fromkeys(FLAGS, True), "isolatedQueryEncoder": True,
            "isolatedTranscriptInput": True, "liveSearchModel": False, "projectID": self.identity,
            "project": self.name + "/Browser.ngv", "saved": saved, "sources": self.sources, "searchCaches": self.caches,
            "clips": clips, "interactions": interactions, "screenshots": images, "progress": self.name + ".json"}
        self.row = json.loads(json.dumps(self.row))
        self.persist(self.row)

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value))

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def persist(self, row):
        self.write(self.output / row["progress"], row)

    def test_complete_independent_fixture(self):
        self.assertTrue(validate(self.row, self.output, 1.5))
        completed = {"event": "completed", "case": "mediabrowser", "scale": 1.5}
        self.assertTrue(media_browser_owner_evidence([self.row, completed], self.output, 1.5)[0])
        self.assertFalse(media_browser_owner_evidence([self.row], self.output, 1.5)[0])
        self.assertFalse(media_browser_owner_evidence([self.row, completed, {"event": "failed"}], self.output, 1.5)[0])

    def test_each_native_action_and_state_is_required_with_synchronized_progress(self):
        for index in range(len(self.row["interactions"])):
            changed = copy.deepcopy(self.row)
            changed["interactions"].pop(index)
            self.persist(changed)
            self.assertFalse(validate(changed, self.output, 1.5), index)
        self.persist(self.row)

    def test_flags_and_actual_viewport_scale_are_required(self):
        for key, value in [(flag, False) for flag in FLAGS] + [
            ("effectiveScale", 1), ("viewport", [1440, 960]), ("backingScale", 0), ("liveSearchModel", True)]:
            changed = copy.deepcopy(self.row); changed[key] = value; self.persist(changed)
            self.assertFalse(validate(changed, self.output, 1.5), key)
        changed = copy.deepcopy(self.row); changed["backingScale"] = 1; self.persist(changed)
        self.assertTrue(validate(changed, self.output, 1.5))

    def test_unscaled_font_and_foreign_project_identity_fail(self):
        changed = copy.deepcopy(self.row)
        next(item for item in changed["interactions"] if item.get("kind") == "text")["field"]["fontPointSize"] = 13
        self.persist(changed)
        self.assertFalse(validate(changed, self.output, 1.5))
        self.persist(self.row)
        self.write(self.project / "ngv.json", {"id": "00000000-0000-4000-8000-000000000002"})
        self.assertFalse(validate(self.row, self.output, 1.5))

    def test_wrong_literal_ranges_fail_even_after_all_report_hashes_are_updated(self):
        changed = copy.deepcopy(self.row)
        self.timeline["tracks"][1]["clips"][0]["trimStartFrame"] = 14
        self.write(self.project / "project.json", self.timeline)
        changed["saved"]["timelineSHA256"] = self.digest(self.project / "project.json")
        changed["clips"][1]["trimStartFrame"] = 14
        for item in changed["interactions"]:
            if item.get("label") in ("spoken drop binding", "native browser save"):
                item["evidence"]["clips"] = changed["clips"]
            if item.get("label") == "segment undo redo": item["evidence"]["redoClips"] = changed["clips"]
            if item.get("label") == "native browser save": item["evidence"]["hashes"] = changed["saved"]
        self.persist(changed)
        self.assertFalse(validate(changed, self.output, 1.5))

    def test_image_index_must_use_still_times_even_with_new_hash(self):
        changed = copy.deepcopy(self.row)
        file = self.directory / "D.png.embed"
        data = bytearray(file.read_bytes()); length = struct.unpack_from("<I", data, 8)[0]
        struct.pack_into("<ddd", data, 12 + length, 1.5, 1, 2); file.write_bytes(data)
        changed["searchCaches"]["d"]["sha256"] = self.digest(file)
        self.persist(changed)
        self.assertFalse(validate(changed, self.output, 1.5))

    def test_wrong_duration_sort_and_nonempty_marquee_start_fail(self):
        for label, key, value in (("duration order", "ids", ["a", "b", "c", "d"]),
                                  ("marquee geometry", "start", [20, 50])):
            changed = copy.deepcopy(self.row)
            next(item for item in changed["interactions"] if item.get("label") == label)["evidence"][key] = value
            self.persist(changed)
            self.assertFalse(validate(changed, self.output, 1.5))

    def test_filtered_shift_uses_new_order_and_excludes_hidden_assets(self):
        for key, value in (("visibleIDs", ["a", "b", "d"]), ("selectedIDs", ["a", "b", "d"]),
                           ("selectedIDs", ["a", "c", "d"]), ("hiddenIDs", []),
                           ("anchorID", "a"), ("targetID", "d"), ("beforeOrder", ["d", "a", "b"])):
            changed = copy.deepcopy(self.row)
            next(item for item in changed["interactions"] if item.get("label") == "filtered range context")["evidence"][key] = value
            self.persist(changed)
            self.assertFalse(validate(changed, self.output, 1.5), key)
        changed = copy.deepcopy(self.row)
        indexes = [index for index, item in enumerate(changed["interactions"])
            if item.get("label") in ("filtered name order", "filtered duration order")]
        left, right = indexes
        changed["interactions"][left], changed["interactions"][right] = changed["interactions"][right], changed["interactions"][left]
        self.persist(changed)
        self.assertFalse(validate(changed, self.output, 1.5))

        for mutation in ("reversed-clicks", "command-click", "foreign-click", "late-select-all", "missing-image-filter", "early-command-a", "missing-command-a"):
            changed = copy.deepcopy(self.row)
            rows = changed["interactions"]
            shift = next(i for i, row in enumerate(rows) if row.get("kind") == "modified-pointer" and row.get("id") == "media.asset.a" and row.get("shift") is True)
            if mutation == "reversed-clicks":
                rows[shift - 1]["id"], rows[shift]["id"] = "media.asset.a", "media.asset.d"
            elif mutation == "command-click":
                rows[shift].update(command=True, shift=False)
            elif mutation == "foreign-click":
                rows.insert(shift, {"kind": "pointer", "id": "media.asset.b"})
            elif mutation == "late-select-all":
                before = next(i for i, row in enumerate(rows) if row.get("label") == "filtered select all")
                after = next(i for i, row in enumerate(rows) if row.get("item") == "Video")
                rows[before], rows[after] = rows[after], rows[before]
            elif mutation == "missing-image-filter":
                rows[:] = [row for row in rows if row.get("item") != "Image"]
            elif mutation == "early-command-a":
                command = next(i for i, row in enumerate(rows) if row.get("kind") == "keyboard" and row.get("characters") == "a")
                before_filter = next(i for i, row in enumerate(rows) if row.get("kind") == "menu" and row.get("item") == "Image")
                rows.insert(before_filter, rows.pop(command))
            else:
                rows[:] = [row for row in rows if not (row.get("kind") == "keyboard" and row.get("characters") == "a")]
            self.persist(changed)
            self.assertFalse(validate(changed, self.output, 1.5), mutation)

    def test_clipped_or_overlapping_controls_and_uncommitted_text_fail(self):
        for frame in ([950, 10, 60, 20], [85, 10, 60, 20]):
            changed = copy.deepcopy(self.row)
            next(item for item in changed["interactions"] if item.get("kind") == "visible-group")["frames"][0] = frame
            self.persist(changed); self.assertFalse(validate(changed, self.output, 1.5))
        changed = copy.deepcopy(self.row)
        next(item for item in changed["interactions"] if item.get("kind") == "text")["field"]["actual"] = ""
        self.persist(changed); self.assertFalse(validate(changed, self.output, 1.5))

    def test_source_cache_screenshot_and_progress_tampering_fail(self):
        changed = copy.deepcopy(self.row)
        changed["searchCaches"]["a"]["sourceSHA256"] = self.sources[1]["sha256"]
        self.persist(changed); self.assertFalse(validate(changed, self.output, 1.5))
        self.persist(self.row)
        (self.project / "media" / "A.mov").write_bytes(b"substituted actual bytes")
        self.assertFalse(validate(self.row, self.output, 1.5))

    def test_screenshot_and_failed_progress_reject_without_other_tampering(self):
        changed = copy.deepcopy(self.row); changed["failure"] = "unclaimed native field"
        self.persist(changed); self.assertFalse(validate(self.row, self.output, 1.5))
        self.persist(self.row)
        (self.output / self.row["screenshots"][0]).write_bytes(b"not PNG")
        self.assertFalse(validate(self.row, self.output, 1.5))
