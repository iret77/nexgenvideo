"""Synthetic validator controls; these are not native acceptance evidence."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from uuid import UUID

from color_reference_evidence import validate


class ColorReferenceValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.scopes = {
            "clip": {"luma": {"mean": 0.2, "black": 0.1, "white": 0.8, "clipLowPct": 1.0, "clipHighPct": 2.0},
                     "saturation": 0.4, "balance": {"warmCool": -0.2, "greenMagenta": 0.3}},
            "reference": {"luma": {"mean": 0.5, "black": 0.15, "white": 0.9, "clipLowPct": 3.0, "clipHighPct": 4.0},
                          "saturation": 0.5, "balance": {"warmCool": 0.1, "greenMagenta": 0.4}},
            "gap": {"lumaMean": -0.3, "lumaBlack": -0.05, "lumaWhite": -0.1,
                    "saturation": -0.1, "warmCool": -0.3, "greenMagenta": -0.1}}
        self.scopes["clipSampling"] = {"kind": "video", "requestedValue": 0, "requestedTimescale": 600,
            "actualValue": 0, "actualTimescale": 30, "actualEpoch": 0}
        self.scopes["referenceSampling"] = {"kind": "video", "requestedValue": 900, "requestedTimescale": 600,
            "actualValue": 45, "actualTimescale": 30, "actualEpoch": 0}
        self.actions, self.screenshots = [], []
        self.requests, self.proposals, self.observations = [], [], []
        self.result = {key: True for key in ("nativeMeasuredComparison", "actualToolReadout", "nativeProposalDiscard",
            "nativeProposalApply", "nativeUndoRedo", "nativeStaleRefusal", "sourceProjectPreserved")}
        self.result.update(liveAgent=False, directMutationRefusals=3, clipID="clip", referenceID="reference",
            interactions=self.actions, measurements=self.observations, screenshots=self.screenshots,
            progress="native-color-reference.json", timelines={})
        reference = b"isolated imported reference fixture"
        (self.root / "Cool comparison reference.mov").write_bytes(reference)
        self.result.update(viewport=[960, 640], scale=1.5, nativeReferenceImport=True, referenceSHA256=self.sha(reference))
        self.before = {"fps": 30, "width": 1920, "height": 1080, "settingsConfigured": True, "markers": [], "tracks": [
            {"id": "track", "clips": [{"id": "clip", "startFrame": 0, "durationFrames": 90, "mediaRef": "source"},
                                      {"id": "untouched", "startFrame": 90, "durationFrames": 30, "mediaRef": "other"}]}]}
        self.applied = self.exposed(0.5)
        self.stale = self.exposed(0.37)
        self.actions.append({"kind": "file-panel", "path": "Cool comparison reference.mov",
                             "selectedURLVerified": True, "nativePathEditorVerified": True})
        for identifier in ("color.reference.open", "color.reference.choose", "library.pick.reference"):
            self.click(identifier)
        self.timeline("before", self.before)
        self.measure(1)
        for stage in ("measured-frame-clip", "measured-frame-reference", "measured"):
            self.capture(stage)
        self.propose(1); self.capture("proposal"); self.click("color.reference.discard")
        self.state("native color discard", {"comparisonID": self.observations[0]["comparisonID"],
            "proposalAbsent": True, "comparisonAbsent": True, "applyAbsent": True, "proposeAbsent": True,
            "status": "Color proposal discarded. Measure again for a new comparison."})
        self.timeline("discarded", self.before)
        self.measure(2); self.propose(2); self.click("color.reference.apply")
        self.timeline("applied", self.applied); self.capture("applied")
        for stage, value, modifiers in (("undone", self.before, 1 << 20), ("redone", self.applied, (1 << 20) | (1 << 17)), ("restored", self.before, 1 << 20)):
            self.actions.append({"kind": "keyboard", "code": 6, "modifiers": modifiers})
            self.timeline(stage, value)
        self.measure(3); self.propose(3)
        self.click("inspector.adjust.value.color.exposure.ev")
        self.actions.append({"kind": "text", "field": {"id": "inspector.adjust.value.color.exposure.ev", "actual": "0.37",
                            "expected": "0.37", "focusLeftTarget": True}})
        self.timeline("stale-before", self.stale); self.click("color.reference.apply")
        self.timeline("stale-after", self.stale); self.capture("stale-refusal")
        self.persist()

    def sha(self, data):
        return hashlib.sha256(data).hexdigest()

    def write(self, name, value):
        data = json.dumps(value, sort_keys=True).encode()
        (self.root / name).write_bytes(data)
        return data

    def click(self, identifier):
        self.actions.append({"kind": "pointer", "id": identifier})

    def state(self, label, evidence):
        self.actions.append({"kind": "verified-state", "label": label, "evidence": evidence})

    def timeline(self, stage, value):
        path = "timeline-" + stage + ".json"
        ref = {"path": path, "sha256": self.sha(self.write(path, value))}
        self.result["timelines"][stage] = ref
        self.state("native color timeline", {"stage": stage, "artifact": ref})

    def replace_timeline(self, stage, value):
        ref = self.result["timelines"][stage]
        ref["sha256"] = self.sha(self.write(ref["path"], value))

    def capture(self, stage):
        path = "validator-only-" + stage + ".png"
        data = b"\x89PNG\r\n\x1a\nvalidator-only-" + stage.encode()
        (self.root / path).write_bytes(data); self.screenshots.append(path)
        self.state("native color capture", {"stage": stage, "path": path, "sha256": self.sha(data)})

    def exposed(self, value):
        result = copy.deepcopy(self.before)
        result["tracks"][0]["clips"][0]["effects"] = [{"id": str(UUID(int=90)), "type": "color.exposure", "enabled": True, "params": {"ev": {"value": value}}}]
        return result

    def measure(self, index):
        self.click("color.reference.measure")
        images = [f"isolated-original-request-{index}-{i}".encode() for i in range(2)]
        image_hashes = [self.sha(image) for image in images]
        # Synthetic ordered clip/reference bytes model the actual retained tool/request binding.
        blocks = [{"kind": "image", "mediaType": "image/jpeg", "base64": base64.b64encode(image).decode()} for image in images]
        blocks.append({"kind": "text", "text": json.dumps(self.scopes)})
        path = f"actual-color-tool-{index}.json"
        observation = {"comparisonID": str(UUID(int=index)), "mean": "0.2|0.5|-0.3", "toolPath": path,
            "toolSHA256": self.sha(self.write(path, blocks)), "clipImageSHA256": image_hashes[0], "referenceImageSHA256": image_hashes[1],
            "toolClipImageSHA256": image_hashes[0], "toolReferenceImageSHA256": image_hashes[1],
            "black": "0.1|0.15|-0.05", "white": "0.8|0.9|-0.1", "saturation": "0.4|0.5|-0.1",
            "warmCool": "-0.2|0.1|-0.3", "greenMagenta": "0.3|0.4|-0.1", "clipping": "1.0|2.0|3.0|4.0"}
        self.observations.append(observation); self.state("actual native color measurement", observation)
        scope = {"comparisonID": observation["comparisonID"], "clipID": "clip", "referenceID": "reference"}
        measured = json.dumps(self.scopes)
        text = "Native comparison scope: " + json.dumps(scope) + "\nActual inspect_color measurements:\n" + measured + "\nAttached images are current graded clip, then raw reference."
        self.requests.append({"scope": scope, "text": text, "sessionID": str(UUID(int=50)), "turnID": str(UUID(int=100 + index)),
            "measurementsJSON": measured, "images": [{"mediaType": "image/jpeg", "base64": base64.b64encode(image).decode()} for image in images], "imageSHA256": image_hashes,
            "mutationAttempt": {"toolUseID": str(UUID(int=200 + index)), "toolName": "apply_color",
                "arguments": {"clipIds": ["clip"], "exposure": 2}, "isError": True,
                "content": [{"kind": "text", "text": "This color-comparison turn cannot directly change a clip."}]}})
        self.proposals.append(dict(scope, grade={"exposure": 0.5}, rationale="Isolated validator proposal"))

    def propose(self, index):
        self.click("color.reference.propose")
        request_path, proposal_path = f"actual-color-request-{index}.json", f"actual-color-proposal-{index}.json"
        self.state("actual native color proposal", {"comparisonID": self.observations[index - 1]["comparisonID"],
            "requestPath": request_path, "requestSHA256": self.sha(self.write(request_path, self.requests[index - 1])),
            "proposalPath": proposal_path, "proposalSHA256": self.sha(self.write(proposal_path, self.proposals[index - 1])), "visibleExposure": "0.5"})

    def replace_request(self, index):
        path = f"actual-color-request-{index}.json"
        digest = self.sha(self.write(path, self.requests[index - 1]))
        for row in self.actions:
            if row.get("label") == "actual native color proposal" and row["evidence"]["requestPath"] == path:
                row["evidence"]["requestSHA256"] = digest

    def persist(self):
        self.write("color-reference-result.json", self.result)
        self.write("native-color-reference.json", {"schema": "native-visual-source-progress/v1",
            "interactions": self.result["interactions"], "screenshots": self.screenshots, "failure": None})

    def rejected(self):
        self.persist()
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_isolated_validator_shape_with_distinct_image_encodings(self):
        validate(self.root)

    def test_wrong_applied_exposure_even_with_rebound_hash_is_rejected(self):
        self.replace_timeline("applied", self.exposed(2))
        self.rejected()

    def test_non_target_change_even_with_rebound_hash_is_rejected(self):
        changed = copy.deepcopy(self.applied); changed["tracks"][0]["clips"][1]["durationFrames"] = 31
        self.replace_timeline("applied", changed)
        self.rejected()

    def test_non_effect_target_change_is_rejected(self):
        changed = copy.deepcopy(self.applied); changed["tracks"][0]["clips"][0]["startFrame"] = 1
        self.replace_timeline("applied", changed)
        self.rejected()

    def test_existing_exposure_identity_and_other_effects_are_preserved(self):
        before = copy.deepcopy(self.before)
        before["tracks"][0]["clips"][0]["effects"] = [dict(self.applied["tracks"][0]["clips"][0]["effects"][0], params={"ev": {"value": 0.1}}),
            {"id": "other-effect", "type": "blur", "enabled": True, "params": {"radius": {"value": 2}}}]
        for stage in ("before", "discarded", "undone", "restored"):
            self.replace_timeline(stage, before)
        for stage, value in (("applied", 0.5), ("redone", 0.5), ("stale-before", 0.37), ("stale-after", 0.37)):
            changed = copy.deepcopy(before); changed["tracks"][0]["clips"][0]["effects"][0]["params"]["ev"]["value"] = value
            self.replace_timeline(stage, changed)
        self.persist(); validate(self.root)
        changed["tracks"][0]["clips"][0]["effects"][1]["enabled"] = False
        self.replace_timeline("stale-before", changed)
        self.rejected()

    def test_reused_comparison_is_rejected(self):
        self.observations[1]["comparisonID"] = self.observations[0]["comparisonID"]
        self.rejected()

    def test_reused_turn_is_rejected_after_hash_rebinding(self):
        self.requests[1]["turnID"] = self.requests[0]["turnID"]; self.replace_request(2)
        self.rejected()

    def test_foreign_proposal_target_is_rejected_after_hash_rebinding(self):
        path = "actual-color-proposal-2.json"
        changed = dict(self.proposals[1], clipID="foreign")
        for row in self.actions:
            if row.get("label") == "actual native color proposal" and row["evidence"]["proposalPath"] == path:
                row["evidence"]["proposalSHA256"] = self.sha(self.write(path, changed))
        self.rejected()

    def test_request_image_substitution_is_rejected_after_hash_rebinding(self):
        self.requests[1]["images"][0]["base64"] = base64.b64encode(b"substituted").decode()
        self.replace_request(2); self.rejected()

    def test_sample_times_in_the_request_cannot_change_from_the_actual_tool_readout(self):
        measured = json.loads(self.requests[0]["measurementsJSON"])
        measured["referenceSampling"]["actualValue"] = 46
        changed = json.dumps(measured)
        self.requests[0]["text"] = self.requests[0]["text"].replace(self.requests[0]["measurementsJSON"], changed)
        self.requests[0]["measurementsJSON"] = changed
        self.replace_request(1); self.rejected()

    def test_wrong_measured_readout_is_rejected(self):
        self.observations[2]["mean"] = "0.7|0.5|0.2"
        self.rejected()

    def test_overwritten_tool_path_is_rejected(self):
        self.observations[0]["toolPath"] = self.observations[2]["toolPath"]
        self.rejected()

    def test_changed_tool_bytes_are_rejected(self):
        (self.root / "actual-color-tool-1.json").write_text("[]")
        self.rejected()

    def test_undo_before_apply_is_rejected(self):
        i = next(i for i, row in enumerate(self.actions) if row.get("kind") == "keyboard")
        self.actions.insert(0, self.actions.pop(i))
        self.rejected()

    def test_missing_native_stale_edit_is_rejected(self):
        self.result["interactions"] = [row for row in self.actions if row.get("kind") != "text"]
        self.rejected()

    def test_stale_apply_mutation_is_rejected(self):
        self.replace_timeline("stale-after", self.applied)
        self.rejected()

    def test_missing_native_file_panel_is_rejected(self):
        self.result["interactions"] = self.actions[1:]
        self.rejected()

    def test_wrong_keyboard_modifiers_are_rejected(self):
        next(row for row in self.actions if row.get("kind") == "keyboard")["modifiers"] = 0
        self.rejected()

    def test_screenshot_corruption_is_rejected(self):
        (self.root / self.screenshots[0]).write_bytes(b"not png")
        self.rejected()

    def test_progress_substitution_is_rejected(self):
        self.persist(); self.write("native-color-reference.json", {"interactions": [], "screenshots": [], "failure": None})
        with self.assertRaises(ValueError): validate(self.root)

    def test_viewport_scale_and_live_claims_are_rejected(self):
        for field, invalid in (("viewport", [1000, 700]), ("scale", 2), ("liveAgent", True)):
            previous = self.result[field]; self.result[field] = invalid; self.rejected(); self.result[field] = previous

    def test_traversal_and_symlinked_artifacts_are_rejected(self):
        ref = self.result["timelines"]["before"]
        previous = ref["path"]; ref["path"] = "../outside.json"; self.rejected(); ref["path"] = previous
        alias = self.root / "alias"; alias.symlink_to(self.root, target_is_directory=True)
        ref["path"] = "alias/" + previous; self.rejected()

    def test_malformed_evidence_has_value_error(self):
        self.result["measurements"] = [None, None, None]
        next(row for row in self.actions if row.get("label") == "actual native color measurement")["evidence"] = None
        self.persist()
        with self.assertRaisesRegex(ValueError, "Malformed native color evidence"):
            validate(self.root)

    def test_progress_cannot_alias_the_result_file(self):
        self.result["progress"] = "color-reference-result.json"
        self.rejected()

    def test_rebound_request_and_display_hashes_cannot_replace_retained_tool_frames(self):
        replacement = b"a different request frame"
        self.requests[1]["images"][0]["base64"] = base64.b64encode(replacement).decode()
        self.requests[1]["imageSHA256"][0] = self.sha(replacement)
        self.observations[1]["clipImageSHA256"] = self.sha(replacement)
        self.replace_request(2)
        self.rejected()

    def test_tool_and_observation_hashes_are_checked_against_actual_base64(self):
        self.observations[0]["toolClipImageSHA256"] = "f" * 64
        self.rejected()

    def test_measured_non_mean_rows_and_clipping_are_not_self_asserted(self):
        for name in ("black", "white", "saturation", "warmCool", "greenMagenta", "clipping"):
            previous = self.observations[0][name]
            self.observations[0][name] = "0|0|0|0" if name == "clipping" else "0|0|0"
            self.rejected(); self.observations[0][name] = previous

    def test_visible_proposal_exposure_must_match_typed_proposal(self):
        next(row["evidence"] for row in self.actions if row.get("label") == "actual native color proposal")["visibleExposure"] = "2.0"
        self.rejected()

    def test_discard_requires_actual_missing_controls_and_status(self):
        discarded = next(row["evidence"] for row in self.actions if row.get("label") == "native color discard")
        for key in ("proposalAbsent", "comparisonAbsent", "applyAbsent", "proposeAbsent"):
            discarded[key] = False; self.rejected(); discarded[key] = True
        discarded["status"] = "AI proposal ready"; self.rejected()

    def test_capture_cannot_reuse_a_different_stages_screenshot(self):
        captures = [row["evidence"] for row in self.actions if row.get("label") == "native color capture"]
        captures[1].update(path=captures[0]["path"], sha256=captures[0]["sha256"])
        self.rejected()

    def test_screenshot_list_cannot_repeat_paths(self):
        self.screenshots.append(self.screenshots[0]); self.rejected()

    def test_existing_exposure_cannot_move_within_other_preserved_effects(self):
        before = copy.deepcopy(self.before)
        blur = {"id": "before-blur", "type": "blur", "enabled": True, "params": {}}
        exposure = dict(self.applied["tracks"][0]["clips"][0]["effects"][0], params={"ev": {"value": 0.1}})
        before["tracks"][0]["clips"][0]["effects"] = [blur, exposure]
        for stage in ("before", "discarded", "undone", "restored"):
            self.replace_timeline(stage, before)
        for stage, value in (("applied", 0.5), ("redone", 0.5), ("stale-before", 0.37), ("stale-after", 0.37)):
            after = copy.deepcopy(before)
            after["tracks"][0]["clips"][0]["effects"][1]["params"]["ev"]["value"] = value
            self.replace_timeline(stage, after)
        self.persist(); validate(self.root)
        moved = copy.deepcopy(before)
        moved["tracks"][0]["clips"][0]["effects"] = [dict(exposure, params={"ev": {"value": 0.5}}), blur]
        self.replace_timeline("applied", moved); self.rejected()


if __name__ == "__main__":
    unittest.main()
