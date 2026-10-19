"""Independent native case validation; no app execution or synthetic success records."""
from pathlib import Path
import json
import workspace_ui_acceptance as checks


LEGACY_CASES = {"workspace", "cards", "analysis", "provenance", "musicvideo", "hoststates", "storyboard"}


def validate_case(case, rows, output, scale):
    if case not in checks.ALL_CASES or scale not in checks.SCALES:
        return False, []
    completed = [row for row in rows if row.get("event") == "completed"]
    expected = 3 if case == "generationrecovery" else 1
    if (len(completed) != expected or any(row.get("scale") != scale for row in completed)
        or any(row.get("case", "workspace") != case for row in completed)
        or any(row.get("event") == "failed" for row in rows)):
        return False, []
    try:
        if case in LEGACY_CASES:
            valid, images = legacy_case(case, rows, output, scale)
        else:
            names = {
                "filmflow": "filmflow_owner_evidence",
                "ledger": "ledger_owner_evidence", "captionrevision": "caption_revision_evidence",
                "exportformats": "export_formats_evidence", "exportrecovery": "export_recovery_evidence",
                "layeredtimeline": "layered_timeline_evidence", "aienhanced": "ai_enhanced_owner_evidence",
                "framecontinuation": "frame_continuation_owner_evidence", "nativeextension": "native_extension_owner_evidence",
                "timelineediting": "timeline_editing_evidence", "chronologynegative": "chronology_negative_evidence",
                "sanitynegative": "sanity_negative_evidence", "animatedstill": "animated_still_evidence",
                "frames": "frames_owner_evidence", "manualvideomodes": "manual_video_modes_evidence",
                "sourceoperations": "source_operations_evidence", "mediabrowser": "media_browser_owner_evidence",
                "appnle": "app_nle_owner_evidence", "filmreview": "filmreview_evidence",
                "corefilmreview": "corefilmreview_evidence", "planning": "planning_evidence",
                "genericnle": "generic_nle_evidence", "medialibrary": "media_library_evidence",
                "animationaudio": "animation_audio_evidence", "manualgeneration": "manual_generation_evidence",
                "performance": "performance_evidence", "performanceroles": "performance_role_evidence", "textcaptions": "text_captions_evidence",
                "generationrecovery": "generation_recovery_evidence",
            }
            valid, images = getattr(checks, names[case])(rows, output, scale)
        return valid and all(valid_image(output, name) for name in images), images
    except (KeyError, IndexError, TypeError, ValueError, OSError, AttributeError, OverflowError):
        return False, []


def valid_image(root, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute() or ".." in Path(name).parts:
        return False
    path = root / name
    return (path.resolve().is_relative_to(root.resolve()) and not path.is_symlink()
            and path.is_file() and path.stat().st_size > 1000
            and path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))


def legacy_case(case, rows, output, scale):
    def events(name):
        return [row for row in rows if row.get("event") == name]
    def one(name):
        values = events(name)
        if len(values) != 1:
            raise ValueError("Expected one " + name)
        return values[0]
    def flags(row, names):
        return all(row.get(key) is True for key in names)
    images = []
    if case == "workspace":
        workspace = events("workspace"); hidden = one("panels-hidden"); narrow = one("narrow-production")
        library = one("media-library"); keyboard = one("text-keyboard-isolation"); invariant = one("invariants")
        inspector = events("inspector"); keyframes = [row for row in inspector if row.get("keyframes") == "open"]
        images = [row.get("screenshot") for row in workspace + [hidden, narrow, library]]
        images += [row.get("screenshot") for row in inspector if row.get("keyframes") != "open"]
        images += [layout.get("screenshot") for row in keyframes for layout in row.get("laneLayoutEvidence", [])]
        valid = ({row.get("workspace") for row in workspace} == checks.EXPECTED_WORKSPACES
            and len(workspace) == len(checks.EXPECTED_WORKSPACES)
            and set(narrow.get("workbenchControls", [])) == {"production.sidebar", "production.status"}
            and library.get("assetCount") == 500 and set(library.get("types", [])) == {"image", "audio", "document"}
            and flags(library, ("nestedFolderOpened", "workspaceStatePreserved"))
            and library.get("searchSelectedAsset") == "fixture-498"
            and flags(keyboard, ("spaceEditsText", "deleteEditsText", "selectAllTargetsText", "timelineUnchanged",
                "mediaUnchanged", "selectionUnchanged", "playbackUnchanged"))
            and {(row.get("family"), row.get("keyframes")) for row in inspector} == checks.EXPECTED_INSPECTOR_CASES
            and len(inspector) == len(checks.EXPECTED_INSPECTOR_CASES)
            and len(keyframes) == len(checks.EXPECTED_KEYFRAME_LANES)
            and all(checks.valid_keyframe_lane_evidence(row) for row in keyframes)
            and flags(invariant, ("liveStateUnchanged", "projectBytesUnchanged", "undoUnchanged", "workingCopyUnchanged"))
            and len(images) == 8 + len(checks.EXPECTED_INSPECTOR_CASES) + len(checks.EXPECTED_KEYFRAME_LANES))
    elif case == "cards":
        row = one("project-cards"); images = [row.get("screenshot")]
        valid = (abs(row.get("width", 0) - 213) <= 1 and abs(row.get("height", 0) - 170.4) <= 1
                 and flags(row, ("openVerified", "unavailableDisabled", "unavailableContentSeparated")))
    elif case == "analysis":
        row = one("analysis-interaction"); images = row.get("screenshots", [])
        extra_valid, extra_images = checks.analysis_remeasurement_evidence(rows, output, scale)
        valid = (row.get("selectedStart") == 6 and row.get("playedPosition", 0) > 6.1 and row.get("zoom") == 2
                 and flags(row, ("fitRestored", "changedSourceDisabled", "savedProjectUnchanged"))
                 and len(images) == 3 and extra_valid)
        images = images + extra_images
    elif case == "provenance":
        row = one("asset-provenance"); images = row.get("screenshots", [])
        valid = (row.get("families") == ["imported", "generated", "enhanced", "offline"]
                 and flags(row, ("syntheticReceipts", "exactOriginRendered", "originalSelected", "offlineActionsCorrect",
                     "projectUnchanged", "legacyNameReadable")) and row.get("viewportWidth") == 440
                 and row.get("viewportHeight") == 650 and len(images) == 7)
    elif case == "musicvideo":
        row = one("musicvideo-startup"); images = row.get("screenshots", [])
        valid = (row.get("phases") == checks.MUSICVIDEO_V2_PHASES and len(images) == 3
                 and flags(row, ("externalPackLoaded", "exactBinding", "libraryDidNotAssignTrack", "viewingDidNotAdvance",
                     "disabledApprovalDidNotMutate", "intakeCheckpointSettled", "artifactTabsExcludeWorkflowControls",
                     "pipelineRestored", "tasksReachable")))
    elif case == "hoststates":
        row = one("host-state-history"); images = list(row.get("screenshots", []))
        valid = (len(images) == 1 and flags(row, ("supersededRequestHasNoAction", "resetApprovalsMarked",
                 "revisionNamesResetApprovals", "rejectedFirstWriteNotUnverified")))
        if [row.get("event") for row in rows if row.get("event") in {
                "host-state-history", "agent-structured-owner", "agent-review-child-owner", "completed"}] != [
                "host-state-history", "agent-structured-owner", "agent-review-child-owner", "completed"]:
            return False, []
        structured = one("agent-structured-owner")
        directory = "scale-" + str(round(scale * 100)) + "-agent-structured"
        if structured.get("evidenceDirectory") != directory:
            return False, []
        from agent_structured_results_evidence import validate_owner
        verified = validate_owner(output / directory, scale)
        recorded = json.loads((output / directory / "agent-structured-result.json").read_text())
        if {key: value for key, value in structured.items() if key not in {"event", "os", "evidenceDirectory"}} != recorded:
            return False, []
        images += [directory + "/" + name for name in verified["images"]]
        children = one("agent-review-child-owner")
        if (type(children.get("scale")) not in (int, float)
                or any(type(backend.get("scale")) not in (int, float) for backend in children.get("backends", []))):
            return False, []
        directory = "scale-" + str(round(scale * 100)) + "-review-children"
        if children.get("evidenceDirectory") != directory:
            return False, []
        from review_child_owner_evidence import validate as validate_children
        verified = validate_children(output / directory, scale)
        if {key: value for key, value in children.items() if key not in {"event", "os", "evidenceDirectory"}} != verified:
            return False, []
        images += [directory + "/" + backend["backend"] + "/" + name
                   for backend in verified["backends"] for name in backend["native"]["screenshots"]]
    else:
        row = one("storyboard-review"); production = one("production-workbench"); utility = one("agent-activity")
        cards = production.get("storyboardCards", [])
        activity_valid, activity_images = checks.activity_evidence(rows, output, scale)
        valid = (row.get("cardDestination") == "Storyboard" and row.get("pipelineDestination") == "Storyboard"
            and flags(row, ("openedTabWithoutModal", "tabRoundTrip", "pipelineActionSameTarget", "approvalControlsUsable",
                "shownBytesMatchApproval", "changeMarked", "declinedFromStoryboard", "gatesUnchanged", "savedProjectUnchanged"))
            and len(row.get("screenshots", [])) == 2 and checks.valid_production_workbench(production)
            and len(cards) == 2 and utility.get("complete") is True and len(utility.get("screenshots", [])) == 3
            and activity_valid)
        images = (row.get("screenshots", []) + production.get("screenshots", []) + utility.get("screenshots", [])
                  + [card.get("screenshot") for card in cards] + activity_images)
    return valid, images
