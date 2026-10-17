import argparse
import unittest

from recorded_hang_replay import parse_comparison_viewport, recorded_editor_window, transcript_geometry


class RecordedHangGeometryTests(unittest.TestCase):
    def test_missing_or_legacy_viewport_requires_explicit_comparison(self):
        for records in ([], [{"operation": "scroll", "values": [1500, 900, 600, 0]}]):
            with self.assertRaisesRegex(ValueError, "declare --comparison-viewport explicitly"):
                transcript_geometry(records)
            self.assertEqual(transcript_geometry(records, parse_comparison_viewport("480x560")), {
                "transcriptGeometrySource": "comparison",
                "comparisonTranscriptWidth": 480, "comparisonTranscriptHeight": 560,
            })

    def test_recorded_viewport_wins_over_explicit_comparison(self):
        records = [
            {"sequence": 2, "operation": "scroll", "values": [1800, 1190, 610, 0, 328]},
            {"sequence": 1, "operation": "scroll", "values": [1500, 900, 600, 0, 320]},
        ]
        self.assertEqual(transcript_geometry(records, (480, 560)), {
            "transcriptGeometrySource": "recorded",
            "recordedTranscriptWidth": 328, "recordedTranscriptHeight": 610,
        })

    def test_invalid_recorded_viewport_cannot_be_hidden_by_comparison(self):
        for invalid in (float("nan"), float("inf"), True, False, 0, -1):
            for index in (2, 4):
                values = [1500, 900, 600, 0, 320]
                values[index] = invalid
                with self.subTest(invalid=invalid, index=index), self.assertRaisesRegex(ValueError, "recorded.*invalid"):
                    transcript_geometry([{"operation": "scroll", "values": values}], (480, 560))
        with self.assertRaisesRegex(ValueError, "recorded.*invalid"):
            transcript_geometry([{"operation": "scroll", "hadNonFiniteValues": True,
                                  "values": [1500, 900, 600, 0, 320]}], (480, 560))

    def test_comparison_argument_rejects_invalid_dimensions(self):
        for invalid in ("", "480", "480x", "x560", "480x560x640", "truex560", "nanx560", "480xinf", "0x560", "480x-1"):
            with self.subTest(invalid=invalid), self.assertRaises(argparse.ArgumentTypeError):
                parse_comparison_viewport(invalid)
        for invalid in (float("nan"), float("inf"), True, False, 0, -1):
            for dimensions in ((invalid, 560), (480, invalid)):
                with self.subTest(dimensions=dimensions), self.assertRaisesRegex(ValueError, "comparison.*invalid"):
                    transcript_geometry([], dimensions)

    def test_recorded_editor_window_is_required_and_not_inferred_from_comparison(self):
        self.assertIsNone(recorded_editor_window([]))
        for invalid in (float("nan"), float("inf"), True, False, 0, -1):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "window.*invalid"):
                recorded_editor_window([{"operation": "window", "values": [1, invalid, 1040]}])
        records = [
            {"sequence": 1, "operation": "window", "values": [1, 1463, 1040]},
            {"sequence": 2, "operation": "window", "values": [2, 881, 448]},
        ]
        self.assertEqual(recorded_editor_window(records), records[0])


if __name__ == "__main__":
    unittest.main()
