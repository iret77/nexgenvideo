import unittest

from verify_recorded_hang_result import verification_errors


class RecordedHangResultTests(unittest.TestCase):
    def test_stalled_released_control_must_stop_inside_captured_failure_window(self):
        result = {
            "timedOut": True,
            "geometryRequested": True,
            "transcriptGeometrySource": "recorded",
            "recordedWindowWidth": 1463,
            "recordedWindowHeight": 1040,
            "recordedTranscriptWidth": 328,
            "recordedTranscriptHeight": 610,
            "constraintOverflowWarning": True,
            "lastSequence": 247,
            "progress": {
                "finished": False, "sequence": 245,
                "transcriptGeometrySource": "recorded",
                "transcriptWidth": 328, "transcriptHeight": 610,
                "scrollTarget": "scroll-1", "transcriptScrollTarget": "scroll-1", "scrollEventsSent": 600,
                "scrollMotion": {"target": "scroll-1", "before": 200, "after": 140,
                                 "contentHeight": 1010, "viewportHeight": 610},
                "windowWidth": 1463, "windowHeight": 1040,
            },
        }
        self.assertEqual(verification_errors(result, "baseline"), [])

        result["progress"]["sequence"] = 247
        self.assertEqual(verification_errors(result, "baseline"), [])

        result["progress"]["sequence"] = None
        self.assertIn(
            "released control did not identify the stalled sequence",
            verification_errors(result, "baseline"),
        )

    def test_completed_released_control_is_a_valid_nondeterministic_control(self):
        result = {
            "timedOut": False,
            "exitCode": 0,
            "geometryRequested": True,
            "transcriptGeometrySource": "recorded",
            "recordedWindowWidth": 1463,
            "recordedWindowHeight": 1040,
            "recordedTranscriptWidth": 328,
            "recordedTranscriptHeight": 610,
            "lastSequence": 247,
            "progress": {
                "finished": True, "sequence": None,
                "transcriptGeometrySource": "recorded",
                "transcriptWidth": 328, "transcriptHeight": 610,
                "scrollTarget": "scroll-1", "transcriptScrollTarget": "scroll-1", "scrollEventsSent": 600,
                "scrollMotion": {"target": "scroll-1", "before": 200, "after": 140,
                                 "contentHeight": 1010, "viewportHeight": 610},
                "windowWidth": 1463, "windowHeight": 1040,
            },
        }
        self.assertEqual(verification_errors(result, "baseline"), [])

    def test_candidate_must_finish_with_a_responsive_main_thread(self):
        result = {
            "timedOut": False,
            "exitCode": 0,
            "geometryRequested": True,
            "transcriptGeometrySource": "recorded",
            "recordedWindowWidth": 1463,
            "recordedWindowHeight": 1040,
            "recordedTranscriptWidth": 328,
            "recordedTranscriptHeight": 610,
            "constraintOverflowWarning": True,
            "progress": {
                "finished": True,
                "sequence": None,
                "transcriptGeometrySource": "recorded",
                "windowWidth": 1463,
                "windowHeight": 1040,
                "transcriptWidth": 328, "transcriptHeight": 610,
                "scrollTarget": "scroll-1", "transcriptScrollTarget": "scroll-1", "scrollEventsSent": 600,
                "scrollMotion": {"target": "scroll-1", "before": 200, "after": 140,
                                 "contentHeight": 1010, "viewportHeight": 610},
                "maximumPulseGap": 0.4,
            },
        }
        self.assertEqual(verification_errors(result, "candidate"), [])

        result["progress"]["scrollEventsSent"] = 0
        self.assertIn("no complete scroll gesture was sent to the transcript",
                      verification_errors(result, "candidate"))
        result["progress"]["scrollEventsSent"] = 600
        result["progress"]["transcriptWidth"] = 260
        self.assertIn("replay transcript width 260.0 does not match recorded 328.0",
                      verification_errors(result, "candidate"))
        result["progress"]["transcriptWidth"] = 328
        result["progress"]["scrollTarget"] = "workflow-sidebar"
        self.assertIn("scroll target was not the full diagnostic transcript",
                      verification_errors(result, "candidate"))
        result["progress"]["scrollTarget"] = "scroll-1"

        motion = result["progress"]["scrollMotion"]
        motion["target"] = "other-scroll"
        self.assertIn("no scroll movement was measured on the transcript",
                      verification_errors(result, "candidate"))
        motion["target"] = "scroll-1"
        motion["after"] = motion["before"]
        self.assertIn("scroll gesture did not move the transcript away from its interior offset",
                      verification_errors(result, "candidate"))
        motion["after"] = 140
        motion["before"] = 400
        self.assertIn("scroll gesture did not move the transcript away from its interior offset",
                      verification_errors(result, "candidate"))
        motion["before"] = 200
        self.assertEqual(verification_errors(result, "candidate"), [])

        result["progress"]["windowWidth"] = 1200
        self.assertIn(
            "replay window width 1200.0 does not match recorded 1463.0",
            verification_errors(result, "candidate"),
        )
        result["progress"]["windowWidth"] = 1463

        result["progress"]["maximumPulseGap"] = 8.0
        self.assertIn(
            "candidate main-thread pulse gap 8.000s exceeded 5.000s",
            verification_errors(result, "candidate"),
        )

    def test_candidate_rejects_an_incomplete_replay(self):
        result = {
            "timedOut": True,
            "exitCode": -9,
            "geometryRequested": True,
            "transcriptGeometrySource": "recorded",
            "recordedWindowWidth": 1463,
            "recordedWindowHeight": 1040,
            "recordedTranscriptWidth": 328,
            "recordedTranscriptHeight": 610,
            "constraintOverflowWarning": False,
            "progress": {
                "finished": False,
                "sequence": 245,
                "transcriptGeometrySource": "recorded",
                "windowWidth": 1463,
                "windowHeight": 1040,
                "transcriptWidth": 328, "transcriptHeight": 610,
                "scrollTarget": "scroll-1", "transcriptScrollTarget": "scroll-1", "scrollEventsSent": 600,
                "scrollMotion": {"target": "scroll-1", "before": 200, "after": 140,
                                 "contentHeight": 1010, "viewportHeight": 610},
                "maximumPulseGap": 0.3,
            },
        }
        errors = verification_errors(result, "candidate")
        self.assertIn("candidate replay timed out", errors)
        self.assertIn("candidate did not finish every captured state", errors)

    def comparison_result(self):
        return {
            "timedOut": False, "exitCode": 0, "geometryRequested": True,
            "recordedWindowWidth": 1463, "recordedWindowHeight": 1040,
            "transcriptGeometrySource": "comparison",
            "comparisonTranscriptWidth": 480, "comparisonTranscriptHeight": 560,
            "progress": {
                "finished": True, "sequence": None, "maximumPulseGap": 0.4,
                "windowWidth": 1463, "windowHeight": 1040,
                "transcriptGeometrySource": "comparison", "transcriptWidth": 480, "transcriptHeight": 560,
                "scrollTarget": "scroll-1", "transcriptScrollTarget": "scroll-1", "scrollEventsSent": 600,
                "scrollMotion": {"target": "scroll-1", "before": 200, "after": 140,
                                 "contentHeight": 1010, "viewportHeight": 560},
            },
        }

    def test_declared_comparison_geometry_is_valid_for_both_variants(self):
        for variant in ("baseline", "candidate"):
            self.assertEqual(verification_errors(self.comparison_result(), variant), [])

    def test_comparison_geometry_cannot_be_missing_or_mislabelled(self):
        for field in ("transcriptGeometrySource", "comparisonTranscriptWidth", "comparisonTranscriptHeight"):
            result = self.comparison_result()
            del result[field]
            with self.subTest(field=field):
                self.assertTrue(verification_errors(result, "candidate"))
        result = self.comparison_result()
        result["progress"]["transcriptGeometrySource"] = "recorded"
        self.assertIn("replay transcript geometry source does not match the declared source",
                      verification_errors(result, "candidate"))
        result = self.comparison_result()
        result["recordedTranscriptWidth"] = 328
        result["recordedTranscriptHeight"] = 610
        self.assertIn("comparison geometry must not replace recorded transcript geometry",
                      verification_errors(result, "candidate"))

    def test_comparison_geometry_keeps_independent_window_and_transcript_checks(self):
        for field in ("windowWidth", "windowHeight", "transcriptWidth", "transcriptHeight"):
            result = self.comparison_result()
            result["progress"][field] += 2
            with self.subTest(field=field):
                self.assertTrue(verification_errors(result, "candidate"))

    def test_rejects_nonfinite_boolean_and_nonpositive_dimensions(self):
        for value in (float("nan"), float("inf"), True, False, 0, -1):
            for field in ("recordedWindowWidth", "recordedWindowHeight", "comparisonTranscriptWidth", "comparisonTranscriptHeight"):
                result = self.comparison_result()
                result[field] = value
                with self.subTest(field=field, value=value):
                    self.assertTrue(verification_errors(result, "candidate"))
            for field in ("windowWidth", "windowHeight", "transcriptWidth", "transcriptHeight"):
                result = self.comparison_result()
                result["progress"][field] = value
                with self.subTest(actual=field, value=value):
                    self.assertTrue(verification_errors(result, "candidate"))

    def test_comparison_geometry_does_not_waive_scroll_or_responsiveness(self):
        for field, value in (("scrollTarget", "other"), ("scrollEventsSent", 0),
                             ("maximumPulseGap", 5.1), ("maximumPulseGap", float("nan")),
                             ("maximumPulseGap", float("inf")), ("maximumPulseGap", -0.1),
                             ("maximumPulseGap", True)):
            result = self.comparison_result()
            result["progress"][field] = value
            with self.subTest(field=field, value=value):
                self.assertTrue(verification_errors(result, "candidate"))


if __name__ == "__main__":
    unittest.main()
