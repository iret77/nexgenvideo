"""Verify actual native alignment receipts and their exported preview bytes."""
import hashlib
import json
from collections import Counter
from fractions import Fraction


def validate(row, directory, evidence_file, sha256_string):
    proof = row.get("performanceAlignment", {})
    interactions = row.get("nativeEvidence", {}).get("interactions", [])
    states = {item.get("label"): item.get("evidence", {}) for item in interactions if item.get("kind") == "verified-state"}
    pointers = {item.get("id") for item in interactions if item.get("kind") == "pointer"}
    overall = states.get("native multi-shot performance alignment", {})
    upload = states.get("real performance timing audio uploaded", {})
    exact = [item.get("evidence") for item in interactions
             if item.get("kind") == "verified-state" and item.get("label") == "native exact performance alignment"]
    try:
        ids, receipts = proof["shotIDs"], proof["receipts"]
        if (len(ids) != 2 or len(set(ids)) != 2 or len(receipts) != 4 or receipts != exact
            or proof.get("purpose") != "timing_only"
            or not all(proof.get(key) is True for key in ("nativeGeneratedAndImportedEntries", "nativeWholePreviewAndConfirmation",
                "takeAndRangeChangesBlockAssembly", "finalAssemblyReady"))
            or not all(overall.get(key) is True for key in ("takeChangeRevokedAlignment", "rangeChangeRevokedAlignment", "finalAssemblyReady"))
            or overall.get("shotIDs") != ids or {overall.get("generatedShotID"), overall.get("importedShotID")} != set(ids)
            or Counter(item["shotID"] for item in receipts) != {overall["generatedShotID"]: 3, overall["importedShotID"]: 1}
            or len({item["receiptSHA256"] for item in receipts}) != 4
            or not {"performance.alignment.play", "performance.alignment.observe", "performance.alignment.confirm",
                "performance.alignment.close", *("performance.alignment.open." + value for value in ids)}.issubset(pointers)
            or upload.get("shotID") != overall["generatedShotID"] or upload.get("nativeBatchApproved") is not True
            or not sha256_string(upload.get("audioSHA256")) or upload.get("byteCount", 0) <= 44 or not upload.get("modeID")
            or any(type(proof.get(key)) is not int or proof[key] != overall.get(key)
                   for key in ("sourceStartSample", "sourceEndSample", "sampleRate"))
            or proof["sourceStartSample"] != 0 or proof["sourceEndSample"] <= 0 or not 8000 <= proof["sampleRate"] <= 192000):
            return False
        boundaries = {}
        segment = None
        song = None
        for item in receipts:
            receipt_path = evidence_file(directory, item.get("receiptFile"))
            preview_path = evidence_file(directory, item.get("previewFile"))
            if (receipt_path is None or preview_path is None
                or hashlib.sha256(receipt_path.read_bytes()).hexdigest() != item["receiptSHA256"]
                or hashlib.sha256(preview_path.read_bytes()).hexdigest() != item["previewSHA256"]):
                return False
            receipt = json.loads(receipt_path.read_text())
            binding = receipt["binding"]
            duration = Fraction(binding["duration"]["value"], binding["duration"]["timescale"])
            start = Fraction(binding["songStart"]["value"], binding["songStart"]["timescale"])
            materialized = binding["segment"]
            draft = materialized["draft"]
            if (receipt.get("schema") != "native-performance-alignment/v1" or receipt.get("reviewer") != "native-user"
                or receipt.get("watchedAndListened") is not True or not item["observation"].strip()
                or receipt.get("observation") != item["observation"] or binding.get("shotID") != item["shotID"]
                or receipt["preview"]["sha256"] != item["previewSHA256"] or binding["video"]["sha256"] != item["videoSHA256"]
                or binding["originalSong"]["sha256"] != item["songSHA256"] or not sha256_string(item["songSHA256"])
                or item["songStart"] != [binding["songStart"]["value"], binding["songStart"]["timescale"]]
                or item["duration"] != [binding["duration"]["value"], binding["duration"]["timescale"]]
                or duration <= 0 or item["observedSeconds"] < float(duration - Fraction(1, binding["duration"]["timescale"]))
                or item.get("preparedCancelPreservedReceipt") is not True
                or draft.get("shot_ids") != ids or draft.get("purpose") != "timing_only"
                or draft.get("performer_ids") != [] or draft.get("mouth_ownership") != []
                or draft.get("source_start_sample") != proof["sourceStartSample"]
                or draft.get("source_end_sample") != proof["sourceEndSample"] or draft.get("sample_rate") != proof["sampleRate"]
                or materialized.get("segment_sha256") != upload["audioSHA256"]
                or materialized.get("segment_byte_count") != upload["byteCount"]
                or materialized.get("exported_sample_count") != proof["sourceEndSample"]
                or (segment is not None and materialized != segment) or (song is not None and item["songSHA256"] != song)
                or (item["shotID"] in boundaries and boundaries[item["shotID"]] != (start, duration))):
                return False
            segment, song = materialized, item["songSHA256"]
            boundaries[item["shotID"]] = start, duration
        first, second = (boundaries[value] for value in ids)
        return (first[0] == 0 and first[0] + first[1] == second[0]
                and second[0] + second[1] == Fraction(proof["sourceEndSample"], proof["sampleRate"]))
    except (KeyError, TypeError, ValueError, OSError, ZeroDivisionError, AttributeError):
        return False
