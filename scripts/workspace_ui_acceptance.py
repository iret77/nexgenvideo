"""Exercise and verify the native five-workspace editor on a macOS 26 runner."""
import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

from manual_generation_extended_evidence import manual_generation_extended_evidence
from app_nle_owner_evidence import app_nle_owner_evidence
from media_browser_owner_evidence import media_browser_owner_evidence
from generation_recovery_acceptance import generation_recovery_evidence, run_generation_recovery


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
from source_operations_evidence import source_operations_evidence
from manual_video_modes_evidence import manual_video_modes_evidence
from color_reference_evidence import validate as validate_color_reference

ALL_CASES = ("workspace", "cards", "analysis", "provenance", "musicvideo", "hoststates", "storyboard", "filmreview", "planning", "genericnle", "corefilmreview", "medialibrary", "animationaudio", "manualgeneration", "performance", "textcaptions", "generationrecovery", "appnle", "mediabrowser", "sourceoperations", "manualvideomodes", "frames")
ACCEPTANCE_SCOPES = {"all": ALL_CASES, "frames": ("frames",), "filmreview": ("filmreview",), "activity": ("storyboard",), "planning": ("planning",), "genericnle": ("genericnle",), "corefilmreview": ("corefilmreview",), "medialibrary": ("medialibrary",), "animationaudio": ("animationaudio",), "manualgeneration": ("manualgeneration",), "performance": ("performance",), "textcaptions": ("textcaptions",), "generationrecovery": ("generationrecovery",), "appnle": ("appnle",), "mediabrowser": ("mediabrowser",), "sourceoperations": ("sourceoperations",), "manualvideomodes": ("manualvideomodes",)}
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


def generation_timing(evidence):
    cut = evidence.get("plannedCutSeconds")
    duration = evidence.get("requestedDurationSeconds")
    provider_frames = evidence.get("providerDurationFrames")
    if (type(cut) not in (int, float) or not math.isfinite(cut) or abs(cut - 2.0) > 0.075
        or type(duration) is not int or duration != math.ceil(cut + 2)
        or type(provider_frames) is not int or provider_frames != duration * 30):
        return None
    cut_frames = math.floor(cut * 30 + 0.5)
    if (any(type(evidence.get(key)) is not int for key in (
            "generatedSourceStartFrame", "generatedSourceEndFrame", "importedSourceEndFrame", "totalFrames"))
        or evidence.get("generatedSourceStartFrame") != 30
        or evidence.get("generatedSourceEndFrame") != 30 + cut_frames
        or evidence.get("importedSourceEndFrame") != 129 - cut_frames
        or provider_frames < cut_frames + 60
        or evidence.get("totalFrames") != 129):
        return None
    return cut_frames, duration


def valid_native_generation(evidence):
    timing = generation_timing(evidence)
    if timing is None:
        return False
    cut_frames, duration = timing
    review_end = (cut_frames + 30) / 30
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
        or not isinstance(screenshots, list) or len(screenshots) != 4
        or not all(isinstance(name, str) and name and Path(name).name == name for name in screenshots)
        or len(set(screenshots)) != 4):
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
        if (finding.get("verdict") != verdict or finding.get("startSeconds") != 1 or finding.get("endSeconds") != review_end
            or not isinstance(observation, str) or not observation.startswith(f"Supplied acceptance decision: {passes[index]} ")):
            return False
        if index == 0:
            expected += [("take.verdict", "conforms", "rejected"), ("take.verdict", "rejected", "conforms")]
        else:
            expected.append(("take.verdict", "conforms", "acceptedDeviation"))
        expected += [("take.observation", "", observation), ("take.start", "0.0", "1.0"),
                     ("take.end", str(float(duration)), str(review_end)), ("take.record-pass", str(index), str(index + 1))]
    expected += [("take.save", "0", "6"), ("take.use", "none", evidence["takeID"]), ("take.close", "open", "closed")]
    expected.append(("take.workspace.select." + evidence["takeID"], "none", evidence["takeID"]))
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
                              and abs(original_end - duration) < 1.0 / 30)
        if (item.get("index") != index or item.get("controlID") != control
            or not before_matches or item.get("after") != after
            or item.get("documentWindowNumber") != document_window
            or item.get("windowNumber") != (document_window if index < 2 or control.startswith("take.workspace.select.") else sheet_window)):
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

POSTPRODUCTION_CONTROL_IDS = frozenset((
    "Position X", "Position Y", "Scale", "Rotation", "Opacity", "Speed",
    "flip arrow.left.and.right", "flip arrow.up.and.down",
    "color.exposure.ev", "color.contrast.amount", "color.highlightsShadows.highlights", "color.highlightsShadows.shadows",
    "color.blacksWhites.blacks", "color.blacksWhites.whites", "color.temperature.temperature", "color.temperature.tint",
    "color.vibrance.amount", "color.saturation.amount", "blur.sharpen.amount", "blur.noiseReduction.amount",
    "blur.noiseReduction.chroma", "blur.noiseReduction.detail", "detail.clarity.clarity", "detail.clarity.dehaze",
    "blur.gaussian.radius", "blur.motion.radius", "blur.motion.angle", "stylize.vignette.amount",
    "stylize.vignette.midpoint", "stylize.vignette.roundness", "stylize.vignette.feather", "stylize.grain.amount",
    "stylize.grain.size", "stylize.glow.intensity", "stylize.glow.radius", "stylize.glow.threshold", "stylize.glow.warmth",
    "key.chroma.keyHue", "key.chroma.tolerance", "key.chroma.softness", "key.chroma.spill",
    "Basic Correction bypass/reset and rendered exposure", "Lift color and rendered composition", "Lift level",
    "Gamma color and rendered composition", "Gamma level", "Gain color and rendered composition", "Gain level",
    "Curves Y", "Curves R", "Curves G", "Curves B", "Hue Curves Hue", "Hue Curves Sat", "Hue Curves Luma",
))


def postproduction_control_evidence(value):
    return (isinstance(value, dict) and isinstance(value.get("controls"), list)
            and all(isinstance(item, str) for item in value["controls"])
            and set(value["controls"]) == POSTPRODUCTION_CONTROL_IDS
            and len(value["controls"]) == len(POSTPRODUCTION_CONTROL_IDS)
            and value.get("playerItemCompositionExposureAndWheels") is True
            and value.get("baselineRestored") is True)


POSTPRODUCTION_NATIVE_VALUES = {
    "inspector.value.Position X": ("32",), "inspector.value.Position Y": ("18",),
    "inspector.value.Scale": ("80",), "inspector.value.Rotation": ("15",),
    "inspector.value.Opacity": ("75", "50"), "inspector.value.Speed": ("2.00",),
    **{"inspector.adjust.value." + key: values for key, values in {
        "color.exposure.ev": ("0.50", "1.00"), "color.contrast.amount": ("1.20",),
        "color.highlightsShadows.highlights": ("-0.30",), "color.highlightsShadows.shadows": ("0.30",),
        "color.blacksWhites.blacks": ("0.20",), "color.blacksWhites.whites": ("-0.20",),
        "color.temperature.temperature": ("7500",), "color.temperature.tint": ("20",),
        "color.vibrance.amount": ("0.30",), "color.saturation.amount": ("0.70",),
        "blur.sharpen.amount": ("0.40",), "blur.noiseReduction.amount": ("0.40",),
        "blur.noiseReduction.chroma": ("0.40",), "blur.noiseReduction.detail": ("0.30",),
        "detail.clarity.clarity": ("0.20",), "detail.clarity.dehaze": ("0.20",),
        "blur.gaussian.radius": ("10",), "blur.motion.radius": ("10",), "blur.motion.angle": ("30",),
        "stylize.vignette.amount": ("0.30",), "stylize.vignette.midpoint": ("0.30",),
        "stylize.vignette.roundness": ("0.20",), "stylize.vignette.feather": ("0.30",),
        "stylize.grain.amount": ("0.20",), "stylize.grain.size": ("2.00",),
        "stylize.glow.intensity": ("0.30",), "stylize.glow.radius": ("30",),
        "stylize.glow.threshold": ("0.40",), "stylize.glow.warmth": ("0.20",),
        "key.chroma.keyHue": ("0.20",), "key.chroma.tolerance": ("0.30",),
        "key.chroma.softness": ("0.30",), "key.chroma.spill": ("0.30",),
    }.items()},
}
POSTPRODUCTION_CAPTURE_LABELS = (
    "transform", "basic-correction", "detail", "blur", "motion-blur", "vignette", "film-grain", "glow", "chroma-key",
    "wheel-lift", "wheel-gamma", "wheel-gain", "curve-Y", "curve-R", "curve-G", "curve-B",
    "hue-curve-Hue", "hue-curve-Sat", "hue-curve-Luma",
)


def postproduction_native_evidence(interactions, screenshots):
    if (not isinstance(interactions, list) or not all(isinstance(item, dict) for item in interactions)
        or not isinstance(screenshots, list) or not all(isinstance(item, str) for item in screenshots)):
        return False
    fields = [item.get("field") for item in interactions if item.get("kind") == "text"]
    if not all(isinstance(field, dict) for field in fields):
        return False
    relevant = [field for field in fields if isinstance(field.get("id"), str) and field["id"] in POSTPRODUCTION_NATIVE_VALUES]
    if (not all(isinstance(field.get("expected"), str) and field.get("actual") == field["expected"]
                and field.get("stage") == "commit-requested" and field.get("commitInput") == "Tab"
                and field.get("requiresFocusExit") is True and field.get("focusLeftTarget") is True
                and field.get("ownsEditor") is False and type(field.get("window")) is int and field["window"] > 0
                for field in relevant)
        or Counter((field["id"], field["expected"]) for field in relevant) != Counter(
            (key, value) for key, values in POSTPRODUCTION_NATIVE_VALUES.items() for value in values)):
        return False
    document_windows = {field["window"] for field in relevant}
    if len(document_windows) != 1:
        return False
    drags = [item for item in interactions if item.get("kind") == "drag"
             and isinstance(item.get("id"), str) and item["id"] in {"inspector.wheel.Lift", "inspector.wheel.Gamma", "inspector.wheel.Gain",
                                   "inspector.curve.canvas", "inspector.hue-curve.canvas"}]
    if (Counter(item["id"] for item in drags) != Counter({
            "inspector.wheel.Lift": 1, "inspector.wheel.Gamma": 1, "inspector.wheel.Gain": 1,
            "inspector.curve.canvas": 4, "inspector.hue-curve.canvas": 3})
        or not all(item.get("window") in document_windows and item.get("start") == [0.5, 0.5]
                   and item.get("end") == ([0.7, 0.4] if item["id"].startswith("inspector.wheel.") else [0.5, 0.25])
                   for item in drags)):
        return False
    segments = [(item.get("id"), item.get("item")) for item in interactions
                if item.get("kind") == "segment-accessibility" and item.get("id") in (
                    "inspector.curve.channel", "inspector.hue-curve.channel")]
    expected_segments = [("inspector.curve.channel", channel) for channel in ("Y", "R", "G", "B")]
    expected_segments += [("inspector.hue-curve.channel", channel) for channel in ("Hue", "Sat", "Luma")]
    if segments != expected_segments:
        return False
    clicks = Counter(item.get("id") for item in interactions if item.get("kind") == "pointer" and isinstance(item.get("id"), str))
    if any(clicks[key] < count for key, count in {
        "inspector.transform.arrow.left.and.right": 1, "inspector.transform.arrow.up.and.down": 1,
        "inspector.adjust.bypass.Basic Correction": 2, "inspector.reset.Reset basic correction": 1,
        "inspector.wheel.level.Lift": 1, "inspector.wheel.level.Gamma": 1, "inspector.wheel.level.Gain": 1,
    }.items()):
        return False
    return all(sum(name.endswith("-finishing-" + label + ".png") for name in screenshots) == 1
               for label in POSTPRODUCTION_CAPTURE_LABELS)


def native_lut_evidence(value, interactions, screenshots):
    if (not isinstance(value, dict) or not isinstance(interactions, list)
        or not all(isinstance(item, dict) for item in interactions)
        or not isinstance(screenshots, list) or not all(isinstance(item, str) for item in screenshots)
        or value.get("readableName") != "Look.cube" or value.get("selectedIntensity") != 1
        or value.get("invalidError") != "The LUT is unreadable or its stored bytes changed. Choose a valid .cube LUT, or remove the effect."
        or not all(value.get(key) is True for key in (
            "cancelPreservedTimeline", "invalidFileVisible", "sameFilenameBytesPreserved", "intensityBypassReset",
            "nativeUndoRedo", "playerItemCompositionVerified", "nativeSaveAndReopen", "exportGradeVerified"))
        or not all(sha256_string(value.get(key)) for key in ("firstSHA256", "secondSHA256"))
        or value["firstSHA256"] == value["secondSHA256"]
        or any(value.get(prefix + "Path") != "resources/luts/" + value[prefix + "SHA256"] + ".cube"
               for prefix in ("first", "second"))):
        return False
    recovery = value.get("legacyRecovery")
    if (not isinstance(recovery, dict) or not all(recovery.get(key) is True for key in (
            "openedWithVisibleProblem", "nativeRemoveUndo", "nativeRelink", "nativeSaveAndReopen", "originalProjectPreserved",
            "replacementAbsentBeforeSave"))
        or not sha256_string(recovery.get("originalPackageSHA256Before"))
        or recovery.get("originalPackageSHA256After") != recovery.get("originalPackageSHA256Before")
        or recovery.get("replacementSHA256") != value["secondSHA256"]
        or not isinstance(recovery.get("screenshots"), list) or not recovery["screenshots"]
        or not all(isinstance(name, str) and name in screenshots for name in recovery["screenshots"])
        or not all(any(name.endswith("-" + label + ".png") for name in recovery["screenshots"])
                   for label in ("missing-on-open", "relinked"))
        or not isinstance(recovery.get("interactions"), list)
        or not all(isinstance(item, dict) for item in recovery["interactions"])):
        return False
    recovery_inputs = recovery["interactions"]
    if (not all(any(item.get("kind") == "pointer" and item.get("id") == key for item in recovery_inputs)
                for key in ("editor.lut.review", "inspector.lut.remove", "inspector.lut.relink"))
        or not all(any(item.get("kind") == "keyboard" and item.get("characters") == key for item in recovery_inputs)
                   for key in ("z", "s"))
        or not any(item.get("kind") == "file-panel" and item.get("path") == "Look.cube"
                   and item.get("selectedURLVerified") is True and item.get("nativePathEditorVerified") is True
                   for item in recovery_inputs)):
        return False
    panels = [item for item in interactions if item.get("kind") == "file-panel"
              and item.get("path") in ("Look.cube", "Invalid.cube")]
    intensity = [item.get("field") for item in interactions if item.get("kind") == "text"
                 and isinstance(item.get("field"), dict) and item["field"].get("id") == "inspector.lut.intensity"]
    clicks = Counter(item.get("id") for item in interactions if item.get("kind") == "pointer" and isinstance(item.get("id"), str))
    return ([item["path"] for item in panels] == ["Invalid.cube", "Look.cube", "Look.cube"]
        and all(item.get("selectedURLVerified") is True and item.get("nativePathEditorVerified") is True for item in panels)
        and any(item.get("kind") == "file-panel-cancel" for item in interactions)
        and [item.get("actual") for item in intensity] == ["50", "100"]
        and all(item.get("actual") == item.get("expected") and item.get("requiresFocusExit") is True
                and item.get("focusLeftTarget") is True and item.get("ownsEditor") is False
                and item.get("stage") == "commit-requested" for item in intensity)
        and clicks["inspector.adjust.bypass.LUTs"] == 2 and clicks["inspector.reset.Reset luts"] == 1
        and all(sum(name.endswith("-lut-" + label + ".png") for name in screenshots) == 1
                for label in ("invalid", "inverted", "intensity", "portable-replacement")))


def color_reference_evidence(value, output, scale):
    try:
        if not isinstance(value, dict) or value.get("scale") != scale:
            return False, []
        directory = "color-reference-" + str(round(scale * 100))
        actual = validate_color_reference(output / directory)
        if actual != value:
            return False, []
        return True, [directory + "/" + name for name in actual["screenshots"]]
    except (OSError, ValueError, KeyError, TypeError, IndexError, StopIteration):
        return False, []


def generic_nle_evidence(rows, output, scale):
    records = [row for row in rows if row.get("event") == "generic-nle"]
    completions = [row for row in rows if row.get("event") == "completed" and row.get("case") == "genericnle"]
    if (len(records) != 1 or len(completions) != 1
        or any(row.get("scale") != scale for row in records + completions)
        or any(row.get("event") == "failed" for row in rows)):
        return False, []
    row = records[0]
    screenshots = row.get("screenshots", [])
    interactions = row.get("interactions", [])
    color_valid, color_images = color_reference_evidence(row.get("colorReference"), output, scale)
    valid = (color_valid and row.get("viewport") == [960, 640]
        and postproduction_control_evidence(row.get("finishingControls"))
        and postproduction_native_evidence(interactions, screenshots)
        and native_lut_evidence(row.get("nativeLUT"), interactions, screenshots)
        and row.get("decodedFrames") == 240
        and type(row.get("durationSeconds")) in (int, float) and abs(row["durationSeconds"] - 8) < 0.0001
        and type(row.get("motionPixels")) in (int, float) and row["motionPixels"] > 20
        and all(row.get(key) is True for key in (
            "nativeImport", "libraryImportDidNotInsert", "nativeSourceInsert", "nativeSplitUndoRedo",
            "nativeClipboardUndoRedo", "nativePostproduction", "nativeExportAndPoster", "visibleQC",
            "nativeSaveAndReopen", "noProductionEnrollment", "splitBoundaryVerified", "unsavedBaselineVerified"))
        and all(sha256_string(row.get(key)) for key in ("timelineSHA256", "outputSHA256", "posterSHA256"))
        and isinstance(interactions, list) and len(interactions) >= 20
        and all(any(isinstance(item, dict) and item.get("kind") == "keyboard" and item.get("characters") == key
                    for item in interactions) for key in ("k", "z", "Z", "c", "v", "s"))
        and isinstance(screenshots, list) and len(screenshots) >= 6 and len(set(screenshots)) == len(screenshots)
        and all(isinstance(name, str) and Path(name).name == name and (output / name).is_file()
                and (output / name).stat().st_size > 1000
                and (output / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n") for name in screenshots))
    return valid, (screenshots + color_images) if isinstance(screenshots, list) else []


def native_media_relink_evidence(value, screenshots):
    if not isinstance(value, dict) or not all(value.get(key) is True for key in (
        "cancelPreservedBindings", "incompatibleSourceRejected", "ambiguousFolderRejected", "nativeFileUndoRedo",
        "nativeFolderRelink", "identitiesAndTimelinePreserved", "exactSourceBytes", "nativeSaveAndReopen", "originalProjectPreserved")):
        return False
    inputs, images = value.get("interactions"), value.get("screenshots")
    if (not isinstance(inputs, list) or not all(isinstance(item, dict) for item in inputs)
        or not isinstance(images, list) or not all(isinstance(name, str) and name in screenshots for name in images)):
        return False
    paths = [item.get("path") for item in inputs if item.get("kind") == "file-panel"
             and item.get("selectedURLVerified") is True and item.get("nativePathEditorVerified") is True]
    return (all(name in paths for name in ("Original.mov", "Brief.txt", "Incoming"))
        and any(isinstance(name, str) and name.endswith("-ambiguous") for name in paths)
        and any(item.get("kind") == "file-panel-cancel" for item in inputs)
        and all(any(item.get("kind") == "keyboard" and item.get("characters") == key for item in inputs) for key in ("z", "Z", "s"))
        and all(any(name.endswith("-" + label + ".png") for name in images)
                for label in ("offline-source", "incompatible-source", "ambiguous-folder", "all-relinked")))


def text_captions_evidence(rows, output, scale):
    records = [row for row in rows if row.get("event") == "text-captions"]
    completed = [row for row in rows if row.get("event") == "completed" and row.get("case") == "textcaptions"]
    if (len(records) != 1 or len(completed) != 1 or any(row.get("event") == "failed" for row in rows)
        or any(row.get("scale") != scale for row in records + completed)):
        return False, []
    row = records[0]
    actions, images = row.get("interactions"), row.get("screenshots")
    if (row.get("viewport") != [960, 640] or row.get("interfaceScale") != scale or row.get("transcriptionSeam") != "source-bound-client" or row.get("liveTranscription") is not False
        or row.get("isolatedSpeechRequests") != 3 or row.get("captionStart") != 30 or row.get("captionDuration") != 45
        or not all(row.get(key) is True for key in ("nativeTitleCreationUndoRedo", "nativeTextUndo", "nativeTitleStyle",
            "playerItemCompositionTitle", "independentTextLayers", "nativeCaptionOptions", "nativeCaptionCancel",
            "nativeCaptionStaleRefusal", "nativeCaptionPlacement", "nativeFillerUndoRedo", "nativeSaveAndReopen"))
        or not isinstance(actions, list) or not all(isinstance(item, dict) for item in actions)
        or not isinstance(images, list) or len(images) != 6 or len(set(images)) != 6
        or not all(isinstance(image, str) for image in images)):
        return False, []
    pointers = [item.get("id") for item in actions if item.get("kind") == "pointer"]
    menus = {(item.get("id"), tuple(item.get("path", []))) for item in actions if item.get("kind") == "menu" and item.get("closed") is True}
    fields = [item["field"] for item in actions if item.get("kind") == "text" and isinstance(item.get("field"), dict)]
    keys = [item.get("characters") for item in actions if item.get("kind") == "keyboard"]
    required_fields = [("text.content", "Release title"), ("text.content", "Second layer"),
        ("inspector.value.Text size", "72"), ("inspector.value.Text opacity", "60"), ("inspector.value.Caption size", "36")]
    project = row.get("project")
    if not isinstance(project, str) or Path(project).name != project or not project.endswith(".ngv"):
        return False, []
    try:
        saved = json.loads((output / project / "project.json").read_text())
        clips = [clip for track in saved["tracks"] for clip in track["clips"]]
        texts = [clip for clip in clips if clip.get("mediaType") == "text"]
        text = {clip["textContent"]: clip for clip in texts}
        baseline = row.get("baseline")
        if not isinstance(baseline, str) or Path(baseline).name != baseline:
            return False, []
        original = json.loads((output / baseline).read_text())
        source_clips = [clip for track in original["tracks"] for clip in track["clips"]]
        original_unchanged = (len(source_clips) == 2 and {clip["id"] for clip in source_clips} == {"visual", "voice-clip"}
            and all(clip["startFrame"] == 0 and clip["durationFrames"] == 180 for clip in source_clips)
            and [clip for clip in clips if clip.get("mediaType") != "text"] == source_clips)
        title, caption = text["Release title"], text["HELLO WORLD."]
        persisted = (original_unchanged and len(texts) == 3 and len(text) == 3
            and sum(bool(clip.get("captionGroupId")) for clip in texts) == 1
            and text["Second layer"]["textStyle"]["fontSize"] != 72
            and text["Second layer"]["textStyle"]["alignment"] != "right" and "Second layer" in text and title["opacity"] == 0.6
            and title["textStyle"]["fontSize"] == 72 and title["textStyle"]["alignment"] == "right"
            and title["textStyle"]["background"]["enabled"] is True and title["textStyle"]["border"]["enabled"] is True
            and title["textStyle"]["shadow"]["enabled"] is False and caption["textStyle"]["fontSize"] == 36
            and caption["startFrame"] == 30 and caption["durationFrames"] == 45 and bool(caption["captionGroupId"]))
    except (OSError, ValueError, KeyError, TypeError):
        return False, []
    pending = [item.get("evidence", {}) for item in actions if item.get("kind") == "verified-state"
        and item.get("label") == "visible pending title edit"]
    visible_pending = (len(pending) == 1 and pending[0].get("documentEdited") is True
        and all(isinstance(pending[0].get(key), (int, float)) and 0 < pending[0][key] < 10000
            for key in ("textWidth", "textHeight", "glyphWidth", "glyphHeight")))
    after_save = [item.get("evidence", {}) for item in actions if item.get("kind") == "verified-state"
        and item.get("label") == "pending title edit after Save"]
    saved_pending = (len(after_save) == 1 and after_save[0].get("savedText") == "Release titleX"
        and after_save[0].get("pendingText") == "Release titleXY" and after_save[0].get("focusPreserved") is True
        and after_save[0].get("documentEdited") is True)
    valid = (persisted and visible_pending and saved_pending and pointers.count("editing.add-text") == 3 and pointers.count("captions.generate") == 3
        and any(item.get("kind") == "verified-state" and item.get("label") == "title size undo includes fitted frame"
            and item.get("evidence") == {"fontSize": 72, "restoredExactTimeline": True} for item in actions)
        and pointers.count("captions.cancel") == 1 and all(key in pointers for key in
            ("text.toggle.Background", "text.toggle.Border", "text.toggle.Shadow", "text.alignment", "captions.censor"))
        and keys.count("z") >= 4 and keys.count("Z") >= 2 and "s" in keys
        and all((identifier, (label,)) in menus for identifier, label in
            (("captions.source", "A1 · 1 clip"), ("captions.language", "English (United States)"), ("captions.case", "UPPERCASE"), ("captions.actions", "Remove filler words")))
        and all(any(field.get("id") == identifier and field.get("expected") == value and field.get("actual") == value
            and isinstance(field.get("fontPointSize"), (int, float)) and abs(field["fontPointSize"] - 13 * scale) < 0.5
            and field.get("requiresFocusExit") is True and field.get("focusLeftTarget") is True for field in fields)
            for identifier, value in required_fields)
        and all(any(image.endswith("-" + label + ".png") for image in images) for label in
            ("styled-title", "two-title-layers", "caption-cancel", "caption-stale", "generated-captions", "caption-cleanup-undo-redo"))
        and all(Path(image).name == image and (output / image).is_file() and (output / image).stat().st_size > 1000
            and (output / image).read_bytes().startswith(b"\x89PNG\r\n\x1a\n") for image in images))
    return valid, images


def native_media_organization_evidence(row, screenshots, sources, scale):
    if not isinstance(row, dict):
        return False
    selected, unselected = row.get("selectedAssetID"), row.get("unselectedAssetID")
    actions, images = row.get("interactions"), row.get("screenshots")
    source_ids = {item["filename"]: item["id"] for item in sources}
    if (selected != source_ids.get("Original.mov") or unselected != source_ids.get("Reference.png")
        or not isinstance(selected, str) or not isinstance(unselected, str) or selected == unselected
        or row.get("directMutationRefusals") != 6 or row.get("completedProposalRefusals") != 3
        or row.get("liveAgent") is not False
        or not all(row.get(key) is True for key in ("nativeProposal", "nativeCancel", "nativeSelectiveApply",
            "nativeSingleUndoRedo", "nativeStaleRefusal", "nativeSaveAndReopen", "sourceBytesPreserved",
            "originalProjectPreserved", "stableUndoLabels"))
        or not isinstance(actions, list) or not all(isinstance(item, dict) for item in actions)
        or not isinstance(images, list) or len(images) != 4 or not all(image in screenshots for image in images)):
        return False
    pointers = [item.get("id") for item in actions if item.get("kind") == "pointer"]
    required = {"media.action.Organize": 3, "agent.task.run": 3, "agent.dialog.cancel": 2,
                "agent.dialog.confirm": 2, "media.organization.choice." + selected: 2}
    if not all(pointers.count(key) == count for key, count in required.items()):
        return False
    def positions(kind, key, value):
        return [index for index, item in enumerate(actions) if item.get("kind") == kind and item.get(key) == value]
    organize = positions("pointer", "id", "media.action.Organize")
    run = positions("pointer", "id", "agent.task.run")
    cancel = positions("pointer", "id", "agent.dialog.cancel")
    confirm = positions("pointer", "id", "agent.dialog.confirm")
    select = positions("pointer", "id", "media.organization.choice." + selected)
    undo, redo, save = [positions("keyboard", "characters", key) for key in ("z", "Z", "s")]
    rename = [index for index, item in enumerate(actions) if item.get("kind") == "context-menu"
              and item.get("id") == "media.asset." + unselected and item.get("closed") is True and item.get("path") == ["Rename"]]
    fields = [index for index, item in enumerate(actions) if item.get("kind") == "text" and isinstance(item.get("field"), dict)
              and item["field"].get("id") == "media.rename." + unselected
              and item["field"].get("expected") == "Independent edit" and item["field"].get("actual") == "Independent edit"
              and item["field"].get("requiresFocusExit") is True and item["field"].get("focusLeftTarget") is True]
    if not all(len(items) == 1 for items in (undo, redo, save, rename, fields)):
        return False
    ordered = [organize[0], run[0], cancel[0], organize[1], run[1], select[0], confirm[0], undo[0], redo[0],
               organize[2], run[2], rename[0], fields[0], select[1], confirm[1], cancel[1], save[0]]
    expected_images = {f"media-organization-{round(scale * 100)}-{label}.png" for label in
                       ("proposal", "selected-change", "applied-undo-redo", "stale-proposal")}
    return (ordered == sorted(ordered) and len(set(ordered)) == len(ordered)
        and "media.organization.choice." + unselected not in pointers and set(images) == expected_images)


def media_library_evidence(rows, output, scale):
    records = [row for row in rows if row.get("event") == "native-media-library"]
    completions = [row for row in rows if row.get("event") == "completed" and row.get("case") == "medialibrary"]
    if (len(records) != 1 or len(completions) != 1
        or any(row.get("scale") != scale for row in records + completions)
        or any(row.get("event") == "failed" for row in rows)):
        return False, []
    row = records[0]
    screenshots, sources, interactions = row.get("screenshots"), row.get("sources"), row.get("interactions")
    expected = {"Original.mov": "video", "Ambience.wav": "audio", "Reference.png": "image",
                "Brief.txt": "document", "Captions.srt": "subtitle", "Motion.json": "lottie"}
    if (row.get("viewport") != [960, 640]
        or not all(row.get(key) is True for key in (
            "nativeFolderImport", "cancelPreservedLibrary", "importDidNotInsert", "documentNotPlaceable",
            "nativeRenameUndoRedo", "originalFilenamePreserved", "nativeCopyPath", "nativeSearchAndFilter",
            "nativeSelectAll", "nativeUsedDeleteUndo", "nativeNestedMoveDeleteUndo", "nativeSaveAndReopen"))
        or not isinstance(sources, list) or len(sources) != 6 or not all(isinstance(item, dict) for item in sources)
        or not all(isinstance(item.get("filename"), str) and expected.get(item["filename"]) == item.get("type")
                   and isinstance(item.get("id"), str) and item["id"] and sha256_string(item.get("sha256")) for item in sources)
        or len({item["id"] for item in sources}) != 6 or {item["filename"] for item in sources} != set(expected)
        or not isinstance(interactions, list) or not all(isinstance(item, dict) for item in interactions)
        or not isinstance(screenshots, list) or not all(isinstance(name, str) for name in screenshots)):
        return False, []
    context_paths = [item.get("path") for item in interactions if item.get("kind") == "context-menu" and item.get("closed") is True]
    fields = [item["field"] for item in interactions if item.get("kind") == "text" and isinstance(item.get("field"), dict)]
    valid = (native_media_relink_evidence(row.get("nativeRelink"), screenshots)
        and native_media_organization_evidence(row.get("nativeOrganization"), screenshots, sources, scale)
        and all(path in context_paths for path in (["Rename"], ["Copy Path"], ["Delete"], ["Open"], ["Move to Folder", "Selected"]))
        and context_paths.count(["Delete"]) == 2
        and all(any(item.get("kind") == "keyboard" and item.get("characters") == key for item in interactions)
                for key in ("z", "Z", "a", "s"))
        and any(item.get("kind") == "file-panel-cancel" for item in interactions)
        and any(item.get("kind") == "file-panel" and item.get("path") == "Incoming"
                and item.get("selectedURLVerified") is True and item.get("nativePathEditorVerified") is True for item in interactions)
        and all(any(field.get("expected") == value and field.get("actual") == value
                    and field.get("requiresFocusExit") is True and field.get("focusLeftTarget") is True for field in fields)
                for value in ("Opening movement", "Archive", "Selected"))
        and all(any(name.endswith("-" + label + ".png") for name in screenshots) for label in (
            "six-file-types", "original-filename-search", "image-filter", "select-all", "nested-folders", "folder-delete-undo"))
        and len(set(screenshots)) == len(screenshots)
        and all(Path(name).name == name and (output / name).is_file() and (output / name).stat().st_size > 1000
                and (output / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n") for name in screenshots))
    return valid, screenshots


ANIMATION_AUDIO_VALUES = {
    "inspector.value.Opacity": ("25", "75"),
    "inspector.adjust.value.color.exposure.ev": ("-1.00", "1.00", "1.50"),
    "editing.audio.volume": ("-12.0", "-6.0"),
    "editing.audio.fade-in": ("0.50",), "editing.audio.fade-out": ("1.00",),
    "inspector.value.Speed": ("2.00",),
}
ANIMATION_AUDIO_MENUS = [
    ("editing.keyframe.opacity.30", "Hold"), ("editing.keyframe.opacity.30", "Linear"),
    ("editing.keyframe.opacity.30", "Smooth"), ("editing.keyframe.opacity.90", "Delete Keyframe"),
    ("editing.keyframe.opacity.30", "Clear Animation"),
    ("editing.keyframe.effect.color.exposure.ev.90", "Delete Keyframe"),
    ("editing.keyframe.effect.color.exposure.ev.30", "Clear Animation"), ("editing.keyframe.effect.color.exposure.ev.30", "Hold"),
    ("editing.keyframe.effect.color.exposure.ev.30", "Linear"), ("editing.keyframe.volume.30", "Linear"),
]


def animation_audio_evidence(rows, output, scale):
    records = [row for row in rows if row.get("event") == "animation-audio"]
    completed = [row for row in rows if row.get("event") == "completed" and row.get("case") == "animationaudio"]
    if (len(records) != 1 or len(completed) != 1 or any(row.get("scale") != scale for row in records + completed)
        or any(row.get("event") == "failed" for row in rows)):
        return False, []
    row = records[0]
    inputs, images = row.get("interactions"), row.get("screenshots")
    if (row.get("viewport") != [960, 640] or not all(row.get(key) is True for key in (
        "nativeOpacityKeys", "nativeInterpolation", "nativePreviousNext", "nativeMoveDeleteClearUndo", "nativeEffectKeys",
        "nativeEffectMoveDeleteClearUndo", "nativeEffectPreviousNext", "nativeAudioInterpolation",
        "playerItemCompositionAnimation", "nativeVolumeKeys", "nativeFadesAndTempoUndo", "unselectedAudioPreserved", "nativeSaveAndReopen"))
        or not isinstance(inputs, list) or not all(isinstance(item, dict) for item in inputs)
        or not isinstance(images, list) or not all(isinstance(name, str) for name in images)):
        return False, []
    fields = [item.get("field") for item in inputs if item.get("kind") == "text"]
    if not all(isinstance(field, dict) and isinstance(field.get("id"), str) and isinstance(field.get("expected"), str) for field in fields):
        return False, []
    actual_values = Counter((field["id"], field["expected"]) for field in fields)
    expected_values = Counter((key, value) for key, values in ANIMATION_AUDIO_VALUES.items() for value in values)
    if (actual_values != expected_values or not all(field.get("actual") == field["expected"]
        and field.get("commitInput") == "Tab" and field.get("stage") == "commit-requested"
        and field.get("requiresFocusExit") is True and field.get("focusLeftTarget") is True and field.get("ownsEditor") is False for field in fields)):
        return False, []
    menus = [(item.get("id"), item["path"][0]) for item in inputs if item.get("kind") == "context-menu"
             and item.get("closed") is True and isinstance(item.get("path"), list) and len(item["path"]) == 1]
    pointer_ids = [item.get("id") for item in inputs if item.get("kind") == "pointer"]
    valid = (menus == ANIMATION_AUDIO_MENUS
        and all(pointer_ids.count(key) >= count for key, count in {
            "editing.keyframe.opacity.stamp": 2, "editing.effect.color.exposure.ev.stamp": 2,
            "editing.keyframe.volume.stamp": 2, "editing.keyframe.opacity.previous": 1,
            "editing.keyframe.opacity.next": 1, "editing.effect.color.exposure.ev.previous": 1,
            "editing.effect.color.exposure.ev.next": 1}.items())
        and all(any(item.get("kind") == "drag" and item.get("id") == identifier
                and item.get("start") == [0.75, 0.5] and item.get("end") == [0.5, 0.5] for item in inputs)
                for identifier in ("editing.keyframe-lane.opacity", "editing.keyframe-lane.effect.color.exposure.ev"))
        and sum(item.get("kind") == "keyboard" and item.get("characters") == "z" for item in inputs) >= 7
        and any(item.get("kind") == "keyboard" and item.get("characters") == "s" for item in inputs)
        and all(any(name.endswith("-" + label + ".png") for name in images)
                for label in ("opacity-keyframes", "effect-keyframes", "volume-and-fades"))
        and len(images) == len(set(images))
        and all(Path(name).name == name and (output / name).is_file() and (output / name).stat().st_size > 1000
                and (output / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n") for name in images))
    return valid, images


def manual_generation_evidence(rows, output, scale):
    records = [row for row in rows if row.get("event") == "manual-generation"]
    completions = [row for row in rows if row.get("event") == "completed" and row.get("case") == "manualgeneration"]
    if (len(records) != 1 or len(completions) != 1
        or any(row.get("scale") != scale for row in records + completions)
        or any(row.get("event") == "failed" for row in rows)):
        return False, []
    row = records[0]
    inputs, images = row.get("interactions"), row.get("screenshots")
    if (row.get("viewport") != [960, 640] or row.get("nativeScenario") is not True or row.get("liveProvider") is not False
        or not isinstance(inputs, list) or not all(isinstance(item, dict) for item in inputs)
        or not isinstance(images, list) or not all(isinstance(name, str) for name in images)):
        return False, []
    states = [item for item in inputs if item.get("kind") == "verified-state"]
    expected_labels = ["manual image generation uses the native reviewed request",
                       "source-only offering and native library picker", "native rerun loss is explicit"]
    if ([item.get("label") for item in states[:3]] != expected_labels
        or not all(isinstance(item.get("evidence"), dict) for item in states)):
        return False, []
    image, source, rerun = [item["evidence"] for item in states[:3]]
    discovery = image.get("discovery")
    if (not isinstance(discovery, dict) or discovery.get("liveProvider") is not False
        or discovery.get("endpointIDs") != ["fal-ai/flux/dev", "fal-ai/flux/schnell", "fal-ai/gemini-25-flash-image/edit"]
        or discovery.get("requests") != ["https://api.fal.ai/v1/models?category=" + category + "&status=active&limit=100"
                                        for category in ("text-to-image", "image-to-image")]):
        return False, []
    if (not all(sha256_string(image.get(key)) for key in ("packageID", "outputSHA256"))
        or not all(image.get(key) is True for key in ("copiedPromptMatched", "discardDidNotSubmit", "changedInputsInvalidateReview", "nativeApproval"))
        or not sha256_string(source.get("sourceSHA256")) or source.get("nativeAssignment") is not True
        or not all(isinstance(source.get(key), str) and source[key] for key in ("sourceID", "modelID"))
        or not all(rerun.get(key) is True for key in ("originalIntentRestored", "missingReferenceBlocked", "newRequestIsExplicit"))):
        return False, []
    fields = [item["field"] for item in inputs if item.get("kind") == "text" and isinstance(item.get("field"), dict)
        and item["field"].get("id") == "generation.media.intent"]
    intent = "A single red circle on a pale wall, static wide composition."
    if ([field.get("expected") for field in fields] != [intent, intent + " Soft side lighting."]
        or not all(field.get("id") == "generation.media.intent" and field.get("actual") == field["expected"]
                   and field.get("commitInput") == "Tab" and field.get("stage") == "commit-requested" for field in fields)):
        return False, []
    pointers = Counter(item.get("id") for item in inputs if item.get("kind") == "pointer" and isinstance(item.get("id"), str))
    models = [item for item in inputs if item.get("kind") == "menu" and item.get("id") == "generation.media.model"]
    valid = (all(pointers[key] == count for key, count in {
        "generation.media.type.Image": 1, "generation.media.type.Video": 1, "generation.media.review": 3,
        "generation.media.package.details": 2, "generation.media.package.copy-prompt": 1,
        "generation.media.package.copy-package": 2, "generation.media.discard": 1, "generation.media.approve": 1,
        "generation.media.pick.Source Video": 1, "library.pick." + source["sourceID"]: 1,
        "ai-edit.rerun": 2, "generation.media.new-request": 1}.items())
        and len(models) == 2 and all(item.get("closed") is True and isinstance(item.get("path"), list)
            and len(item["path"]) == 1 and isinstance(item["path"][0], str) and item["path"][0] for item in models)
        and len(images) == 11 and len(set(images)) == 11
        and manual_generation_extended_evidence(row, output)
        and all(any(name.endswith("-" + label + ".png") for name in images) for label in
                ("request-before-approval", "source-only-model-before-assignment", "missing-rerun-reference-visible"))
        and all((path := evidence_file(output, name)) is not None and path.stat().st_size > 1000
                and path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n") for name in images))
    return valid, images


def planning_evidence(rows, output, scale):
    plans = [row for row in rows if row.get("event") == "production-planning"]
    completions = [row for row in rows if row.get("event") == "completed" and row.get("case") == "planning"]
    if (len(plans) != 1 or len(completions) != 1
        or any(row.get("scale") != scale for row in plans + completions)
        or any(row.get("event") == "failed" for row in rows)):
        return False, []
    plan = plans[0]
    expected_images = [f"scale-{round(scale * 100)}-planning-{name}.png" for name in (
        "script", "missing-sketch", "sketches", "animatic", "approval-with-activity", "shot-planning")]
    valid = (plan.get("workflow") == "core.production.v2"
        and all(plan.get(key) is True for key in (
            "actualToolWriters", "nativeScriptEdit", "missingSketchBlocked", "nativeSketchAssignment",
            "animaticPlayedAndPaused", "activityDoesNotCoverApproval", "nativeApprovalAdvancedPhase", "shotIDsPreserved"))
        and plan.get("generatedSketchesTested") is False
        and plan.get("screenshots") == expected_images
        and all((output / name).is_file() and (output / name).stat().st_size > 1000
                and (output / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n") for name in expected_images))
    return valid, expected_images


MUSICVIDEO_V2_PHASES = ["project_init", "analysis", "brief", "production_design", "treatment", "script",
                       "storyboard", "shot_planning", "bible", "shotlist", "sanity", "frames", "render_review", "render"]
CORE_V2_PHASES = [phase for phase in MUSICVIDEO_V2_PHASES if phase != "analysis"]
V2_ARTIFACTS = ["Project", "Analysis", "Project Brief", "Production Design", "Treatment", "Script", "Storyboard",
                "Shot Planning", "Bible", "Shotlist", "Review", "Review", "Render Review", "Review"]


def evidence_file(directory, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute() or ".." in Path(name).parts:
        return None
    path = directory / name
    return path if path.is_file() and path.resolve().is_relative_to(directory.resolve()) else None


def valid_v2_gates(rows, kind):
    expected = MUSICVIDEO_V2_PHASES if kind == "musicvideo" else CORE_V2_PHASES[4:]
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows) or [row.get("phase") for row in rows] != expected:
        return False
    for index, row in enumerate(rows):
        next_phase = expected[index + 1] if index + 1 < len(expected) else "complete"
        if (row.get("nextPhase") != next_phase or row.get("approvedPersisted") is not True or row.get("handoffHidden") is not True
            or not all(sha256_string(row.get(key)) for key in ("gatesBeforeSHA256", "gatesAfterSHA256"))
            or row["gatesBeforeSHA256"] == row["gatesAfterSHA256"]):
            return False
        if kind == "musicvideo":
            if (row.get("artifactTitle") != V2_ARTIFACTS[index]
                or row.get("handoffPhase") != next_phase or row.get("surface") != "production"
                or row.get("selectedPhaseAfter") != ("render" if next_phase == "complete" else next_phase)
                or row.get("controlID") != "agent.gate.approve" or row.get("openControlID") != "agent.gate.open"
                or row.get("openedFromPhase") not in expected or row["openedFromPhase"] == row["phase"]
                or not all(row.get(key) is True for key in ("blockedBeforeApproval", "readyBeforeClick", "handoffHidden"))
                or not row.get("blockedReason") or not sha256_string(row.get("artifactSHA256"))
                or row.get("packagedInstructions") is not (next_phase != "complete")
                or (row.get("handoffInstructionsSHA256") is not None if next_phase == "complete"
                    else not sha256_string(row.get("handoffInstructionsSHA256")))
                or not isinstance(row.get("screenshots"), list) or len(row["screenshots"]) != 3):
                return False
            try:
                uuid.UUID(row.get("handoffTurnID", ""))
            except (ValueError, TypeError, AttributeError):
                return False
    return kind != "musicvideo" or len({row["handoffTurnID"] for row in rows}) == len(rows)


def frames_owner_evidence(rows, output, scale):
    from production_frames_owner_evidence import validate
    candidates = [row for row in rows if row.get("event") == "production-frames-owner"]
    complete = [row for row in rows if row.get("event") == "completed" and row.get("case") == "frames"]
    name = f"scale-{round(scale * 100)}-frames-owner"
    if (len(candidates) != 1 or len(complete) != 1 or complete[0].get("scale") != scale
        or candidates[0].get("scale") != scale or candidates[0].get("evidenceDirectory") != name
        or any(row.get("event") == "failed" for row in rows)):
        return False, []
    row = candidates[0]
    valid = validate(row, output / name, scale)
    return valid, [str(Path(name) / image) for image in row.get("nativeEvidence", {}).get("screenshots", [])] if valid else []


def owner_evidence(rows, output, scale, kind, performance=False):
    event = "production-v2-performance" if performance else "production-v2-owner"
    candidates = [row for row in rows if row.get("event") == event and row.get("workflow") == kind]
    case = "performance" if performance else "filmreview" if kind == "musicvideo" else "corefilmreview"
    complete = [row for row in rows if row.get("event") == "completed" and row.get("case") == case]
    if (len(candidates) != 1 or len(complete) != 1 or complete[0].get("scale") != scale
        or any(row.get("event") == "failed" for row in rows)):
        return False, []
    row = candidates[0]
    name = f"scale-{round(scale * 100)}-owner-v2-{kind}" + ("-performance" if performance else "")
    directory = output / name
    from production_frames_owner_evidence import validate_auto_sketches
    if not validate_auto_sketches(row.get("nativeEvidence", {}), directory):
        return False, []
    if kind == "musicvideo":
        from pattern_recommendations_evidence import validate as validate_patterns
        if row.get("patternEvidenceDirectory") != "patterns":
            return False, []
        try:
            validate_patterns(directory / "patterns")
        except (KeyError, TypeError, ValueError, OSError, AttributeError):
            return False, []
    required = ("nativeScriptEdit", "nativeMultipleMoments", "nativeStoryboardUndoRedo", "nativeMomentAssignments",
                "nativeAnimaticMomentChange", "nativeShotSourceAndRange", "nativeShotUndoRedo", "nativeReferences",
                "nativePreRenderReview", "realCompilerAndHTTPGeneration", "nativeTakeReview", "nativeRangeReviewAndInsertUndo",
                "savedAndReopened", "allPhasesApproved")
    if (row.get("scale") != scale or row.get("evidenceDirectory") != name
        or row.get("phases") != (MUSICVIDEO_V2_PHASES if kind == "musicvideo" else CORE_V2_PHASES)
        or row.get("viewport") != {"width": 960, "height": 640, "textScale": scale}
        or row.get("executionFixture") != "mixed_generated_imported"
        or not all(row.get(key) is True for key in required)
        or not valid_v2_gates(row.get("nativeGateApprovals"), kind)):
        return False, []
    canonical = row.get("canonicalSHA256", {})
    delivery = row.get("delivery", {})
    decoded = delivery.get("decodedMedia", {})
    native = row.get("nativeEvidence", {})
    interactions = native.get("interactions", [])
    if (not canonical or not all(sha256_string(value) for value in canonical.values())
        or not all(delivery.get(key) is True for key in ("nativeAssembly", "nativeFullFilmReview", "nativeStyleReview",
            "nativeExportWorkspace", "nativeSaveDestination", "posterSelectedRemovedRestored", "movieAndPosterPublished", "actualOutputQC", "changedOutputRejected"))
        or not all(sha256_string(delivery.get(key)) for key in ("reviewFilmSHA256", "styleFingerprint", "outputSHA256", "posterSHA256"))
        or delivery.get("styleFindingCount", 0) < 1 or not delivery.get("reviewedBoundaries")
        or decoded.get("verifiedShots", 0) < 2 or decoded.get("verifiedFrames") != 3 * decoded.get("verifiedShots", 0)
        or decoded.get("verifiedAudioClips", 0) < 1 or decoded.get("decodedAudioSamples", 0) < 48_000
        or decoded.get("audioCorrelation", 0) < 0.98 or decoded.get("audioRMS", 0) <= 0.001
        or not isinstance(interactions, list) or not all(isinstance(value, dict) for value in interactions)):
        return False, []
    pointers = {item.get("id") for item in interactions if item.get("kind") == "pointer"}
    required_controls = {"script.scene.apply", "storyboard.edit.apply", "storyboard.undo", "storyboard.redo",
                         "storyboard.native-sketch.confirm", "render-review.record-native", "generation-batch.approve",
                         "take.record-pass", "take.save", "take.use", "take.range.play", "take.range.save", "take.range.add",
                         "take.repair.save", "take.repair.continue", "production.assembly.keep", "production.assembly.rebuild",
                         "production.assembly.cancel-rebuild", "production.assembly.confirm-rebuild",
                         "production.assembly.build", "sequence.build", "sequence.play", "sequence.pause", "sequence.whole",
                         "sequence.inspect-boundary", "sequence.adjacent", "sequence.record", "style.begin", "style.record",
                         "export.start", "export.artwork.frame", "export.artwork.remove", "export.qc.recheck"}
    states = {item.get("label"): item.get("evidence", {}) for item in interactions if item.get("kind") == "verified-state"}
    expected_states = {"native Script revision", "multiple moments with native Undo and Redo", "native shot reference",
                       "native sketch assignment", "two moments within one shot", "native source range", "native Shot Planning Undo and Redo",
                       "reference-only Frames contract", "native pre-render inspection", "inspected direction bound to submission", "real HTTP generation approved natively",
                       "native take repair stop and rescue", "native assembly drift keep cancel rebuild",
                       "native whole-take selection", "native reviewed range selected and inserted", "native production assembly",
                       "complete native film playback", "complete native take playback", "complete compiled direction inspected",
                       "native timeline style", "native delivery byte changes rejected", "actual exported movie and poster"}
    if (not required_controls.issubset(pointers) or not expected_states.issubset(states)
        or states["reference-only Frames contract"].get("generatedFrameClaim") is not False
        or states["reference-only Frames contract"].get("requiredFrameRoles") != []
        or states["native reviewed range selected and inserted"].get("insertUndoPreservedSelection") is not True
        or states["native whole-take selection"].get("passes") != ["identity", "continuity", "timing", "camera", "audio", "style"]
        or states["native whole-take selection"].get("rejectedSelectionBlocked") is not True
        or states["complete native take playback"].get("input") != "nativePointer"
        or not sha256_string(states["inspected direction bound to submission"].get("promptSHA256"))
        or states["inspected direction bound to submission"].get("promptSHA256") != states["complete compiled direction inspected"].get("textSHA256")
        or not sha256_string(states["inspected direction bound to submission"].get("reviewFingerprint"))
        or states["inspected direction bound to submission"].get("reviewFingerprint") != states["native pre-render inspection"].get("fingerprint")
        or not any(item.get("kind") == "save-panel" and item.get("exactURLVerified") is True for item in interactions)
        or not any(item.get("kind") == "visible-group" and item.get("frames") for item in interactions)):
        return False, []
    repair, drift = states["native take repair stop and rescue"], states["native assembly drift keep cancel rebuild"]
    if (not all(repair.get(key) is True for key in ("invalidLimitBlocked", "staleContinuationBlocked", "actualGenerationGuardBlocked"))
        or not all(sha256_string(repair.get(key)) for key in ("stopSHA256", "rescueSHA256", "reviewSHA256"))
        or repair["stopSHA256"] == repair["rescueSHA256"]
        or any(type(repair.get(key)) is not int for key in ("providerRequestsBefore", "providerRequestsAfter", "spendEventsBefore", "spendEventsAfter"))
        or repair["providerRequestsBefore"] != repair["providerRequestsAfter"] or repair["spendEventsBefore"] != repair["spendEventsAfter"]
        or not all(drift.get(key) is True for key in ("keepPreservedTimeline", "cancelPreservedTimeline", "rebuildRestoredPlan", "gatesUnchanged"))
        or drift.get("editedOpacity") != 0.5 or not drift.get("editedClipID")
        or len(set(drift.get("rebuiltClipIDs", []))) < 2):
        return False, []
    for key in ("owner-v2-film.mp4", "owner-v2-film.poster.png", "owner-v2-film-review.json", "owner-v2-delivery.json", native.get("progress")):
        if evidence_file(directory, key) is None:
            return False, []
    movie = evidence_file(directory, delivery.get("movie"))
    if movie is None or hashlib.sha256(movie.read_bytes()).hexdigest() != delivery["outputSHA256"]:
        return False, []
    poster = directory / "owner-v2-film.poster.png"
    if hashlib.sha256(poster.read_bytes()).hexdigest() != delivery["posterSHA256"]:
        return False, []
    try:
        attempt = json.loads((directory / "owner-v2-delivery.json").read_text())
        review_path = directory / "owner-v2-film-review.json"
        review = json.loads(review_path.read_text())
        if (attempt.get("schema") != "delivery-attempt/v1" or attempt.get("status") != "succeeded"
            or attempt.get("output_sha256") != delivery["outputSHA256"]
            or attempt.get("output_byte_count") != movie.stat().st_size
            or attempt.get("probe_qc", {}).get("passed") is not True
            or attempt.get("sequence_review_sha256") != hashlib.sha256(review_path.read_bytes()).hexdigest()
            or attempt.get("finished_timeline_sha256") != review.get("timeline", {}).get("sha256")
            or review.get("schema") != "production-sequence-review/v2"
            or review.get("wholePlaybackCompleted") is not True or review.get("adjacentPairCompleted") is not True
            or review.get("cutFrames") != delivery["reviewedBoundaries"]
            or review.get("reel", {}).get("sha256") != delivery["reviewFilmSHA256"]
            or canonical.get("reviews/sequence/current.v2.json") != hashlib.sha256(review_path.read_bytes()).hexdigest()
            or len(review.get("findings", [])) != len(delivery["reviewedBoundaries"]) + 1):
            return False, []
    except (OSError, ValueError, TypeError, AttributeError):
        return False, []
    if kind == "musicvideo":
        cover = row.get("cover", {})
        if (not all(cover.get(key) is True for key in ("nativeCoverEntry", "nativeFormatSubjectModel", "nativeCoverSpendApproval",
                "actualCoverDownloadedAndPreviewed", "nativeKeepDecision", "typographyExplicitlyDeclined", "pipelineUnchanged"))
            or not sha256_string(cover.get("sha256")) or "native optional cover completed" not in states
            or not {"export.cover.start", "agent.dialog.confirm"}.issubset(pointers)
            or not {"native additional Music Video audio", "native Music Video audio preserved by assembly", "original Music Video song occurs once", "actual Music Video visual arc compiled"}.issubset(states)
            or states.get("actual Music Video visual arc compiled", {}).get("providerPromptMatched") is not True
            or not all(states.get("actual Music Video visual arc compiled", {}).get(key) for key in ("sectionID", "visualFunction", "changeExplanation"))
            or not sha256_string(states.get("actual Music Video visual arc compiled", {}).get("compiledSHA256"))
            or decoded.get("verifiedAudioClips", 0) < 2):
            return False, []
    images = native.get("screenshots", []) + [image for gate in row["nativeGateApprovals"] for image in gate.get("screenshots", [])]
    if not images or len(images) != len(set(images)):
        return False, []
    for image in images:
        path = evidence_file(directory, image)
        if path is None or path.stat().st_size <= 1000 or not path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
            return False, []
    return True, [str(Path(name) / image) for image in images]


def filmreview_evidence(rows, output, scale):
    return owner_evidence(rows, output, scale, "musicvideo")


def corefilmreview_evidence(rows, output, scale):
    return owner_evidence(rows, output, scale, "core")


def performance_evidence(rows, output, scale):
    from production_performance_evidence import validate
    valid, images = owner_evidence(rows, output, scale, "musicvideo", performance=True)
    if not valid:
        return False, []
    row = next(row for row in rows if row.get("event") == "production-v2-performance")
    return (True, images) if validate(row, output / row["evidenceDirectory"], evidence_file, sha256_string) else (False, [])


def activity_evidence(rows, output, scale):
    activity = [row for row in rows if row.get("event") == "production-activity"]
    if len(activity) != 1:
        return False, []
    row = activity[0]
    decisions = row.get("decisions", [])
    if (row.get("scale") != scale
        or not all(row.get(key) is True for key in ("inspectorRestored", "preferencesPreserved", "workspaceTransitions"))
        or row.get("minimumViewport", {}).get("width") != 960
        or row.get("minimumViewport", {}).get("height") != 640
        or [item.get("operation") for item in decisions] != ["decline", "approve", "rewind"]
        or [item.get("phase") for item in decisions] != ["brief", "brief", "storyboard"]):
        return False, []

    def rect(value):
        if not isinstance(value, dict):
            return None
        values = [value.get(key) for key in ("x", "y", "width", "height")]
        if any(type(v) not in (int, float) or not math.isfinite(v) for v in values):
            return None
        x, y, width, height = values
        return values if x >= 0 and y >= 0 and width > 0 and height > 0 and x + width <= 960 and y + height <= 640 else None

    for item in decisions:
        if (not all(item.get(key) is True for key in ("activityStayedOpen", "disjointControls", "nativeClick"))
            or item.get("controlID") != ("agent.gate.decline" if item["operation"] == "decline" else "agent.gate.approve")
            or not all(sha256_string(item.get(key)) for key in ("gatesBeforeSHA256", "gatesAfterSHA256"))
            or (item["gatesBeforeSHA256"] == item["gatesAfterSHA256"]) != (item["operation"] == "decline")):
            return False, []
        area = rect(item.get("activityFrame"))
        controls = [rect(item.get(key)) for key in ("primaryFrame", "declineFrame")]
        if area is None or any(control is None for control in controls):
            return False, []
        ax, ay, aw, ah = area
        if any(ax < x + w and x < ax + aw and ay < y + h and y < ay + ah for x, y, w, h in controls):
            return False, []
    images = row.get("screenshots", [])
    valid = len(images) == 3 and len(set(images)) == 3 and all(
        isinstance(name, str) and Path(name).name == name and (output / name).is_file()
        and (output / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n") for name in images
    )
    return valid, images


def run_scale(executable, output, scale, scope="all"):
    if scope not in ACCEPTANCE_SCOPES:
        raise ValueError(f"Unknown acceptance scope: {scope}")
    label = str(round(scale * 100))
    log_path = output / f"scale-{label}.log"
    started = time.monotonic()
    case_results = []
    output_chunks = []
    for scenario in ACCEPTANCE_SCOPES[scope]:
        case_started = time.monotonic()
        try:
            # AppKit must not reopen documents left by an earlier acceptance process.
            if scenario == "generationrecovery":
                case_output, code = run_generation_recovery(executable, output, scale)
            else:
                process = subprocess.run(
                    [executable, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
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
                    timeout=600 if scenario in ("frames", "filmreview", "corefilmreview", "performance") else 360 if scenario in ("manualvideomodes", "sourceoperations", "appnle", "genericnle", "animationaudio", "manualgeneration", "textcaptions") else 180 if scenario in ("mediabrowser", "planning", "medialibrary") else 90,
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

    if scope == "activity":
        valid, screenshots = activity_evidence(rows, output, scale)
        completion = [row for row in rows if row.get("event") == "completed"]
        restored = [row for row in rows if row.get("event") == "started"]
        utility = [row for row in rows if row.get("event") == "agent-activity"]
        valid = (valid and return_code == 0 and len(completion) == 1
                 and completion[0].get("case") == "storyboard" and completion[0].get("scale") == scale
                 and len(restored) == 1 and restored[0].get("restorationIgnored") is True
                 and len(utility) == 1 and utility[0].get("complete") is True)
        return {"completed": valid, "elapsedSeconds": time.monotonic() - started, "events": rows,
                "exitCode": return_code, "cases": case_results, "reason": "completed" if valid else "invalid-evidence",
                "scale": scale, "scope": scope, "log": log_path.name, "screenshots": screenshots}

    if scope in ("frames", "manualvideomodes", "sourceoperations", "mediabrowser", "appnle", "filmreview", "corefilmreview", "planning", "genericnle", "medialibrary", "animationaudio", "manualgeneration", "performance", "textcaptions", "generationrecovery"):
        validator = {"frames": frames_owner_evidence, "manualvideomodes": manual_video_modes_evidence, "sourceoperations": source_operations_evidence, "mediabrowser": media_browser_owner_evidence, "appnle": app_nle_owner_evidence, "planning": planning_evidence, "filmreview": filmreview_evidence, "genericnle": generic_nle_evidence, "corefilmreview": corefilmreview_evidence, "medialibrary": media_library_evidence, "animationaudio": animation_audio_evidence, "manualgeneration": manual_generation_evidence, "performance": performance_evidence, "textcaptions": text_captions_evidence, "generationrecovery": generation_recovery_evidence}[scope]
        valid_evidence, screenshots = validator(rows, output, scale)
        valid = return_code == 0 and valid_evidence
        return {
            "completed": valid,
            "elapsedSeconds": time.monotonic() - started,
            "events": rows,
            "exitCode": return_code,
            "cases": case_results,
            "reason": "scope-completed" if valid else "invalid-evidence",
            "scale": scale,
            "scope": scope,
            "screenshots": screenshots,
        }

    workspace_rows = [row for row in rows if row.get("event") == "workspace"]
    workspaces = {row.get("workspace") for row in workspace_rows}
    completed = sum(row.get("event") == "completed" for row in rows) == len(ALL_CASES) + 1
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
    planning = [row for row in rows if row.get("event") == "production-planning"]
    production = [row for row in rows if row.get("event") == "production-workbench"]
    agent_activity = [row for row in rows if row.get("event") == "agent-activity"]
    film_review = [row for row in rows if row.get("event") == "production-v2-owner"]
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
        for row in analysis + provenance + musicvideo + host_states + storyboard + production + agent_activity + planning
        for name in row.get("screenshots", [])
    ]
    screenshots += [
        card.get("screenshot")
        for row in production
        for card in row.get("storyboardCards", [])
        if isinstance(card, dict)
    ]
    native_images = filmreview_evidence(rows, output, scale)[1] + corefilmreview_evidence(rows, output, scale)[1]
    native_images += generic_nle_evidence(rows, output, scale)[1] + media_library_evidence(rows, output, scale)[1]
    native_images += animation_audio_evidence(rows, output, scale)[1] + manual_generation_evidence(rows, output, scale)[1]
    native_images += performance_evidence(rows, output, scale)[1] + text_captions_evidence(rows, output, scale)[1]
    native_images += generation_recovery_evidence(rows, output, scale)[1]
    native_images += app_nle_owner_evidence(rows, output, scale)[1]
    native_images += media_browser_owner_evidence(rows, output, scale)[1]
    native_images += source_operations_evidence(rows, output, scale)[1]
    native_images += manual_video_modes_evidence(rows, output, scale)[1]
    native_images += frames_owner_evidence(rows, output, scale)[1]
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
        and musicvideo[0].get("phases") == MUSICVIDEO_V2_PHASES
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
        and planning_evidence(rows, output, scale)[0]
        and generic_nle_evidence(rows, output, scale)[0]
        and len(production) == 1
        and valid_production_workbench(production[0])
        and activity_evidence(rows, output, scale)[0]
        and len(agent_activity) == 1
        and agent_activity[0].get("complete") is True
        and len(agent_activity[0].get("screenshots", [])) == 3
        and len(film_review) == 2
        and filmreview_evidence(rows, output, scale)[0]
        and corefilmreview_evidence(rows, output, scale)[0]
        and media_library_evidence(rows, output, scale)[0]
        and animation_audio_evidence(rows, output, scale)[0]
        and manual_generation_evidence(rows, output, scale)[0]
        and performance_evidence(rows, output, scale)[0]
        and text_captions_evidence(rows, output, scale)[0]
        and app_nle_owner_evidence(rows, output, scale)[0]
        and media_browser_owner_evidence(rows, output, scale)[0]
        and source_operations_evidence(rows, output, scale)[0]
        and manual_video_modes_evidence(rows, output, scale)[0]
        and frames_owner_evidence(rows, output, scale)[0]
        and generation_recovery_evidence(rows, output, scale)[0]
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
        == 40 + len(EXPECTED_INSPECTOR_CASES) + len(EXPECTED_KEYFRAME_LANES) + len(native_images)
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
        "scope": scope,
        "screenshots": screenshots,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    parser.add_argument("output")
    parser.add_argument("--scope", choices=ACCEPTANCE_SCOPES, default="all")
    args = parser.parse_args(argv)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    results = [run_scale(args.executable, output, scale, args.scope) for scale in SCALES]
    completed = all(item["completed"] for item in results)
    result = {
        "completed": completed,
        "scope": args.scope,
        "selectedCases": list(ACCEPTANCE_SCOPES[args.scope]),
        "unexecutedCases": [case for case in ALL_CASES if case not in ACCEPTANCE_SCOPES[args.scope]],
        "fullWorkspaceAcceptance": args.scope == "all" and completed,
        "runs": results,
    }
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True))
    print(json.dumps(result, sort_keys=True))
    return 0 if result["completed"] else 1


if __name__ == "__main__":
    sys.exit(main())
