"""Verify the real negative audit, refused approval and scoped native correction."""
from collections import Counter
import hashlib
import json
from pathlib import Path

from production_chronology_owner_evidence import gate
from production_frames_owner_evidence import read, visible_group


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(directory):
    directory = Path(directory)
    result = json.loads(read(directory, "sanity-result.json"))
    progress = json.loads(read(directory, "sanity-owner.json"))
    require(result["schema"] == "sanity-owner-acceptance/v1" and progress.get("failure") is None,
            "The native Sanity case failed")
    shot = result["shotID"]
    before = read(directory, "blocked-gates.yaml")
    require(before == read(directory, "refused-gates.yaml") and gate(before, "shotlist") and not gate(before, "sanity"),
            "The actual error was approved or its refusal changed approval bytes")
    after = read(directory, "repaired-gates.yaml")
    require(gate(after, "sanity") and not gate(after, "frames") and result["nextPhase"] == "frames",
            "The correction approved a future phase or failed to approve Sanity")
    blocked = json.loads(read(directory, "blocked-sanity.json"))
    repaired = json.loads(read(directory, "repaired-sanity.json"))
    errors = [value for value in blocked["findings"] if value["level"] == "error"]
    require(len(errors) == 1 and errors[0]["code"] == "BLOCKING_ANCHOR_MISSING" and errors[0]["shot_id"] == shot,
            "The persisted deterministic audit lacks its deliberate actual missing anchor")
    require(not any(value["level"] == "error" for value in repaired["findings"])
            and blocked["input_fingerprint"] != repaired["input_fingerprint"], "Sanity reused a stale successful audit")
    plans = []
    for stage in ("blocked", "repaired"):
        representation = json.loads(read(directory, stage + "-projection.json"))
        actual = read(directory, stage + ".v5.yaml")
        require(hashlib.sha256(actual).hexdigest() == representation["sourceSHA256"], "Plan representation differs from actual canonical YAML bytes")
        plans.append(representation["projection"])
    old, new = plans
    require(old["schema"] == new["schema"] == "shotlist/v5" and new["header"]["revision"] > old["header"]["revision"],
            "Repair bypassed normalized revision history")
    old_shots, new_shots = old["executionPlan"]["shots"], new["executionPlan"]["shots"]
    require([value["id"] for value in old_shots] == [value["id"] for value in new_shots]
            and old["timings"] == new["timings"] and old_shots[0]["id"] == shot,
            "Repair replaced actual Shot identity or editorial timing")
    require(len(old_shots[0]["blocking"]) == 1 and old_shots[0]["blocking"][0].get("anchor_asset_id") is None
            and all(not value["blocking"] for value in new_shots), "The alleged missing-anchor correction never changed that real requirement")
    for original, corrected in zip(old_shots, new_shots):
        require({key: value for key, value in original.items() if key != "blocking"}
                == {key: value for key, value in corrected.items() if key != "blocking"}, "Scoped repair changed unrelated execution intent")
    require(result["runtimeToolCalls"] == 1 and result["providerGenerations"] == 0
            and result["wrongPhaseTool"] == "write_script" and result["canonicalScriptUnchanged"]
            and '"script"' in result["wrongPhaseRefusal"] and '"sanity"' in result["wrongPhaseRefusal"]
            and "current phase" in result["wrongPhaseRefusal"],
            "Repair bypassed the real tool contract or unrelated phase mutation was accepted")
    interactions = progress["interactions"]
    clicks = Counter(row.get("id") for row in interactions if row.get("kind") == "pointer")
    required = ["sanity.finding.BLOCKING_ANCHOR_MISSING." + shot, "agent.task.run",
                "pipeline.overview.approve.shotlist", "pipeline.overview.approve.sanity"]
    require(all(clicks[value] >= 1 for value in required), "A required actual native decision was bypassed")
    require(clicks["pipeline.overview.approve.shotlist"] == 2, "Initial and corrected plans were not both natively approved")
    require(any(row.get("kind") == "text" and row.get("field", {}).get("id") == "agent.composer.input" for row in interactions),
            "No actual scoped correction was typed")
    require(any(row.get("kind") == "menu" and row.get("id") == "agent.task.choose"
                and row.get("item") == "Revise Selected Object" and row.get("closed") for row in interactions),
            "The actual selected-object task was not chosen")
    require(any(row.get("kind") == "menu" and row.get("id") == "pipeline.overview.actions.shotlist"
                and row.get("item") == "Rewind to here…" and row.get("closed") for row in interactions),
            "Native Shot List rewind was bypassed")
    require(any(row.get("kind") == "visible-group" and visible_group(row) for row in interactions), "No actual bounded controls were observed")
    require(len(progress["screenshots"]) >= 2 and all(read(directory, name).startswith(b"\x89PNG\r\n\x1a\n")
            for name in progress["screenshots"]), "Actual native refusal/correction screenshots are missing")
    return {"schema": "independent-sanity-owner-verification/v1", "actualFinding": errors[0]["code"],
            "nativeCorrectionAndApproval": True, "wrongPhaseWriterRefused": True, "providerGenerations": 0}
