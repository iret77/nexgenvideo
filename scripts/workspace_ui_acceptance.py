"""Exercise and verify the native five-workspace editor on a macOS 26 runner."""
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid


EXPECTED_WORKSPACES = {"media", "production", "edit", "postproduction", "export"}
EXPECTED_INSPECTOR_CASES = {
    ("text", None),
    ("video", "closed"),
    ("video", "open"),
    ("effects", None),
    ("ai", None),
    ("audio", "closed"),
    ("audio", "open"),
    ("mixed", None),
    ("asset", None),
    ("caption", None),
}
EXPECTED_KEYFRAME_LANES = {
    "audio": ["volume"],
    "video": ["position", "scale", "rotation", "opacity", "crop"],
}
SCALES = (1.0, 1.25, 1.5)
MUSICVIDEO_PHASES = ["project_init", "analysis", "brief", "production_design", "treatment",
                    "storyboard", "bible", "shotlist", "sanity", "frames", "render"]
MUSICVIDEO_ARTIFACTS = ["Project", "Analysis", "Project Brief", "Production Design", "Treatment",
                       "Storyboard", "Bible", "Shotlist", "Review", "Review", "Review"]


def sha256_string(value):
    return isinstance(value, str) and len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def valid_native_gate_evidence(rows):
    if (not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows)
        or [row.get("phase") for row in rows] != MUSICVIDEO_PHASES):
        return False
    for index, row in enumerate(rows):
        next_phase = MUSICVIDEO_PHASES[index + 1] if index + 1 < len(MUSICVIDEO_PHASES) else "complete"
        if (row.get("nextPhase") != next_phase or row.get("handoffPhase") != next_phase
            or row.get("openedFromPhase") not in MUSICVIDEO_PHASES or row.get("openedFromPhase") == row["phase"]
            or row.get("selectedPhaseAfter") != ("render" if next_phase == "complete" else next_phase)
            or row.get("controlID") != "agent.gate.approve" or row.get("openControlID") != "agent.gate.open"
            or row.get("surface") != "production"
            or row.get("artifactTitle") != MUSICVIDEO_ARTIFACTS[index]
            or not isinstance(row.get("blockedReason"), str) or not row["blockedReason"].strip()
            or row.get("packagedInstructions") is not (next_phase != "complete")
            or (row.get("handoffInstructionsSHA256") is not None if next_phase == "complete"
                else not sha256_string(row.get("handoffInstructionsSHA256")))
            or not all(row.get(key) is True for key in (
                "blockedBeforeApproval", "readyBeforeClick", "approvedPersisted", "handoffHidden"))
            or not all(sha256_string(row.get(key)) for key in ("artifactSHA256", "gatesBeforeSHA256", "gatesAfterSHA256"))
            or row["gatesBeforeSHA256"] == row["gatesAfterSHA256"]
            or not isinstance(row.get("screenshots"), list) or len(row["screenshots"]) != 3
            or not all(isinstance(name, str) and name and Path(name).name == name for name in row["screenshots"])):
            return False
        try:
            uuid.UUID(row.get("handoffTurnID", ""))
        except (ValueError, TypeError, AttributeError):
            return False
    images = [name for row in rows for name in row["screenshots"]]
    return len(images) == len(set(images)) and len({row["handoffTurnID"] for row in rows}) == len(rows)


def valid_bible_blocker(row):
    if not isinstance(row, dict):
        return False
    reason = row.get("reason")
    return (
        row.get("phase") == "bible" and row.get("status") == "Incomplete" and row.get("futureStatus") == "Upcoming"
        and isinstance(reason, str) and "Bible" in reason and "reference images" in reason
        and not any(term in reason for term in ("bible.yaml", "/", "write_bible", "schema", "Not started"))
        and row.get("diagnosticOpenedByControl") == "pipeline.overview.dock.diagnostics"
        and all(row.get(key) is True for key in ("approvalUnavailable", "diagnosticMatchesReadiness",
                                               "diagnosticHiddenByDefault", "gatesUnchanged", "invalidArtifactPresent"))
        and sha256_string(row.get("diagnosticSHA256"))
        and isinstance(row.get("screenshots"), list) and len(row["screenshots"]) == 2
    )


def valid_production_workbench(row):
    if not isinstance(row, dict) or not all(row.get(key) is True for key in (
        "threeColumns", "noTimelineOrEmptyPreview", "shotInspectorBound", "twoStoryboardSections", "statusVisible",
    )) or len(row.get("screenshots", [])) != 3:
        return False
    expected = [
        ("verse1.01", [("Section", "Verse 1"), ("Section timing", "0.0–12.0 s"), ("Camera", "Slow dolly"),
                       ("Framing", "Wide"), ("Angle", "Frontal"), ("Height", "Eye Level")]),
        ("chorus1.01", [("Section", "Chorus 1"), ("Section timing", "12.0–24.0 s"), ("Camera", "Slow push in"),
                        ("Framing", "Medium"), ("Angle", "Frontal"), ("Lens Hint", "Wide"), ("Location view", "Wide · Noon")]),
    ]
    selections = row.get("shotInspectorSelections")
    return isinstance(selections, list) and len(selections) == len(expected) and all(
        isinstance(item, dict) and item.get("shotID") == shot
        and item.get("controlID") == f"storyboard.shot.{shot}"
        and item.get("renderedFields") == [{"label": label, "value": value} for label, value in fields]
        and item.get("rawFieldsAbsent") is True and item.get("previousSelectionAbsent") is True
        for item, (shot, fields) in zip(selections, expected)
    )


def native_film_screenshots(row):
    gates = row.get("nativeGateApprovals", [])
    bible = row.get("nativeBibleBlocker", {})
    generation = row.get("generation", {})
    return ([name for gate in (gates if isinstance(gates, list) else [])
             if isinstance(gate, dict) for name in gate.get("screenshots", [])]
            + (bible.get("screenshots", []) if isinstance(bible, dict) else [])
            + (generation.get("nativeScreenshots", []) if isinstance(generation, dict) else []))


def valid_native_generation(evidence):
    approval, take = evidence.get("nativeApproval"), evidence.get("nativeTakeReview")
    interactions, screenshots = evidence.get("nativeInteractions"), evidence.get("nativeScreenshots")
    if (not isinstance(evidence.get("takeID"), str) or not evidence["takeID"].strip()
        or not isinstance(approval, dict) or not isinstance(take, dict) or not isinstance(interactions, list)
        or approval.get("authorityBefore") is not False
        or approval.get("continuationPhases") != ["render"] or approval.get("continuationHidden") is not True
        or any(type(approval.get(key)) is not int or approval[key] != 0
               for key in ("journalCountBefore", "requestCountBefore", "spendCountBefore"))
        or not isinstance(approval.get("authorityAfterID"), str) or not approval["authorityAfterID"].strip()
        or not sha256_string(approval.get("approvedPackageSHA256"))
        or approval["approvedPackageSHA256"] != evidence.get("packageID")
        or not isinstance(approval.get("pricingOverrideItemIDs"), list) or len(approval["pricingOverrideItemIDs"]) != 1
        or not all(isinstance(item, str) and item for item in approval["pricingOverrideItemIDs"])
        or take.get("takeIDBefore") != "" or take.get("takeIDAfter") != evidence.get("takeID")
        or type(take.get("findingsBefore")) is not int or take["findingsBefore"] != 0
        or take.get("selectedTakeIDBefore") is not None or take.get("selectedTakeIDAfter") != evidence.get("takeID")
        or not sha256_string(take.get("reviewSHA256"))
        or not isinstance(screenshots, list) or len(screenshots) != 3
        or not all(isinstance(name, str) and name and Path(name).name == name for name in screenshots)
        or len(set(screenshots)) != 3):
        return False
    findings = take.get("findings")
    passes = ["identity", "continuity", "timing", "camera", "audio", "style"]
    if (not isinstance(findings, list) or not all(isinstance(item, dict) for item in findings)
        or [item.get("pass") for item in findings] != passes):
        return False
    expected = [("generation-batch.approve", "unapproved", approval["authorityAfterID"]),
                ("take.open", "closed", "open"), ("take.picker", "", evidence["takeID"])]
    for index, finding in enumerate(findings):
        verdict = "conforms" if index == 0 else "acceptedDeviation"
        observation = finding.get("observation")
        if (finding.get("verdict") != verdict or finding.get("startSeconds") != 1 or finding.get("endSeconds") != 3
            or not isinstance(observation, str) or not observation.startswith(f"Supplied acceptance decision: {passes[index]} ")):
            return False
        if index == 0:
            expected += [("take.verdict", "conforms", "rejected"), ("take.verdict", "rejected", "conforms")]
        else:
            expected.append(("take.verdict", "conforms", "acceptedDeviation"))
        expected += [("take.observation", "", observation), ("take.start", "0.0", "1.0"),
                     ("take.end", "4.0", "3.0"), ("take.record-pass", str(index), str(index + 1))]
    expected += [("take.save", "0", "6"), ("take.use", "none", evidence["takeID"]), ("take.close", "open", "closed")]
    if len(interactions) != len(expected) or not all(isinstance(item, dict) for item in interactions):
        return False
    document_window = interactions[0].get("documentWindowNumber")
    sheet_window = interactions[2].get("windowNumber")
    if any(type(number) is not int or number <= 0 for number in (document_window, sheet_window)) or document_window == sheet_window:
        return False
    for index, (item, (control, before, after)) in enumerate(zip(interactions, expected)):
        before_matches = item.get("before") == before
        if control == "take.end":
            try:
                original_end = float(item.get("before"))
            except (TypeError, ValueError):
                return False
            before_matches = (isinstance(item.get("before"), str) and math.isfinite(original_end)
                              and abs(original_end - 4.0) < 1.0 / 30)
        if (item.get("index") != index or item.get("controlID") != control
            or not before_matches or item.get("after") != after
            or item.get("documentWindowNumber") != document_window
            or item.get("windowNumber") != (document_window if index < 2 else sheet_window)):
            return False
        frames = [item.get("frame"), item.get("viewport")]
        if not all(isinstance(frame, list) and len(frame) == 4
                   and all(type(value) in (int, float) and math.isfinite(value) for value in frame)
                   and frame[2] > 0 and frame[3] > 0 for frame in frames):
            return False
        frame, viewport = [dict(zip(("x", "y", "width", "height"), values)) for values in frames]
        if not contains_frame(viewport, frame):
            return False
    return True


def valid_frame(frame):
    return (
        isinstance(frame, dict)
        and set(frame) == {"height", "width", "x", "y"}
        and frame["height"] > 0
        and frame["width"] > 0
    )


def contains_frame(outer, inner, tolerance=1):
    return (
        inner["x"] >= outer["x"] - tolerance
        and inner["y"] >= outer["y"] - tolerance
        and inner["x"] + inner["width"]
        <= outer["x"] + outer["width"] + tolerance
        and inner["y"] + inner["height"]
        <= outer["y"] + outer["height"] + tolerance
    )


def matching_frame(first, second, tolerance=1):
    return all(abs(first[key] - second[key]) <= tolerance for key in first)


def valid_keyframe_layout(layout, expected_mode, expected_lanes):
    inspector = layout.get("inspectorFrame")
    panel = layout.get("panelFrame")
    ruler = layout.get("rulerFrame")
    ruler_overlay = layout.get("rulerOverlayFrame")
    lanes = layout.get("laneEvidence")
    if (
        layout.get("mode") != expected_mode
        or layout.get("reachableLaneLabels") != expected_lanes
        or not isinstance(layout.get("screenshot"), str)
        or not all(valid_frame(frame) for frame in [inspector, panel, ruler, ruler_overlay])
        or not contains_frame(inspector, ruler)
        or not matching_frame(ruler, ruler_overlay)
        or not isinstance(lanes, list)
        or any(not isinstance(item, dict) for item in lanes)
        or [item.get("property") for item in lanes] != expected_lanes
    ):
        return False
    if expected_mode == "stacked":
        target = layout.get("inspectorWidthTarget")
        if not isinstance(target, (int, float)) or abs(inspector["width"] - target) > 1:
            return False
    elif "inspectorWidthTarget" in layout:
        return False
    for lane in lanes:
        clip = lane.get("clipFrame")
        label = lane.get("labelFrame")
        track = lane.get("trackFrame")
        overlay = lane.get("overlayFrame")
        if (
            lane.get("visible") is not True
            or not all(valid_frame(frame) for frame in [clip, label, track, overlay])
            or not contains_frame(clip, label)
            or not contains_frame(clip, track)
            or not contains_frame(inspector, label)
            or not contains_frame(inspector, track)
            or not matching_frame(track, overlay)
            or abs(track["x"] - ruler["x"]) > 1
            or abs(track["width"] - ruler["width"]) > 1
        ):
            return False
        if expected_mode == "side":
            if label["x"] + label["width"] > track["x"] + 1:
                return False
        elif label["y"] + label["height"] > track["y"] + 1:
            return False
    return True


def valid_keyframe_lane_evidence(row):
    expected = EXPECTED_KEYFRAME_LANES.get(row.get("family"))
    evidence = row.get("laneLayoutEvidence")
    if (
        expected is None
        or not isinstance(evidence, list)
        or any(not isinstance(item, dict) for item in evidence)
        or [item.get("mode") for item in evidence] != ["side", "stacked"]
    ):
        return False
    return all(
        valid_keyframe_layout(layout, mode, expected)
        for layout, mode in zip(evidence, ["side", "stacked"])
    )




def valid_generation_evidence(evidence):
    if not isinstance(evidence, dict):
        return False
    if not valid_native_generation(evidence):
        return False
    if (
        evidence.get("generatedShotIDs") != ["s001"]
        or evidence.get("importedShotIDs") != ["s002"]
        or evidence.get("spendEvents") != ["reserved", "submitted", "settled"]
        or evidence.get("requestMethods") != ["POST", "PUT", "POST", "GET", "GET", "GET"]
        or evidence.get("generatedSourceStartFrame") != 30
        or evidence.get("generatedSourceEndFrame") != 90
        or evidence.get("totalFrames") != 129
        or evidence.get("unexpectedRequestCount") != 0
        or any(type(evidence.get(key)) is not int or evidence[key] != 1 for key in (
            "submitCount", "pollCount", "resultCount", "downloadCount", "uploadCount",
        ))
    ):
        return False
    description = evidence.get("providerEvidence")
    if not isinstance(description, str) or not all(term in description for term in (
        "FalClient", "simulator", "no live provider",
    )):
        return False
    for key in ("compiledPromptSHA256", "referenceSHA256", "outputSHA256", "selectedSourceSHA256"):
        value = evidence.get(key)
        if not isinstance(value, str) or len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
            return False
    return (
        evidence["selectedSourceSHA256"] == evidence["outputSHA256"]
        and all(isinstance(evidence.get(key), str) and evidence[key].strip() for key in (
            "batchID", "packageID", "takeID", "generationAssetID",
        ))
    )

def valid_musicvideo_review(row, output):
    if not isinstance(row, dict):
        return False
    viewport = row.get("viewport")
    controls = row.get("controls")
    if (
        row.get("route") != "mixed-musicvideo"
        or not valid_generation_evidence(row.get("generation"))
        or not valid_native_gate_evidence(row.get("nativeGateApprovals"))
        or not valid_bible_blocker(row.get("nativeBibleBlocker"))
        or not all(row.get(key) is True for key in (
            "nativeSequenceReview", "nativeStyleReview", "recordDisabledUntilReviewed",
            "reviewInputsPersisted", "timelineUnchangedByReview", "nativeExportSubmitted",
            "exportCompleted", "sequenceReviewBound", "styleReviewBound", "fullSongDuration", "reviewReelHasAudio",
        ))
        or not valid_frame(viewport)
        or viewport["width"] != 960 or viewport["height"] != 640
        or row.get("expectedDurationFrames") != 129
        or row.get("shotIDs") != ["s001", "s002"]
        or row.get("verifiedShotImages") != 2
        or row.get("verifiedMovingShots") != len(row["shotIDs"])
        or type(row.get("verifiedFrames")) is not int
        or row["verifiedFrames"] < 2 * len(row["shotIDs"])
        or row.get("sequenceFindingCount") != 1
        or not isinstance(row.get("styleFindingCount"), int) or row["styleFindingCount"] < 1
        or not isinstance(controls, list) or not controls
        or len(row.get("screenshots", [])) != 7
    ):
        return False
    for key, minimum in (("playbackSeconds", 4.26), ("decodedAudioSamples", 200000), ("decodedAudioRMS", 0.001),
                         ("decodedAudioCorrelation", 0.98)):
        value = row.get(key)
        if type(value) not in (int, float) or not math.isfinite(value) or value < minimum:
            return False
    if row["decodedAudioCorrelation"] > 1.000001:
        return False
    for item in controls:
        if not isinstance(item, dict):
            return False
        control, clip = item.get("control"), item.get("viewport")
        if (
            not valid_frame(control) or not valid_frame(clip)
            or not all(isinstance(value, (int, float)) and math.isfinite(value)
                       for frame in (control, clip) for value in frame.values())
            or not contains_frame(clip, control) or not contains_frame(viewport, clip)
        ):
            return False
    identifiers = {item.get("id") for item in controls}
    if not {
        "pipeline.overview.select.render", "sequence.disclosure", "sequence.build", "sequence.play",
        "sequence.shots", "sequence.start", "sequence.end", "sequence.evidence", "sequence.severity",
        "sequence.action", "sequence.add", "sequence.adjacent", "sequence.whole", "sequence.record",
        "style.disclosure", "style.begin", "style.record", "production.export",
    }.issubset(identifiers):
        return False
    if not any(isinstance(key, str) and key.startswith("style.choice.") for key in identifiers):
        return False
    if not any(isinstance(key, str) and key.startswith("style.observation.") for key in identifiers):
        return False
    transitions = row.get("pickerTransitions")
    if not isinstance(transitions, list) or not all(
        isinstance(item, dict) and all(isinstance(item.get(key), str) and item[key]
                                      for key in ("id", "before", "after"))
        and item["before"] != item["after"] for item in transitions
    ):
        return False
    expected_transitions = [
        {"id": "sequence.severity", "before": "warning", "after": "info"},
        {"id": "sequence.action", "before": "local_repair", "after": "accept"},
    ]
    style_choices = {key for key in identifiers if isinstance(key, str) and key.startswith("style.choice.")}
    if (transitions[:2] != expected_transitions or len(transitions) != 2 + len(style_choices)
        or len(style_choices) != row["styleFindingCount"]
        or {item["id"] for item in transitions[2:]} != style_choices
        or not all(item["before"] == "unreviewed" and item["after"] == "accepted_deviation"
                   for item in transitions[2:])
        or row.get("recordedSequenceSelection") != {"severity": "info", "action": "accept"}):
        return False
    try:
        names = [row[key] for key in ("movie", "deliveryReceipt")]
        if not all(isinstance(name, str) and name and Path(name).name == name for name in names):
            return False
        movie = (output / names[0]).read_bytes()
        receipt = json.loads((output / names[1]).read_text())
        return (
            len(movie) > 1000 and movie[4:8] == b"ftyp"
            and hashlib.sha256(movie).hexdigest() == row.get("outputSHA256") == receipt.get("output_sha256")
            and receipt.get("schema") == "delivery-attempt/v1"
            and receipt.get("status") == "succeeded"
            and receipt.get("output_byte_count") == len(movie)
            and receipt.get("probe_qc", {}).get("passed") is True
            and isinstance(receipt.get("sequence_review_sha256"), str)
            and len(receipt["sequence_review_sha256"]) == 64
        )
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return False

def run_scale(executable, output, scale):
    label = str(round(scale * 100))
    log_path = output / f"scale-{label}.log"
    started = time.monotonic()
    case_results = []
    output_chunks = []
    for scenario in ("workspace", "cards", "analysis", "provenance", "musicvideo", "hoststates", "storyboard", "filmreview"):
        case_started = time.monotonic()
        try:
            process = subprocess.run(
                [executable],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env={
                    **os.environ,
                    "NGV_WORKSPACE_UI_ACCEPTANCE": "1",
                    "NGV_WORKSPACE_UI_EVIDENCE": str(output.resolve()),
                    "NGV_WORKSPACE_UI_SCALE": str(scale),
                    "NGV_WORKSPACE_UI_CASE": scenario,
                    "NGV_INSPECTOR_UI_ACCEPTANCE": "1",
                },
                timeout=180 if scenario == "filmreview" else 90,
                check=False,
                text=True,
            )
            case_output = process.stdout
            code = process.returncode
        except subprocess.TimeoutExpired as error:
            case_output = error.stdout or ""
            if isinstance(case_output, bytes):
                case_output = case_output.decode(errors="replace")
            code = 124
        output_chunks.append(case_output)
        case_results.append({
            "case": scenario,
            "exitCode": code,
            "elapsedSeconds": time.monotonic() - case_started,
        })
    output_text = "\n".join(output_chunks)
    log_path.write_text(output_text)
    return_code = next((item["exitCode"] for item in case_results if item["exitCode"] != 0), 0)

    rows = []
    for line in output_text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and "event" in row:
            rows.append(row)

    workspace_rows = [row for row in rows if row.get("event") == "workspace"]
    workspaces = {row.get("workspace") for row in workspace_rows}
    completed = sum(row.get("event") == "completed" for row in rows) == 8
    hidden = [row for row in rows if row.get("event") == "panels-hidden"]
    narrow = [row for row in rows if row.get("event") == "narrow-production"]
    invariants = [row for row in rows if row.get("event") == "invariants"]
    library = [row for row in rows if row.get("event") == "media-library"]
    keyboard = [row for row in rows if row.get("event") == "text-keyboard-isolation"]
    cards = [row for row in rows if row.get("event") == "project-cards"]
    analysis = [row for row in rows if row.get("event") == "analysis-interaction"]
    provenance = [row for row in rows if row.get("event") == "asset-provenance"]
    musicvideo = [row for row in rows if row.get("event") == "musicvideo-startup"]
    host_states = [row for row in rows if row.get("event") == "host-state-history"]
    storyboard = [row for row in rows if row.get("event") == "storyboard-review"]
    production = [row for row in rows if row.get("event") == "production-workbench"]
    agent_activity = [row for row in rows if row.get("event") == "agent-activity"]
    film_review = [row for row in rows if row.get("event") == "musicvideo-film-review"]
    inspector = [row for row in rows if row.get("event") == "inspector"]
    open_keyframes = [row for row in inspector if row.get("keyframes") == "open"]
    screenshots = [
        row.get("screenshot")
        for row in workspace_rows + hidden + narrow + library + cards
    ]
    screenshots += [
        row.get("screenshot")
        for row in inspector
        if row.get("keyframes") != "open"
    ]
    screenshots += [
        layout.get("screenshot")
        for row in open_keyframes
        for layout in row.get("laneLayoutEvidence", [])
        if isinstance(layout, dict)
    ]
    screenshots += [
        name
        for row in analysis + provenance + musicvideo + host_states + storyboard + production + agent_activity + film_review
        for name in row.get("screenshots", [])
    ]
    native_images = [name for row in film_review for name in native_film_screenshots(row)]
    screenshots += native_images
    valid_images = all(
        isinstance(name, str)
        and (output / name).is_file()
        and (output / name).stat().st_size > 1000
        and (output / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
        for name in screenshots
    )
    valid = (
        return_code == 0
        and completed
        and workspaces == EXPECTED_WORKSPACES
        and len(workspace_rows) == len(EXPECTED_WORKSPACES)
        and len(hidden) == 1
        and len(narrow) == 1
        and set(narrow[0].get("workbenchControls", []))
        == {"production.sidebar", "production.status"}
        and len(library) == 1
        and library[0].get("assetCount") == 500
        and set(library[0].get("types", [])) == {"image", "audio", "document"}
        and library[0].get("nestedFolderOpened") is True
        and library[0].get("searchSelectedAsset") == "fixture-498"
        and library[0].get("workspaceStatePreserved") is True
        and len(keyboard) == 1
        and all(keyboard[0].get(key) is True for key in (
            "spaceEditsText", "deleteEditsText", "selectAllTargetsText", "timelineUnchanged",
            "mediaUnchanged", "selectionUnchanged", "playbackUnchanged",
        ))
        and len(cards) == 1
        and abs(cards[0].get("width", 0) - 213) <= 1
        and abs(cards[0].get("height", 0) - 170.4) <= 1
        and cards[0].get("openVerified") is True
        and cards[0].get("unavailableDisabled") is True
        and cards[0].get("unavailableContentSeparated") is True
        and len(analysis) == 1
        and analysis[0].get("selectedStart") == 6
        and analysis[0].get("playedPosition", 0) > 6.1
        and analysis[0].get("zoom") == 2
        and analysis[0].get("fitRestored") is True
        and analysis[0].get("changedSourceDisabled") is True
        and analysis[0].get("savedProjectUnchanged") is True
        and len(analysis[0].get("screenshots", [])) == 3
        and len(provenance) == 1
        and provenance[0].get("families") == ["imported", "generated", "enhanced", "offline"]
        and all(provenance[0].get(key) is True for key in (
            "syntheticReceipts", "exactOriginRendered", "originalSelected",
            "offlineActionsCorrect", "projectUnchanged", "legacyNameReadable",
        ))
        and provenance[0].get("viewportWidth") == 440
        and provenance[0].get("viewportHeight") == 650
        and len(provenance[0].get("screenshots", [])) == 7
        and len(musicvideo) == 1
        and musicvideo[0].get("phases") == [
            "project_init", "analysis", "brief", "production_design", "treatment",
            "storyboard", "bible", "shotlist", "sanity", "frames", "render",
        ]
        and all(musicvideo[0].get(key) is True for key in (
            "externalPackLoaded", "exactBinding", "libraryDidNotAssignTrack",
            "viewingDidNotAdvance", "disabledApprovalDidNotMutate", "intakeCheckpointSettled",
            "artifactTabsExcludeWorkflowControls", "pipelineRestored", "tasksReachable",
        ))
        and len(musicvideo[0].get("screenshots", [])) == 3
        and len(host_states) == 1
        and all(host_states[0].get(key) is True for key in (
            "supersededRequestHasNoAction", "resetApprovalsMarked",
            "revisionNamesResetApprovals", "rejectedFirstWriteNotUnverified",
        ))
        and len(host_states[0].get("screenshots", [])) == 1
        and len(storyboard) == 1
        and storyboard[0].get("cardDestination") == "Storyboard"
        and storyboard[0].get("pipelineDestination") == "Storyboard"
        and all(storyboard[0].get(key) is True for key in (
            "openedTabWithoutModal", "tabRoundTrip", "pipelineActionSameTarget",
            "approvalControlsUsable", "shownBytesMatchApproval", "changeMarked",
            "declinedFromStoryboard", "gatesUnchanged", "savedProjectUnchanged",
        ))
        and len(storyboard[0].get("screenshots", [])) == 2
        and len(production) == 1
        and valid_production_workbench(production[0])
        and len(agent_activity) == 1
        and agent_activity[0].get("complete") is True
        and len(agent_activity[0].get("screenshots", [])) == 3
        and len(film_review) == 1
        and valid_musicvideo_review(film_review[0], output)
        and len(invariants) == 1
        and {(row.get("family"), row.get("keyframes")) for row in inspector}
        == EXPECTED_INSPECTOR_CASES
        and len(inspector) == len(EXPECTED_INSPECTOR_CASES)
        and len(open_keyframes) == len(EXPECTED_KEYFRAME_LANES)
        and all(valid_keyframe_lane_evidence(row) for row in open_keyframes)
        and invariants[0].get("liveStateUnchanged") is True
        and invariants[0].get("projectBytesUnchanged") is True
        and invariants[0].get("undoUnchanged") is True
        and invariants[0].get("workingCopyUnchanged") is True
        and len(screenshots)
        == 38 + len(EXPECTED_INSPECTOR_CASES) + len(EXPECTED_KEYFRAME_LANES) + len(native_images)
        and valid_images
    )
    return {
        "completed": valid,
        "elapsedSeconds": time.monotonic() - started,
        "events": rows,
        "exitCode": return_code,
        "cases": case_results,
        "reason": "completed" if valid else "invalid-evidence",
        "scale": scale,
        "screenshots": screenshots,
    }


def main():
    executable, output_path = sys.argv[1:]
    output = Path(output_path)
    output.mkdir(parents=True, exist_ok=True)
    results = [run_scale(executable, output, scale) for scale in SCALES]
    result = {
        "completed": all(item["completed"] for item in results),
        "runs": results,
    }
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True))
    print(json.dumps(result, sort_keys=True))
    return 0 if result["completed"] else 1


if __name__ == "__main__":
    sys.exit(main())
