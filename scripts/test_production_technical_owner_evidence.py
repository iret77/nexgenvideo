"""Synthetic validator fixtures; these files are not native acceptance evidence."""
import copy
import json
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
import tempfile
import unittest

from production_technical_owner_evidence import digest, snapshot, validate


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def technical_fixture(directory, native, conditioning=True, other_generated=True, revision_overrides=None, changed_duration=270):
    directory = Path(directory)
    rows = native["interactions"]
    def event(label, evidence):
        rows.append({"kind": "verified-state", "label": label, "evidence": evidence})
    def pointer(action):
        rows.append({"kind": "pointer", "id": "production.technical." + action})
    def image(suffix):
        name = "unit-" + suffix + ".png"
        (directory / name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"unit-parser-image" * 100)
        native["screenshots"].append(name)
        reference = {"path": name, "sha256": digest((directory / name).read_bytes())}
        event("native technical capture", {"label": suffix, "screenshot": reference})
        return reference
    offering = {"catalog_model_id": "unit-model", "provider_id": "isolated-fixture"}
    original = {"execution": {"id": "first-shot", "source_mode": "generated", "primary_action": "An unchanged actual scene",
        "generation_requirement": {"modality_id": "video", "resolution": "720p", "mode_ids": ["image-to-video"],
            "requires_first_frame": conditioning, "requires_last_frame": conditioning}},
        "selectedModelID": "unit-model", "selectedOffering": offering, "referenceDemands": [],
        "sourceInTicks": 30, "nativeDurationTicks": 240,
        "coreInputs": {"first_frame_mode_id": "image-to-video", "last_frame_mode_id": "image-to-video"} if conditioning else {}}
    if conditioning:
        original["endFrameBoundary"] = {"characterCount": 0, "characterPositions": "", "gaze": "", "visibleZones": []}
    changed = copy.deepcopy(original)
    changed.update(sourceInTicks=60, nativeDurationTicks=changed_duration)
    changed["execution"]["generation_requirement"]["resolution"] = "480p"
    if conditioning:
        changed["execution"]["generation_requirement"]["requires_last_frame"] = False
        del changed["coreInputs"]["last_frame_mode_id"]
    other = copy.deepcopy(original) if other_generated else {"execution": {"source_mode": "imported"}, "sourceInTicks": 60}
    other["execution"]["id"] = "second-shot"
    candidates = [{"modelID": "unit-model", "offering": offering, "resolutions": ["720p", "480p"], "modeIDs": ["image-to-video"]}]
    def export(label, revision, shot):
        revision = (revision_overrides or {}).get(label, revision)
        prefix = "technical-" + label + "/"
        files = {}
        def write(name, data):
            path = directory / (prefix + name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            files[prefix + name] = digest(data)
            return {"id": name, "path": name, "role": "unit", "sha256": digest(data)}
        draft = write("draft.json", encoded({"source": "same-story"}))
        timing = write("timing.json", encoded({"durationTicks": 240}))
        bible = write("bible.yaml", b"unit: unchanged\n")
        graph = write(f"graphs/v{revision}.json", encoded({"assets": []})); graph["id"] = "graph"
        shot = copy.deepcopy(shot)
        execution = {"id": "execution-" + str(revision), "shots": [shot["execution"], other["execution"]]}
        execution_ref = write(f"execution/v{revision}.json", encoded(execution)); execution_ref["role"] = "core.execution-plan"
        inputs = [draft, timing, bible, graph, execution_ref]
        routes = []
        for item, suffix in [(shot, ""), (other, "-other")]:
            if "generation_requirement" not in item["execution"]:
                continue
            identity = item["execution"]["id"]
            template_ref = write(f"templates/v{revision}{suffix}.json", encoded({"shot_id": identity, "core_inputs": item["coreInputs"]}))
            template_ref["role"] = "core.production-input-template"
            route_ref = write(f"routes/v{revision}{suffix}.json", encoded({"shot_id": identity, "offering": offering}))
            route_ref["role"] = "core.production-route"
            demand_ref = write(f"demands/v{revision}{suffix}.json", encoded({"shot_id": identity, "demands": item["referenceDemands"]}))
            demand_ref["role"] = "core.planned-reference-demands"
            inputs += [template_ref, route_ref, demand_ref]
            routes.append({"shotID": identity, "route": route_ref})
        projection = {"schema": "shotlist/v5", "header": {"revision": revision, "inputs": inputs},
            "executionPlan": execution, "draftReference": draft, "storyboardReference": timing,
            "mode": "generic", "endFrameBoundaries": {value["execution"]["id"]: value["endFrameBoundary"] for value in (shot, other) if "endFrameBoundary" in value},
            "timebase": {"ticksPerSecond": 30}, "sourceBindings": [], "sourceInputRanges": [], "editorialBindings": [], "chains": [],
            "timings": [{"shotID": "first-shot", "startTicks": 0, "durationTicks": 120,
                "nativeDurationTicks": shot["nativeDurationTicks"], "sourceInTicks": shot["sourceInTicks"]},
                {"shotID": "second-shot", "startTicks": 120, "durationTicks": 120, "sourceInTicks": other["sourceInTicks"],
                    **({"nativeDurationTicks": other["nativeDurationTicks"]} if "nativeDurationTicks" in other else {})}]}
        projection_ref = write(f"shotlist/v{revision}.v5.yaml", b"unit: retained YAML bytes; native decode is separately joined\n" + str(revision).encode())
        promotion = {"schema": "shot-planning-promotion/v1", "header": {"revision": revision, "inputs": inputs + [projection_ref]},
            "draft": draft, "timing": timing, "bible": bible, "assetGraph": graph, "projection": projection_ref,
            "resolutions": [], "routes": routes}
        proposal = {"shots": [shot, other], "expectedDraftFingerprint": draft["sha256"], "expectedAssetGraphFingerprint": graph["sha256"]}
        write("shot-planning/promotion-current.v1.json", encoded(promotion))
        write("decoded-projection.json", encoded(projection)); write("decoded-proposal.json", encoded(proposal))
        write("actual-candidates.json", encoded(candidates)); write("gates.yaml", b"shotlist: pending\n")
        row = {"directory": prefix[:-1], "files": files, "fingerprint": digest(encoded(proposal) + str(revision).encode()), "revision": revision,
            "projection": prefix + projection_ref["path"], "promotion": prefix + "shot-planning/promotion-current.v1.json",
            "proposal": prefix + "decoded-proposal.json", "decodedProjection": prefix + "decoded-projection.json"}
        event("native technical snapshot", {"label": label, "snapshot": row})
        return row
    start = len(rows)
    before = export("before", 1, original)
    rows.insert(start, {"kind": "verified-state", "label": "native technical begin",
                        "evidence": {"shotID": "first-shot", "fingerprint": before["fingerprint"]}})
    for label in ("duration -1", "duration not a time", "trim 999", "missing model", "missing mode"):
        if label.startswith(("duration", "trim")):
            field, value = label.split(" ", 1)
            rows.append({"kind": "text", "field": {"id": "production.technical." + field,
                "expected": value, "actual": value, "focusLeftTarget": True}})
        else:
            field = label.split(" ")[1]
            rows.append({"kind": "menu", "id": "production.technical." + field, "item": "Choose " + field, "closed": True})
        reference = image("technical-invalid-" + label.replace(" ", "-"))
        event("native technical refusal", {"input": label, "applyEnabled": False, "message": "Actual invalid input", "screenshot": reference})
    for key in ("model", "mode", "resolution", "conditioning"):
        rows.append({"kind": "menu", "id": "production.technical." + key, "closed": True})
    image("technical-cancel-dirty"); pointer("cancel")
    cancelled = export("cancelled", 1, original)
    duration_text = format((Decimal(changed_duration) / 30).quantize(Decimal("0.000000000001"), rounding=ROUND_HALF_UP), "f").rstrip("0").rstrip(".")
    for field, value in (("duration", duration_text), ("trim", "2")):
        rows.append({"kind": "text", "field": {"id": "production.technical." + field,
            "actual": value, "expected": value, "focusLeftTarget": True}})
    rows.append({"kind": "visible-group", "ids": ["production.technical.apply", "production.technical.cancel"],
        "viewport": [0, 0, 640, 540], "frames": [[400, 10, 200, 30], [10, 10, 100, 30]]})
    image("technical-before-apply"); pointer("apply")
    applied = export("applied", 2, changed)
    results = {"before": before, "cancelled": cancelled, "applied": applied}
    for label, revision, shot, characters, modifiers in [("undo", 3, original, "z", 1048576), ("redo", 4, changed, "Z", 1179648), ("restored", 5, original, "z", 1048576)]:
        rows.append({"kind": "keyboard", "code": 6, "characters": characters, "modifiers": modifiers})
        results[label] = export(label, revision, shot)
    image("technical-original-restored")
    event("native technical Shot settings", {"shotID": "first-shot", **results})
    return results


class TechnicalEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.native = {"interactions": [], "screenshots": []}
        self.result = technical_fixture(self.root, self.native)

    def check(self):
        return validate(self.native, self.root, require_conditioning=True)

    def replace(self, label, relative, value):
        name = "technical-" + label + "/" + relative
        raw = encoded(value); (self.root / name).write_bytes(raw)
        self.result[label]["files"][name] = digest(raw)

    def rebind(self, label):
        prefix = "technical-" + label + "/"
        files = self.result[label]["files"]
        def references(value):
            if isinstance(value, dict):
                if "path" in value and "sha256" in value and prefix + value["path"] in files:
                    value["sha256"] = files[prefix + value["path"]]
                for child in value.values():
                    references(child)
            elif isinstance(value, list):
                for child in value:
                    references(child)
        for _ in range(len(files) + 1):
            changed = False
            for name in list(files):
                if not name.endswith(".json"):
                    continue
                value = json.loads((self.root / name).read_bytes())
                references(value)
                raw = encoded(value)
                if digest(raw) != files[name]:
                    (self.root / name).write_bytes(raw)
                    files[name] = digest(raw)
                    changed = True
            if not changed:
                return
        self.fail("Synthetic reference graph did not converge")

    def load(self, label, relative):
        return json.loads((self.root / ("technical-" + label + "/" + relative)).read_bytes())

    def test_complete_parser_fixture(self):
        self.assertTrue(self.check())

    def test_complete_mixed_imported_parser_fixture(self):
        self.native = {"interactions": [], "screenshots": []}
        self.result = technical_fixture(self.root, self.native, other_generated=False)
        self.assertTrue(self.check())

    def test_displayed_rational_seconds_restore_the_same_tick(self):
        self.native = {"interactions": [], "screenshots": []}
        self.result = technical_fixture(self.root, self.native, changed_duration=271)
        self.assertTrue(self.check())
        typed = [row["field"] for row in self.native["interactions"] if row.get("kind") == "text" and row["field"].get("id") == "production.technical.duration"][-1]
        typed["actual"] = typed["expected"] = "9.05"
        self.assertFalse(self.check())

    def test_changed_canonical_bytes(self):
        (self.root / "technical-applied/routes/v2.json").write_bytes(b"changed")
        self.assertFalse(self.check())

    def test_rehashed_route_model_disagrees(self):
        name = "technical-applied/routes/v2.json"
        route = json.loads((self.root / name).read_bytes()); route["offering"]["catalog_model_id"] = "other"
        self.replace("applied", "routes/v2.json", route)
        self.rebind("applied")
        with self.assertRaisesRegex(ValueError, "route differs from its proposal"):
            snapshot(self.root, self.result["applied"], "applied", "first-shot")
        self.assertFalse(self.check())

    def test_cancel_cannot_publish_new_bytes(self):
        candidates = json.loads((self.root / "technical-cancelled/actual-candidates.json").read_bytes())
        candidates.append({"modelID": "unused", "offering": {"catalog_model_id": "unused"}})
        self.replace("cancelled", "actual-candidates.json", candidates)
        self.assertEqual(snapshot(self.root, self.result["cancelled"], "cancelled", "first-shot")["shot"]["selectedModelID"], "unit-model")
        self.assertFalse(self.check())

    def test_decode_summary_cannot_substitute_canonical_execution(self):
        proposal = json.loads((self.root / self.result["applied"]["proposal"]).read_bytes())
        proposal["shots"][0]["execution"]["primary_action"] = "substituted"
        self.replace("applied", "decoded-proposal.json", proposal)
        self.assertFalse(self.check())

    def test_gate_change_even_when_rehashed(self):
        name = "technical-redo/gates.yaml"; raw = b"shotlist: approved\n"
        (self.root / name).write_bytes(raw); self.result["redo"]["files"][name] = digest(raw)
        self.assertFalse(self.check())

    def test_missing_keyboard_redo(self):
        self.native["interactions"] = [row for row in self.native["interactions"] if row.get("characters") != "Z"]
        self.assertFalse(self.check())

    def test_invalid_apply_must_be_disabled(self):
        next(row for row in self.native["interactions"] if row.get("label") == "native technical refusal")["evidence"]["applyEnabled"] = True
        self.assertFalse(self.check())

    def test_uncommitted_field_is_not_native_input(self):
        next(row for row in self.native["interactions"] if row.get("kind") == "text")["field"]["focusLeftTarget"] = False
        self.assertFalse(self.check())

    def test_revision_bool_rejected(self):
        self.result["before"]["revision"] = True
        self.assertFalse(self.check())

    def test_removed_screenshot(self):
        self.native["screenshots"].pop()
        self.assertFalse(self.check())

    def test_symlinked_artifact_rejected(self):
        path = self.root / "technical-before/graphs/v1.json"
        other = self.root / "retained-copy.json"; path.rename(other); path.symlink_to(other)
        self.assertFalse(self.check())

    def test_applied_snapshot_must_follow_apply(self):
        rows = self.native["interactions"]
        snap = next(row for row in rows if row.get("label") == "native technical snapshot" and row["evidence"]["label"] == "applied")
        rows.remove(snap)
        rows.insert(next(i for i, row in enumerate(rows) if row.get("id") == "production.technical.apply"), snap)
        self.assertFalse(self.check())

    def test_all_history_keys_before_any_history_snapshot_are_rejected(self):
        rows = self.native["interactions"]
        keys = [row for row in rows if row.get("kind") == "keyboard"]
        rows[:] = [row for row in rows if row not in keys]
        position = next(i for i, row in enumerate(rows) if row.get("label") == "native technical snapshot" and row["evidence"]["label"] == "undo")
        rows[position:position] = keys
        self.assertFalse(self.check())

    def test_snapshot_or_refusal_outside_the_native_scope_is_rejected(self):
        for label in ("native technical snapshot", "native technical refusal"):
            with self.subTest(label=label):
                candidate = copy.deepcopy(self.native)
                row = next(row for row in candidate["interactions"] if row.get("label") == label)
                candidate["interactions"].remove(row)
                candidate["interactions"].insert(0, row)
                self.assertFalse(validate(candidate, self.root, require_conditioning=True))

    def test_later_invalid_input_cannot_attest_an_earlier_refusal(self):
        rows = self.native["interactions"]
        typed = next(row for row in rows if row.get("kind") == "text" and row["field"]["actual"] == "999")
        rows.remove(typed)
        rows.insert(next(i for i, row in enumerate(rows) if row.get("label") == "native technical refusal" and row["evidence"]["input"] == "trim 999") + 1, typed)
        self.assertFalse(self.check())

    def test_missing_model_refusal_requires_its_actual_empty_picker(self):
        self.native["interactions"] = [row for row in self.native["interactions"] if row.get("item") != "Choose model"]
        self.assertFalse(self.check())

    def test_refusal_cannot_reuse_another_captured_image(self):
        failures = [row["evidence"] for row in self.native["interactions"] if row.get("label") == "native technical refusal"]
        failures[0]["screenshot"] = failures[1]["screenshot"]
        self.assertFalse(self.check())

    def test_changed_timed_screenshot_bytes_are_rejected(self):
        capture = next(row["evidence"] for row in self.native["interactions"] if row.get("label") == "native technical capture")
        (self.root / capture["screenshot"]["path"]).write_bytes(b"\x89PNG\r\n\x1a\nsubstitute")
        self.assertFalse(self.check())

    def test_non_target_route_semantics_cannot_change_even_when_fully_rebound(self):
        value = self.load("applied", "routes/v2-other.json")
        value["quality_score"] = 0.1
        self.replace("applied", "routes/v2-other.json", value)
        self.rebind("applied")
        snapshot(self.root, self.result["applied"], "applied", "first-shot")
        self.assertFalse(self.check())

    def test_non_target_template_is_joined_to_its_proposal(self):
        value = self.load("applied", "templates/v2-other.json")
        value["core_inputs"] = {}
        self.replace("applied", "templates/v2-other.json", value)
        self.rebind("applied")
        with self.assertRaisesRegex(ValueError, "template differs from its proposal"):
            snapshot(self.root, self.result["applied"], "applied", "first-shot")
        self.assertFalse(self.check())

    def test_reference_demands_are_joined_to_actual_canonical_demand_bytes(self):
        value = self.load("applied", "demands/v2.json")
        value["demands"] = [{"asset_id": "foreign"}]
        self.replace("applied", "demands/v2.json", value)
        self.rebind("applied")
        with self.assertRaisesRegex(ValueError, "demands differ from their proposal"):
            snapshot(self.root, self.result["applied"], "applied", "first-shot")
        self.assertFalse(self.check())

    def test_canonical_non_target_source_range_must_match_its_proposal(self):
        value = self.load("applied", "decoded-projection.json")
        value["timings"][1]["sourceInTicks"] += 1
        self.replace("applied", "decoded-projection.json", value)
        with self.assertRaisesRegex(ValueError, "timing differs from its proposal"):
            snapshot(self.root, self.result["applied"], "applied", "first-shot")
        self.assertFalse(self.check())

    def test_coherent_non_target_shot_range_drift_is_rejected(self):
        for label in ("applied", "redo"):
            proposal = self.load(label, "decoded-proposal.json")
            projection = self.load(label, "decoded-projection.json")
            proposal["shots"][1]["sourceInTicks"] += 1
            projection["timings"][1]["sourceInTicks"] += 1
            self.replace(label, "decoded-proposal.json", proposal)
            self.replace(label, "decoded-projection.json", projection)
            snapshot(self.root, self.result[label], label, "first-shot")
        self.assertEqual(self.load("applied", "decoded-proposal.json"), self.load("redo", "decoded-proposal.json"))
        self.assertFalse(self.check())

    def test_mode_is_an_invariant(self):
        changed = self.load("applied", "decoded-projection.json")
        changed["mode"] = "multicam"
        self.replace("applied", "decoded-projection.json", changed)
        snapshot(self.root, self.result["applied"], "applied", "first-shot")
        self.assertFalse(self.check())

    def test_authored_end_boundaries_are_joined_to_the_canonical_projection(self):
        changed = self.load("applied", "decoded-projection.json")
        changed["endFrameBoundaries"] = {}
        self.replace("applied", "decoded-projection.json", changed)
        with self.assertRaisesRegex(ValueError, "end boundaries differ from their proposal"):
            snapshot(self.root, self.result["applied"], "applied", "first-shot")
        self.assertFalse(self.check())

    def test_unhashed_gates_file_cannot_attest_state(self):
        del self.result["applied"]["files"]["technical-applied/gates.yaml"]
        with self.assertRaisesRegex(ValueError, "Unbound technical gates"):
            snapshot(self.root, self.result["applied"], "applied", "first-shot")
        self.assertFalse(self.check())

    def test_wrong_draft_binding_is_rejected_after_hashes_match(self):
        proposal = self.load("applied", "decoded-proposal.json")
        proposal["expectedDraftFingerprint"] = "b" * 64
        self.replace("applied", "decoded-proposal.json", proposal)
        with self.assertRaisesRegex(ValueError, "approved source binding"):
            snapshot(self.root, self.result["applied"], "applied", "first-shot")
        self.assertFalse(self.check())

    def test_non_monotonic_revision_is_a_coherent_snapshot_but_not_a_valid_history(self):
        self.native = {"interactions": [], "screenshots": []}
        self.result = technical_fixture(self.root, self.native, revision_overrides={"undo": 2})
        for label in self.result:
            snapshot(self.root, self.result[label], label, "first-shot")
        self.assertFalse(self.check())

    def test_undo_cannot_restore_a_different_but_coherent_range(self):
        proposal = self.load("undo", "decoded-proposal.json")
        projection = self.load("undo", "decoded-projection.json")
        proposal["shots"][0]["sourceInTicks"] += 1
        projection["timings"][0]["sourceInTicks"] += 1
        self.replace("undo", "decoded-proposal.json", proposal)
        self.replace("undo", "decoded-projection.json", projection)
        snapshot(self.root, self.result["undo"], "undo", "first-shot")
        self.assertFalse(self.check())

    def test_visible_identifier_cannot_substitute_for_a_late_native_click(self):
        original = copy.deepcopy(self.native["interactions"])
        for action, snapshot_label in [("cancel", "cancelled"), ("apply", "applied")]:
            with self.subTest(action=action):
                rows = self.native["interactions"] = copy.deepcopy(original)
                i = next(i for i, row in enumerate(rows) if row.get("kind") == "pointer" and row.get("id") == "production.technical." + action)
                click = rows[i]
                rows[i] = {"kind": "visible", "id": click["id"]}
                end = next(i for i, row in enumerate(rows) if row.get("label") == "native technical snapshot" and row["evidence"]["label"] == snapshot_label)
                rows.insert(end + 1, click)
                self.assertFalse(self.check())

    def test_apply_image_must_follow_last_submitted_field_values(self):
        rows = self.native["interactions"]
        capture = next(row for row in rows if row.get("label") == "native technical capture" and row["evidence"]["label"] == "technical-before-apply")
        rows.remove(capture)
        cancelled = next(i for i, row in enumerate(rows) if row.get("label") == "native technical snapshot" and row["evidence"]["label"] == "cancelled")
        rows.insert(cancelled + 1, capture)
        self.assertFalse(self.check())
