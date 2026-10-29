import copy
import json
from pathlib import Path
import tempfile
import unittest

from production_frames_owner_evidence import digest, validate, validate_auto_sketches


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def auto_sketch_fixture(directory, interactions, forged_package=False):
    def state(label, evidence):
        interactions.append({"kind": "verified-state", "label": label, "evidence": evidence})
    def click(identifier):
        interactions.append({"kind": "pointer", "id": identifier})
    def write(name, data):
        (directory / name).write_bytes(data)
        return digest(data)
    state("actual image catalog via isolated HTTP", {"liveProvider": False})
    for index in range(2):
        moment = f"moment-{index}"
        prefix = "automatic-sketch-" + moment
        image = b"\x89PNG\r\n\x1a\n" + bytes([index]) * 100
        prompt = b"unit compiled sketch prompt"
        image_ref = {"sha256": digest(image)}
        payload = {"prompt": prompt.decode()}
        package = {"id": str(index) * 64 if forged_package else digest(encoded(payload)), "payload": payload}
        package_bytes = encoded(package)
        output = {"assetID": moment, "output": image_ref,
                  "package": {"id": package["id"], "sha256": digest(package_bytes)}, "input": {"prompt": prompt.decode()}}
        output_bytes = encoded(output)
        generation = {"shotID": "shot", "momentID": moment, "image": image_ref, "outputReceipt": {"sha256": digest(output_bytes)}}
        generation_bytes = encoded(generation)
        proof = {"schema": "storyboard-sketch-proof/v1", "shotID": "shot", "momentID": moment, "image": image_ref,
                 "source": {"generated": {"generationEventID": moment, "compiledPrompt": {"sha256": digest(prompt)},
                                          "generationReceipt": {"sha256": digest(generation_bytes)}}}}
        proof_bytes = encoded(proof)
        artifacts = {prefix + "-" + suffix: data for suffix, data in [("proof.json", proof_bytes), ("image.png", image),
            ("prompt.txt", prompt), ("output.json", output_bytes), ("package.json", package_bytes), ("generation.json", generation_bytes)]}
        hashes = {name: write(name, data) for name, data in artifacts.items()}
        click("generation-batch.approve"); click("storyboard.sketch.inspect." + moment)
        state("automatic Storyboard sketch through actual tools", {"shotID": "shot", "momentID": moment, "assetID": moment,
            "evidencePrefix": prefix, "files": hashes, "nativeSpendApproval": True, "staleAssignmentRejected": True,
            "liveProvider": False, "livePricing": False, "imageSHA256": digest(image), "proofSHA256": digest(proof_bytes),
            "packageSHA256": package["id"], "promptSHA256": digest(prompt)})


def fixture(directory, forged_frame_package=False, forged_sketch_package=False):
    interactions = []
    def state(label, evidence):
        interactions.append({"kind": "verified-state", "label": label, "evidence": evidence})
    def click(identifier):
        interactions.append({"kind": "pointer", "id": identifier})
    def write(name, data):
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return digest(data)
    native = {"interactions": interactions, "screenshots": [f"screen-{index}.png" for index in range(12)], "progress": "native-frames.json"}
    for name in native["screenshots"]:
        write(name, b"\x89PNG\r\n\x1a\n" + b"unit screenshot" * 100)
    auto_sketch_fixture(directory, interactions, forged_package=forged_sketch_package)
    from test_production_technical_owner_evidence import technical_fixture
    technical_fixture(directory, native)
    reference_bytes = b"unit reference bytes for independent PUT hashing"
    reference_sha = digest(reference_bytes)
    artifacts = {}
    candidates = {}
    generated = {}
    def frame_file(name, data):
        name = "frame-evidence/" + name
        artifacts[name] = write(name, data)
    def candidate(index, role):
        image = b"\x89PNG\r\n\x1a\n" + bytes([index + 10]) * 100
        prompt = "unit compiled frame " + str(index)
        plan = {"bindings": [{"sha256": reference_sha}]}
        plan_hash = digest(encoded(plan))
        payload = {"prompt": prompt, "target": {"endpoint": "unit-image-model"}, "generationInput": {"frameReferencePlan": plan},
                   "binding": {"frameReferencePlanSHA256": plan_hash}}
        package = {"id": str(index) * 64 if forged_frame_package else digest(encoded(payload)), "payload": payload}
        package_bytes = encoded(package)
        output = {"assetID": "asset-" + str(index), "output": {"sha256": digest(image)},
                  "package": {"id": package["id"], "sha256": digest(package_bytes)}}
        value = {"receipt": {"schema": "production-frame-receipt/v1", "shotID": "shot", "role": role, "generation": output},
                 "usage": {"shotID": "shot", "role": role, "outputSHA256": digest(image), "plan": plan}}
        raw = encoded(value)
        identifier = digest(raw)
        for suffix, data in [(".json", raw), (".png", image), ("-output.json", encoded(output)), ("-package.json", package_bytes)]:
            frame_file(identifier + suffix, data)
        observed = {"role": role, "shotID": "shot", "providerRequestID": "request", "modelEndpoint": "unit-image-model", "candidateID": identifier, "assetID": output["assetID"], "packageSHA256": package["id"],
            "imageSHA256": digest(image), "planSHA256": plan_hash, "promptSHA256": digest(prompt.encode()),
            "referenceSHA256": [reference_sha], "uploadedSHA256": [reference_sha], "nativeSpendApproval": True, "liveProvider": False}
        generated[identifier] = observed
        candidates[identifier] = value
        click("generation-batch.approve")
        state("actual generated frame", observed)
        for action in ("frames.use." + identifier, "production.input.image.open." + identifier, "frames.audit.accept.shot." + role):
            click(action)
        state("native frame deviations accepted", {"imageSHA256": digest(image), "qualityClaim": False, "overall": "minor"})
        return identifier
    ids = [candidate(index, "start") for index in range(3)]
    end = candidate(3, "end")
    busy_prefix = "batch-busy-evidence/"
    queued = {"batchID": "batch", "authorityID": "unit-authority", "approvedAt": 1, "revision": 0,
              "executions": [{"itemID": "item", "state": "queued", "outputAssetIDs": []}]}
    completed = copy.deepcopy(queued)
    completed["revision"] = 3
    completed["executions"][0].update(state="complete", transactionID="transaction", providerRequestID="request",
                                      outputAssetIDs=[generated[ids[0]]["assetID"]])
    frame_package = json.loads((directory / "frame-evidence" / (ids[0] + "-package.json")).read_bytes())
    batch = {"id": "batch", "payload": {"items": [{"id": "item", "package": frame_package}]}}
    request_bodies = [encoded({"file_name": "frame-input-0.png"}), reference_bytes,
                      encoded({"prompt": "unit compiled frame 0", "image_urls": ["https://media.invalid/frame-input-0.png"]})]
    request_methods = ["POST", "PUT", "POST"]
    request_urls = ["https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3",
                    "https://upload.invalid/frame-input-0.png", "https://queue.fal.run/unit-image-model"]
    requests = []
    for index, body in enumerate(request_bodies):
        filename = f"request-{index}.bin"
        write(busy_prefix + filename, body)
        requests.append({"method": request_methods[index], "url": request_urls[index],
                         "bodySHA256": digest(body), "bodyFile": filename})
    for suffix, data in [("journal-approved.json", encoded(queued)), ("journal-paused.json", encoded(queued)),
                         ("journal-complete.json", encoded(completed)), ("batch.json", encoded(batch)),
                         ("requests.json", encoded(requests))]:
        write(busy_prefix + suffix, data)
    first_generated = next(index for index, row in enumerate(interactions)
                           if row.get("label") == "actual generated frame" and row["evidence"]["candidateID"] == ids[0])
    pause_row = {"kind": "verified-state", "label": "approved batch paused by competing host lease", "evidence": {
        "batchID": "batch", "batchSHA256": digest(encoded(batch)), "journalSHA256": digest(encoded(queued)), "pausedSHA256": digest(encoded(queued)),
        "requestCountBeforeContinue": 0, "spendEventCountBefore": 0, "spendEventCountPaused": 0,
        "continueEnabledWhileBusy": False, "continueEnabledWhenIdle": True, "activeBatchBeforeRelease": "batch",
        "catalogBarrierResumed": True, "catalogWaiterCount": 1, "pauseReason": "hostBusy",
        "pauseLabel": "Isolated competing native edit", "idleSettleMilliseconds": 250, "liveProvider": False}}
    interactions[first_generated:first_generated] = [pause_row, {"kind": "pointer", "id": "generation-batch.continue.batch"}]
    interactions.insert(first_generated + 3, {"kind": "verified-state", "label": "approved batch explicitly continued", "evidence": {
        "batchID": "batch", "candidateID": ids[0], "assetID": generated[ids[0]]["assetID"],
        "outputSHA256": generated[ids[0]]["imageSHA256"], "liveProvider": False}})
    for label in ["batch-paused-host-busy", "batch-paused-host-idle"]:
        filename = "unit-" + label + ".png"
        write(filename, b"\x89PNG\r\n\x1a\n" + b"parser-only screenshot" * 100)
        native["screenshots"].append(filename)
    for role, values in [("start", ids), ("end", [end])]:
        index = {"schema": "production-frame-candidates/v1", "shotID": "shot", "role": role,
                 "candidates": [{"id": identifier, "sha256": identifier} for identifier in values],
                 "active": values[-1], "decisions": [{"candidateID": identifier} for identifier in values]}
        frame_file(role + "-index.json", encoded(index))
        audit = {"shot_id": "shot", "role": role, "render_sha256": generated[values[-1]]["imageSHA256"],
                 "checks": {"framing": {"status": "minor"}}}
        audit_yaml = b"unit yaml audit " + role.encode()
        frame_file(role + "-audit.json", encoded(audit)); frame_file(role + "-audit.yaml", audit_yaml)
        frame_file(role + "-acceptance.json", encoded({"schema": "frame-audit-acceptance/v1",
            "imageSHA256": audit["render_sha256"], "auditSHA256": digest(audit_yaml), "acceptedChecks": ["framing"], "reason": "unit deviation"}))
    for kind, selected in [("redo", [ids[0]]), ("remix", ids[:2])]:
        recipe = {"kind": kind, "shotID": "shot", "role": "start", "sources": [{"candidate": {"id": value}, "aspects": ["Composition"]} for value in selected]}
        recipe_bytes = encoded(recipe)
        frame_file(digest(recipe_bytes) + "-iteration.json", recipe_bytes)
        state("native frame " + kind, {"candidateIDs": selected, "iterationSHA256": digest(recipe_bytes)})
        click("frames.iteration.submit")
    click("frames.redo." + ids[0]); click("frames.remix.shot.start")
    for identifier in ids[:2]: click("frames.pick." + identifier)
    state("application-menu", {"path": ["File", "Save"]})
    interactions.append({"kind": "visible-group", "ids": ["frames.iteration.cancel", "frames.iteration.submit"],
                         "frames": [[0, 0, 100, 30], [120, 0, 100, 30]], "viewport": [0, 0, 720, 500]})
    for index in range(6):
        interactions.append({"kind": "text", "field": {"id": "frames.iteration.note" if index < 2 else "frames.audit.reason.shot.start",
            "stage": "commit-requested", "commitInput": "Tab", "expected": "explicit reason", "actual": "explicit reason", "fontPointSize": 13}})
    report = {"workflow": "core", "viewport": {"width": 960, "height": 640, "textScale": 1, "backingScale": 2}, "framesApproved": True,
        "frames": {"shotID": "shot", "roles": ["start", "end"], "candidateIDs": ids, "selectedID": ids[-1], "endCandidateID": end,
            "selectionHistory": ids, "liveProvider": False, "staleSelectionRejected": True, "oldAuditRejected": True,
            "redoPreservedSelection": True, "remixPreservedSelection": True,
            "changedEvidence": {"changedPipelineCopyRejected": True, "changedHomeSourceRejected": True, "restoredExactEvidence": True}},
        "persistence": {"nativeSave": True, "candidateHistoryPreserved": True, "selectedFrameAndAuditsCurrent": True,
            "reopenMethod": "VideoProject.load", "files": artifacts}, "nativeEvidence": native}
    (directory / native["progress"]).write_bytes(encoded({"interactions": interactions, "screenshots": native["screenshots"], "failure": None}))
    return report


class FrameOwnerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.report = fixture(self.directory)

    def test_exact_artifact_graph_is_accepted(self):
        self.assertTrue(validate(self.report, self.directory, 1))

    def test_result_flags_cannot_replace_source_bytes(self):
        identifier = self.report["frames"]["candidateIDs"][0]
        (self.directory / "frame-evidence" / (identifier + ".png")).write_bytes(b"changed")
        self.assertFalse(validate(self.report, self.directory, 1))

    def test_new_candidates_cannot_replace_selection_without_native_use(self):
        for key in ("staleSelectionRejected", "oldAuditRejected", "redoPreservedSelection", "remixPreservedSelection"):
            changed = copy.deepcopy(self.report); changed["frames"][key] = False
            self.assertFalse(validate(changed, self.directory, 1))
        changed = copy.deepcopy(self.report); changed["frames"]["selectedID"] = changed["frames"]["candidateIDs"][0]
        self.assertFalse(validate(changed, self.directory, 1))

    def test_missing_real_ui_actions_are_rejected_even_in_matching_progress(self):
        for control in ("generation-batch.approve", "frames.iteration.submit", "frames.use." + self.report["frames"]["selectedID"]):
            changed = copy.deepcopy(self.report)
            rows = changed["nativeEvidence"]["interactions"]
            rows[:] = [row for row in rows if row.get("id") != control]
            (self.directory / "native-frames.json").write_bytes(encoded({"interactions": rows, "screenshots": changed["nativeEvidence"]["screenshots"], "failure": None}))
            self.assertFalse(validate(changed, self.directory, 1))

    def test_sketch_proof_swap_is_rejected(self):
        self.assertTrue(validate_auto_sketches(self.report["nativeEvidence"], self.directory))
        row = next(value["evidence"] for value in self.report["nativeEvidence"]["interactions"]
                   if value.get("label") == "automatic Storyboard sketch through actual tools")
        name = row["evidencePrefix"] + "-proof.json"
        proof = json.loads((self.directory / name).read_bytes())
        proof["momentID"] = "different-moment"
        raw = encoded(proof)
        (self.directory / name).write_bytes(raw)
        row["files"][name] = row["proofSHA256"] = digest(raw)
        self.assertFalse(validate_auto_sketches(self.report["nativeEvidence"], self.directory))

    def test_six_approvals_must_precede_their_own_six_generations(self):
        changed = copy.deepcopy(self.report)
        rows = changed["nativeEvidence"]["interactions"]
        frames = [i for i, row in enumerate(rows) if row.get("label") == "actual generated frame"]
        first = max(i for i in range(frames[0]) if rows[i].get("id") == "generation-batch.approve")
        second = max(i for i in range(frames[1]) if rows[i].get("id") == "generation-batch.approve")
        rows.insert(first, rows.pop(second))
        self.write_progress(changed)
        self.assertFalse(validate(changed, self.directory, 1))

    def test_self_declared_package_ids_fail_with_other_hashes_consistent(self):
        for option in ("forged_frame_package", "forged_sketch_package"):
            directory = self.directory / option
            directory.mkdir()
            changed = fixture(directory, **{option: True})
            self.assertFalse(validate(changed, directory, 1))

    def test_sketch_inspection_cannot_follow_its_retained_observation(self):
        changed = copy.deepcopy(self.report)
        rows = changed["nativeEvidence"]["interactions"]
        index = next(i for i, row in enumerate(rows) if row.get("id") == "storyboard.sketch.inspect.moment-0")
        action = rows.pop(index)
        result = next(i for i, row in enumerate(rows) if row.get("label") == "automatic Storyboard sketch through actual tools")
        rows.insert(result + 1, action)
        self.write_progress(changed)
        self.assertFalse(validate(changed, self.directory, 1))

    def test_iteration_sources_and_visible_ids_cannot_repeat(self):
        changed = copy.deepcopy(self.report)
        row = next(value["evidence"] for value in changed["nativeEvidence"]["interactions"] if value.get("label") == "native frame remix")
        row["candidateIDs"].append(row["candidateIDs"][0])
        self.write_progress(changed)
        self.assertFalse(validate(changed, self.directory, 1))
        changed = copy.deepcopy(self.report)
        row = next(value for value in changed["nativeEvidence"]["interactions"] if value.get("kind") == "visible-group"
                   and "frames.iteration.submit" in value.get("ids", []))
        row["ids"].append("frames.iteration.submit")
        row["frames"].append([240, 0, 100, 30])
        self.write_progress(changed)
        self.assertFalse(validate(changed, self.directory, 1))

    def write_progress(self, report):
        (self.directory / "native-frames.json").write_bytes(encoded({"interactions": report["nativeEvidence"]["interactions"],
            "screenshots": report["nativeEvidence"]["screenshots"], "failure": None}))

    def test_font_scale_is_not_inferred_from_retina_pixels(self):
        self.assertFalse(validate(self.report, self.directory, 1.5))
        changed = copy.deepcopy(self.report); changed["viewport"]["textScale"] = 1.5
        self.assertFalse(validate(changed, self.directory, 1.5))
        for row in changed["nativeEvidence"]["interactions"]:
            if row.get("kind") == "text": row["field"]["fontPointSize"] = 19.5
        (self.directory / "native-frames.json").write_bytes(encoded({"interactions": changed["nativeEvidence"]["interactions"],
            "screenshots": changed["nativeEvidence"]["screenshots"], "failure": None}))
        self.assertTrue(validate(changed, self.directory, 1.5))

    def test_reopen_and_audit_requirements_remain_mandatory(self):
        for key in ("nativeSave", "candidateHistoryPreserved", "selectedFrameAndAuditsCurrent"):
            changed = copy.deepcopy(self.report); changed["persistence"][key] = False
            self.assertFalse(validate(changed, self.directory, 1))

    def test_scope_requires_its_actual_completed_case(self):
        from workspace_ui_acceptance import frames_owner_evidence
        name = "scale-100-frames-owner"
        directory = self.directory / name
        directory.mkdir()
        report = fixture(directory)
        report.update(event="production-frames-owner", scale=1, evidenceDirectory=name)
        completed = {"event": "completed", "case": "frames", "scale": 1}
        self.assertTrue(frames_owner_evidence([report, completed], self.directory, 1)[0])
        self.assertFalse(frames_owner_evidence([report], self.directory, 1)[0])
        self.assertFalse(frames_owner_evidence([report, completed], self.directory, 1.5)[0])
        self.assertFalse(frames_owner_evidence([report, report, completed], self.directory, 1)[0])


if __name__ == "__main__":
    unittest.main()
