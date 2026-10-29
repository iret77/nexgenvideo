import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from review_child_owner_evidence import validate
from test_agent_structured_results_evidence import png


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True))


def fixture(directory, scale=1.0, resume_authorization=1, authorization_ids=True, authorization_identities=None):
    """Synthetic parser fixture only; never native or model execution evidence."""
    rows = []
    for backend in ["anthropicAPI", "claudeCode"]:
        root = directory / backend
        root.mkdir(parents=True)
        run_id, manifest_id = "run-fixture", "manifest-fixture"
        index = []
        def artifact(path, value, identifier=None):
            target = root / "artifacts" / path
            put(target, value)
            sha = hashlib.sha256(target.read_bytes()).hexdigest()
            index.append({"path": path, "artifact": "artifacts/" + path, "sha256": sha})
            return {"id": identifier or path, "role": "synthetic-parser", "path": path, "sha256": sha}
        manifest = {"id": manifest_id, "snapshot": {"shots": [{"shotID": str(i)} for i in range(34)]},
                    "derivatives": [{"id": str(i), "reference": {"id": str(i)}} for i in range(34)],
                    "pages": [{"id": "page-" + str(i), "itemIDs": ["item-" + str(i)], "imageIDs": [str(i * 2), str(i * 2 + 1)]} for i in range(17)]}
        put(root / "actual-manifest.json", manifest)
        manifest_ref = artifact("manifest.json", manifest, manifest_id)
        identities = authorization_identities or ["auth-0", "auth-1"]
        auths = [artifact("auth-" + str(i) + ".json", {"runID": run_id, "backend": backend, "manifest": manifest_ref,
            **({"id": identities[i]} if authorization_ids else {})}, "auth-" + str(i)) for i in range(2)]
        children, requests, lines = [], [], []
        for i, page in enumerate(manifest["pages"] + [{"id": "summary", "itemIDs": ["summary-item"]}]):
            kind = "synthesis" if i == 17 else "page"
            auth_index = 0 if i < 3 else resume_authorization
            auth = auths[auth_index]
            submission = {"manifestID": manifest_id, "pageID": page["id"], "observations": [{"itemID": item, "text": "Explicit synthetic parser observation"} for item in page["itemIDs"]], "findings": []}
            def evidence(tool, args):
                value = json.dumps(args, sort_keys=True, separators=(",", ":"))
                actual_tool = "mcp__nexgen__" + tool if backend == "claudeCode" else tool
                return {"runID": run_id, "authID": identities[auth_index], "manifestID": manifest_id, "pageID": page["id"], "generationID": "generation-" + str(i),
                        "response": {"toolName": actual_tool, "modelID": "fixture-review-model", "messageID": "message-" + tool + str(i), "toolUseID": tool + str(i),
                                     "sessionID": "child-" + str(i), "toolInputJSON": value, "toolInputSHA256": hashlib.sha256(value.encode()).hexdigest()}}
            delivery = {"kind": kind, "pageID": page["id"], "itemIDs": page["itemIDs"], "authorization": auth,
                        "deliveredImages": [{"reference": {"id": image}} for image in page.get("imageIDs", [])],
                        "readEvidence": evidence("get_render_review_page", {})}
            delivery_ref = artifact("delivery-" + str(i) + ".json", delivery)
            children.append(artifact("child-" + str(i) + ".json", {"delivery": delivery_ref, "authorization": auth,
                "submission": submission, "writeEvidence": evidence("write_render_review_page", submission)}))
            requests.append({"authID": identities[auth_index], "pageID": page["id"], "runID": run_id,
                "manifestID": manifest_id, "backend": backend, "kind": kind})
            for j, call in enumerate((delivery["readEvidence"], evidence("write_render_review_page", submission))):
                response = call["response"]
                tool = {"type": "tool_use", "id": response["toolUseID"], "name": response["toolName"],
                        "input": json.loads(response["toolInputJSON"])}
                message = {"id": response["messageID"], "model": response["modelID"], "content": [tool]}
                if backend == "anthropicAPI":
                    index_number = i * 2 + j
                    put(root / ("api-request-" + str(index_number) + ".json"), {"model": "fixture-review-model"})
                    events = [{"type": "message_start", "message": {"id": message["id"], "model": message["model"]}},
                              {"type": "content_block_start", "index": 0, "content_block": {**tool, "input": {}}},
                              {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": response["toolInputJSON"]}},
                              {"type": "content_block_stop", "index": 0}, {"type": "message_stop"}]
                    (root / ("api-response-" + str(index_number) + ".sse")).write_text("".join("data: " + json.dumps(event) + "\n\n" for event in events))
                else:
                    lines.append(json.dumps({"type": "assistant", "message": message}))
        final = {"status": "completed", "runID": run_id, "backend": backend, "modelID": "fixture-review-model", "manifest": manifest_ref, "authorizations": auths, "children": children}
        interrupted = {**final, "status": "interrupted", "authorizations": auths[:1], "children": children[:3]}
        put(root / "completed-journal.json", final); put(root / "interrupted-journal.json", interrupted)
        put(root / "write-checkpoint-journal.json", {**interrupted, "status": "running"})
        checkpoint = {"pageID": "page-2", "authID": auths[0]["id"], "page": children[2],
            "publishedPages": 3, "completedPages": 2, "shutdownHeld": True, "phaseLeaseHeld": True}
        put(root / "artifact-index.json", index); put(root / "actual-child-requests.json", requests)
        if backend == "claudeCode": put(root / "actual-cli-decoder-lines.json", lines)
        chat = {"synthetic": "Unchanged conversation/provider session fixture"}
        put(root / "chat-before.json", chat); put(root / "chat-after.json", chat)
        sha = hashlib.sha256((root / "chat-before.json").read_bytes()).hexdigest()
        beats = {"maximumGapSeconds": 0.05, "maximumAllowedGapSeconds": 0.5,
                 "boundaries": [{"label": name, "time": i} for i, name in enumerate(["prepare-start", "prepared", "completed"])],
                 "samples": [{"time": 0.05, "gapSeconds": 0.05}, {"time": 0.10, "gapSeconds": 0.05}]}
        put(root / "actual-ui-heartbeats.json", beats)
        clicks = ["render-review.agent.prepare", "render-review.agent.approve", "render-review.agent.cancel", "render-review.agent.prepare", "render-review.agent.approve"]
        actions = [{"kind": "pointer", "id": value} for value in clicks]
        actions.insert(2, {"kind": "verified-state", "label": "actual committed page before cancellation", "evidence": checkpoint})
        actions.insert(4, {"kind": "verified-state", "label": "actual Cancel waits for owned shutdown", "evidence": {
            "pageID": "page-2", "phaseLeaseHeld": True, "registryActive": True, "state": "stopping"}})
        native = {"interactions": actions, "progress": "native.json", "screenshots": ["native.png", "native-committed-page-shutdown-held.png"]}
        put(root / "native.json", {**native, "failure": None})
        (root / "native.png").write_bytes(png())
        (root / "native-committed-page-shutdown-held.png").write_bytes(png())
        row = {"backend": backend, "scale": scale, "viewport": [960, 640], "liveAgent": False,
               "shotCount": 34, "imageCount": 34, "pageCount": 17, "manifestID": manifest_id, "runID": run_id,
               "authorizationCount": 2, "interruptedPages": 2, "childContexts": len(requests), "receiptCount": len(index),
               "committedPageCheckpoint": checkpoint,
               "chatSHA256Before": sha, "chatSHA256After": sha, "native": native, "heartbeats": beats}
        put(root / "backend-result.json", row); rows.append(row)
    result = {"scale": scale, "liveAgent": False, "backends": rows}
    put(directory / "review-child-owner-result.json", result)
    return result


class ReviewChildOwnerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); fixture(self.root)

    def test_explicit_synthetic_parser_fixture(self):
        self.assertEqual(len(validate(self.root)["backends"]), 2)

    def test_outer_scale_mismatch(self):
        with self.assertRaises(ValueError): validate(self.root, 1.5)

    def test_retained_receipt_tamper(self):
        (self.root / "anthropicAPI/artifacts/child-0.json").write_text("changed")
        with self.assertRaises(ValueError): validate(self.root)

    def test_chat_mutation(self):
        put(self.root / "claudeCode/chat-after.json", {"unexpected": "new turn"})
        with self.assertRaises(ValueError): validate(self.root)

    def test_missing_api_wire(self):
        (self.root / "anthropicAPI/api-request-0.json").unlink()
        with self.assertRaises(ValueError): validate(self.root)

    def test_resume_cannot_reuse_old_authorization(self):
        path = self.root / "anthropicAPI/completed-journal.json"
        value = json.loads(path.read_text()); value["authorizations"] = value["authorizations"][:1]; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_lost_retained_page(self):
        path = self.root / "anthropicAPI/completed-journal.json"
        value = json.loads(path.read_text()); value["children"].pop(0); put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_mismatched_saved_backend_result(self):
        path = self.root / "anthropicAPI/backend-result.json"
        value = json.loads(path.read_text()); value["liveAgent"] = True; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_committed_page_must_survive_cancel_for_both_backends(self):
        for backend in ("anthropicAPI", "claudeCode"):
            path = self.root / backend / "interrupted-journal.json"
            original = json.loads(path.read_text())
            changed = copy.deepcopy(original); changed["children"].pop()
            checkpoint = self.root / backend / "write-checkpoint-journal.json"
            saved_checkpoint = json.loads(checkpoint.read_text())
            put(path, changed); put(checkpoint, {**changed, "status": "running"})
            with self.assertRaisesRegex(ValueError, "committed page was orphaned"): validate(self.root)
            put(path, original); put(checkpoint, saved_checkpoint)

    def test_explicit_resume_must_not_repeat_committed_context(self):
        for backend in ("anthropicAPI", "claudeCode"):
            path = self.root / backend / "actual-child-requests.json"
            original = json.loads(path.read_text())
            repeated = copy.deepcopy(next(row for row in original if row["pageID"] == "page-2"))
            repeated["authID"] = "auth-1"
            put(path, original + [repeated])
            result_path = self.root / "review-child-owner-result.json"
            result = json.loads(result_path.read_text()); saved = copy.deepcopy(result)
            record = next(row for row in result["backends"] if row["backend"] == backend)
            record["childContexts"] += 1
            put(result_path, result); put(self.root / backend / "backend-result.json", record)
            if backend == "anthropicAPI":
                number = len(list((self.root / backend).glob("api-request-*.json")))
                (self.root / backend / f"api-request-{number}.json").write_bytes((self.root / backend / "api-request-0.json").read_bytes())
                (self.root / backend / f"api-response-{number}.sse").write_bytes((self.root / backend / "api-response-0.sse").read_bytes())
            else:
                decoder = self.root / backend / "actual-cli-decoder-lines.json"
                original_lines = json.loads(decoder.read_text()); put(decoder, original_lines + [original_lines[0]])
            with self.assertRaisesRegex(ValueError, "Resume repeated the already committed page"): validate(self.root)
            if backend == "claudeCode": put(decoder, original_lines)
            else:
                for suffix in ("json", "sse"):
                    name = f"api-{'request' if suffix == 'json' else 'response'}-{number}.{suffix}"
                    (self.root / backend / name).rename(self.root / backend / (name + ".ignored"))
            put(path, original); put(result_path, saved)
            put(self.root / backend / "backend-result.json", next(row for row in saved["backends"] if row["backend"] == backend))

    def update_record(self, backend, update):
        result_path = self.root / "review-child-owner-result.json"
        result = json.loads(result_path.read_text())
        record = next(row for row in result["backends"] if row["backend"] == backend)
        update(record)
        put(result_path, result); put(self.root / backend / "backend-result.json", record)
        put(self.root / backend / "native.json", {**record["native"], "failure": None})
        return record

    def test_cancel_must_follow_committed_checkpoint_for_each_backend(self):
        for backend in ("anthropicAPI", "claudeCode"):
            original = json.loads((self.root / "review-child-owner-result.json").read_text())
            def change(record):
                actions = record["native"]["interactions"]
                actions[2], actions[3] = actions[3], actions[2]
            self.update_record(backend, change)
            with self.assertRaisesRegex(ValueError, "Cancel did not wait"): validate(self.root)
            put(self.root / "review-child-owner-result.json", original)
            previous = next(row for row in original["backends"] if row["backend"] == backend)
            put(self.root / backend / "backend-result.json", previous); put(self.root / backend / "native.json", {**previous["native"], "failure": None})

    def test_boolean_scale_cannot_claim_actual_100_percent(self):
        path = self.root / "review-child-owner-result.json"
        value = json.loads(path.read_text()); value["scale"] = True
        for row in value["backends"]:
            row["scale"] = True; put(self.root / row["backend"] / "backend-result.json", row)
        put(path, value)
        with self.assertRaisesRegex(ValueError, "scale or fixture scope"): validate(self.root, 1.0)

    def test_false_held_shutdown_cannot_be_replaced_by_true_summary(self):
        self.update_record("claudeCode", lambda record: record["committedPageCheckpoint"].update(shutdownHeld=False))
        with self.assertRaisesRegex(ValueError, "committed page was orphaned"): validate(self.root)

    def test_missing_stopping_state_cannot_prove_owned_shutdown(self):
        self.update_record("claudeCode", lambda record: record["native"].update(interactions=[row for row in record["native"]["interactions"] if row.get("label") != "actual Cancel waits for owned shutdown"]))
        with self.assertRaisesRegex(ValueError, "Cancel did not wait"): validate(self.root)

    def test_retained_failure_log_refuses_even_with_true_success_record(self):
        native = self.root / "anthropicAPI/native.json"
        value = json.loads(native.read_text()); value["failure"] = "Actual isolated fixture failure"; put(native, value)
        with self.assertRaisesRegex(ValueError, "native log differs"): validate(self.root)

    def test_heartbeat_maximum_is_recomputed_from_actual_samples(self):
        def change(record):
            record["heartbeats"]["samples"][1].update(time=0.65, gapSeconds=0.6)
        record = self.update_record("anthropicAPI", change)
        put(self.root / "anthropicAPI/actual-ui-heartbeats.json", record["heartbeats"])
        with self.assertRaisesRegex(ValueError, "actual retained samples"): validate(self.root)

    def test_actual_cli_tool_identity_must_match_receipt(self):
        path = self.root / "claudeCode/actual-cli-decoder-lines.json"
        lines = json.loads(path.read_text()); value = json.loads(lines[0]); value["message"]["id"] = "unrelated-real-shaped-response"; lines[0] = json.dumps(value); put(path, lines)
        with self.assertRaisesRegex(ValueError, "backend responses do not bind"): validate(self.root)

    def test_actual_api_tool_input_must_match_receipt(self):
        path = self.root / "anthropicAPI/api-response-0.sse"
        rows = [json.loads(line[6:]) for line in path.read_text().splitlines() if line.startswith("data: ")]
        next(row for row in rows if row["type"] == "content_block_delta")["delta"]["partial_json"] = '{"unrelated":true}'
        path.write_text("".join("data: " + json.dumps(row) + "\n\n" for row in rows))
        with self.assertRaisesRegex(ValueError, "backend responses do not bind"): validate(self.root)


    def test_new_authorization_must_actually_own_resumed_children(self):
        root = self.root / "unused-new-approval"
        fixture(root, resume_authorization=0)
        with self.assertRaisesRegex(ValueError, "resumed child did not use the new approval"): validate(root)

    def test_authorization_identity_must_come_from_its_own_artifact(self):
        root = self.root / "missing-authorization-identity"
        fixture(root, authorization_ids=False)
        with self.assertRaisesRegex(ValueError, "authorization artifact lacks its own identity"): validate(root)

    def test_separate_resumed_artifact_cannot_reuse_the_original_authorization_identity(self):
        for resumed_id in ("auth-0", "AUTH-0"):
            root = self.root / ("reused-authorization-" + resumed_id)
            fixture(root, authorization_identities=["auth-0", resumed_id])
            with self.subTest(resumed_id=resumed_id), self.assertRaisesRegex(ValueError, "reused an authorization identity"):
                validate(root)

    def test_backend_boolean_scale_cannot_claim_100_percent(self):
        self.update_record("anthropicAPI", lambda row: row.update(scale=True))
        with self.assertRaisesRegex(ValueError, "actual backend result differs"): validate(self.root, 1.0)

    def test_request_must_match_its_actual_run_manifest_backend_and_kind(self):
        for backend in ("anthropicAPI", "claudeCode"):
            path = self.root / backend / "actual-child-requests.json"
            original = json.loads(path.read_text())
            for key in ("runID", "manifestID", "backend", "kind"):
                with self.subTest(backend=backend, key=key):
                    rows = copy.deepcopy(original); rows[-1][key] = "unrelated"
                    put(path, rows)
                    with self.assertRaisesRegex(ValueError, "actual request context differs"): validate(self.root)
                    put(path, original)


if __name__ == "__main__": unittest.main()
