import copy
import json
import math
import struct
import unittest

from caption_revision_evidence import audio_cut, fixture_geometry, float_samples, frame_cut, frame_ids, linked_cut, picture_cut, row_centers


class CaptionRevisionEvidenceTests(unittest.TestCase):
    def timelines(self):
        def source(identifier, asset, kind):
            return {"id": identifier, "mediaRef": asset, "mediaType": kind, "sourceClipType": kind,
                    "startFrame": 0, "durationFrames": 180, "trimStartFrame": 0, "trimEndFrame": 0,
                    "speed": 1, "volume": 1, "linkGroupId": "original-link", "effects": []}
        transform = {"centerX": .5, "centerY": .7, "width": .9, "height": .15}
        before = {"fps": 30, "width": 320, "height": 180, "markers": [], "tracks": [
            {"id": "caption-track", "syncLocked": True, "clips": [
                {"id": "first", "startFrame": 0, "durationFrames": 90, "textContent": "Hello um world", "transform": transform},
                {"id": "second", "startFrame": 90, "durationFrames": 30, "textContent": "Fal cloud", "transform": transform}]},
            {"id": "picture-track", "syncLocked": True, "clips": [source("visual", "picture", "video")]},
            {"id": "voice-track", "syncLocked": True, "clips": [source("audio", "voice", "audio")]}]}
        after = copy.deepcopy(before)
        for track in after["tracks"][1:]:
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
        after["tracks"][0]["clips"][1]["startFrame"] = 60
        first = after["tracks"][0]["clips"][0]
        first.update(durationFrames=60, textContent="Hello world", effects=[{
            "id": "first.speech-envelope", "type": "core.clip-envelope.v1", "enabled": True,
            "params": {"definition": {"string": json.dumps({"start": 0, "end": 90,
                "head": {"anchor": 0, "length": 0, "interpolation": "linear"},
                "tail": {"anchor": 90, "length": 0, "interpolation": "linear"}})}}}])
        return before, after

    def test_linked_original_ranges_and_follower_are_preserved(self):
        before, after = self.timelines()
        fixture_geometry(before)
        linked_cut(before, after)

    def test_visible_caption_geometry_excludes_both_frame_identity_bands(self):
        before, _ = self.timelines()
        fixture_geometry(before)
        wrong = copy.deepcopy(before)
        wrong["tracks"] = [wrong["tracks"][1], wrong["tracks"][2], wrong["tracks"][0]]
        with self.assertRaisesRegex(ValueError, "above the opaque picture"): fixture_geometry(wrong)
        wrong = copy.deepcopy(before)
        for clip in wrong["tracks"][0]["clips"]: clip["transform"]["centerY"] = .88
        with self.assertRaises(ValueError): fixture_geometry(wrong)

    def test_wrong_audio_trim_unlinked_partner_and_unselected_text_are_rejected(self):
        before, after = self.timelines()
        for path, value in (((2, 1, "trimStartFrame"), 30), ((2, 1, "linkGroupId"), "wrong-partner"),
                            ((1, 1, "speed"), 2), ((0, 1, "textContent"), "Unexpected replacement"),
                            ((0, 1, "startFrame"), 90), ((0, 0, "textContent"), "Hello um world"),
                            ((0, 0, "durationFrames"), 90)):
            wrong = copy.deepcopy(after)
            track, clip, field = path
            wrong["tracks"][track]["clips"][clip][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                linked_cut(before, wrong)

    def test_relinked_left_pair_cannot_replace_original_link_identity(self):
        before, after = self.timelines()
        for track in after["tracks"][1:]: track["clips"][0]["linkGroupId"] = "unreviewed-new-left-link"
        with self.assertRaises(ValueError): linked_cut(before, after)

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
        params = wrong["tracks"][1]["clips"][1]["effects"][0]["params"]
        definition = json.loads(params["definition"]["string"])
        definition["head"]["length"] = 30
        params["definition"]["string"] = json.dumps(definition)
        with self.assertRaises(ValueError):
            linked_cut(before, wrong)
        wrong = copy.deepcopy(after)
        wrong["tracks"][2]["clips"][0]["effects"].append({"type": "volume", "enabled": True})
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

    def test_frame_identity_pixels_discriminate_one_frame_errors(self):
        def encoded(identity):
            bits = [1, 0] + [(identity >> bit) & 1 for bit in range(8)] + [1 - ((identity >> bit) & 1) for bit in range(8)]
            row = bytearray(bytes((20, 40, 200, 255)) * 320)
            for cell, bit in enumerate(bits):
                for x in range(32 + cell * 14, 32 + (cell + 1) * 14): row[x * 4:x * 4 + 4] = bytes((bit * 255, bit * 255, bit * 255, 255))
            return row * 2
        original = list(range(180))
        expected = original[:30] + original[60:]
        self.assertEqual(frame_ids(b"".join(encoded(i) for i in original), 180), original)
        self.assertEqual(frame_ids(b"".join(encoded(i) for i in expected), 150), expected)
        frame_cut(original, expected)
        for wrong in (original[:29] + original[59:], original[:31] + original[61:],
                      expected[:50] + [expected[49]] + expected[51:]):
            with self.assertRaises(ValueError): frame_cut(original, frame_ids(b"".join(encoded(i) for i in wrong), 150))
        corrupt = encoded(0)
        for band in range(2):
            for x in range(32 + 10 * 14, 32 + 11 * 14): corrupt[band * 1280 + x * 4:band * 1280 + x * 4 + 3] = b"\x00\x00\x00"
        with self.assertRaises(ValueError): frame_ids(corrupt, 1)
        with self.assertRaises(ValueError): frame_ids(encoded(0)[:1280] + corrupt[1280:], 1)
        with self.assertRaises(ValueError): frame_ids(encoded(1)[:1280] + encoded(2)[1280:], 1)

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
        self.assertEqual(len(audio_cut(original, correct)), 5)
        shifted = audio_cut(original, [0.0] * 128 + correct)
        self.assertTrue(all(row["lagSamples"] == row["globalLagSamples"] == -128 for row in shifted))
        wrong_cuts = (original[:80_000], original[:32_000] + original[48_000:], [0.0] * 80_000)
        for wrong in wrong_cuts:
            with self.assertRaises(ValueError):
                audio_cut(original, wrong)
        for offset in (-533, 512, 533):
            slipped = original[:16_000] + original[32_000 + offset:]
            with self.subTest(durationSlipSamples=offset), self.assertRaisesRegex(ValueError, "changes its source alignment"):
                audio_cut(original, slipped)
            moved = original[:16_000 + offset] + original[32_000 + offset:]
            self.assertEqual(len(moved), len(correct))
            for start in (1600, 19_200, 67_200):
                self.assertEqual(moved[start:start + 11_200], correct[start:start + 11_200])
            with self.subTest(cutPositionSamples=offset), self.assertRaisesRegex(ValueError, "cut boundary"):
                audio_cut(original, moved)


if __name__ == "__main__":
    unittest.main()
