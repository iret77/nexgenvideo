import copy
import json
from pathlib import Path
import tempfile
import unittest

from generation_batch_busy_evidence import validate
from production_frames_owner_evidence import digest
from test_production_frames_owner_evidence import fixture


class BatchBusyEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.native = fixture(self.root)["nativeEvidence"]

    def test_exact_queued_bytes_and_native_continuation_are_required(self):
        self.assertTrue(validate(self.native, self.root))
        path = self.root / "batch-busy-evidence/journal-paused.json"
        changed = json.loads(path.read_bytes())
        changed["executions"][0]["state"] = "blocked"
        path.write_text(json.dumps(changed))
        self.assertFalse(validate(self.native, self.root))

    def test_status_flags_do_not_replace_native_click(self):
        changed = copy.deepcopy(self.native)
        changed["interactions"][:] = [row for row in changed["interactions"]
                                      if row.get("id") != "generation-batch.continue.batch"]
        self.assertFalse(validate(changed, self.root))

    def test_duplicate_submission_or_changed_output_is_rejected(self):
        path = self.root / "batch-busy-evidence/requests.json"
        requests = json.loads(path.read_bytes())
        path.write_text(json.dumps(requests + requests))
        self.assertFalse(validate(self.native, self.root))
        path.write_text(json.dumps(requests))
        complete = self.root / "batch-busy-evidence/journal-complete.json"
        journal = json.loads(complete.read_bytes())
        journal["executions"][0]["outputAssetIDs"] = ["different-output"]
        complete.write_text(json.dumps(journal))
        self.assertFalse(validate(self.native, self.root))

    def test_requests_or_enabled_button_during_busy_phase_are_rejected(self):
        for key, value in [("requestCountBeforeContinue", 1), ("continueEnabledWhileBusy", True),
                           ("continueEnabledWhenIdle", False), ("spendEventCountPaused", 1)]:
            changed = copy.deepcopy(self.native)
            evidence = next(row["evidence"] for row in changed["interactions"]
                            if row.get("label") == "approved batch paused by competing host lease")
            evidence[key] = value
            self.assertFalse(validate(changed, self.root))

    def pause(self, native=None):
        return next(row["evidence"] for row in (native or self.native)["interactions"]
                    if row.get("label") == "approved batch paused by competing host lease")

    def test_equal_but_blocked_journals_cannot_claim_an_unsent_pause(self):
        path = self.root / "batch-busy-evidence/journal-approved.json"
        journal = json.loads(path.read_bytes())
        journal["executions"][0]["state"] = "blocked"
        changed = json.dumps(journal).encode()
        path.write_bytes(changed)
        (self.root / "batch-busy-evidence/journal-paused.json").write_bytes(changed)
        self.pause()["journalSHA256"] = self.pause()["pausedSHA256"] = digest(changed)
        self.assertFalse(validate(self.native, self.root))

    def test_actual_started_resumed_and_host_busy_reason_are_required(self):
        for key, value in [("activeBatchBeforeRelease", "other"), ("catalogBarrierResumed", False),
                           ("catalogWaiterCount", 0), ("pauseReason", "requestRefused"),
                           ("pauseLabel", "unrelated work"), ("idleSettleMilliseconds", 0)]:
            changed = copy.deepcopy(self.native)
            self.pause(changed)[key] = value
            self.assertFalse(validate(changed, self.root))

    def test_screenshots_role_and_temporal_order_are_required(self):
        changed = copy.deepcopy(self.native)
        changed["screenshots"] = [name for name in changed["screenshots"] if "batch-paused-host-busy" not in name]
        self.assertFalse(validate(changed, self.root))
        changed = copy.deepcopy(self.native)
        generated = next(row for row in changed["interactions"] if row.get("label") == "actual generated frame")
        generated["evidence"]["role"] = "end"
        self.assertFalse(validate(changed, self.root))
        changed = copy.deepcopy(self.native)
        continued = next(row for row in changed["interactions"] if row.get("label") == "approved batch explicitly continued")
        changed["interactions"].remove(continued)
        changed["interactions"].insert(0, continued)
        self.assertFalse(validate(changed, self.root))
        changed = copy.deepcopy(self.native)
        changed["interactions"].append({"kind": "pointer", "id": "generation-batch.continue.batch"})
        self.assertFalse(validate(changed, self.root))

    def test_batch_authority_revision_and_package_are_exact(self):
        path = self.root / "batch-busy-evidence/journal-complete.json"
        before = path.read_bytes()
        for key, value in [("batchID", "other"), ("authorityID", "other"), ("revision", 0)]:
            changed = json.loads(before)
            changed[key] = value
            path.write_text(json.dumps(changed))
            self.assertFalse(validate(self.native, self.root))
        path.write_bytes(before)
        changed = copy.deepcopy(self.native)
        next(row["evidence"] for row in changed["interactions"] if row.get("label") == "actual generated frame")["packageSHA256"] = "f" * 64
        self.assertFalse(validate(changed, self.root))

    def test_actual_put_and_compiled_post_bytes_are_independently_joined(self):
        path = self.root / "batch-busy-evidence/requests.json"
        requests = json.loads(path.read_bytes())
        put = next(row for row in requests if row["method"] == "PUT")
        (self.root / "batch-busy-evidence" / put["bodyFile"]).write_bytes(b"substituted reference bytes")
        put["bodySHA256"] = digest(b"substituted reference bytes")
        path.write_text(json.dumps(requests))
        self.assertFalse(validate(self.native, self.root))

    def test_rehashed_provider_prompt_still_has_to_match_the_compiled_prompt(self):
        path = self.root / "batch-busy-evidence/requests.json"
        requests = json.loads(path.read_bytes())
        post = next(row for row in requests if row["url"] == "https://queue.fal.run/unit-image-model")
        body = self.root / "batch-busy-evidence" / post["bodyFile"]
        changed = json.loads(body.read_bytes())
        changed["prompt"] = "different uncompiled direction"
        changed = json.dumps(changed).encode()
        body.write_bytes(changed)
        post["bodySHA256"] = digest(changed)
        path.write_text(json.dumps(requests))
        self.assertFalse(validate(self.native, self.root))

    def test_wrong_or_extra_provider_posts_are_rejected(self):
        path = self.root / "batch-busy-evidence/requests.json"
        before = path.read_bytes()
        requests = json.loads(before)
        requests[-1]["url"] = "https://queue.fal.run/different-model"
        path.write_text(json.dumps(requests))
        self.assertFalse(validate(self.native, self.root))
        requests = json.loads(before)
        requests.append({"method": "POST", "url": "https://other.invalid/submit", "bodySHA256": digest(b""), "bodyFile": "request-3.bin"})
        (self.root / "batch-busy-evidence/request-3.bin").write_bytes(b"")
        path.write_text(json.dumps(requests))
        self.assertFalse(validate(self.native, self.root))

    def test_boolean_counts_and_revisions_are_not_integers(self):
        for key in ["requestCountBeforeContinue", "spendEventCountBefore", "spendEventCountPaused", "catalogWaiterCount", "idleSettleMilliseconds"]:
            changed = copy.deepcopy(self.native)
            self.pause(changed)[key] = key == "catalogWaiterCount"
            self.assertFalse(validate(changed, self.root))
        path = self.root / "batch-busy-evidence/journal-complete.json"
        value = json.loads(path.read_bytes())
        value["revision"] = True
        path.write_text(json.dumps(value))
        self.assertFalse(validate(self.native, self.root))

    def test_exact_batch_bytes_endpoint_and_provider_receipt_are_bound(self):
        path = self.root / "batch-busy-evidence/batch.json"
        before = path.read_bytes()
        value = json.loads(before)
        value["payload"]["items"][0]["package"]["payload"]["target"]["endpoint"] = "different-model"
        path.write_text(json.dumps(value))
        self.assertFalse(validate(self.native, self.root))
        self.pause()["batchSHA256"] = digest(path.read_bytes())
        self.assertFalse(validate(self.native, self.root))
        path.write_bytes(before)
        self.pause()["batchSHA256"] = digest(before)
        path = self.root / "batch-busy-evidence/journal-complete.json"
        value = json.loads(path.read_bytes())
        value["executions"][0]["providerRequestID"] = "different-actual-request"
        path.write_text(json.dumps(value))
        self.assertFalse(validate(self.native, self.root))


if __name__ == "__main__":
    unittest.main()
