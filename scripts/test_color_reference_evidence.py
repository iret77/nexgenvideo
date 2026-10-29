import base64
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from color_reference_evidence import validate


class ColorReferenceValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.scope = {"comparisonID": "isolated-validator-id", "clipID": "clip", "referenceID": "reference"}
        self.scopes = {"clip": {"luma": {"mean": 0.2}}, "reference": {"luma": {"mean": 0.5}}, "gap": {"lumaMean": -0.3}}
        images = [b"isolated-validator-image-1", b"isolated-validator-image-2"]
        self.blocks = [{"kind": "image", "base64": base64.b64encode(image).decode()} for image in images]
        self.blocks.append({"kind": "text", "text": json.dumps(self.scopes)})
        tool = self.write("actual-color-tool.json", self.blocks)
        request = self.write("actual-color-request.json", {"scope": self.scope, "text": "actual bounded request fixture",
            "imageSHA256": [self.sha(image) for image in images]})
        proposal = self.write("actual-color-proposal.json", dict(self.scope, grade={"exposure": 0.5}, rationale="Isolated validator proposal"))
        clicks = ["color.reference.open", "color.reference.choose", "library.pick.reference", "color.reference.discard"]
        clicks += ["color.reference.measure", "color.reference.propose"] * 3 + ["color.reference.apply"] * 2
        actions = [{"kind": "pointer", "id": value} for value in clicks]
        actions += [{"kind": "keyboard", "code": 6}] * 3
        actions.append({"kind": "text", "field": {"id": "inspector.adjust.value.color.exposure.ev"}})
        actions += [{"kind": "verified-state", "label": "actual native color measurement",
                     "evidence": {"mean": "0.2|0.5|-0.3", "toolSHA256": self.sha(tool)}}] * 3
        screenshots = ["validator-only-" + str(i) + ".png" for i in range(4)]
        for name in screenshots:
            (self.root / name).write_bytes(b"\x89PNG\r\n\x1a\nvalidator-only")
        self.result = {key: True for key in ("nativeMeasuredComparison", "actualToolReadout", "nativeProposalDiscard",
            "nativeProposalApply", "nativeUndoRedo", "nativeStaleRefusal", "sourceProjectPreserved")}
        self.result.update(liveAgent=False, directMutationRefusals=3, clipID="clip", referenceID="reference",
            requestSHA256=self.sha(request), proposalSHA256=self.sha(proposal), interactions=actions,
            screenshots=screenshots, progress="native-color-reference.json")
        self.persist()

    def sha(self, data):
        return hashlib.sha256(data).hexdigest()

    def write(self, name, value):
        data = json.dumps(value, sort_keys=True).encode()
        (self.root / name).write_bytes(data)
        return data

    def persist(self):
        self.write("color-reference-result.json", self.result)
        self.write("native-color-reference.json", {"interactions": self.result["interactions"],
            "screenshots": self.result["screenshots"], "failure": None})

    def test_isolated_validator_shape(self):
        validate(self.root)

    def test_missing_actual_apply_is_rejected(self):
        self.result["interactions"] = [row for row in self.result["interactions"] if row.get("id") != "color.reference.apply"]
        self.persist()
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_scope_substitution_is_rejected(self):
        changed = dict(self.scope, clipID="foreign", grade={"exposure": 0.5}, rationale="Substituted")
        self.result["proposalSHA256"] = self.sha(self.write("actual-color-proposal.json", changed))
        self.persist()
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_wrong_measured_readout_is_rejected(self):
        self.result["interactions"][-1]["evidence"]["mean"] = "0.7|0.5|0.2"
        self.persist()
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_missing_stale_native_edit_is_rejected(self):
        self.result["interactions"] = [row for row in self.result["interactions"] if row.get("kind") != "text"]
        self.persist()
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_live_ai_claim_is_rejected(self):
        self.result["liveAgent"] = True
        self.persist()
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_changed_actual_tool_bytes_are_rejected(self):
        self.blocks[-1]["text"] = json.dumps(dict(self.scopes, gap={"lumaMean": 0.7}))
        self.write("actual-color-tool.json", self.blocks)
        with self.assertRaises(ValueError):
            validate(self.root)


if __name__ == "__main__":
    unittest.main()
