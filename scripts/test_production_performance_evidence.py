import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from production_performance_evidence import validate
from workspace_ui_acceptance import evidence_file, sha256_string


def fixture(directory):
    ids = ["generated", "imported"]
    segment = {"draft": {"shot_ids": ids, "purpose": "timing_only", "performer_ids": [], "mouth_ownership": [],
        "source_start_sample": 0, "source_end_sample": 384000, "sample_rate": 48000},
        "segment_sha256": "a" * 64, "segment_byte_count": 768044, "exported_sample_count": 384000}
    receipts = []
    for index, shot in enumerate(["generated", "imported", "generated", "generated"]):
        preview = ("unit-preview-" + str(index)).encode()
        preview_hash = hashlib.sha256(preview).hexdigest()
        start = 4 if shot == "imported" else 0
        note = "Actual native observation " + str(index)
        receipt = {"schema": "native-performance-alignment/v1", "reviewer": "native-user", "watchedAndListened": True,
            "observation": note, "preview": {"sha256": preview_hash}, "binding": {"shotID": shot, "segment": segment,
                "songStart": {"value": start * 48000, "timescale": 48000}, "duration": {"value": 192000, "timescale": 48000},
                "video": {"sha256": "b" * 64}, "originalSong": {"sha256": "c" * 64}}}
        data = json.dumps(receipt).encode()
        receipt_file, preview_file = f"receipt-{index}.json", f"preview-{index}.mov"
        (directory / receipt_file).write_bytes(data)
        (directory / preview_file).write_bytes(preview)
        receipts.append({"shotID": shot, "receiptSHA256": hashlib.sha256(data).hexdigest(), "previewSHA256": preview_hash,
            "receiptFile": receipt_file, "previewFile": preview_file, "videoSHA256": "b" * 64, "songSHA256": "c" * 64,
            "songStart": [start * 48000, 48000], "duration": [192000, 48000], "observedSeconds": 4,
            "observation": note, "preparedCancelPreservedReceipt": True})
    overall = {"shotIDs": ids, "generatedShotID": "generated", "importedShotID": "imported", "sourceStartSample": 0,
        "sourceEndSample": 384000, "sampleRate": 48000, "takeChangeRevokedAlignment": True,
        "rangeChangeRevokedAlignment": True, "finalAssemblyReady": True}
    upload = {"shotID": "generated", "nativeBatchApproved": True, "audioSHA256": "a" * 64,
        "byteCount": 768044, "modeID": "offered-mode"}
    interactions = [{"kind": "verified-state", "label": label, "evidence": evidence} for label, evidence in
        [("native multi-shot performance alignment", overall), ("real performance timing audio uploaded", upload)]
        + [("native exact performance alignment", value) for value in receipts]]
    interactions += [{"kind": "pointer", "id": "performance.alignment." + key} for key in
        ("play", "observe", "confirm", "close", "open.generated", "open.imported")]
    return {"performanceAlignment": {"shotIDs": ids, "purpose": "timing_only", "receipts": receipts,
        "sourceStartSample": 0, "sourceEndSample": 384000, "sampleRate": 48000,
        "nativeGeneratedAndImportedEntries": True, "nativeWholePreviewAndConfirmation": True,
        "takeAndRangeChangesBlockAssembly": True, "finalAssemblyReady": True}, "nativeEvidence": {"interactions": interactions}}


class PerformanceEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def valid(self, row):
        return validate(row, self.directory, evidence_file, sha256_string)

    def test_actual_paths_receipts_and_inputs_are_all_required(self):
        row = fixture(self.directory)
        self.assertTrue(self.valid(row))
        for index in range(len(row["nativeEvidence"]["interactions"])):
            changed = copy.deepcopy(row)
            changed["nativeEvidence"]["interactions"].pop(index)
            self.assertFalse(self.valid(changed), index)

    def test_preview_and_receipt_bytes_cannot_be_replaced(self):
        for index in range(4):
            for key in ("receiptFile", "previewFile"):
                row = fixture(self.directory)
                (self.directory / row["performanceAlignment"]["receipts"][index][key]).write_bytes(b"changed")
                self.assertFalse(self.valid(row), (index, key))

    def test_rehashed_wrong_song_clock_or_unconfirmed_receipt_fails(self):
        for change in ("song", "duration", "confirmation", "segment"):
            row = fixture(self.directory)
            item = row["performanceAlignment"]["receipts"][1]
            path = self.directory / item["receiptFile"]
            receipt = json.loads(path.read_text())
            if change == "song":
                receipt["binding"]["originalSong"]["sha256"] = item["songSHA256"] = "d" * 64
            elif change == "duration":
                receipt["binding"]["duration"]["value"] = 191999
                item["duration"][0] = 191999
            elif change == "segment":
                receipt["binding"]["segment"]["segment_sha256"] = "d" * 64
            else:
                receipt["watchedAndListened"] = False
            data = json.dumps(receipt).encode()
            path.write_bytes(data)
            item["receiptSHA256"] = hashlib.sha256(data).hexdigest()
            self.assertFalse(self.valid(row), change)

    def test_declared_success_cannot_replace_playback_or_cancellation(self):
        for key, value in (("observedSeconds", 0), ("preparedCancelPreservedReceipt", False), ("receiptFile", "../outside.json")):
            row = fixture(self.directory)
            row["performanceAlignment"]["receipts"][0][key] = value
            self.assertFalse(self.valid(row), key)
