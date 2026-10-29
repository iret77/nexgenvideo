import base64
import copy
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from generation_recovery_acceptance import generation_recovery_evidence


class GenerationRecoveryEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name); self.directory = self.output / "generation-recovery-150"; self.directory.mkdir()
        def write(name, value):
            (self.directory / name).write_text(json.dumps(value))
        self.write = write
        def wave(value):
            data = struct.pack("<f", value) * 144000
            fmt = struct.pack("<HHIIHH", 3, 1, 48000, 192000, 4, 32)
            chunks = b"fmt " + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", len(data)) + data
            return b"RIFF" + struct.pack("<I", len(chunks) + 4) + b"WAVE" + chunks
        first_bytes, second_bytes = wave(0), wave(0.1)
        (self.directory / "history-output.wav").write_bytes(first_bytes)
        (self.directory / "first-output.wav").write_bytes(first_bytes); (self.directory / "second-output.wav").write_bytes(second_bytes)
        state = {"processID": 101, "batchID": "b" * 64, "itemIDs": ["one", "two", "three"], "firstOutputID": "output-one",
            "firstOutputSHA256": hashlib.sha256(first_bytes).hexdigest(), "acceptedRequestID": "recorded-two", "packageIDs": ["p-one", "p-two", "p-three"]}
        write("state.json", state)
        batch = {"id": state["batchID"], "payload": {"projectKey": "fixture-project", "items": [{"id": name, "package": {"id": package, "payload": {
            "operation": "audio", "modality": "audio", "prompt": "actual compiled " + name}}}
            for name, package in zip(state["itemIDs"], state["packageIDs"])]}}
        self.batch = batch
        executions = [{"itemID": name, "state": status, "providerRequestID": request, "transactionID": transaction,
            "providerRequestResumable": request is not None, "placeholders": [name] if request else [], "outputAssetIDs": outputs}
            for name, status, request, transaction, outputs in (("one", "complete", "recorded-one", "transaction-one", ["output-one"]),
                ("two", "running", "recorded-two", "transaction-two", []), ("three", "canceled", None, None, []))]
        self.first = {"batchID": state["batchID"], "authorityID": "real-host-authority", "approvedAt": 42,
            "pricingOverrideItemIDs": state["itemIDs"], "executions": executions}
        self.second = copy.deepcopy(self.first); self.second["executions"][1].update(state="complete", outputAssetIDs=["output-two"])
        self.logs = {"spendEvents": [{"kind": kind, "transactionId": transaction, "providerRequestId": request}
            for kind, transaction, request in (("reserved", "transaction-one", None), ("submitted", "transaction-one", "recorded-one"),
                ("reserved", "transaction-two", None), ("submitted", "transaction-two", "recorded-two"))]}
        posts = [{"method": "POST", "url": "https://queue.fal.run/fal-ai/elevenlabs/music", "body": base64.b64encode(json.dumps({
            "prompt": item["package"]["payload"]["prompt"], "music_length_ms": 3000, "force_instrumental": True}).encode()).decode()}
            for item in batch["payload"]["items"][:2]]
        self.resumed_requests = [{"method": "GET", "url": "https://queue.fal.run/fal-ai/elevenlabs/requests/recorded-two" + suffix, "body": ""}
            for suffix in ("/status", "")]
        for stage, journal, requests in (("prepare", self.first, posts), ("resume", self.second, self.resumed_requests), ("authoritylost", self.first, [])):
            write(stage + "-batch.json", batch); write(stage + "-journal.json", journal)
            write(stage + "-spend.json", self.logs); write(stage + "-http.json", requests)
        write("authority-before-loss.json", {"journal": self.second, "batch": batch, "projectKey": "fixture-project"})
        write("authority-remaining-batches.json", [])
        images = ["generation-recovery-150/native-" + name + ".png" for name in
            ("review-before-one-approval", "remaining-canceled-known-job-retained", "restarted-history-and-results", "history-without-authority")]
        for image in images: (self.output / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"image" * 250)
        prepare_actions = [{"kind": "pointer", "id": name} for name in ("generation-batch.approve", "agent.stop")]
        prepare_actions += [{"kind": "keyboard", "characters": "s"}, {"kind": "verified-state", "label": "native queued requests stopped before process restart",
            "evidence": {"batchID": state["batchID"], "acceptedRequestID": "recorded-two", "providerSubmissions": 2,
                "completedRetained": True, "thirdCanceledWithoutSubmission": True}}]
        resume_actions = [{"kind": "pointer", "id": "generation-batch.open." + name} for name in ("output-one", "output-two")]
        resume_actions += [{"kind": "verified-state", "label": "actual process restart resumes only the recorded audio job", "evidence": {
            "previousProcessID": 101, "acceptedRequestID": "recorded-two", "providerSubmissions": 0,
            "firstOutputSHA256": state["firstOutputSHA256"], "secondOutputSHA256": hashlib.sha256(second_bytes).hexdigest(),
            "completedRetained": True, "thirdStillCanceled": True, "nativeHistoryResultsOpened": True}}]
        resume_actions += [{"kind": "keyboard", "characters": "s"}]
        lost_actions = [{"kind": "pointer", "id": "generation-batch.open.output-one"},
            {"kind": "visible-group", "ids": ["generation-batch.authority-missing." + state["batchID"]]},
            {"kind": "verified-state", "label": "missing local authority preserves readable history without execution", "evidence": {
                "projectKey": "fixture-project", "coordinatorIdle": True, "coordinatorErrorFree": True,
                "authorityAvailable": False, "warning": "Execution authority is not available on this Mac. This batch is history only.",
                "providerRequests": 0, "firstOutputSHA256": state["firstOutputSHA256"], "acceptedRequestID": "recorded-two"}}]
        visible = [{"kind": "visible-group", "ids": ["generation-batch.state." + name]} for name in state["itemIDs"]]
        self.rows = [{"event": "generation-recovery", "stage": stage, "processID": pid, "batchID": state["batchID"], "scale": 1.5,
            "directory": "generation-recovery-150", "liveProvider": False, "screenshots": screenshots, "interactions": actions + visible}
            for stage, pid, screenshots, actions in (("prepare", 101, images[:2], prepare_actions), ("resume", 202, images[2:3], resume_actions), ("authoritylost", 303, images[3:], lost_actions))]
        self.rows += [{"event": "generation-recovery-process", "stage": stage, "processID": pid, "exitCode": 0, "scale": 1.5}
            for stage, pid in (("prepare", 101), ("resume", 202), ("authoritylost", 303))]
        self.rows += [{"event": "completed", "case": "generationrecovery", "scale": 1.5} for _ in range(3)]

    def accepts(self, rows=None):
        return generation_recovery_evidence(rows or self.rows, self.output, 1.5)[0]

    def test_independent_actual_process_identity_and_all_native_actions_are_required(self):
        self.assertTrue(self.accepts())
        changed = copy.deepcopy(self.rows); changed[1]["processID"] = 101; changed[4]["processID"] = 101
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.rows); changed[2]["processID"] = 202; changed[5]["processID"] = 202
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.rows); changed[5]["exitCode"] = 124
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.rows); changed[1], changed[2] = changed[2], changed[1]
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.rows)
        changed[0]["screenshots"], changed[2]["screenshots"] = changed[2]["screenshots"], changed[0]["screenshots"]
        self.assertFalse(self.accepts(changed))
        for row_index in (0, 1, 2):
            for action_index in range(len(self.rows[row_index]["interactions"])):
                changed = copy.deepcopy(self.rows); changed[row_index]["interactions"].pop(action_index)
                self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.rows); changed[4]["exitCode"] = 124
        self.assertFalse(self.accepts(changed))

    def test_resubmission_foreign_job_or_transaction_and_reused_approval_are_rejected(self):
        self.write("resume-http.json", self.resumed_requests + [{"method": "POST", "url": "https://queue.fal.run/paid", "body": ""}])
        self.assertFalse(self.accepts()); self.write("resume-http.json", self.resumed_requests)
        for key, value in (("providerRequestID", "new-paid-job"), ("transactionID", "new-reservation")):
            changed = copy.deepcopy(self.second); changed["executions"][1][key] = value
            self.write("resume-journal.json", changed); self.assertFalse(self.accepts())
        self.write("resume-journal.json", self.second)
        changed = copy.deepcopy(self.second); changed["approvedAt"] = 43
        self.write("resume-journal.json", changed); self.assertFalse(self.accepts())
        self.write("resume-journal.json", self.second)
        changed = copy.deepcopy(self.logs); changed["spendEvents"].append({"kind": "reserved", "transactionId": "third"})
        self.write("resume-spend.json", changed); self.assertFalse(self.accepts())

    def test_lost_completed_result_submitted_canceled_job_and_changed_bytes_fail(self):
        changed = copy.deepcopy(self.second); changed["executions"][0]["outputAssetIDs"] = []
        self.write("resume-journal.json", changed); self.assertFalse(self.accepts())
        self.write("resume-journal.json", self.second)
        changed = copy.deepcopy(self.first); changed["executions"][2].update(transactionID="third", providerRequestID="paid-third")
        self.write("prepare-journal.json", changed); self.assertFalse(self.accepts())
        self.write("prepare-journal.json", self.first)
        (self.directory / "second-output.wav").write_bytes((self.directory / "first-output.wav").read_bytes())
        self.assertFalse(self.accepts())

    def test_history_only_requires_actual_authority_loss_and_zero_provider_requests(self):
        self.write("authoritylost-http.json", [{"method": "GET", "url": "https://queue.fal.run/known/status"}])
        self.assertFalse(self.accepts()); self.write("authoritylost-http.json", [])
        self.write("authority-remaining-batches.json", [self.batch["id"]])
        self.assertFalse(self.accepts()); self.write("authority-remaining-batches.json", [])
        self.write("authority-remaining-batches.json", ["foreign"])
        self.assertFalse(self.accepts()); self.write("authority-remaining-batches.json", [])
        for key, value in (("projectKey", "different-project"), ("coordinatorIdle", False), ("coordinatorErrorFree", False), ("authorityAvailable", True), ("providerRequests", 1), ("warning", ""), ("acceptedRequestID", "foreign")):
            changed = copy.deepcopy(self.rows)
            changed[2]["interactions"][2]["evidence"][key] = value
            self.assertFalse(self.accepts(changed))
        self.write("authoritylost-journal.json", self.second)
        self.assertFalse(self.accepts())


if __name__ == "__main__":
    unittest.main()
