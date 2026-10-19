import copy
from pathlib import Path
import tempfile
import unittest

from workspace_ui_acceptance import manual_generation_evidence
from test_workspace_ui_manual_audio import extended_fixture


class ManualGenerationEvidenceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.output = Path(directory.name)
        images = ["manual-" + label + ".png" for label in (
            "request-before-approval", "source-only-model-before-assignment", "missing-rerun-reference-visible")]
        for name in images:
            (self.output / name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"image" * 250)
        states = [
            ("manual image generation uses the native reviewed request", {
                "packageID": "a" * 64, "outputSHA256": "b" * 64, "copiedPromptMatched": True,
                "modelID": "fal-ai/flux/dev", "modelLabel": "Image model", "selectedModelID": "fal-ai/flux/dev",
                "discovery": {"liveProvider": False,
                    "endpointIDs": ["fal-ai/flux/dev", "fal-ai/flux/schnell", "fal-ai/gemini-25-flash-image/edit"],
                    "requests": ["https://api.fal.ai/v1/models?category=" + category + "&status=active&limit=100"
                                 for category in ("text-to-image", "image-to-image")]},
                "discardDidNotSubmit": True, "changedInputsInvalidateReview": True, "nativeApproval": True}),
            ("source-only offering and native library picker", {
                "modelLabel": "Source model", "selectedModelID": "source-model",
                "sourceSlotBefore": "", "sourceSlotAfter": "original", "reviewEnabledBefore": False,
                "reviewEnabledAfter": True, "reviewOpened": True, "reviewPackageID": "d" * 64,
                "reviewModelID": "source-model", "reviewSourceID": "original", "intent": "Preserve the source composition and motion.",
                "sourceID": "original", "modelID": "source-model", "sourceSHA256": "c" * 64, "nativeAssignment": True}),
            ("native rerun loss is explicit", {
                "faultInjection": "missing reference asset ID in stored generation input", "injectedDirectlyIntoModel": True,
                "scope": "Test-only direct stored generation-input mutation followed by the real native Rerun action; no owner workflow or live-provider proof.",
                "originalIntentRestored": True, "missingReferenceBlocked": True, "newRequestIsExplicit": True})]
        values = ["A single red circle on a pale wall, static wide composition.",
                  "A single red circle on a pale wall, static wide composition. Soft side lighting."]
        inputs = []
        def pointer(key): inputs.append({"kind": "pointer", "id": key})
        def menu(label): inputs.append({"kind": "menu", "id": "generation.media.model", "closed": True, "path": [label]})
        def text(value): inputs.append({"kind": "text", "field": {"id": "generation.media.intent", "expected": value,
            "actual": value, "commitInput": "Tab", "stage": "commit-requested"}})
        def state(index): inputs.append({"kind": "verified-state", "label": states[index][0], "evidence": states[index][1]})
        pointer("generation.media.type.Image"); menu("Image model"); text(values[0])
        for key in ("generation.media.review", "generation.media.package.details", "generation.media.package.copy-prompt", "generation.media.package.copy-package"): pointer(key)
        text(values[1])
        for key in ("generation.media.review", "generation.media.discard", "generation.media.review", "generation.media.package.details", "generation.media.package.copy-package", "generation.media.approve"): pointer(key)
        state(0); pointer("generation.media.type.Video"); menu("Source model"); text("Preserve the source composition and motion.")
        pointer("generation.media.pick.Source Video"); pointer("library.pick.original")
        for key in ("generation.media.review", "generation.media.package.details", "generation.media.package.copy-package", "generation.media.discard"): pointer(key)
        state(1)
        pointer("ai-edit.rerun"); pointer("ai-edit.rerun"); pointer("generation.media.new-request"); state(2)
        self.row = {"event": "manual-generation", "scale": 1.5, "effectiveScale": 1.5, "backingScale": 2, "viewport": [960, 640],
            "nativeScenario": True, "liveProvider": False, "screenshots": images, "interactions": inputs}
        extended_inputs, extended_images = extended_fixture(self.output)
        self.row["interactions"] += extended_inputs
        self.row["screenshots"] += extended_images
        self.complete = {"event": "completed", "case": "manualgeneration", "scale": 1.5}

    def accepts(self, row):
        return manual_generation_evidence([row, self.complete], self.output, 1.5)[0]

    def test_every_owner_action_is_required(self):
        self.assertTrue(self.accepts(self.row))
        for key in ("screenshots", "interactions"):
            for index in range(len(self.row[key])):
                changed = copy.deepcopy(self.row)
                changed[key].pop(index)
                with self.subTest(key=key, index=index):
                    self.assertFalse(self.accepts(changed))

    def test_actual_isolated_discovery_observation_is_required(self):
        for field, value in (("liveProvider", True), ("endpointIDs", ["fal-ai/flux/dev"]), ("requests", [])):
            changed = copy.deepcopy(self.row)
            [row for row in changed["interactions"] if row.get("kind") == "verified-state"][0]["evidence"]["discovery"][field] = value
            self.assertFalse(self.accepts(changed))

    def test_actual_viewport_and_scale_are_required(self):
        for key, value in (("viewport", [1440, 960]), ("effectiveScale", 1), ("backingScale", 0), ("backingScale", True)):
            changed = copy.deepcopy(self.row); changed[key] = value
            self.assertFalse(self.accepts(changed), key)

    def test_model_selection_and_injected_failure_are_bound(self):
        for index, key, value in ((0, "modelID", "unlisted-model"), (0, "selectedModelID", "other-model"),
                                  (0, "modelLabel", "Other image"), (1, "modelID", "other-source"),
                                  (1, "selectedModelID", "other-source"), (1, "modelLabel", "Other source"),
                                  (1, "sourceSlotBefore", "already-assigned"), (1, "sourceSlotAfter", "other-source"),
                                  (1, "reviewEnabledBefore", True), (1, "reviewPackageID", "invalid"),
                                  (1, "reviewModelID", "other-model"), (1, "reviewSourceID", "other-source"),
                                  (1, "intent", "different request"), (2, "faultInjection", ""), (2, "scope", "")):
            changed = copy.deepcopy(self.row)
            states = [row for row in changed["interactions"] if row.get("kind") == "verified-state"]
            states[index]["evidence"][key] = value
            self.assertFalse(self.accepts(changed), key)
        changed = copy.deepcopy(self.row)
        menus = [row for row in changed["interactions"] if row.get("id") == "generation.media.model"]
        menus[0]["path"], menus[1]["path"] = menus[1]["path"], menus[0]["path"]
        self.assertFalse(self.accepts(changed))

    def test_failed_proof_or_wrong_binding_never_passes(self):
        for index, keys in ((0, ("copiedPromptMatched", "discardDidNotSubmit", "changedInputsInvalidateReview", "nativeApproval")),
                            (1, ("nativeAssignment", "reviewEnabledAfter", "reviewOpened")),
                            (2, ("originalIntentRestored", "missingReferenceBlocked", "newRequestIsExplicit", "injectedDirectlyIntoModel"))):
            for key in keys:
                changed = copy.deepcopy(self.row)
                [row for row in changed["interactions"] if row.get("kind") == "verified-state"][index]["evidence"][key] = False
                self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        [row for row in changed["interactions"] if row.get("kind") == "verified-state"][1]["evidence"]["sourceID"] = "different"
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        text = next(item for item in changed["interactions"] if item["kind"] == "text")
        text["field"]["actual"] = "compiled prompt instead of intent"
        self.assertFalse(self.accepts(changed))
        self.assertFalse(self.accepts({**self.row, "liveProvider": True}))

    def test_incomplete_or_duplicate_approval_and_bad_images_fail(self):
        self.assertFalse(manual_generation_evidence([self.row], self.output, 1.5)[0])
        self.assertFalse(manual_generation_evidence([self.row, self.complete], self.output, 1)[0])
        self.assertFalse(manual_generation_evidence([self.row, self.complete, {"event": "failed"}], self.output, 1.5)[0])
        changed = copy.deepcopy(self.row)
        changed["interactions"].append({"kind": "pointer", "id": "generation.media.approve"})
        self.assertFalse(self.accepts(changed))
        (self.output / self.row["screenshots"][0]).write_bytes(b"missing native image")
        self.assertFalse(self.accepts(self.row))

    def test_approval_discard_and_native_results_have_actual_order(self):
        changed = copy.deepcopy(self.row); rows = changed["interactions"]
        first = next(i for i, row in enumerate(rows) if row.get("id") == "generation.media.discard")
        second = next(i for i, row in enumerate(rows) if row.get("id") == "generation.media.approve")
        rows[first], rows[second] = rows[second], rows[first]
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row); rows = changed["interactions"]
        result = next(i for i, row in enumerate(rows) if row.get("kind") == "verified-state")
        rows.insert(0, rows.pop(result))
        self.assertFalse(self.accepts(changed))
        self.assertFalse(manual_generation_evidence([None, self.complete], self.output, 1.5)[0])
        changed = copy.deepcopy(self.row); changed["interactions"].insert(0, None)
        self.assertFalse(self.accepts(changed))


if __name__ == "__main__":
    unittest.main()
