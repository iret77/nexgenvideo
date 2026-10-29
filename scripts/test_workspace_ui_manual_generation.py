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
                "discovery": {"liveProvider": False,
                    "endpointIDs": ["fal-ai/flux/dev", "fal-ai/flux/schnell", "fal-ai/gemini-25-flash-image/edit"],
                    "requests": ["https://api.fal.ai/v1/models?category=" + category + "&status=active&limit=100"
                                 for category in ("text-to-image", "image-to-image")]},
                "discardDidNotSubmit": True, "changedInputsInvalidateReview": True, "nativeApproval": True}),
            ("source-only offering and native library picker", {
                "sourceID": "original", "modelID": "source-model", "sourceSHA256": "c" * 64, "nativeAssignment": True}),
            ("native rerun loss is explicit", {
                "originalIntentRestored": True, "missingReferenceBlocked": True, "newRequestIsExplicit": True})]
        pointers = ["generation.media.type.Image", "generation.media.type.Video",
            "generation.media.review", "generation.media.review", "generation.media.review",
            "generation.media.package.details", "generation.media.package.details", "generation.media.package.copy-prompt",
            "generation.media.package.copy-package", "generation.media.package.copy-package", "generation.media.discard",
            "generation.media.approve", "generation.media.pick.Source Video", "library.pick.original",
            "ai-edit.rerun", "ai-edit.rerun", "generation.media.new-request"]
        values = ["A single red circle on a pale wall, static wide composition.",
                  "A single red circle on a pale wall, static wide composition. Soft side lighting."]
        self.row = {"event": "manual-generation", "scale": 1.5, "viewport": [960, 640],
            "nativeScenario": True, "liveProvider": False, "screenshots": images,
            "interactions": [{"kind": "verified-state", "label": label, "evidence": evidence} for label, evidence in states]
                + [{"kind": "pointer", "id": key} for key in pointers]
                + [{"kind": "text", "field": {"id": "generation.media.intent", "expected": value,
                    "actual": value, "commitInput": "Tab", "stage": "commit-requested"}} for value in values]
                + [{"kind": "menu", "id": "generation.media.model", "closed": True, "path": [label]}
                   for label in ("Image model", "Source model")]}
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

    def test_real_isolated_discovery_must_precede_image_generation(self):
        for field, value in (("liveProvider", True), ("endpointIDs", ["fal-ai/flux/dev"]), ("requests", [])):
            changed = copy.deepcopy(self.row)
            changed["interactions"][0]["evidence"]["discovery"][field] = value
            self.assertFalse(self.accepts(changed))

    def test_failed_proof_or_wrong_binding_never_passes(self):
        for index, keys in ((0, ("copiedPromptMatched", "discardDidNotSubmit", "changedInputsInvalidateReview", "nativeApproval")),
                            (1, ("nativeAssignment",)), (2, ("originalIntentRestored", "missingReferenceBlocked", "newRequestIsExplicit"))):
            for key in keys:
                changed = copy.deepcopy(self.row)
                changed["interactions"][index]["evidence"][key] = False
                self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        changed["interactions"][1]["evidence"]["sourceID"] = "different"
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


if __name__ == "__main__":
    unittest.main()
