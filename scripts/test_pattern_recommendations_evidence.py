import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from pattern_recommendations_evidence import validate


def pattern_fixture(directory):
    def write_bytes(name, value):
        (directory / name).write_bytes(value)
        return value
    def write(name, value):
        return write_bytes(name, json.dumps(value, sort_keys=True).encode())
    def sha(value):
        return hashlib.sha256(value).hexdigest()
    pattern_id = "isolated-validator-pattern"
    candidate = {"pattern_id": pattern_id, "fit_score": 42.3, "fit_band": "provisional",
                 "confidence": 0.3, "input_coverage": 0.4, "rank": None, "excluded": False,
                 "exclusion_reasons": [], "conflicts": ["Unresolved pacing"]}
    scored, unscored, invalid = [pattern_id], ["unauthored-validator-pattern"], []
    provider = {"recommendations": {"results": [candidate], "slots": {"best_overall_pattern_id": None}},
                "library_coverage": {"scored": scored, "unscored": unscored, "invalid": invalid,
                                     "total": len(scored + unscored + invalid)}}
    provider_bytes = write("pattern-provider.json", provider)
    write_bytes("pattern-selected.recommendations.json", provider_bytes)
    signature = write("pattern-selected.pattern.json", {"id": pattern_id, "asl_range": {"basis": "inferred"}})
    brief = write_bytes("pattern-selected.brief.yaml", b"project: isolated-validator\n")
    decision = {"patternID": pattern_id, "restored": False, "resultSHA256": sha(provider_bytes),
                "selectedPatternSHA256": sha(signature), "briefSHA256": sha(brief),
                "warnings": ["Unresolved pacing", "Not ranked: inputs or confidence are incomplete."],
                "reason": "A deliberate validator fixture choice."}
    decision_bytes = write("pattern-decision.json", decision)
    clicks = ["production.pattern.open", "production.pattern.details." + pattern_id,
              "production.pattern.choose." + pattern_id, "production.pattern.none",
              "production.pattern.exclude." + pattern_id, "production.pattern.exclude." + pattern_id,
              "production.pattern.acknowledge", "production.pattern.confirm"]
    interactions = [{"kind": "pointer", "id": value} for value in clicks]
    for label, evidence in [
        ("pattern visible provider values", {"patternID": pattern_id, "index": "42",
                                             "confidenceCoverage": "0.3|0.4", "library": f"{len(scored)}/{len(scored + unscored + invalid)}"}),
        ("pattern visible signature basis", {"field": "asl", "basis": "inferred"}),
        ("pattern stale snapshot refused", {"apiNegativeOnly": True, "briefUnchanged": True}),
    ]:
        interactions.append({"kind": "verified-state", "label": label, "evidence": evidence})
    interactions += [{"kind": "text", "field": {"id": "production.pattern.reason", "actual": decision["reason"]}},
                     {"kind": "keyboard", "code": 6, "modifiers": 1 << 20},
                     {"kind": "keyboard", "code": 6, "modifiers": (1 << 20) | (1 << 17)}]
    images = []
    for label in ("comparison", "signature", "excluded", "selected", "optional-no-pattern"):
        name = "validator-" + label + ".png"
        write_bytes(name, b"\x89PNG\r\n\x1a\nvalidator-only")
        images.append(name)
    evidence = {"interactions": interactions, "screenshots": images, "progress": "native-pattern.json"}
    write("native-pattern.json", {"interactions": interactions, "screenshots": images, "failure": None})
    result = {key: True for key in ("nativeRecommendations", "exactProviderResult", "nativeExcludeInclude",
                                   "persistedWarnings", "nativeUndoRedo", "nativeNoPattern", "staleSnapshotRejected", "gatesUnchanged")}
    result.update(nativeDeliberateChoice=True, liveProvider=False, patternID=pattern_id, evidenceBasis="inferred",
                  providerSHA256=sha(provider_bytes), decisionSHA256=sha(decision_bytes), evidence=evidence)
    write("pattern-result.json", result)
    for name in ("pattern-gates-before.yaml", "pattern-gates-after.yaml"):
        write_bytes(name, b"brief: pending\n")

    return pattern_id


class PatternEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.pattern_id = pattern_fixture(self.root)

    @staticmethod
    def sha(data):
        return hashlib.sha256(data).hexdigest()

    def write_bytes(self, name, value):
        (self.root / name).write_bytes(value)
        return value

    def write(self, name, value):
        return self.write_bytes(name, json.dumps(value, sort_keys=True).encode())

    def change(self, name, update):
        value = json.loads((self.root / name).read_text())
        update(value)
        self.write(name, value)

    def test_complete_isolated_validator_fixture(self):
        self.assertEqual(validate(self.root)["patternID"], self.pattern_id)

    def test_native_choose_action_missing(self):
        self.change("pattern-result.json", lambda value: value["evidence"]["interactions"].pop(2))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_actual_provider_response_changed(self):
        self.change("pattern-provider.json", lambda value: value["recommendations"]["results"][0].update(fit_score=99))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_signature_relabelled_measured(self):
        self.change("pattern-result.json", lambda value: value.update(evidenceBasis="measured"))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_warning_archive_changed(self):
        self.change("pattern-decision.json", lambda value: value.update(warnings=[]))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_brief_snapshot_changed(self):
        self.write_bytes("pattern-selected.brief.yaml", b"project: substituted\n")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_native_observation_changed_in_both_reports(self):
        for name in ("pattern-result.json", "native-pattern.json"):
            def update(value):
                rows = value.get("evidence", value)["interactions"]
                next(row["evidence"] for row in rows if row.get("label") == "pattern visible provider values")["confidenceCoverage"] = "1|1"
            self.change(name, update)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_phase_was_approved(self):
        self.write_bytes("pattern-gates-after.yaml", b"brief: approved\n")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_screenshot_missing(self):
        self.change("pattern-result.json", lambda value: value["evidence"].update(screenshots=[]))
        with self.assertRaises(ValueError):
            validate(self.root)


if __name__ == "__main__":
    unittest.main()
