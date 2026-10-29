import json
from pathlib import Path
import tempfile
import unittest

from test_agent_structured_results_evidence import png, structured_fixture
from test_review_child_owner_evidence import fixture as review_fixture
from workspace_native_evidence import validate_case


class HoststatesStructuredJoinTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.make_fixture(1.5)

    def make_fixture(self, scale):
        self.directory = "scale-" + str(round(scale * 100)) + "-agent-structured"
        child = self.root / self.directory
        child.mkdir()
        structured_fixture(child, scale=scale)
        self.review_directory = "scale-" + str(round(scale * 100)) + "-review-children"
        review = review_fixture(self.root / self.review_directory, scale=scale)
        (self.root / "history.png").write_bytes(png())
        self.rows = [
            {"event": "host-state-history", "scale": scale, "screenshots": ["history.png"],
             "supersededRequestHasNoAction": True, "resetApprovalsMarked": True,
             "revisionNamesResetApprovals": True, "rejectedFirstWriteNotUnverified": True},
            {**json.loads((child / "agent-structured-result.json").read_text()),
             "event": "agent-structured-owner", "os": "synthetic parser fixture",
             "evidenceDirectory": self.directory},
            {**review, "event": "agent-review-child-owner", "os": "synthetic parser fixture",
             "evidenceDirectory": self.review_directory},
            {"event": "completed", "scale": scale, "case": "hoststates"},
        ]

    def test_synthetic_event_file_join_is_accepted(self):
        self.assertTrue(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_old_history_alone_cannot_cover_structured_results(self):
        self.rows.pop(1)
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_conflicting_owner_event_is_rejected(self):
        self.rows[1]["sourceSHA256"] = "0" * 64
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_missing_owner_artifacts_are_rejected(self):
        (self.root / self.directory).rename(self.root / "unavailable")
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_structured_results_alone_cannot_cover_bounded_review_children(self):
        self.rows.pop(2)
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_conflicting_review_child_event_is_rejected(self):
        self.rows[2]["backends"][0]["childContexts"] += 1
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_missing_review_child_artifacts_are_rejected(self):
        (self.root / self.review_directory).rename(self.root / "unavailable-review")
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_validation_does_not_mutate_the_actual_event_screenshots(self):
        before = json.dumps(self.rows, sort_keys=True)
        self.assertTrue(validate_case("hoststates", self.rows, self.root, 1.5)[0])
        self.assertTrue(validate_case("hoststates", self.rows, self.root, 1.5)[0])
        self.assertEqual(json.dumps(self.rows, sort_keys=True), before)

    def test_child_event_must_follow_structured_owner(self):
        self.rows[1], self.rows[2] = self.rows[2], self.rows[1]
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_duplicate_owner_event_refused(self):
        self.rows.insert(2, dict(self.rows[1]))
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_missing_completed_event_refused(self):
        self.rows.pop()
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_missing_original_history_refused(self):
        self.rows.pop(0)
        self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.5)[0])

    def test_boolean_child_event_scale_cannot_equal_100_percent(self):
        self.make_fixture(1.0)
        self.assertTrue(validate_case("hoststates", self.rows, self.root, 1.0)[0])
        for target in [self.rows[2], *self.rows[2]["backends"]]:
            with self.subTest(backend=target.get("backend", "owner")):
                target["scale"] = True
                self.assertFalse(validate_case("hoststates", self.rows, self.root, 1.0)[0])
                target["scale"] = 1.0
