from copy import deepcopy
import unittest

from production_source_video_owner_evidence import validate_next_shot_navigation


class NextShotNavigationEvidenceTests(unittest.TestCase):
    def evidence(self):
        return {"interactions": [
            {"kind": "pointer", "id": "take.open", "window": 2},
            {"kind": "pointer", "id": "take.next", "window": 1},
            {"kind": "pointer", "id": "take.next", "window": 2},
            {"kind": "verified-state", "label": "native next open shot in sheet and workspace", "evidence": {
                "firstTakeID": "first-take", "nextTakeID": "next-take", "nextShotID": "second-shot",
                "selectionAndReviewUnchanged": True, "selectionSHA256Before": "a" * 64,
                "selectionSHA256After": "a" * 64}},
        ], "screenshots": ["source-" + str(i) + "-next-shot-" + label + ".png" for i, label in enumerate(
            ["sheet-before", "sheet-after", "workspace-before", "workspace-after"])]}

    def validate(self, value):
        validate_next_shot_navigation(value, "first-take", "next-take", "second-shot", "a" * 64)

    def test_exact_two_surface_navigation_is_accepted(self):
        self.validate(self.evidence())

    def test_changed_identity_or_canonical_selection_is_rejected(self):
        for key in ["firstTakeID", "nextTakeID", "nextShotID", "selectionSHA256Before", "selectionSHA256After"]:
            with self.subTest(key=key):
                value = self.evidence()
                value["interactions"][-1]["evidence"][key] = "unrelated"
                with self.assertRaises(ValueError):
                    self.validate(value)

    def test_missing_surface_click_or_image_is_rejected(self):
        for index in [1, 2]:
            value = self.evidence()
            value["interactions"].pop(index)
            with self.assertRaises(ValueError):
                self.validate(value)
        for index in range(4):
            value = self.evidence()
            value["screenshots"].pop(index)
            with self.assertRaises(ValueError):
                self.validate(value)

    def test_one_surface_twice_and_duplicate_receipt_are_rejected(self):
        value = self.evidence()
        value["interactions"][2]["window"] = 1
        with self.assertRaises(ValueError):
            self.validate(value)
        value = self.evidence()
        value["interactions"].append(deepcopy(value["interactions"][-1]))
        with self.assertRaises(ValueError):
            self.validate(value)

    def test_navigation_must_preserve_approval_truth(self):
        for flag in [False, 0, 1, "true"]:
            with self.subTest(flag=flag):
                value = self.evidence()
                value["interactions"][-1]["evidence"]["selectionAndReviewUnchanged"] = flag
                with self.assertRaises(ValueError):
                    self.validate(value)

    def test_wrong_window_role_and_duplicate_image_are_rejected(self):
        value = self.evidence()
        value["interactions"][0]["window"] = 3
        with self.assertRaises(ValueError):
            self.validate(value)
        value = self.evidence()
        value["screenshots"].append(value["screenshots"][0])
        with self.assertRaises(ValueError):
            self.validate(value)


if __name__ == "__main__":
    unittest.main()
