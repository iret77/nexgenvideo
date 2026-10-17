import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from workspace_ui_acceptance import valid_musicvideo_review


class FilmReviewEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        movie = b"\x00\x00\x00\x20ftyp" + b"fixture" * 200
        digest = hashlib.sha256(movie).hexdigest()
        (self.output / "film.mp4").write_bytes(movie)
        self.receipt = {
            "schema": "delivery-attempt/v1", "status": "succeeded", "output_sha256": digest,
            "output_byte_count": len(movie), "probe_qc": {"passed": True}, "sequence_review_sha256": "b" * 64,
        }
        self.write_receipt()
        frame = {"x": 0, "y": 0, "width": 960, "height": 640}
        ids = [
            "pipeline.overview.select.render", "sequence.disclosure", "sequence.build", "sequence.play",
            "sequence.shots", "sequence.start", "sequence.end", "sequence.evidence", "sequence.severity",
            "sequence.action", "sequence.add", "sequence.adjacent", "sequence.whole", "sequence.record",
            "style.disclosure", "style.begin", "style.record", "production.export", "style.choice.test",
            "style.observation.test",
        ]
        self.row = {
            "route": "mixed-musicvideo", "viewport": frame,
            "generation": {
                "providerEvidence": "Real FalClient against a simulator; no live provider evidence.",
                "batchID": "batch", "packageID": "package", "takeID": "take", "generationAssetID": "asset",
                "compiledPromptSHA256": "a" * 64, "referenceSHA256": "b" * 64,
                "outputSHA256": "c" * 64, "selectedSourceSHA256": "c" * 64,
                "generatedShotIDs": ["s001"], "importedShotIDs": ["s002"],
                "submitCount": 1, "pollCount": 1, "resultCount": 1, "downloadCount": 1, "uploadCount": 1,
                "unexpectedRequestCount": 0, "requestMethods": ["POST", "PUT", "POST", "GET", "GET", "GET"],
                "spendEvents": ["reserved", "submitted", "settled"],
                "generatedSourceStartFrame": 30, "generatedSourceEndFrame": 90, "totalFrames": 129,
            },
            "controls": [{"id": key, "control": {"x": 10, "y": 10, "width": 200, "height": 30},
                          "viewport": frame.copy()} for key in ids],
            "pickerTransitions": [
                {"id": "sequence.severity", "before": "warning", "after": "info"},
                {"id": "sequence.action", "before": "local_repair", "after": "accept"},
                {"id": "style.choice.test", "before": "unreviewed", "after": "accepted_deviation"},
            ],
            "recordedSequenceSelection": {"severity": "info", "action": "accept"},
            "expectedDurationFrames": 129, "shotIDs": ["s001", "s002"], "verifiedShotImages": 2,
            "verifiedMovingShots": 2, "verifiedFrames": 4, "decodedAudioCorrelation": 0.999,
            "sequenceFindingCount": 1, "styleFindingCount": 1, "screenshots": [f"{i}.png" for i in range(7)],
            "playbackSeconds": 4.3, "decodedAudioSamples": 206400, "decodedAudioRMS": 0.1,
            "movie": "film.mp4", "deliveryReceipt": "receipt.json", "outputSHA256": digest,
        }
        for key in (
            "nativeSequenceReview", "nativeStyleReview", "recordDisabledUntilReviewed", "reviewInputsPersisted",
            "timelineUnchangedByReview", "nativeExportSubmitted", "exportCompleted", "sequenceReviewBound",
            "styleReviewBound", "fullSongDuration", "reviewReelHasAudio",
        ):
            self.row[key] = True

    def write_receipt(self):
        (self.output / "receipt.json").write_text(json.dumps(self.receipt))

    def test_accepts_complete_bound_delivery(self):
        self.assertTrue(valid_musicvideo_review(self.row, self.output))

    def test_rejects_clipped_control_even_when_all_actions_claim_success(self):
        self.row["controls"][0]["control"]["y"] = 630
        self.assertFalse(valid_musicvideo_review(self.row, self.output))

    def test_rejects_larger_window_or_missing_native_input(self):
        row = copy.deepcopy(self.row)
        row["viewport"]["width"] = 1470
        self.assertFalse(valid_musicvideo_review(row, self.output))
        self.row["controls"] = [item for item in self.row["controls"] if item["id"] != "sequence.evidence"]
        self.assertFalse(valid_musicvideo_review(self.row, self.output))

    def test_rejects_short_silent_or_unplayed_movie_claim(self):
        for key, value in (("playbackSeconds", 0), ("decodedAudioSamples", 100), ("decodedAudioRMS", 0),
                           ("verifiedShotImages", 1), ("decodedAudioRMS", float("nan"))):
            with self.subTest(key=key, value=value):
                row = {**self.row, key: value}
                self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_unchanged_unobserved_or_unpersisted_picker_selections(self):
        for key in ("pickerTransitions", "recordedSequenceSelection"):
            row = copy.deepcopy(self.row)
            del row[key]
            self.assertFalse(valid_musicvideo_review(row, self.output))
        for index in range(3):
            row = copy.deepcopy(self.row)
            row["pickerTransitions"][index]["before"] = row["pickerTransitions"][index]["after"]
            self.assertFalse(valid_musicvideo_review(row, self.output))
        row = copy.deepcopy(self.row)
        row["recordedSequenceSelection"]["severity"] = "warning"
        self.assertFalse(valid_musicvideo_review(row, self.output))
        row = copy.deepcopy(self.row)
        row["pickerTransitions"] = row["pickerTransitions"][:2]
        self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_wrong_song_despite_nonzero_audio(self):
        for correlation in (0, 0.97, float("nan"), float("inf"), 1.2, None, True):
            with self.subTest(correlation=correlation):
                self.assertFalse(valid_musicvideo_review(
                    {**self.row, "decodedAudioCorrelation": correlation}, self.output))
        missing = self.row.copy()
        del missing["decodedAudioCorrelation"]
        self.assertFalse(valid_musicvideo_review(missing, self.output))

    def test_rejects_still_or_single_frame_comparison(self):
        for key, value in (("verifiedMovingShots", 1), ("verifiedMovingShots", 0),
                           ("verifiedFrames", 3), ("verifiedFrames", 2), ("verifiedFrames", None)):
            with self.subTest(key=key, value=value):
                self.assertFalse(valid_musicvideo_review({**self.row, key: value}, self.output))
        for key in ("verifiedMovingShots", "verifiedFrames"):
            missing = self.row.copy()
            del missing[key]
            self.assertFalse(valid_musicvideo_review(missing, self.output))

    def test_rejects_imported_only_or_missing_generation_chain(self):
        self.assertFalse(valid_musicvideo_review({**self.row, "route": "imported-musicvideo"}, self.output))
        missing = self.row.copy()
        del missing["generation"]
        self.assertFalse(valid_musicvideo_review(missing, self.output))
        for key, value in (
            ("submitCount", 0), ("pollCount", 0), ("resultCount", 0), ("downloadCount", 0),
            ("uploadCount", 0), ("unexpectedRequestCount", 1), ("takeID", ""),
            ("generatedSourceStartFrame", 0), ("generatedSourceEndFrame", 120),
            ("selectedSourceSHA256", "d" * 64), ("compiledPromptSHA256", "none"),
            ("spendEvents", ["reserved", "settled"]), ("requestMethods", []),
        ):
            with self.subTest(key=key, value=value):
                row = copy.deepcopy(self.row)
                row["generation"][key] = value
                self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_changed_movie_and_unbound_review_receipt(self):
        self.receipt["sequence_review_sha256"] = None
        self.write_receipt()
        self.assertFalse(valid_musicvideo_review(self.row, self.output))
        self.receipt["sequence_review_sha256"] = "b" * 64
        self.write_receipt()
        (self.output / "film.mp4").write_bytes(b"changed bytes")
        self.assertFalse(valid_musicvideo_review(self.row, self.output))


if __name__ == "__main__":
    unittest.main()
