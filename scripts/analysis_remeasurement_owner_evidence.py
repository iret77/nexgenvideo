"""Native remeasurement/failure/retry against actual canonical bytes and runner stages."""
import hashlib
import json
from pathlib import Path

from production_frames_owner_evidence import read, states, visible_group


def require(value, message):
    if not value: raise ValueError(message)


def validate(directory, expected_scale=None):
    directory = Path(directory)
    load = lambda name: json.loads(read(directory, name))
    digest = lambda name: hashlib.sha256(read(directory, name)).hexdigest()
    result = load("analysis-owner-result.json")
    scale = result.get("scale")
    require(scale in (1.0, 1.25, 1.5) and (expected_scale is None or scale == expected_scale)
            and result.get("viewport") == [960, 640] and result.get("liveAgent") is False
            and result.get("liveAnalyzer") is False, "actual analysis presentation/fixture limits differ")
    source = result["songName"]
    require(source == "Analysis owner song.wav" and digest(source) == result["songSHA256"], "actual assigned song bytes changed")
    before, after = load("initial-analysis.json"), load("retried-analysis.json")
    require(read(directory, "initial-analysis.json") == read(directory, "failed-analysis.json") == read(directory, "during-analysis.json")
            and digest("retried-analysis.json") != digest("initial-analysis.json"), "failed/running remeasurement replaced its last-known artifact or Retry did not publish")
    require(before["song_sha256"] == after["song_sha256"] == result["songSHA256"] and before["song_path"] == after["song_path"]
            and before["duration_s"] == after["duration_s"] == 8, "retry changed actual source/duration")
    for name in ("initial-analysis", "failed-analysis", "during-analysis", "retried-analysis"):
        proof = load(name + "-proof.json")
        require(proof["schema"] == "analysis_measurement_proof/v1" and proof["song_sha256"] == result["songSHA256"]
                and proof["project"] == before["project"] and not proof.get("lyrics_alignment"), "actual measurement source proof differs")
    require(before["structure_resolution"]["status"] == "needs_review" and before["structure_resolution"]["method"] == "unresolved"
            and before["downbeats"] == [0], "the actual Consolidator did not publish unresolved structure")
    require(any(row["stage"] == "music_understanding" and row["status"] == "unavailable" for row in before["stage_diagnostics"]), "actual absent-adapter uncertainty missing")
    require(after["downbeat_source"] == "music-understanding" and after["structure_resolution"]["method"] == "music_understanding_hierarchy"
            and after["structure_resolution"]["status"] == "resolved" and len(after["sections"]) == 2,
            "retried canonical hierarchy differs from explicit deterministic adapter")
    require(read(directory, "gates-before-refusal.yaml") == read(directory, "gates-after-refusal.yaml") and "unresolved" in result.get("gateRefusal", ""),
            "uninterpreted analysis changed approval")
    jobs = [result[name] for name in ("initialJob", "failedJob", "duringJob", "retriedJob")]
    initial, failed, during, complete = jobs
    require(len({initial["runID"], failed["runID"], complete["runID"]}) == 3 and during["runID"] == complete["runID"]
            and [job["status"] for job in jobs] == ["completed", "failed", "running", "completed"]
            and len({job["root"] for job in jobs}) == 1 and all(job["phase"] == "analysis" and job["sourceFilename"] == source for job in jobs),
            "actual host jobs did not fail/retry one current phase independently")
    stages = ["decode_audio", "measure_structure", "separate_stems", "resolve_beat_grid", "detect_harmony", "align_lyrics", "write_analysis"]
    require(initial["stages"] == complete["stages"] == stages and complete["completed"] == complete["total"] == len(stages)
            and failed["stages"] == during["stages"] == ["decode_audio"] and during["completed"] == 0,
            "progress is not actual runner-emitted stage boundaries")
    tools = load("actual-tools.json")
    require(len(tools["requests"]) == 2 and all(any("analysis" in text.lower() for text in request) for request in tools["requests"])
            and [row["isError"] for row in tools["results"]] == [True, False]
            and "isolated analysis decoder is temporarily unavailable" in tools["results"][0]["result"],
            "actual native Continue/Retry tool path is incomplete")
    require(tools["decoder"] == [{"attempt": attempt, "sha256": result["songSHA256"], "filename": source} for attempt in (1, 2)],
            "real decoder did not receive the exact current source for both attempts")
    actions = result["interactions"]
    progress = load(result["progress"])
    require(progress.get("failure") is None and progress["interactions"] == actions and progress["screenshots"] == result["screenshots"], "native analysis driver log differs")
    clicks = [row.get("id") for row in actions if row.get("kind") == "pointer"]
    require(clicks.count("dock.continue") == 2 and clicks.count("production.ai") == clicks.count("production.activity.close") == 1,
            "actual native remeasurement/Retry/failure reading inputs missing")
    reduced = states(actions, "actual reduced measurement evidence")
    require(len(reduced) == 1 and "No system music-structure analyzer is registered." in reduced[0]["visible"]
            and reduced[0]["analysisSHA256"] == digest("initial-analysis.json") and reduced[0]["songSHA256"] == result["songSHA256"]
            and reduced[0].get("unresolvedWarning") and reduced[0].get("approveEnabled") is False, "actual uncertainty was not visibly exposed")
    observed_failure = states(actions, "actual analysis failure")
    require(len(observed_failure) == 1 and observed_failure[0]["job"] == failed
            and observed_failure[0]["visibleError"] == result["visibleFailure"]
            and "isolated analysis decoder is temporarily unavailable" in result["visibleFailure"]
            and observed_failure[0]["analysisSHA256"] == digest("failed-analysis.json"), "actual visible retryable failure missing")
    retained = states(actions, "actual remeasurement retains last grid")
    require(retained == [{"job": during, "trackName": source, "grid": f"beats={len(before['beats'])};downbeats={len(before['downbeats'])};sections={len(before['sections'])}", "analysisSHA256": digest("during-analysis.json")}], "remeasurement overlay used a different source/grid")
    require(any({"analysis.remeasure", "analysis.grid"}.issubset(row.get("ids", [])) and visible_group(row)
                for row in actions if row.get("kind") == "visible-group"), "remeasurement grid/progress was clipped or overlapped")
    finished = states(actions, "actual retry completed")
    require(finished == [{"job": complete, "analysisSHA256": digest("retried-analysis.json"),
                         "grid": f"beats={len(after['beats'])};downbeats={len(after['downbeats'])};sections=2", "nextPhase": "analysis"}],
            "new actual grid or interpretation/approval boundary differs")
    for identifier in ("analysis.structure.unresolved", "analysis.diagnostics", "analysis.remeasure", "pipeline.overview.approve.analysis"):
        require(any(identifier in row.get("ids", []) and visible_group(row) for row in actions if row.get("kind") == "visible-group"), "actual uncertainty/progress was clipped")
    require(len(result["screenshots"]) >= 4 and all(len(read(directory, name)) > 1000
            and read(directory, name).startswith(b"\x89PNG\r\n\x1a\n") for name in result["screenshots"]), "actual analysis owner screenshots missing")
    return result
