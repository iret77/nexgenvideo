import binascii
import copy
import hashlib
import struct
import zlib
from pathlib import Path
import tempfile
import unittest

from workspace_ui_acceptance import animation_audio_evidence


def png(width=960, height=640):
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", binascii.crc32(kind + value) & 0xffffffff)
    pixels = b"".join(b"\0" + bytes((y % 256, 60, 100)) * width for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


class AnimationAudioEvidenceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.output = Path(directory.name)
        images = ["animation-audio-150-" + str(index) + "-" + label + ".png" for index, label in
                  enumerate(("opacity-keyframes", "effect-keyframes", "volume-and-fades"))]
        for image in images:
            (self.output / image).write_bytes(png())
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
        self.row = {"event": "animation-audio", "scale": 1.5, "effectiveScale": 1.5,
            "screenshotEvidence": [{"filename": name, "sha256": hashlib.sha256((self.output / name).read_bytes()).hexdigest(),
                                    "bounds": [960, 640], "backingScale": 1, "pixels": [960, 640]} for name in images], "viewport": [960, 640], "screenshots": images,
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
        for key, value in (("id", "wrong-field"), ("actual", "100"), ("expected", "50"), ("commitInput", "Return"), ("stage", "typing"),
                           ("focusLeftTarget", False), ("ownsEditor", True), ("requiresFocusExit", False), ("id", [])):
            changed = copy.deepcopy(self.row)
            changed["interactions"][0]["field"][key] = value
            self.assertFalse(self.accepts(changed))
        for key, value in self.row.items():
            if value is True:
                self.assertFalse(self.accepts({**self.row, key: False}))

    def test_screenshot_hash_geometry_case_and_scale_are_bound(self):
        for key, value in (("sha256", "0" * 64), ("bounds", [320, 180]), ("backingScale", 2), ("pixels", [1920, 1280])):
            changed = copy.deepcopy(self.row)
            changed["screenshotEvidence"][0][key] = value
            with self.subTest(key=key):
                self.assertFalse(self.accepts(changed))
        for name in ("other-150-0-opacity-keyframes.png", "animation-audio-100-0-opacity-keyframes.png"):
            changed = copy.deepcopy(self.row)
            changed["screenshots"][0] = name
            changed["screenshotEvidence"][0]["filename"] = name
            (self.output / name).write_bytes(png())
            self.assertFalse(self.accepts(changed))
        self.assertFalse(self.accepts({**self.row, "effectiveScale": 1}))
        for data in (b"\x89PNG\r\n\x1a\n" + b"native" * 200, png(320, 180), png()[:-1]):
            changed = copy.deepcopy(self.row)
            name = changed["screenshots"][0]
            (self.output / name).write_bytes(data)
            changed["screenshotEvidence"][0]["sha256"] = hashlib.sha256(data).hexdigest()
            self.assertFalse(self.accepts(changed))

    def test_backing_pixels_are_independent_from_interface_scale(self):
        changed = copy.deepcopy(self.row)
        for item in changed["screenshotEvidence"]:
            data = png(1920, 1280)
            (self.output / item["filename"]).write_bytes(data)
            item.update({"backingScale": 2, "pixels": [1920, 1280], "sha256": hashlib.sha256(data).hexdigest()})
        self.assertTrue(self.accepts(changed))

    def test_non_object_row_is_refused(self):
        self.assertFalse(animation_audio_evidence([self.row, None, self.completed], self.output, 1.5)[0])

    def test_incomplete_scale_failure_and_missing_image(self):
        self.assertFalse(animation_audio_evidence([self.row], self.output, 1.5)[0])
        self.assertFalse(animation_audio_evidence([self.row, self.completed], self.output, 1.0)[0])
        self.assertFalse(animation_audio_evidence([self.row, self.completed, {"event": "failed"}], self.output, 1.5)[0])
        (self.output / self.row["screenshots"][0]).write_bytes(b"not a native image")
        self.assertFalse(self.accepts(self.row))


if __name__ == "__main__":
    unittest.main()
