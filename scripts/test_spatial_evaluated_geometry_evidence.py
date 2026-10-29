"""Synthetic validator negatives, never evidence of a native Blender run."""
import json
import unittest
from spatial_evaluated_geometry_evidence import command, fingerprint, integer, matrix


class GeometryEvidenceValidationTests(unittest.TestCase):
    def test_fingerprint_binds_actual_program_revision_and_timeout(self):
        source = "print('bounds')\n"
        expected = fingerprint(source, "12345678-1234-1234-1234-123456789abc", 240)
        self.assertEqual(expected, fingerprint(source, "12345678-1234-1234-1234-123456789ABC", 240))
        self.assertNotEqual(expected, fingerprint(source + "\n", "12345678-1234-1234-1234-123456789abc", 240))
        self.assertNotEqual(expected, fingerprint(source, None, 240))
        self.assertNotEqual(expected, fingerprint(source, "12345678-1234-1234-1234-123456789abc", 241))
        with self.assertRaises(ValueError):
            fingerprint(source, None, True)

    def test_command_requires_exact_retained_helper_and_real_settings(self):
        script = b"apply_command(ngv_command)\n"
        settings = json.dumps({"kind": "evaluate_bounds", "state": {"frames": [{"frame": 0}]}})
        source = "import json\nngv_command = json.loads(" + json.dumps(settings) + ")\n" + script.decode()
        self.assertEqual(command(source, script)[0]["state"]["frames"][0]["frame"], 0)
        with self.assertRaises(ValueError):
            command(source, script + b"# another helper\n")
        with self.assertRaises(ValueError):
            command(source.replace("ngv_command =", "foreign_command ="), script)

    def test_native_pose_comparison_rejects_partial_nan_and_shifted_matrix(self):
        expected = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        matrix(expected, expected)
        for value in [expected[:-1], [float("nan")] + expected[1:], expected[:3] + [2] + expected[4:]]:
            with self.assertRaises(ValueError):
                matrix(value, expected)
        for value in [True, 1.0, -1]:
            with self.assertRaises(ValueError):
                integer(value, "frame")


if __name__ == "__main__":
    unittest.main()
