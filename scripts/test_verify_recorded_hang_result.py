import unittest

from verify_recorded_hang_result import verification_errors


class RecordedHangResultTests(unittest.TestCase):
    def test_stalled_released_control_must_stop_inside_captured_failure_window(self):
        result = {
            "timedOut": True,
            "geometryRequested": True,
            "constraintOverflowWarning": True,
            "lastSequence": 247,
            "progress": {"finished": False, "sequence": 245},
        }
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
            "lastSequence": 247,
            "progress": {"finished": True, "sequence": None},
        }
        self.assertEqual(verification_errors(result, "baseline"), [])

    def test_candidate_must_finish_with_a_responsive_main_thread(self):
        result = {
            "timedOut": False,
            "exitCode": 0,
            "geometryRequested": True,
            "constraintOverflowWarning": True,
            "progress": {
                "finished": True,
                "sequence": None,
                "maximumPulseGap": 0.4,
            },
        }
        self.assertEqual(verification_errors(result, "candidate"), [])

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
            "constraintOverflowWarning": False,
            "progress": {
                "finished": False,
                "sequence": 245,
                "maximumPulseGap": 0.3,
            },
        }
        errors = verification_errors(result, "candidate")
        self.assertIn("candidate replay timed out", errors)
        self.assertIn("candidate did not finish every captured state", errors)


if __name__ == "__main__":
    unittest.main()
