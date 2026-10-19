"""Synthetic action/refusal mutations; these do not assert native or AI quality."""
import copy
import unittest

import test_color_reference_evidence as fixture
from color_reference_evidence import validate


class ColorActionAndRefusalTests(unittest.TestCase):
    def setUp(self):
        self.case = fixture.ColorReferenceValidatorTests("test_isolated_validator_shape_with_distinct_image_encodings")
        self.addCleanup(self.case.doCleanups)
        self.case.setUp()
        validate(self.case.root)

    def before_second_measure(self, action):
        position = [i for i, row in enumerate(self.case.actions)
                    if row.get("kind") == "pointer" and row.get("id") == "color.reference.measure"][1]
        self.case.actions.insert(position, action)

    def rejected_action(self):
        self.case.persist()
        with self.assertRaisesRegex(ValueError, "Unexpected native color action"):
            validate(self.case.root)

    def rejected_attempt(self):
        self.case.replace_request(2)
        self.case.persist()
        with self.assertRaisesRegex(ValueError, "mutation attempt"):
            validate(self.case.root)

    def test_extra_apply_without_a_snapshot_change_is_rejected(self):
        self.before_second_measure({"kind": "pointer", "id": "color.reference.apply"})
        self.rejected_action()

    def test_extra_undo_before_the_next_measurement_is_rejected(self):
        self.before_second_measure({"kind": "keyboard", "code": 6, "modifiers": 1 << 20})
        self.rejected_action()

    def test_extra_measure_and_propose_cannot_borrow_the_next_observation(self):
        position = [i for i, row in enumerate(self.case.actions)
                    if row.get("kind") == "pointer" and row.get("id") == "color.reference.measure"][1]
        self.case.actions[position:position] = [{"kind": "pointer", "id": "color.reference.measure"},
                                              {"kind": "pointer", "id": "color.reference.propose"}]
        self.rejected_action()

    def test_trailing_apply_cannot_escape_final_snapshot(self):
        self.case.actions.append({"kind": "pointer", "id": "color.reference.apply"})
        self.rejected_action()

    def test_viewport_scrolling_does_not_count_as_an_extra_grade_action(self):
        self.before_second_measure({"kind": "wheel", "id": "color.reference.frame.clip", "delta": -100,
                                    "before": [0, 0], "after": [0, 100]})
        self.case.persist()
        validate(self.case.root)

    def test_optional_correction_disclosure_has_one_exact_position(self):
        identifier = "inspector.adjust.value.color.exposure.ev"
        position = next(i for i, row in enumerate(self.case.actions)
                        if row.get("kind") == "pointer" and row.get("id") == identifier)
        disclosure = {"kind": "pointer", "id": "inspector.section.Basic Correction"}
        self.case.actions.insert(position, disclosure)
        self.case.persist()
        validate(self.case.root)
        self.case.actions.insert(position, copy.deepcopy(disclosure))
        self.rejected_action()

    def test_mutation_refusal_cannot_be_replaced_by_a_success(self):
        self.case.requests[1]["mutationAttempt"]["isError"] = False
        self.rejected_attempt()

    def test_foreign_mutation_arguments_cannot_attest_the_target(self):
        self.case.requests[1]["mutationAttempt"]["arguments"]["clipIds"] = ["foreign-clip"]
        self.rejected_attempt()

    def test_a_different_tool_cannot_attest_apply_color_refusal(self):
        self.case.requests[1]["mutationAttempt"]["toolName"] = "inspect_color"
        self.rejected_attempt()

    def test_unrelated_error_cannot_attest_the_scoped_mutation_guard(self):
        self.case.requests[1]["mutationAttempt"]["content"] = [{"kind": "text", "text": "Unrelated IO error"}]
        self.rejected_attempt()

    def test_counter_alone_cannot_replace_the_retained_mutation_attempt(self):
        del self.case.requests[1]["mutationAttempt"]
        self.rejected_attempt()
