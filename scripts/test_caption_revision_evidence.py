import copy
import json
import math
import struct
import unittest

from caption_revision_evidence import audio_cut, float_samples, linked_cut, picture_cut, row_centers


class CaptionRevisionEvidenceTests(unittest.TestCase):
    def timelines(self):
        def source(identifier, asset, kind):
            return {"id": identifier, "mediaRef": asset, "mediaType": kind, "sourceClipType": kind,
                    "startFrame": 0, "durationFrames": 180, "trimStartFrame": 0, "trimEndFrame": 0,
                    "speed": 1, "volume": 1, "linkGroupId": "original-link", "effects": []}
        before = {"fps": 30, "width": 320, "height": 180, "markers": [], "tracks": [
            {"id": "picture", "syncLocked": True, "clips": [source("visual", "picture", "video")]},
            {"id": "voice", "syncLocked": True, "clips": [source("audio", "voice", "audio")]},
            {"id": "captions", "syncLocked": True, "clips": [
                {"id": "first", "startFrame": 0, "durationFrames": 90, "textContent": "Hello um world"},
                {"id": "second", "startFrame": 90, "durationFrames": 30, "textContent": "Fal cloud"}]}]}
        after = copy.deepcopy(before)
        for track in after["tracks"][:2]:
            left = track["clips"][0]
            right = copy.deepcopy(left)
            left.update(durationFrames=30, trimEndFrame=150)
            right.update(id=right["id"] + "-right", linkGroupId="actual-split-link",
                         startFrame=30, durationFrames=120, trimStartFrame=60)
            track["clips"].append(right)
            for part in track["clips"]:
                offset = part["trimStartFrame"]
                definition = {"start": -offset, "end": 180 - offset,
                    "head": {"anchor": -offset, "length": 0, "interpolation": "linear"},
                    "tail": {"anchor": 180 - offset, "length": 0, "interpolation": "linear"}}
                part["effects"] = [{"id": "b94c17b0-480d-4532-bba2-c01bc53761c0", "type": "core.clip-envelope.v1",
                    "enabled": True, "params": {"definition": {"string": json.dumps(definition)}}}]
        after["tracks"][2]["clips"][1]["startFrame"] = 60
        first = after["tracks"][2]["clips"][0]
        first.update(durationFrames=60, textContent="Hello world", effects=[{
            "id": "first.speech-envelope", "type": "core.clip-envelope.v1", "enabled": True,
            "params": {"definition": {"string": json.dumps({"start": 0, "end": 90,
                "head": {"anchor": 0, "length": 0, "interpolation": "linear"},
                "tail": {"anchor": 90, "length": 0, "interpolation": "linear"}})}}}])
        return before, after

    def test_linked_original_ranges_and_follower_are_preserved(self):
        before, after = self.timelines()
        linked_cut(before, after)

    def test_wrong_audio_trim_unlinked_partner_and_unselected_text_are_rejected(self):
        before, after = self.timelines()
        for path, value in (((1, 1, "trimStartFrame"), 30), ((1, 1, "linkGroupId"), "wrong-partner"),
                            ((0, 1, "speed"), 2), ((2, 1, "textContent"), "Unexpected replacement"),
                            ((2, 1, "startFrame"), 90), ((2, 0, "textContent"), "Hello um world"),
                            ((2, 0, "durationFrames"), 90)):
            wrong = copy.deepcopy(after)
            track, clip, field = path
            wrong["tracks"][track]["clips"][clip][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                linked_cut(before, wrong)

    def test_unrelated_timeline_and_track_changes_are_rejected(self):
        before, after = self.timelines()
        for wrong in (dict(after, markers=[{"startFrame": 1}]), copy.deepcopy(after)):
            if wrong["markers"] == []:
                wrong["tracks"][0]["syncLocked"] = False
            with self.assertRaises(ValueError):
                linked_cut(before, wrong)

    def test_changed_gain_or_unrelated_effect_cannot_hide_inside_split_envelope(self):
        before, after = self.timelines()
        wrong = copy.deepcopy(after)
        params = wrong["tracks"][0]["clips"][1]["effects"][0]["params"]
        definition = json.loads(params["definition"]["string"])
        definition["head"]["length"] = 30
        params["definition"]["string"] = json.dumps(definition)
        with self.assertRaises(ValueError):
            linked_cut(before, wrong)
        wrong = copy.deepcopy(after)
        wrong["tracks"][1]["clips"][0]["effects"].append({"type": "volume", "enabled": True})
        with self.assertRaises(ValueError):
            linked_cut(before, wrong)

    def test_raw_picture_pixels_determine_marker_positions(self):
        width = 80
        row = bytearray(bytes((10, 20, 200, 255)) * width)
        for x in range(30, 35):
            row[x * 4:x * 4 + 4] = bytes((255, 255, 255, 255))
        self.assertEqual(row_centers(row * 2, width, 2), [32 / 80, 32 / 80])
        for data, count in ((row[:-1], 1), (bytes(width * 4), 1), (row, 2)):
            with self.assertRaises(ValueError):
                row_centers(data, width, count)

    def test_picture_rejects_static_or_wrong_cut_even_at_correct_frame_count(self):
        original = [0.3 + frame / 500 for frame in range(180)]
        picture_cut(original, original[:30] + original[60:])
        for wrong in (original[:150], original[:60] + original[90:], [0.3] * 150):
            with self.assertRaises(ValueError):
                picture_cut(original, wrong)
        with self.assertRaises(ValueError):
            picture_cut(original, [float("nan")] * 150)

    def test_pcm_rejects_nonfinite_and_truncated_bytes(self):
        self.assertEqual(list(float_samples(struct.pack("<3f", 0, 0.5, -0.5))), [0, 0.5, -0.5])
        for data in (b"", b"abc", struct.pack("<f", float("nan")), struct.pack("<f", float("inf"))):
            with self.assertRaises(ValueError):
                float_samples(data)

    def test_physical_audio_requires_correct_source_on_both_sides_of_cut(self):
        original = [0.1 * math.sin(2 * math.pi * (173 * (index / 16_000) + 71 * (index / 16_000) ** 2 / 6))
                    + 0.04 * math.sin(2 * math.pi * (421 * (index / 16_000) + 137 * (index / 16_000) ** 2 / 6))
                    for index in range(96_000)]
        correct = original[:16_000] + original[32_000:]
        self.assertEqual(len(audio_cut(original, correct)), 3)
        wrong_cuts = (original[:80_000], original[:32_000] + original[48_000:], [0.0] * 80_000)
        for wrong in wrong_cuts:
            with self.assertRaises(ValueError):
                audio_cut(original, wrong)


if __name__ == "__main__":
    unittest.main()
