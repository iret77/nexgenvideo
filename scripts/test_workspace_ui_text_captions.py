import copy
import json
from pathlib import Path
import tempfile
import unittest

from workspace_ui_acceptance import text_captions_evidence


class TextCaptionEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        images = ["text-captions-150-" + name + ".png" for name in
            ("styled-title", "two-title-layers", "caption-cancel", "caption-stale", "generated-captions", "caption-cleanup-undo-redo")]
        for image in images:
            (self.output / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"image" * 250)
        self.row = {"event": "text-captions", "scale": 1.5, "viewport": [960, 640], "interfaceScale": 1.5, "transcriptionSeam": "source-bound-client", "baseline": "baseline.json", "project": "Titles.ngv",
            "screenshots": images, "liveTranscription": False, "isolatedSpeechRequests": 3,
            "captionStart": 30, "captionDuration": 45,
            **{key: True for key in ("nativeTitleCreationUndoRedo", "nativeTextUndo", "nativeTitleStyle",
                "playerItemCompositionTitle", "independentTextLayers", "nativeCaptionOptions", "nativeCaptionCancel",
                "nativeCaptionStaleRefusal", "nativeCaptionPlacement", "nativeFillerUndoRedo", "nativeSaveAndReopen")}}
        fields = [("text.content", "Release title"), ("text.content", "Second layer"),
            ("inspector.value.Text size", "72"), ("inspector.value.Text opacity", "60"), ("inspector.value.Caption size", "36")]
        self.row["interactions"] = [{"kind": "pointer", "id": key} for key, count in {
            "editing.add-text": 3, "captions.generate": 3, "captions.cancel": 1,
            "text.toggle.Background": 1, "text.toggle.Border": 1, "text.toggle.Shadow": 1,
            "text.alignment": 1, "captions.censor": 1}.items() for _ in range(count)]
        self.row["interactions"] += [{"kind": "keyboard", "characters": key} for key in ["z"] * 4 + ["Z"] * 2 + ["s"]]
        self.row["interactions"] += [{"kind": "menu", "id": key, "path": [label], "closed": True} for key, label in
            (("captions.source", "A1 · 1 clip"), ("captions.language", "English (United States)"), ("captions.case", "UPPERCASE"), ("captions.actions", "Remove filler words"))]
        self.row["interactions"] += [{"kind": "text", "field": {"id": key, "expected": value, "actual": value,
            "requiresFocusExit": True, "focusLeftTarget": True, "fontPointSize": 19.5}} for key, value in fields]
        self.saved = {"tracks": [{"clips": [
            {"mediaType": "text", "textContent": "Release title", "opacity": 0.6,
                "textStyle": {"fontSize": 72, "alignment": "right", "background": {"enabled": True},
                    "border": {"enabled": True}, "shadow": {"enabled": False}}},
            {"mediaType": "text", "textContent": "Second layer", "textStyle": {"fontSize": 48, "alignment": "center"}},
            {"mediaType": "text", "textContent": "HELLO WORLD.", "startFrame": 30, "durationFrames": 45,
                "captionGroupId": "group", "textStyle": {"fontSize": 36}}]}]}
        baseline = {"tracks": [{"clips": [
            {"id": "visual", "mediaType": "video", "mediaRef": "picture", "startFrame": 0, "durationFrames": 180},
            {"id": "voice-clip", "mediaType": "audio", "mediaRef": "voice", "startFrame": 0, "durationFrames": 180}]}]}
        (self.output / "baseline.json").write_text(json.dumps(baseline))
        self.saved["tracks"] += copy.deepcopy(baseline["tracks"])
        project = self.output / "Titles.ngv"
        project.mkdir()
        self.timeline = project / "project.json"
        self.timeline.write_text(json.dumps(self.saved))
        self.complete = {"event": "completed", "case": "textcaptions", "scale": 1.5}

    def accepts(self, row):
        return text_captions_evidence([row, self.complete], self.output, 1.5)[0]

    def test_each_native_input_and_capture_is_required(self):
        self.assertTrue(self.accepts(self.row))
        for key in ("interactions", "screenshots"):
            for index in range(len(self.row[key])):
                changed = copy.deepcopy(self.row)
                changed[key].pop(index)
                self.assertFalse(self.accepts(changed), (key, index))
        for key, value in self.row.items():
            if value is True:
                self.assertFalse(self.accepts({**self.row, key: False}), key)

    def test_actual_saved_timing_style_and_caption_text_are_required(self):
        for key, value in (("startFrame", 31), ("durationFrames", 44), ("textContent", "UM HELLO WORLD."), ("captionGroupId", "")):
            changed = copy.deepcopy(self.saved)
            changed["tracks"][0]["clips"][2][key] = value
            self.timeline.write_text(json.dumps(changed))
            self.assertFalse(self.accepts(self.row))
        self.timeline.write_text("not a project")
        self.assertFalse(self.accepts(self.row))

    def test_duplicate_caption_wrong_scale_and_changed_source_fail(self):
        self.assertTrue(self.accepts(self.row))
        for change in ("duplicate", "source", "second-style"):
            changed = copy.deepcopy(self.saved)
            if change == "duplicate":
                changed["tracks"][0]["clips"].append(copy.deepcopy(changed["tracks"][0]["clips"][2]))
            elif change == "source":
                changed["tracks"][1]["clips"][0]["durationFrames"] = 179
            else:
                changed["tracks"][0]["clips"][1]["textStyle"]["fontSize"] = 72
            self.timeline.write_text(json.dumps(changed))
            self.assertFalse(self.accepts(self.row), change)
        self.timeline.write_text(json.dumps(self.saved))
        self.assertFalse(self.accepts({**self.row, "interfaceScale": 1}))
        changed = copy.deepcopy(self.row)
        for action in changed["interactions"]:
            if action.get("kind") == "text":
                action["field"]["fontPointSize"] = 13
        self.assertFalse(self.accepts(changed))

    def test_fixture_is_never_live_transcription_or_a_partial_pass(self):
        self.assertFalse(self.accepts({**self.row, "liveTranscription": True}))
        self.assertFalse(self.accepts({**self.row, "project": "../Titles.ngv"}))
        self.assertFalse(text_captions_evidence([self.row], self.output, 1.5)[0])
        self.assertFalse(text_captions_evidence([self.row, self.complete, {"event": "failed"}], self.output, 1.5)[0])


if __name__ == "__main__":
    unittest.main()
