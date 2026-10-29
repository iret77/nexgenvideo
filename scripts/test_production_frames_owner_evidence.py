import copy
import json
from pathlib import Path
import tempfile
import unittest

from production_frames_owner_evidence import digest, validate, validate_auto_sketches


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def auto_sketch_fixture(directory, interactions):
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
        package = {"id": str(index) * 64, "payload": {"prompt": prompt.decode()}}
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
        state("automatic Storyboard sketch through actual tools", {"shotID": "shot", "momentID": moment, "assetID": moment,
            "evidencePrefix": prefix, "files": hashes, "nativeSpendApproval": True, "staleAssignmentRejected": True,
            "liveProvider": False, "livePricing": False, "imageSHA256": digest(image), "proofSHA256": digest(proof_bytes),
            "packageSHA256": package["id"], "promptSHA256": digest(prompt)})
        click("generation-batch.approve"); click("storyboard.sketch.inspect." + moment)


def fixture(directory):
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
    auto_sketch_fixture(directory, interactions)
    artifacts = {}
    candidates = {}
    generated = {}
    def frame_file(name, data):
        name = "frame-evidence/" + name
        artifacts[name] = write(name, data)
    def candidate(index, role):
        image = b"\x89PNG\r\n\x1a\n" + bytes([index + 10]) * 100
        prompt = "unit compiled frame " + str(index)
        plan = {"bindings": [{"sha256": "a" * 64}]}
        plan_hash = digest(encoded(plan))
        package = {"id": str(index) * 64, "payload": {"prompt": prompt, "generationInput": {"frameReferencePlan": plan},
                    "binding": {"frameReferencePlanSHA256": plan_hash}}}
        package_bytes = encoded(package)
        output = {"assetID": "asset-" + str(index), "output": {"sha256": digest(image)},
                  "package": {"id": package["id"], "sha256": digest(package_bytes)}}
        value = {"receipt": {"schema": "production-frame-receipt/v1", "shotID": "shot", "role": role, "generation": output},
                 "usage": {"shotID": "shot", "role": role, "outputSHA256": digest(image), "plan": plan}}
        raw = encoded(value)
        identifier = digest(raw)
        for suffix, data in [(".json", raw), (".png", image), ("-output.json", encoded(output)), ("-package.json", package_bytes)]:
            frame_file(identifier + suffix, data)
        observed = {"candidateID": identifier, "assetID": output["assetID"], "packageSHA256": package["id"],
            "imageSHA256": digest(image), "planSHA256": plan_hash, "promptSHA256": digest(prompt.encode()),
            "referenceSHA256": ["a" * 64], "uploadedSHA256": ["a" * 64], "nativeSpendApproval": True, "liveProvider": False}
        generated[identifier] = observed
        candidates[identifier] = value
        state("actual generated frame", observed)
        state("native frame deviations accepted", {"imageSHA256": digest(image), "qualityClaim": False, "overall": "minor"})
        for action in ("generation-batch.approve", "frames.use." + identifier, "production.input.image.open." + identifier,
                       "frames.audit.accept.shot." + role):
            click(action)
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
    batch = {"id": "batch", "payload": {"items": [{"id": "item", "package": {
        "id": generated[ids[0]]["packageSHA256"], "payload": {"target": {"endpoint": "unit-image-model"}}}}]}}
    for suffix, data in [("journal-approved.json", encoded(queued)), ("journal-paused.json", encoded(queued)),
                         ("journal-complete.json", encoded(completed)), ("batch.json", encoded(batch)),
                         ("requests.json", encoded([{"method": "POST", "url": "https://queue.fal.run/unit-image-model", "bodySHA256": "a" * 64}]))]:
        write(busy_prefix + suffix, data)
    state("approved batch paused by competing host lease", {"batchID": "batch", "journalSHA256": digest(encoded(queued)),
        "pausedSHA256": digest(encoded(queued)), "requestCountBeforeContinue": 0, "spendEventCountBefore": 0,
        "spendEventCountPaused": 0, "continueEnabledWhileBusy": False, "continueEnabledWhenIdle": True, "liveProvider": False})
    state("approved batch explicitly continued", {"batchID": "batch", "candidateID": ids[0],
        "assetID": generated[ids[0]]["assetID"], "outputSHA256": generated[ids[0]]["imageSHA256"], "liveProvider": False})
    click("generation-batch.continue.batch")
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
        (self.directory / "automatic-sketch-moment-0-proof.json").write_bytes(b"{}")
        self.assertFalse(validate_auto_sketches(self.report["nativeEvidence"], self.directory))

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
