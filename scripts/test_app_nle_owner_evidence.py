import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from app_nle_owner_evidence import APP_MENUS, CAPTURES, ROOT_FLAGS, EDIT_FLAGS, VIEW_FLAGS, HELP_FLAGS, app_nle_owner_evidence, validate


class AppNLEEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        self.name = "app-nle-owner-150"
        directory = self.output / self.name
        directory.mkdir()
        image = b"\x89PNG\r\n\x1a\n" + b"unit-fixture" * 150
        movie = b"unit-only-output-bytes"
        (directory / "capture.png").write_bytes(image)
        (directory / "film.mp4").write_bytes(movie)
        image_sha, movie_sha = hashlib.sha256(image).hexdigest(), hashlib.sha256(movie).hexdigest()
        source_ids = ["source-a", "source-b"]
        controls = {"home.new", "home.open", "home.project.actual-id", "project.settings.open", "preview.capture-frame",
            "preview.canvas", "preview.transport.play.fill", "preview.transport.pause.fill", "timeline.zoom.in", "timeline.zoom.out",
            "inspector.crop.edit", "project.mismatch.keep", "editor.panel.sidebar", "editor.panel.inspector",
            "source.overwrite.source-b", "source.clear.source-b"}
        controls |= {"editor.workspace." + key for key in ("media", "production", "postproduction", "export", "edit")}
        controls |= {"source." + kind + "." + asset for asset in source_ids for kind in ("in", "out", "insert")}
        interactions = [{"kind": "pointer", "id": key} for key in sorted(controls)]
        interactions += [{"kind": "verified-state", "label": "application-menu", "evidence": {"path": path, "closed": True}}
            for path in sorted(APP_MENUS)]
        interactions += [{"kind": "menu", "id": key, "item": value, "closed": True} for key, value in (
            ("project.settings.Aspect Ratio", "9:16"), ("project.settings.Resolution", "720p"),
            ("project.settings.Frame Rate", "25 fps"), ("project.settings.Frame Rate", "30 fps"),
            ("preview.zoom", "200%"), ("preview.zoom", "50%"), ("preview.zoom", "Fit"))]
        interactions += [{"kind": "context-menu", "path": [value], "closed": True} for value in (
            "Reveal in Finder", "Remove from Recents", "Delete Project", "Previous Preview", "Next Preview",
            "Close Source", "Clear Source History", "Rename")]
        interactions += [{"kind": "keyboard", "characters": key} for key, count in {"a": 2, "x": 2, "c": 1, "v": 2, "z": 8, "Z": 6}.items() for _ in range(count)]
        interactions += [{"kind": "verified-state", "label": "native-drag", "evidence": {"target": target, "from": [10, 10], "to": [20, 20]}}
            for target in ("editor.splitter", "track.height", "preview.transform.move", "preview.crop.corner")]
        interactions += [{"kind": "verified-state", "label": "native-clip-menu", "evidence": {"item": item, "closed": True}}
            for item in ("Link", "Unlink")]
        original, copied = "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"
        typography = {"id": "media.rename.source-a", "effectiveScale": 1.5, "ownerFontPointSize": 19.5,
            "editorFontPointSize": 19.5, "ownsEditor": True, "viewport": [960, 640], "backingScale": 2}
        states = {
            "native-interface-typography": typography,
            "native-viewer-wheel": {"input": "command-wheel-then-plain-wheel", "zoom": 2,
                "anchoredOffset": [2, 2], "pannedOffset": [3, 3], "timelineUnchanged": True},
            "native-pan-overlay-isolation": {"transformDragged": True, "cropDragged": True, "exactUndo": True, "restoredTimelineSHA256": "a" * 64},
            "native-track-controls": {"visibility": True, "mute": True, "syncLock": True, "exactUndoRedo": True, "heightBefore": 50, "heightAfter": 74},
            "native-project-persistence": {"newID": original, "saveAsID": copied, "originalPreserved": True,
                "copyReadbackEqual": True, "removedRecentFilePreserved": True, "confirmedCopyInTrash": True},
            "text-versus-timeline-clipboard": {"textUndoIsolated": True, "cutUndoRedo": True, "pastePreservedSourceAndLink": True},
            "finder-project-selection": {"exactSelectedURL": True},
        }
        interactions += [{"kind": "verified-state", "label": key, "evidence": value} for key, value in states.items()]
        # JSON-normalize the fixture so progress equality tests compare actual JSON types.
        interactions = json.loads(json.dumps(interactions))
        screenshots = [self.name + "-" + label + ".png" for label in sorted(CAPTURES)]
        for filename in screenshots:
            (self.output / filename).write_bytes(image)
        self.row = {**dict.fromkeys(ROOT_FLAGS, True), "event": "app-nle-owner", "scale": 1.5,
            "viewport": [960, 640], "homeViewport": [960, 720], "originalID": original, "copyID": copied,
            "timelineSHA256": "a" * 64, "mediaHashes": {"source-a": "b" * 64, "source-b": "c" * 64, "capture": image_sha},
            "editing": {**dict.fromkeys(EDIT_FLAGS, True), "sourceIDs": source_ids, "fps": 25, "insertFrames": 125,
                "overwriteFrames": 100, "timelineSHA256": "d" * 64, "typography": typography,
                "capture": {"sourceID": "source-a", "newAssetID": "capture", "frame": 50, "fps": 25,
                    "pixelsSHA256": "e" * 64, "file": "capture.png", "fileSHA256": image_sha}},
            "viewing": {**dict.fromkeys(VIEW_FLAGS, True), "nativeWorkspaces": ["media", "production", "postproduction", "export", "edit"], "nativeLayouts": ["default", "media", "vertical"], "unchangedTimelineSHA256": "a" * 64},
            "help": dict.fromkeys(HELP_FLAGS, True),
            "portraitExport": {"file": "film.mp4", "sha256": movie_sha, "width": 720, "height": 1280, "fps": 30, "frames": 150, "qc": True},
            "screenshots": screenshots, "interactions": interactions, "progress": self.name + ".json"}
        self.persist(self.row)

    def persist(self, row):
        (self.output / row["progress"]).write_text(json.dumps(row))

    def test_complete_report_and_all_native_inputs(self):
        self.assertTrue(validate(self.row, self.output, 1.5))
        for index in range(len(self.row["interactions"])):
            changed = copy.deepcopy(self.row)
            changed["interactions"].pop(index)
            self.persist(changed)
            self.assertFalse(validate(changed, self.output, 1.5), index)
        self.persist(self.row)

    def test_each_independent_owner_obligation_is_required(self):
        for path, flags in (((), ROOT_FLAGS), (("editing",), EDIT_FLAGS), (("viewing",), VIEW_FLAGS), (("help",), HELP_FLAGS)):
            for flag in flags:
                changed = copy.deepcopy(self.row)
                target = changed
                for key in path:
                    target = target[key]
                target[flag] = False
                self.persist(changed)
                self.assertFalse(validate(changed, self.output, 1.5), (path, flag))

    def test_wrong_identity_clock_pan_or_capture_is_rejected(self):
        for path, value in (
            (("copyID",), self.row["originalID"]), (("viewport",), [1000, 800]),
            (("portraitExport", "frames"), 149), (("portraitExport", "fps"), 25),
            (("editing", "capture", "newAssetID"), "source-a"), (("editing", "capture", "frame"), 49),
            (("editing", "overwriteFrames"), 125), (("viewing", "unchangedTimelineSHA256"), "0" * 64),
        ):
            changed = copy.deepcopy(self.row)
            target = changed
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            self.persist(changed)
            self.assertFalse(validate(changed, self.output, 1.5), path)
        changed = copy.deepcopy(self.row)
        wheel = next(item["evidence"] for item in changed["interactions"] if item.get("label") == "native-viewer-wheel")
        wheel["pannedOffset"] = wheel["anchoredOffset"]
        self.persist(changed)
        self.assertFalse(validate(changed, self.output, 1.5))

    def test_measured_typography_is_independent_of_backing_pixels(self):
        for key, value in (("effectiveScale", 1), ("ownerFontPointSize", 13), ("editorFontPointSize", 13),
                           ("ownsEditor", False), ("viewport", [1440, 960]), ("backingScale", 0)):
            changed = copy.deepcopy(self.row)
            changed["editing"]["typography"][key] = value
            next(item for item in changed["interactions"] if item.get("label") == "native-interface-typography")["evidence"] = changed["editing"]["typography"]
            self.persist(changed)
            self.assertFalse(validate(changed, self.output, 1.5), key)
        changed = copy.deepcopy(self.row)
        changed["editing"]["typography"]["backingScale"] = 1
        next(item for item in changed["interactions"] if item.get("label") == "native-interface-typography")["evidence"] = changed["editing"]["typography"]
        self.persist(changed)
        self.assertTrue(validate(changed, self.output, 1.5))

    def test_independent_artifact_tampering_and_missing_completion(self):
        complete = {"event": "completed", "case": "appnle", "scale": 1.5}
        self.assertTrue(app_nle_owner_evidence([self.row, complete], self.output, 1.5)[0])
        self.assertFalse(app_nle_owner_evidence([self.row], self.output, 1.5)[0])
        self.assertFalse(app_nle_owner_evidence([self.row, complete, {"event": "failed"}], self.output, 1.5)[0])
        movie = self.output / self.name / "film.mp4"
        movie.write_bytes(b"changed-output")
        self.assertFalse(validate(self.row, self.output, 1.5))

    def test_progress_failure_and_screenshot_substitution(self):
        changed = copy.deepcopy(self.row)
        changed["failure"] = "native window failed"
        self.persist(changed)
        self.assertFalse(validate(self.row, self.output, 1.5))
        self.persist(self.row)
        screenshot = self.output / self.row["screenshots"][0]
        screenshot.write_bytes(b"not a screenshot")
        self.assertFalse(validate(self.row, self.output, 1.5))
