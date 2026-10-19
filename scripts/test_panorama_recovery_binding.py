import hashlib
import json
from tempfile import TemporaryDirectory
import unittest
from pathlib import Path

from retained_spatial_evidence import validate
from test_retained_spatial_evidence import fixture, put


class PanoramaRecoveryBindingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        fixture(self.root)
        self.case = self.root / "panorama-batch-100"

    def edit(self, change):
        path = self.root / "native-panorama-result.json"
        entries = json.loads(path.read_bytes())
        change(entries[0])
        put(path, entries)
        for entry in entries:
            put(self.root / entry["progress"], {"interactions": entry["interactions"],
                "screenshots": entry["screenshots"], "failure": None})

    def observation(self, entry, label):
        return next(action["evidence"] for action in entry["interactions"] if action.get("label") == label)

    def rebind_yaml(self, state):
        path = self.case / ("bible-" + state + ".yaml")
        self.edit(lambda entry: self.observation(entry, "native panorama batch recovery")["canonicalSnapshots"][state]
                  .__setitem__("sha256", hashlib.sha256(path.read_bytes()).hexdigest()))

    def rebind_receipt(self, change):
        path = self.case / "receipt-1.json"
        value = json.loads(path.read_bytes())
        change(value)
        put(path, value)
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        for state in ("selected", "after-undo"):
            path = self.case / ("bible-" + state + ".json")
            bible = json.loads(path.read_bytes())
            bible["locations"][1]["attributes"]["core.native-panorama-receipt-sha256"] = sha
            put(path, bible)
            put(self.case / ("bible-" + state + ".yaml"), bible)
            self.rebind_yaml(state)
        for attempt in (1, 2):
            path = self.case / f"damage-{attempt}.json"
            damage = json.loads(path.read_bytes())
            damage[1]["expectedSHA256"] = sha
            put(path, damage)

    def test_complete_bound_evidence(self):
        validate(self.root)

    def test_semantically_equal_reencoded_undo_yaml_is_accepted(self):
        path = self.case / "bible-after-undo.yaml"
        value = json.loads(path.read_bytes())
        path.write_text("# Independently encoded retained YAML\nproject: fixture\nlocations: "
                        + json.dumps(value["locations"]) + "\n")
        self.rebind_yaml("after-undo")
        validate(self.root)

    def test_unquoted_exponent_preserves_actual_undo_bible_numbers(self):
        path = self.case / "bible-after-undo.yaml"
        value = json.loads(path.read_bytes())
        locations = json.dumps(value["locations"]).replace('"pitch": -5', '"pitch": -5e+0', 1)
        self.assertIn('"pitch": -5e+0', locations)
        path.write_text("project: fixture\nlocations: " + locations + "\n")
        self.rebind_yaml("after-undo")
        validate(self.root)

    def test_quoted_exponent_cannot_replace_actual_undo_bible_number(self):
        path = self.case / "bible-after-undo.yaml"
        value = json.loads(path.read_bytes())
        locations = json.dumps(value["locations"]).replace('"pitch": -5', '"pitch": "-5e+0"', 1)
        self.assertIn('"pitch": "-5e+0"', locations)
        path.write_text("project: fixture\nlocations: " + locations + "\n")
        self.rebind_yaml("after-undo")
        with self.assertRaisesRegex(ValueError, "YAML differs"):
            validate(self.root)

    def test_semantically_equal_second_removal_can_have_different_yaml_bytes(self):
        before = self.case / "bible-before-blocked-undo.yaml"
        value = json.loads(before.read_bytes())
        encoded = "# Second semantic writer transaction\n" + json.dumps(value, indent=2) + "\n"
        for state in ("before-blocked-undo", "after-blocked-undo"):
            (self.case / ("bible-" + state + ".yaml")).write_text(encoded)
            self.rebind_yaml(state)
        validate(self.root)

    def test_rehashed_yaml_cannot_disagree_with_observed_bible(self):
        path = self.case / "bible-after-undo.yaml"
        value = json.loads(path.read_bytes())
        value["locations"][1]["sheets"] = {}
        put(path, value)
        self.rebind_yaml("after-undo")
        with self.assertRaisesRegex(ValueError, "YAML differs"):
            validate(self.root)

    def test_equivalent_but_rewritten_blocked_undo_is_rejected(self):
        path = self.case / "bible-after-blocked-undo.yaml"
        path.write_text(json.dumps(json.loads(path.read_bytes()), indent=2))
        self.rebind_yaml("after-blocked-undo")
        with self.assertRaisesRegex(ValueError, "blocked Undo changed canonical bytes"):
            validate(self.root)

    def test_refusal_message_must_be_observed_after_actual_command_z(self):
        def change(entry):
            actions = entry["interactions"]
            surface = next(action for action in actions if action.get("label") == "panorama undo surface")
            actions.remove(surface)
            ready = next(index for index, action in enumerate(actions) if action.get("label") == "panorama removal undo ready 2")
            actions.insert(ready + 1, surface)
        self.edit(change)
        with self.assertRaisesRegex(ValueError, "post-Cmd-Z"):
            validate(self.root)

    def test_prior_or_different_message_is_rejected(self):
        self.edit(lambda entry: self.observation(entry, "panorama undo surface").__setitem__("message", "Earlier failure"))
        with self.assertRaisesRegex(ValueError, "post-Cmd-Z"):
            validate(self.root)

    def test_plain_z_cannot_stand_in_for_command_z(self):
        def change(entry):
            keys = [action for action in entry["interactions"] if action.get("kind") == "keyboard"]
            keys[-1]["modifiers"] = 0
        self.edit(change)
        with self.assertRaisesRegex(ValueError, "native Cmd-Z"):
            validate(self.root)

    def test_successful_undo_requires_inverse_history_and_no_feedback(self):
        for field in ("canRedo", "managerOwned", "feedbackEmpty", "phaseIdle"):
            with self.subTest(field=field):
                fixture(self.root)
                self.edit(lambda entry: self.observation(entry, "panorama semantic undo restored").__setitem__(field, False))
                with self.assertRaisesRegex(ValueError, "successful Undo did not complete"):
                    validate(self.root)

    def test_text_responder_cannot_claim_document_undo(self):
        self.edit(lambda entry: self.observation(entry, "panorama removal undo ready 2").__setitem__("firstResponderIsTextEditor", True))
        with self.assertRaisesRegex(ValueError, "document Undo manager"):
            validate(self.root)

    def test_invalid_list_must_precede_actual_removal(self):
        def change(entry):
            actions = entry["interactions"]
            invalid = next(action for action in actions if action.get("label") == "actual invalid panorama list 2")
            actions.remove(invalid)
            ready = next(index for index, action in enumerate(actions) if action.get("label") == "panorama removal undo ready 2")
            actions.insert(ready, invalid)
        self.edit(change)
        with self.assertRaisesRegex(ValueError, "invalid list did not precede"):
            validate(self.root)

    def test_long_feedback_fixture_must_scroll_without_hiding_dismiss(self):
        self.edit(lambda entry: self.observation(entry, "production feedback bounded scrolling").__setitem__("dismiss", [20, 20, 100, 30]))
        with self.assertRaisesRegex(ValueError, "obscures Dismiss"):
            validate(self.root)

    def test_bounded_feedback_requires_retained_screenshot_bytes(self):
        path = self.root / "native-panorama-100-production-feedback-long-after-scroll.png"
        path.write_bytes(b"not an actual PNG")
        with self.assertRaisesRegex(ValueError, "bounded feedback screenshot"):
            validate(self.root)

    def test_foreign_location_fails_even_after_receipt_hashes_are_rebound(self):
        self.rebind_receipt(lambda receipt: receipt.__setitem__("locationID", "room"))
        with self.assertRaisesRegex(ValueError, "foreign batch receipt"):
            validate(self.root)

    def test_second_view_paths_must_belong_to_actual_second_location(self):
        self.rebind_receipt(lambda receipt: receipt["views"][0]["image"].__setitem__("path", "bible/ns/native-panorama-owner/wide_front.png"))
        with self.assertRaisesRegex(ValueError, "foreign view directory"):
            validate(self.root)

    def test_selected_source_must_match_native_observation(self):
        self.edit(lambda entry: self.observation(entry, "native panorama batch recovery").__setitem__("selectedSourceSHA256", "0" * 64))
        with self.assertRaisesRegex(ValueError, "actual selected source"):
            validate(self.root)

    def test_copied_pov_requires_membership_after_rebinding_input_hash(self):
        path = self.case / "negative-input-copied-pov.bin"
        path.write_bytes(b"Different bytes with a consistent rebound input hash")
        negative_path = self.case / "copied-pov.json"
        negative = json.loads(negative_path.read_bytes())
        negative["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        put(negative_path, negative)
        with self.assertRaisesRegex(ValueError, "actual panorama/POV bytes"):
            validate(self.root)

    def test_malformed_receipt_shape_is_a_validation_error(self):
        put(self.case / "receipt-1.json", {"panorama": [], "views": []})
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_observation_fields_cannot_be_omitted_or_substituted(self):
        for label, field, wrong in (
                ("panorama removal undo ready 2", "menuTitle", "Undo Another Action"),
                ("panorama undo surface", "feedback", "media.toast"),
                ("native panorama batch recovery", "invalidCount", 1),
                ("native panorama batch recovery", "locationIDs", ["room", "foreign"]),
                ("actual invalid panorama list 2", "visibleLocationIDs", "room"),
                ("native panorama batch recovery", "undoError", "An unrelated error"),
                ("production feedback bounded scrolling", "uiStateFixture", False)):
            with self.subTest(field=field):
                fixture(self.root)
                self.edit(lambda entry: self.observation(entry, label).__setitem__(field, wrong))
                with self.assertRaises(ValueError):
                    validate(self.root)

    def test_negative_refusal_requires_error_result_and_canonical_observation(self):
        path = self.case / "copied-pov.json"
        value = json.loads(path.read_bytes())
        value["isError"] = False
        put(path, value)
        with self.assertRaisesRegex(ValueError, "actual write_bible negative"):
            validate(self.root)
        fixture(self.root)
        self.edit(lambda entry: self.observation(entry, "actual panorama sheet refusal copied-pov").__setitem__("canonicalUnchanged", False))
        with self.assertRaisesRegex(ValueError, "tool refusal differs"):
            validate(self.root)

    def test_first_undo_requires_actual_command_and_empty_baseline_before_it(self):
        def remove(entry):
            key = next(action for action in entry["interactions"] if action.get("kind") == "keyboard")
            entry["interactions"].remove(key)
        self.edit(remove)
        with self.assertRaises(ValueError):
            validate(self.root)
        fixture(self.root)
        def move(entry):
            actions = entry["interactions"]
            baseline = next(action for action in actions if action.get("label") == "panorama successful undo feedback baseline")
            actions.remove(baseline)
            key = next(index for index, action in enumerate(actions) if action.get("kind") == "keyboard")
            actions.insert(key + 1, baseline)
        self.edit(move)
        with self.assertRaisesRegex(ValueError, "baseline did not precede"):
            validate(self.root)


if __name__ == "__main__":
    unittest.main()
