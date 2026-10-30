import copy
import json
from pathlib import Path
import tempfile
import unittest
from uuid import uuid4

from production_spatial_ui_evidence import CASES, CANCELLATIONS, require_cancellations, validate


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
                for cancellation in CANCELLATIONS.get(case, ()):
                    state = next((item for item in interactions if item.get("label") == cancellation), None)
                    if state is None:
                        state = {"kind": "verified-state", "label": cancellation, "evidence": {}}
                        interactions.append(state)
                    state["evidence"].update({"operation": str(uuid4()), "bytes": 131_072,
                        "hashedBytes": 65_536, "callerCancelled": True})
                if case == "nativeClayUI":
                    cancelled = next(item["evidence"] for item in interactions if item.get("label") == "Clay cancel during actual caller hash")
                    cancelled.update(reloadClose="done", renderingDuringReload=False,
                        reloadOperation=str(uuid4()), notice="Render cancelled. Clay video unchanged.")
                    interactions.append({"kind": "verified-state", "label": "Clay reload after render", "evidence": {
                        "renderOperation": str(uuid4()), "reloadOperation": str(uuid4()), "reloadClose": "done", "renderingDuringReload": False}})
                row = {"scale": scale, "effectiveScale": scale, "backingScale": 2, "viewport": [960, 640], "interactions": interactions,
                    "screenshots": [name + ".png"], "progress": name + ".json"}
                if case in CANCELLATIONS:
                    prefix = "spatial-clay-" if case == "nativeClayUI" else "visual-bible-"
                    row.update(cancelDuringHash=True, closeDuringLoading=True)
                    row["screenshots"] = [prefix + str(int(scale * 100)) + "-0-cancelled-during-hash.png"]
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

    def test_actual_partial_hash_and_distinct_cancelled_callers_are_required(self):
        mutations = [("operation", "invalid"), ("operation", "00000000-0000-0000-0000-000000000000"),
            ("bytes", True), ("bytes", 65_536), ("hashedBytes", True), ("hashedBytes", 0),
            ("hashedBytes", 131_072), ("callerCancelled", False), ("callerCancelled", 1)]
        for case, labels in CANCELLATIONS.items():
            for label in labels:
                for field, value in mutations:
                    with self.subTest(case=case, label=label, field=field, value=value):
                        report = self.fixture()
                        self.assertTrue(validate(report, self.directory))
                        row = report[case][0]
                        state = next(item["evidence"] for item in row["interactions"] if item.get("label") == label)
                        state[field] = value
                        (self.directory / row["progress"]).write_text(json.dumps(row))
                        with self.assertRaisesRegex(ValueError, "native spatial cancellation caller hash"):
                            require_cancellations(case, row)
                        self.assertFalse(validate(report, self.directory))
            report = self.fixture()
            row = report[case][0]
            states = {item.get("label"): item.get("evidence") for item in row["interactions"]}
            states[labels[1]]["operation"] = states[labels[0]]["operation"]
            (self.directory / row["progress"]).write_text(json.dumps(row))
            with self.assertRaisesRegex(ValueError, "native spatial cancellation distinct callers"):
                require_cancellations(case, row)
            self.assertFalse(validate(report, self.directory), case)

    def test_cancellation_record_count_screenshot_and_case_completion_are_required(self):
        for case, labels in CANCELLATIONS.items():
            for scale_index in range(3):
                for mutation in ("missing", "duplicate", "screenshot", "render-flag", "loading-flag"):
                    with self.subTest(case=case, scale=scale_index, mutation=mutation):
                        report = self.fixture()
                        self.assertTrue(validate(report, self.directory))
                        row = report[case][scale_index]
                        event = next(item for item in row["interactions"] if item.get("label") == labels[1])
                        if mutation == "missing": row["interactions"].remove(event)
                        elif mutation == "duplicate": row["interactions"].append(copy.deepcopy(event))
                        elif mutation == "screenshot": row["screenshots"] = ["unrelated.png"]
                        elif mutation == "render-flag": row["cancelDuringHash"] = False
                        else: row["closeDuringLoading"] = False
                        message = ("native spatial cancellation record coverage" if mutation in {"missing", "duplicate"}
                            else "native spatial cancellation screenshot" if mutation == "screenshot"
                            else "native spatial cancellation completed cases")
                        with self.assertRaisesRegex(ValueError, message): require_cancellations(case, row)
                        (self.directory / row["progress"]).write_text(json.dumps(row))
                        self.assertFalse(validate(report, self.directory))

    def test_clay_reload_never_claims_to_be_a_cancellable_render(self):
        for label in ("Clay cancel during actual caller hash", "Clay reload after render"):
            for changed in ({"reloadClose": "cancel"}, {"renderingDuringReload": True}, {"reloadOperation": "invalid"}):
                with self.subTest(label=label, change=changed):
                    report = self.fixture(); self.assertTrue(validate(report, self.directory))
                    row = report["nativeClayUI"][0]
                    state = next(item["evidence"] for item in row["interactions"] if item.get("label") == label)
                    state.update(changed)
                    with self.assertRaisesRegex(ValueError, "native Clay reload state"):
                        require_cancellations("nativeClayUI", row)
        for mutation in ("missing", "duplicate", "notice", "same-operation"):
            report = self.fixture(); self.assertTrue(validate(report, self.directory))
            row = report["nativeClayUI"][0]
            success = next(item for item in row["interactions"] if item.get("label") == "Clay reload after render")
            cancelled = next(item["evidence"] for item in row["interactions"] if item.get("label") == "Clay cancel during actual caller hash")
            if mutation == "missing": row["interactions"].remove(success)
            elif mutation == "duplicate": row["interactions"].append(copy.deepcopy(success))
            elif mutation == "notice": cancelled["notice"] = ""
            else: cancelled["reloadOperation"] = cancelled["operation"]
            message = "native Clay reload after render coverage" if mutation in {"missing", "duplicate"} else "native Clay reload state"
            with self.assertRaisesRegex(ValueError, message): require_cancellations("nativeClayUI", row)
