import copy
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
    project = b"project: isolated-validator\n"
    gates = b"brief: pending\n"
    interactions = []
    def state(stage, selected_id, number, restored, copy_of=None):
        if copy_of:
            state_value = json.loads(json.dumps(copy_of))
            for i, record in enumerate(state_value["files"]):
                raw = (directory / record["retainedPath"]).read_bytes()
                record["retainedPath"] = f"pattern-state-{stage}-{i}.bin"
                write_bytes(record["retainedPath"], raw)
            write("pattern-state-" + stage + ".json", state_value)
            return state_value
        decision_id = f"00000000-0000-0000-0000-{number:012d}" if number else None
        brief = ("project: isolated-validator\ndirector_pattern: " + (selected_id or "null") + "\ngenerator: "
                 + ("brief-native@pattern-selection/" + decision_id if decision_id else "initial") + "\n").encode()
        files = {"project.yaml": project, "brief.yaml": brief, "gates.yaml": gates}
        if decision_id:
            prefix = "brief/pattern-selections/" + decision_id
            decision = {"schema": "native-pattern-selection/v1", "id": decision_id,
                        "projectID": "isolated-validator", "patternID": selected_id, "restored": restored,
                        "inputFingerprint": "a" * 64,
                        "resultSHA256": sha(provider_bytes), "selectedPatternSHA256": sha(signature) if selected_id else None,
                        "briefSHA256": sha(brief), "warnings": ["Unresolved pacing", "Not ranked: inputs or confidence are incomplete."] if selected_id else [],
                        "reason": "A deliberate validator fixture choice."}
            decision_bytes = json.dumps(decision, sort_keys=True).encode()
            files.update({"brief/pattern-selection.current.v1.json": decision_bytes,
                          prefix + ".v1.json": decision_bytes, prefix + ".brief.yaml": brief,
                          prefix + ".recommendations.json": provider_bytes})
            if selected_id:
                files[prefix + ".pattern.json"] = signature
            if stage == "selected":
                write_bytes("pattern-decision.json", decision_bytes)
                write_bytes("pattern-selected.brief.yaml", brief)
        records = []
        for i, (path, raw) in enumerate(sorted(files.items())):
            name = f"pattern-state-{stage}-{i}.bin"
            write_bytes(name, raw)
            records.append({"canonicalPath": path, "retainedPath": name, "sha256": sha(raw)})
        return_value = {"sourceRoot": "/isolated-validator/pipeline", "projectID": "isolated-validator",
                        "selectedID": selected_id, "decisionID": decision_id, "briefSHA256": sha(brief), "files": records}
        write("pattern-state-" + stage + ".json", return_value)
        return return_value
    def binding(raw, excluded):
        return {"sha256": sha(raw), "mode": "balanced", "excluded": excluded, "fingerprint": ("b" if excluded else "a") * 64}

    def observed(label, evidence):
        interactions.append({"kind": "verified-state", "label": label, "evidence": evidence})
    def pointer(value):
        interactions.append({"kind": "pointer", "id": value})
    def retained(stage, selected_id, number, restored, copy_of=None):
        value = state(stage, selected_id, number, restored, copy_of)
        observed("pattern persisted " + stage, value)
        return value
    retained("before", None, 0, False)
    pointer("production.pattern.open")
    observed("pattern visible provider values", {"patternID": pattern_id, "index": "42", "confidenceCoverage": "0.3|0.4",
                                               "library": f"{len(scored)}/{len(scored + unscored + invalid)}",
                                               "responseBinding": binding(provider_bytes, [])})
    pointer("production.pattern.details." + pattern_id)
    observed("pattern visible signature basis", {"field": "asl", "basis": "inferred"})
    pointer("production.pattern.exclude." + pattern_id)
    excluded_provider = json.loads(json.dumps(provider))
    excluded_provider["recommendations"]["results"][0].update(excluded=True, fit_score=None, fit_band="excluded", rank=None)
    for stage, excluded, enabled, response in (("excluded", [pattern_id], False, excluded_provider), ("included", [], True, provider)):
        if stage == "included":
            pointer("production.pattern.exclude." + pattern_id)
        name = "pattern-" + stage + "-provider.json"
        raw = write(name, response)
        observed("pattern comparison " + stage, {"response": name, "sha256": sha(raw), "excludedIDs": excluded, "chooseEnabled": enabled,
                  "responseBinding": binding(raw, excluded), "index": None if excluded else "42", "confidenceCoverage": "0.3|0.4",
                  "library": f"{len(scored)}/{len(scored + unscored + invalid)}"})
    pointer("production.pattern.choose." + pattern_id)
    interactions.append({"kind": "text", "field": {"id": "production.pattern.reason", "actual": "A deliberate validator fixture choice."}})
    pointer("production.pattern.acknowledge")
    pointer("production.pattern.confirm")
    selected = retained("selected", pattern_id, 1, False)
    observed("pattern stale snapshot refused", {"apiNegativeOnly": True, "briefUnchanged": True,
                                              "message": "Reload recommendations before choosing a pattern."})
    retained("after-stale", pattern_id, 1, False, selected)
    interactions.append({"kind": "keyboard", "code": 6, "modifiers": 1 << 20})
    retained("undo", None, 2, True)
    interactions.append({"kind": "keyboard", "code": 6, "modifiers": (1 << 20) | (1 << 17)})
    retained("redo", pattern_id, 3, True)
    pointer("production.pattern.none")
    retained("none", None, 4, False)
    images = []
    for label in ("comparison", "signature", "excluded", "included", "selected", "undo", "redo", "optional-no-pattern"):
        name = "validator-" + label + ".png"
        write_bytes(name, b"\x89PNG\r\n\x1a\nvalidator-only")
        images.append(name)
    evidence = {"interactions": interactions, "screenshots": images, "progress": "native-pattern.json"}
    write("native-pattern.json", {"interactions": interactions, "screenshots": images, "failure": None})
    result = {key: True for key in ("nativeRecommendations", "exactProviderResult", "nativeExcludeInclude",
                                   "persistedWarnings", "nativeUndoRedo", "nativeNoPattern", "staleSnapshotRejected", "gatesUnchanged")}
    result.update(nativeDeliberateChoice=True, liveProvider=False, patternID=pattern_id, evidenceBasis="inferred",
                  providerSHA256=sha(provider_bytes), decisionSHA256=sha((directory / "pattern-decision.json").read_bytes()), evidence=evidence)
    write("pattern-result.json", result)
    for name in ("pattern-gates-before.yaml", "pattern-gates-after.yaml"):
        write_bytes(name, gates)
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
        self.change("pattern-result.json", lambda value: value["evidence"].update(interactions=[row for row in value["evidence"]["interactions"] if row.get("id") != "production.pattern.choose." + self.pattern_id]))
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

    def change_interactions(self, update):
        result = json.loads((self.root / "pattern-result.json").read_text())
        update(result["evidence"]["interactions"])
        self.write("pattern-result.json", result)
        progress = json.loads((self.root / "native-pattern.json").read_text())
        progress["interactions"] = result["evidence"]["interactions"]
        self.write("native-pattern.json", progress)

    def replace_snapshot(self, stage, other):
        value = json.loads((self.root / ("pattern-state-" + other + ".json")).read_text())
        self.write("pattern-state-" + stage + ".json", value)
        self.change_interactions(lambda rows: next(row for row in rows if row.get("label") == "pattern persisted " + stage).update(evidence=value))

    def test_plain_z_keys_do_not_prove_document_undo(self):
        self.change_interactions(lambda rows: [row.update(modifiers=row["modifiers"] & ~(1 << 20))
                                              for row in rows if row.get("kind") == "keyboard"])
        with self.assertRaisesRegex(ValueError, "Native Undo and Redo"):
            validate(self.root)

    def test_reordered_undo_and_redo_observations_rejected(self):
        def reorder(rows):
            a = next(i for i, row in enumerate(rows) if row.get("label") == "pattern persisted undo")
            b = next(i for i, row in enumerate(rows) if row.get("label") == "pattern persisted redo")
            rows[a], rows[b] = rows[b], rows[a]
        self.change_interactions(reorder)
        with self.assertRaisesRegex(ValueError, "out of order"):
            validate(self.root)

    def test_valid_receipt_that_did_not_undo_selection_rejected(self):
        self.replace_snapshot("undo", "redo")
        with self.assertRaisesRegex(ValueError, "state sequence"):
            validate(self.root)

    def test_valid_receipt_that_did_not_clear_optional_choice_rejected(self):
        self.replace_snapshot("none", "redo")
        with self.assertRaisesRegex(ValueError, "state sequence"):
            validate(self.root)

    def test_stale_refusal_cannot_hide_an_actual_project_write(self):
        self.replace_snapshot("after-stale", "none")
        with self.assertRaisesRegex(ValueError, "state sequence"):
            validate(self.root)

    def test_excluded_choice_must_be_actually_disabled(self):
        self.change_interactions(lambda rows: next(row["evidence"] for row in rows if row.get("label") == "pattern comparison excluded").update(chooseEnabled=True))
        with self.assertRaisesRegex(ValueError, "disabled native choice"):
            validate(self.root)

    def test_rehashed_exclusion_response_cannot_keep_candidate_included(self):
        response = json.loads((self.root / "pattern-excluded-provider.json").read_text())
        response["recommendations"]["results"][0]["excluded"] = False
        raw = self.write("pattern-excluded-provider.json", response)
        def rebind(rows):
            state = next(row["evidence"] for row in rows if row.get("label") == "pattern comparison excluded")
            state.update(sha256=self.sha(raw))
            state["responseBinding"]["sha256"] = self.sha(raw)
        self.change_interactions(rebind)
        with self.assertRaisesRegex(ValueError, "Exclude/include"):
            validate(self.root)

    def test_hashed_canonical_pointer_must_match_immutable_archive(self):
        state = json.loads((self.root / "pattern-state-redo.json").read_text())
        record = next(row for row in state["files"] if row["canonicalPath"].endswith(".v1.json") and "/pattern-selections/" in row["canonicalPath"])
        raw = json.loads((self.root / record["retainedPath"]).read_text())
        raw["reason"] = "An unrelated archived choice."
        changed = self.write(record["retainedPath"], raw)
        record["sha256"] = self.sha(changed)
        self.write("pattern-state-redo.json", state)
        self.change_interactions(lambda rows: next(row for row in rows if row.get("label") == "pattern persisted redo").update(evidence=state))
        with self.assertRaisesRegex(ValueError, "immutable source closure"):
            validate(self.root)

    def test_missing_persisted_snapshot_is_normalized_refusal(self):
        self.change_interactions(lambda rows: rows.remove(next(row for row in rows if row.get("label") == "pattern persisted selected")))
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_already_expanded_panel_does_not_require_an_open_click(self):
        self.change_interactions(lambda rows: rows.remove(next(row for row in rows if row.get("id") == "production.pattern.open")))
        self.assertEqual(validate(self.root)["patternID"], self.pattern_id)

    def test_unscored_candidate_is_not_a_valid_fixture_choice(self):
        response = json.loads((self.root / "pattern-provider.json").read_text())
        response["recommendations"]["results"][0]["fit_score"] = None
        raw = self.write("pattern-provider.json", response)
        self.change("pattern-result.json", lambda value: value.update(providerSHA256=self.sha(raw)))
        with self.assertRaisesRegex(ValueError, "no finite score"):
            validate(self.root)

    def test_stale_refusal_outside_selected_after_stale_interval_rejected(self):
        for target in ("pattern persisted before", "pattern persisted undo"):
            with self.subTest(target=target):
                pattern_fixture(self.root)
                def move(rows):
                    refusal = next(row for row in rows if row.get("label") == "pattern stale snapshot refused")
                    rows.remove(refusal)
                    index = next(i for i, row in enumerate(rows) if row.get("label") == target)
                    rows.insert(index, refusal)
                self.change_interactions(move)
                with self.assertRaisesRegex(ValueError, "native actions"):
                    validate(self.root)

    def test_each_deliberate_decision_after_save_is_rejected(self):
        for identifier in ("production.pattern.reason", "production.pattern.acknowledge", "production.pattern.confirm"):
            with self.subTest(identifier=identifier):
                pattern_fixture(self.root)
                def move(rows):
                    action = next(row for row in rows if row.get("id") == identifier or row.get("field", {}).get("id") == identifier)
                    rows.remove(action)
                    index = next(i for i, row in enumerate(rows) if row.get("label") == "pattern persisted selected")
                    rows.insert(index + 1, action)
                self.change_interactions(move)
                with self.assertRaisesRegex(ValueError, "choose/save interval"):
                    validate(self.root)

    def test_duplicate_visible_state_cannot_shadow_another_observation(self):
        for label in ("pattern visible provider values", "pattern visible signature basis", "pattern stale snapshot refused"):
            with self.subTest(label=label):
                pattern_fixture(self.root)
                self.change_interactions(lambda rows: rows.append(copy.deepcopy(next(row for row in rows if row.get("label") == label))))
                with self.assertRaisesRegex(ValueError, "Duplicate or invalid"):
                    validate(self.root)

    def test_view_response_cannot_substitute_a_different_hash_options_or_fingerprint(self):
        for label in ("pattern visible provider values", "pattern comparison excluded", "pattern comparison included"):
            for update in ({"sha256": "f" * 64}, {"excluded": ["foreign"]}, {"mode": "unknown"}, {"fingerprint": "not-a-hash"}):
                with self.subTest(label=label, update=update):
                    pattern_fixture(self.root)
                    self.change_interactions(lambda rows: next(row["evidence"] for row in rows if row.get("label") == label)["responseBinding"].update(update))
                    with self.assertRaisesRegex(ValueError, "actual view response"):
                        validate(self.root)
        for label, fingerprint in (("pattern visible provider values", "c" * 64),
                                   ("pattern comparison excluded", "a" * 64),
                                   ("pattern comparison included", "c" * 64)):
            with self.subTest(label=label, valid_but_unbound_fingerprint=fingerprint):
                pattern_fixture(self.root)
                self.change_interactions(lambda rows: next(row["evidence"] for row in rows if row.get("label") == label)["responseBinding"].update(fingerprint=fingerprint))
                with self.assertRaisesRegex(ValueError, "actual view response"):
                    validate(self.root)

    def test_exclusion_must_render_the_bound_response_values(self):
        for update in ({"index": "42"}, {"confidenceCoverage": "1|1"}, {"library": "0/0"}):
            with self.subTest(update=update):
                pattern_fixture(self.root)
                self.change_interactions(lambda rows: next(row["evidence"] for row in rows if row.get("label") == "pattern comparison excluded").update(update))
                with self.assertRaisesRegex(ValueError, "actual rendered response"):
                    validate(self.root)

    def test_stale_refusal_must_not_add_an_unreferenced_canonical_archive(self):
        state = json.loads((self.root / "pattern-state-after-stale.json").read_text())
        raw = self.write_bytes("stale-orphan.bin", b"an unreferenced new archive")
        state["files"].append({"canonicalPath": "brief/pattern-selections/orphan.v1.json", "retainedPath": "stale-orphan.bin", "sha256": self.sha(raw)})
        self.write("pattern-state-after-stale.json", state)
        self.change_interactions(lambda rows: next(row for row in rows if row.get("label") == "pattern persisted after-stale").update(evidence=state))
        with self.assertRaisesRegex(ValueError, "state sequence"):
            validate(self.root)

    def test_extra_undo_modifiers_do_not_describe_the_native_command(self):
        self.change_interactions(lambda rows: next(row for row in rows if row.get("kind") == "keyboard").update(modifiers=(1 << 20) | (1 << 19)))
        with self.assertRaisesRegex(ValueError, "Native Undo and Redo"):
            validate(self.root)

    def test_nonfinite_visible_index_rejected(self):
        self.change_interactions(lambda rows: next(row["evidence"] for row in rows if row.get("label") == "pattern visible provider values").update(index="nan"))
        with self.assertRaisesRegex(ValueError, "Compatibility Index"):
            validate(self.root)


if __name__ == "__main__":
    unittest.main()
