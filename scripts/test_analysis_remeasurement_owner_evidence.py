import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from analysis_remeasurement_owner_evidence import validate


def put(path, value):
    path.write_text(json.dumps(value, sort_keys=True))


def analysis_fixture(directory, scale=1.0):
    """Synthetic validator fixture; not actual native/measurement evidence."""
    directory.mkdir(parents=True, exist_ok=True)
    source = "Analysis owner song.wav"; (directory / source).write_bytes(b"isolated parser song bytes")
    sha = hashlib.sha256((directory / source).read_bytes()).hexdigest()
    before = {"project": "Fixture", "song_path": "audio/" + source, "song_sha256": sha, "duration_s": 8,
              "beats": [0, 0.5], "downbeats": [0], "sections": [{"start": 0, "end": 8}],
              "stage_diagnostics": [{"stage": "music_understanding", "status": "unavailable"}],
              "structure_resolution": {"status": "needs_review", "method": "unresolved"}}
    for name in ("initial-analysis", "failed-analysis", "during-analysis"): put(directory / (name + ".json"), before)
    after = copy.deepcopy(before); after.update(downbeat_source="music-understanding", beats=[0, 0.5, 1], downbeats=[0, 2, 4, 6, 8],
        sections=[{"start": 0, "end": 4}, {"start": 4, "end": 8}], structure_resolution={"method": "music_understanding_hierarchy", "status": "resolved"})
    put(directory / "retried-analysis.json", after)
    for name in ("initial-analysis", "failed-analysis", "during-analysis", "retried-analysis"):
        put(directory / (name + "-proof.json"), {"schema": "analysis_measurement_proof/v1", "project": "Fixture", "song_sha256": sha})
    for name in ("gates-before-refusal.yaml", "gates-after-refusal.yaml"): (directory / name).write_bytes(b"isolated unchanged gate fixture")
    stages = ["decode_audio", "measure_structure", "separate_stems", "resolve_beat_grid", "detect_harmony", "align_lyrics", "write_analysis"]
    def job(run, status, completed):
        return {"runID": run, "status": status, "phase": "analysis", "root": "/isolated/parser/project/pipeline", "sourceFilename": source,
                "stages": stages if status == "completed" else ["decode_audio"], "completed": completed, "total": 7}
    initial, failed, during, complete = job("initial", "completed", 7), job("failed", "failed", 0), job("retry", "running", 0), job("retry", "completed", 7)
    tools = {"requests": [["Continue Analysis"], ["Retry Analysis"]], "results": [
        {"isError": True, "result": "The isolated analysis decoder is temporarily unavailable. Retry the current track."}, {"isError": False}],
        "decoder": [{"attempt": attempt, "sha256": sha, "filename": source} for attempt in (1, 2)]}
    put(directory / "actual-tools.json", tools)
    digest = lambda name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
    error = tools["results"][0]["result"]
    observations = [
        ("actual reduced measurement evidence", {"visible": "No system music-structure analyzer is registered.", "analysisSHA256": digest("initial-analysis.json"), "songSHA256": sha,
                    "unresolvedWarning": "The measured bar grid cannot establish a bar duration.", "approveEnabled": False}),
        ("actual analysis failure", {"job": failed, "visibleError": error, "analysisSHA256": digest("failed-analysis.json")}),
        ("actual remeasurement retains last grid", {"job": during, "trackName": source, "grid": "beats=2;downbeats=1;sections=1", "analysisSHA256": digest("during-analysis.json")}),
        ("actual retry completed", {"job": complete, "analysisSHA256": digest("retried-analysis.json"), "grid": "beats=3;downbeats=5;sections=2", "nextPhase": "analysis"})]
    actions = [{"kind": "pointer", "id": identifier} for identifier in ("dock.continue", "production.ai", "production.activity.close", "dock.continue")]
    actions += [{"kind": "verified-state", "label": label, "evidence": evidence} for label, evidence in observations]
    actions += [{"kind": "visible-group", "ids": [identifier], "frames": [[10, 10, 100, 30]], "viewport": [0, 0, 960, 640]}
                for identifier in ("analysis.structure.unresolved", "analysis.diagnostics", "analysis.remeasure", "pipeline.overview.approve.analysis")]
    actions.append({"kind": "visible-group", "ids": ["analysis.remeasure", "analysis.grid"],
                    "frames": [[10, 10, 100, 30], [10, 100, 800, 80]], "viewport": [0, 0, 960, 640]})
    images = [f"actual-{index}.png" for index in range(4)]
    for name in images: (directory / name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"isolated parser image fixture" * 50)
    result = {"scale": scale, "viewport": [960, 640], "liveAnalyzer": False, "liveAgent": False, "songName": source, "songSHA256": sha,
              "gateRefusal": "Native structure remains unresolved", "visibleFailure": error, "initialJob": initial, "failedJob": failed,
              "duringJob": during, "retriedJob": complete, "interactions": actions, "screenshots": images, "progress": "analysis-owner.json"}
    put(directory / result["progress"], {**result, "failure": None}); put(directory / "analysis-owner-result.json", result)
    return result


class AnalysisRemeasurementEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory(); self.root = Path(self.temp.name); analysis_fixture(self.root)

    def tearDown(self): self.temp.cleanup()

    def test_complete_synthetic_validator_fixture(self):
        self.assertEqual(validate(self.root, 1.0)["retriedJob"]["status"], "completed")

    def test_last_known_grid_not_replaced_during_failure(self):
        (self.root / "failed-analysis.json").write_bytes(b"new incomplete output")
        with self.assertRaises(ValueError): validate(self.root)

    def test_actual_source_bytes_required(self):
        (self.root / "Analysis owner song.wav").write_bytes(b"other track")
        with self.assertRaises(ValueError): validate(self.root)

    def test_actual_measurement_proof_required(self):
        path = self.root / "retried-analysis-proof.json"; value = json.loads(path.read_text()); value["song_sha256"] = "foreign"
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_refusal_must_not_approve(self):
        (self.root / "gates-after-refusal.yaml").write_bytes(b"approved")
        with self.assertRaises(ValueError): validate(self.root)

    def test_real_decoder_attempts_not_bypassed(self):
        path = self.root / "actual-tools.json"; value = json.loads(path.read_text()); value["decoder"].pop()
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_real_stage_order_required(self):
        path = self.root / "analysis-owner-result.json"; value = json.loads(path.read_text()); value["retriedJob"]["stages"].reverse()
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_retry_must_have_new_job_identity(self):
        path = self.root / "analysis-owner-result.json"; value = json.loads(path.read_text()); value["retriedJob"]["runID"] = value["failedJob"]["runID"]
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_wrong_outer_scale_rejected(self):
        with self.assertRaises(ValueError): validate(self.root, 1.5)


    def test_missing_actual_approval_control_or_changed_running_grid_rejected(self):
        original = json.loads((self.root / "analysis-owner-result.json").read_text())
        for fault in ("approval-control", "running-grid", "grid-hidden", "grid-overlapped"):
            result = copy.deepcopy(original)
            if fault == "approval-control":
                result["interactions"] = [event for event in result["interactions"]
                    if not (event.get("kind") == "visible-group" and "pipeline.overview.approve.analysis" in event.get("ids", []))]
            elif fault == "grid-hidden":
                result["interactions"] = [event for event in result["interactions"]
                    if not (event.get("kind") == "visible-group" and "analysis.grid" in event.get("ids", []))]
            elif fault == "grid-overlapped":
                group = next(event for event in result["interactions"]
                    if event.get("kind") == "visible-group" and "analysis.grid" in event.get("ids", []))
                group["frames"][1] = group["frames"][0]
            else:
                row = next(event["evidence"] for event in result["interactions"]
                    if event.get("label") == "actual remeasurement retains last grid")
                row["grid"] = "beats=0;downbeats=0;sections=0"
            put(self.root / "analysis-owner-result.json", result)
            put(self.root / result["progress"], {**result, "failure": None})
            message = {"approval-control": "actual uncertainty/progress was clipped",
                       "running-grid": "remeasurement overlay used a different source/grid",
                       "grid-hidden": "remeasurement grid/progress was clipped or overlapped",
                       "grid-overlapped": "remeasurement grid/progress was clipped or overlapped"}[fault]
            with self.subTest(fault=fault), self.assertRaisesRegex(ValueError, message):
                validate(self.root, 1.0)


if __name__ == "__main__": unittest.main()
