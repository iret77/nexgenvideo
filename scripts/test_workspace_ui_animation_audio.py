import copy
from pathlib import Path
import tempfile
import unittest

from workspace_ui_acceptance import animation_audio_evidence


class AnimationAudioEvidenceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.output = Path(directory.name)
        images = ["animation-audio-150-" + label + ".png" for label in
                  ("opacity-keyframes", "effect-keyframes", "volume-and-fades")]
        for image in images:
            (self.output / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"native" * 200)
        fields = [("inspector.value.Opacity", "25"), ("inspector.value.Opacity", "75"),
            ("inspector.adjust.value.color.exposure.ev", "-1.00"), ("inspector.adjust.value.color.exposure.ev", "1.00"),
            ("inspector.adjust.value.color.exposure.ev", "1.50"), ("editing.audio.volume", "-12.0"),
            ("editing.audio.volume", "-6.0"), ("editing.audio.fade-in", "0.50"),
            ("editing.audio.fade-out", "1.00"), ("inspector.value.Speed", "2.00")]
        menus = [("editing.keyframe.opacity.30", "Hold"), ("editing.keyframe.opacity.30", "Linear"),
            ("editing.keyframe.opacity.30", "Smooth"), ("editing.keyframe.opacity.90", "Delete Keyframe"),
            ("editing.keyframe.opacity.30", "Clear Animation"),
            ("editing.keyframe.effect.color.exposure.ev.90", "Delete Keyframe"),
            ("editing.keyframe.effect.color.exposure.ev.30", "Clear Animation"), ("editing.keyframe.effect.color.exposure.ev.30", "Hold"),
            ("editing.keyframe.effect.color.exposure.ev.30", "Linear"), ("editing.keyframe.volume.30", "Linear")]
        self.row = {"event": "animation-audio", "scale": 1.5, "viewport": [960, 640], "screenshots": images,
            **{key: True for key in ("nativeOpacityKeys", "nativeInterpolation", "nativePreviousNext", "nativeMoveDeleteClearUndo",
                "nativeEffectKeys", "nativeEffectMoveDeleteClearUndo", "nativeEffectPreviousNext", "nativeAudioInterpolation", "playerItemCompositionAnimation", "nativeVolumeKeys", "nativeFadesAndTempoUndo",
                "unselectedAudioPreserved", "nativeSaveAndReopen")},
            "interactions": [{"kind": "text", "field": {"id": key, "expected": value, "actual": value,
                "commitInput": "Tab", "stage": "commit-requested", "requiresFocusExit": True,
                "focusLeftTarget": True, "ownsEditor": False}} for key, value in fields]
                + [{"kind": "context-menu", "id": key, "path": [title], "closed": True} for key, title in menus]
                + [{"kind": "pointer", "id": key} for key in (
                    "editing.keyframe.opacity.stamp", "editing.keyframe.opacity.stamp",
                    "editing.effect.color.exposure.ev.stamp", "editing.effect.color.exposure.ev.stamp",
                    "editing.keyframe.volume.stamp", "editing.keyframe.volume.stamp",
                    "editing.keyframe.opacity.previous", "editing.keyframe.opacity.next",
                    "editing.effect.color.exposure.ev.previous", "editing.effect.color.exposure.ev.next")]
                + [{"kind": "keyboard", "characters": key} for key in ("z", "z", "z", "z", "z", "z", "z", "s")]
                + [{"kind": "drag", "id": identifier, "start": [0.75, 0.5], "end": [0.5, 0.5]}
                   for identifier in ("editing.keyframe-lane.opacity", "editing.keyframe-lane.effect.color.exposure.ev")]}
        self.completed = {"event": "completed", "case": "animationaudio", "scale": 1.5}

    def accepts(self, row):
        return animation_audio_evidence([row, self.completed], self.output, 1.5)[0]

    def test_every_native_operation_and_image_is_required(self):
        self.assertTrue(self.accepts(self.row))
        for key in ("interactions", "screenshots"):
            for index in range(len(self.row[key])):
                changed = copy.deepcopy(self.row)
                changed[key].pop(index)
                with self.subTest(key=key, index=index):
                    self.assertFalse(self.accepts(changed))

    def test_uncommitted_input_wrong_field_or_value_never_passes(self):
        for key, value in (("id", "wrong-field"), ("actual", "100"), ("expected", "50"), ("commitInput", "Return"),
                           ("focusLeftTarget", False), ("ownsEditor", True), ("requiresFocusExit", False), ("id", [])):
            changed = copy.deepcopy(self.row)
            changed["interactions"][0]["field"][key] = value
            self.assertFalse(self.accepts(changed))
        for key, value in self.row.items():
            if value is True:
                self.assertFalse(self.accepts({**self.row, key: False}))

    def test_incomplete_scale_failure_and_missing_image(self):
        self.assertFalse(animation_audio_evidence([self.row], self.output, 1.5)[0])
        self.assertFalse(animation_audio_evidence([self.row, self.completed], self.output, 1.0)[0])
        self.assertFalse(animation_audio_evidence([self.row, self.completed, {"event": "failed"}], self.output, 1.5)[0])
        (self.output / self.row["screenshots"][0]).write_bytes(b"not a native image")
        self.assertFalse(self.accepts(self.row))


if __name__ == "__main__":
    unittest.main()
