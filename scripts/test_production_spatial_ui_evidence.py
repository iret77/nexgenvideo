import copy
import json
from pathlib import Path
import tempfile
import unittest

from production_spatial_ui_evidence import CASES, validate


class SpatialUIEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def fixture(self):
        result = {}
        for case, (label, controls, flags) in CASES.items():
            rows = []
            for scale in [1, 1.25, 1.5]:
                name = case + str(scale)
                evidence = {key: True for key in flags}
                evidence.update({"frameCount": 60, "authoringFrames": [0, 30, 59], "durationSeconds": 2})
                interactions = [{"kind": "pointer", "id": control} for control in sorted(controls)]
                interactions += [{"kind": "verified-state", "label": label, "evidence": evidence},
                    {"kind": "visible-group", "frames": [[0, 0, 100, 50]]}]
                if case == "nativeClayUI":
                    interactions.append({"kind": "verified-state", "label": "complete native Clay playback",
                        "evidence": {"input": "nativePointer", "observedSeconds": 2}})
                row = {"scale": scale, "effectiveScale": scale, "backingScale": 2, "viewport": [960, 640], "interactions": interactions,
                    "screenshots": [name + ".png"], "progress": name + ".json"}
                (self.directory / row["screenshots"][0]).write_bytes(b"\x89PNG\r\n\x1a\n" + b"unit" * 300)
                (self.directory / row["progress"]).write_text(json.dumps(row))
                rows.append(row)
            result[case] = rows
        return result

    def test_all_scales_inputs_and_progress_are_required(self):
        report = self.fixture()
        self.assertTrue(validate(report, self.directory))
        for case in CASES:
            for scale_index in range(3):
                changed = copy.deepcopy(report)
                changed[case].pop(scale_index)
                self.assertFalse(validate(changed, self.directory), (case, scale_index))
                for index in range(len(report[case][scale_index]["interactions"])):
                    changed = copy.deepcopy(report)
                    changed[case][scale_index]["interactions"].pop(index)
                    row = changed[case][scale_index]
                    (self.directory / row["progress"]).write_text(json.dumps(row))
                    self.assertFalse(validate(changed, self.directory), (case, scale_index, index))
                    original = report[case][scale_index]
                    (self.directory / original["progress"]).write_text(json.dumps(original))

    def test_progress_replacement_and_incomplete_pose_are_rejected(self):
        for mutation in ("failure", "pose", "screenshot"):
            report = self.fixture()
            row = report["nativePoseUI"][0]
            if mutation == "failure":
                (self.directory / row["progress"]).write_text(json.dumps({**row, "failure": "native input failed"}))
            elif mutation == "pose":
                state = next(item["evidence"] for item in row["interactions"] if item.get("label") == "native complete shot poses")
                state["authoringFrames"] = [0, 59]
                (self.directory / row["progress"]).write_text(json.dumps(row))
            else:
                row["screenshots"] = ["../outside.png"]
            self.assertFalse(validate(report, self.directory), mutation)

    def test_measured_clay_and_storyboard_presentation_is_required(self):
        for case in ("nativeClayUI", "nativeSpatialStoryboardUI"):
            for field, value in (("viewport", [1440, 960]), ("effectiveScale", 1.5),
                                 ("effectiveScale", None), ("backingScale", None),
                                 ("backingScale", 0), ("backingScale", float("nan")),
                                 ("backingScale", float("inf")), ("backingScale", True)):
                report = self.fixture()
                row = report[case][0]
                row[field] = value
                (self.directory / row["progress"]).write_text(json.dumps(row))
                self.assertFalse(validate(report, self.directory), (case, field, value))
