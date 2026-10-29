import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from workspace_ui_acceptance import owner_evidence


PHASES = ["project_init", "analysis", "brief", "production_design", "treatment", "script", "storyboard",
          "shot_planning", "bible", "shotlist", "sanity", "frames", "render_review", "render"]
TITLES = ["Project", "Analysis", "Project Brief", "Production Design", "Treatment", "Script", "Storyboard",
          "Shot Planning", "Bible", "Shotlist", "Review", "Review", "Render Review", "Review"]


def owner_fixture(output, scale=1.0, kind="musicvideo"):
    name = f"scale-{round(scale * 100)}-owner-v2-{kind}"
    directory = output / name
    directory.mkdir(exist_ok=True)
    gates = []
    phases = PHASES if kind == "musicvideo" else [phase for phase in PHASES if phase != "analysis"]
    native_phases = phases if kind == "musicvideo" else phases[4:]
    for index, phase in enumerate(native_phases):
        following = native_phases[index + 1] if index + 1 < len(native_phases) else "complete"
        gates.append({"phase": phase, "nextPhase": following, "approvedPersisted": True, "handoffHidden": True,
            "gatesBeforeSHA256": "b" * 64, "gatesAfterSHA256": "c" * 64,
            "artifactTitle": TITLES[PHASES.index(phase)], "handoffPhase": following, "surface": "production",
            "selectedPhaseAfter": "render" if following == "complete" else following,
            "controlID": "agent.gate.approve", "openControlID": "agent.gate.open",
            "openedFromPhase": "brief" if phase == "project_init" else "project_init",
            "blockedBeforeApproval": True, "readyBeforeClick": True, "blockedReason": "Required artifact is absent",
            "artifactSHA256": "a" * 64, "packagedInstructions": following != "complete",
            "handoffInstructionsSHA256": None if following == "complete" else "d" * 64,
            "handoffTurnID": f"00000000-0000-4000-8000-{index:012d}",
            "screenshots": [phase + suffix + ".png" for suffix in ("-blocked", "-ready", "-approved")]})
    controls = ["script.scene.apply", "storyboard.edit.apply", "storyboard.undo", "storyboard.redo",
                "storyboard.native-sketch.confirm", "render-review.record-native", "generation-batch.approve",
                "take.record-pass", "take.save", "take.use", "take.range.play", "take.range.save", "take.range.add",
                "take.repair.save", "take.repair.continue", "production.assembly.keep", "production.assembly.rebuild",
                "production.assembly.cancel-rebuild", "production.assembly.confirm-rebuild",
                "production.assembly.build", "sequence.build", "sequence.play", "sequence.pause", "sequence.inspect-boundary",
                "sequence.whole", "sequence.adjacent", "sequence.record", "style.begin", "style.record",
                "export.artwork.frame", "export.artwork.remove", "export.start", "export.qc.recheck",
                "export.cover.start", "agent.dialog.confirm"]
    labels = ["native Script revision", "multiple moments with native Undo and Redo", "native sketch assignment",
              "two moments within one shot", "native source range", "native Shot Planning Undo and Redo", "native shot reference",
              "reference-only Frames contract", "native pre-render inspection", "inspected direction bound to submission", "real HTTP generation approved natively",
              "native take repair stop and rescue", "native assembly drift keep cancel rebuild",
              "native whole-take selection", "native reviewed range selected and inserted", "native production assembly",
              "complete native film playback", "complete native take playback", "complete compiled direction inspected",
              "native timeline style", "native delivery byte changes rejected", "actual exported movie and poster",
              "native optional cover completed", "native additional Music Video audio", "native Music Video audio preserved by assembly",
              "original Music Video song occurs once", "actual Music Video visual arc compiled"]
    states = {label: {} for label in labels}
    states["reference-only Frames contract"] = {"generatedFrameClaim": False, "requiredFrameRoles": []}
    states["native reviewed range selected and inserted"] = {"insertUndoPreservedSelection": True}
    states["native whole-take selection"] = {"passes": ["identity", "continuity", "timing", "camera", "audio", "style"],
                                            "rejectedSelectionBlocked": True}
    states["actual Music Video visual arc compiled"] = {"sectionID": "section1", "visualFunction": "Show the actual planned shapes",
        "changeExplanation": "The approved cut changes shape", "compiledSHA256": "c" * 64, "providerPromptMatched": True}
    states["complete native take playback"] = {"input": "nativePointer"}
    states["complete compiled direction inspected"] = {"textSHA256": "c" * 64}
    states["native pre-render inspection"] = {"fingerprint": "d" * 64}
    states["inspected direction bound to submission"] = {"promptSHA256": "c" * 64, "reviewFingerprint": "d" * 64}
    states["native take repair stop and rescue"] = {"invalidLimitBlocked": True, "staleContinuationBlocked": True,
        "actualGenerationGuardBlocked": True, "stopSHA256": "a" * 64, "rescueSHA256": "b" * 64, "reviewSHA256": "c" * 64,
        "providerRequestsBefore": 4, "providerRequestsAfter": 4, "spendEventsBefore": 1, "spendEventsAfter": 1}
    states["native assembly drift keep cancel rebuild"] = {"keepPreservedTimeline": True, "cancelPreservedTimeline": True,
        "rebuildRestoredPlan": True, "gatesUnchanged": True, "editedOpacity": 0.5, "editedClipID": "clip1", "rebuiltClipIDs": ["clip2", "clip3"]}
    interactions = [{"kind": "pointer", "id": key} for key in controls]
    interactions += [{"kind": "verified-state", "label": key, "evidence": value} for key, value in states.items()]
    interactions += [{"kind": "save-panel", "exactURLVerified": True}, {"kind": "visible-group", "frames": [[0, 0, 100, 50]]}]
    images = ["actual-window.png"]
    for image in images + [image for gate in gates for image in gate["screenshots"]]:
        (directory / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"unit-image" * 200)
    movie = b"unit-test-movie" * 200
    poster = b"\x89PNG\r\n\x1a\n" + b"unit-poster" * 200
    (directory / "owner-v2-film.mp4").write_bytes(movie)
    (directory / "owner-v2-film.poster.png").write_bytes(poster)
    review = {"schema": "production-sequence-review/v2", "timeline": {"sha256": "e" * 64},
              "reel": {"sha256": "f" * 64}, "wholePlaybackCompleted": True, "adjacentPairCompleted": True,
              "cutFrames": [120], "findings": [{"scope": "wholePlayback"}, {"scope": "adjacentPair"}]}
    review_bytes = json.dumps(review).encode()
    (directory / "owner-v2-film-review.json").write_bytes(review_bytes)
    receipt = {"schema": "delivery-attempt/v1", "status": "succeeded", "output_sha256": hashlib.sha256(movie).hexdigest(),
               "output_byte_count": len(movie), "probe_qc": {"passed": True}, "finished_timeline_sha256": "e" * 64,
               "sequence_review_sha256": hashlib.sha256(review_bytes).hexdigest()}
    (directory / "owner-v2-delivery.json").write_text(json.dumps(receipt))
    (directory / "progress.json").write_text(json.dumps({"interactions": interactions}))
    delivery = {key: True for key in ("nativeAssembly", "nativeFullFilmReview", "nativeStyleReview", "nativeExportWorkspace",
        "nativeSaveDestination", "posterSelectedRemovedRestored", "movieAndPosterPublished", "actualOutputQC", "changedOutputRejected")}
    delivery.update({"reviewFilmSHA256": "f" * 64, "styleFingerprint": "b" * 64, "outputSHA256": hashlib.sha256(movie).hexdigest(),
                     "posterSHA256": hashlib.sha256(poster).hexdigest(), "styleFindingCount": 1, "reviewedBoundaries": [120],
                     "movie": "owner-v2-film.mp4", "decodedMedia": {"verifiedShots": 2, "verifiedFrames": 6, "verifiedAudioClips": 2,
                         "decodedAudioSamples": 384000, "audioCorrelation": 0.999, "audioRMS": 0.12}})
    cover = {key: True for key in ("nativeCoverEntry", "nativeFormatSubjectModel", "nativeCoverSpendApproval",
             "actualCoverDownloadedAndPreviewed", "nativeKeepDecision", "typographyExplicitlyDeclined", "pipelineUnchanged")}
    cover["sha256"] = "a" * 64
    row = {key: True for key in ("nativeScriptEdit", "nativeMultipleMoments", "nativeStoryboardUndoRedo", "nativeMomentAssignments",
        "nativeAnimaticMomentChange", "nativeShotSourceAndRange", "nativeShotUndoRedo", "nativeReferences", "nativePreRenderReview",
        "realCompilerAndHTTPGeneration", "nativeTakeReview", "nativeRangeReviewAndInsertUndo", "savedAndReopened", "allPhasesApproved")}
    row.update({"event": "production-v2-owner", "workflow": kind, "scale": scale, "evidenceDirectory": name,
                "executionFixture": "mixed_generated_imported", "phases": phases, "viewport": {"width": 960, "height": 640, "textScale": scale},
                "nativeGateApprovals": gates, "canonicalSHA256": {"reviews/sequence/current.v2.json": hashlib.sha256(review_bytes).hexdigest()},
                "delivery": delivery, "cover": cover, "nativeEvidence": {"interactions": interactions, "screenshots": images, "progress": "progress.json"}})
    return [row, {"event": "completed", "case": "filmreview" if kind == "musicvideo" else "corefilmreview", "scale": scale}]


class V2OwnerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)

    def test_actual_v2_cases_and_core_bootstrap_are_distinguished(self):
        for kind in ("core", "musicvideo"):
            for scale in (1.0, 1.25, 1.5):
                rows = owner_fixture(self.output, scale, kind)
                self.assertTrue(owner_evidence(rows, self.output, scale, kind)[0])
                for index in range(len(rows[0]["nativeGateApprovals"])):
                    changed = copy.deepcopy(rows)
                    changed[0]["nativeGateApprovals"].pop(index)
                    self.assertFalse(owner_evidence(changed, self.output, scale, kind)[0])

    def test_no_owner_flags_replace_input_playback_or_reading(self):
        rows = owner_fixture(self.output)
        for index in range(len(rows[0]["nativeEvidence"]["interactions"])):
            changed = copy.deepcopy(rows)
            changed[0]["nativeEvidence"]["interactions"].pop(index)
            self.assertFalse(owner_evidence(changed, self.output, 1.0, "musicvideo")[0], index)
        for key, value in (("executionFixture", "private_song_imported"), ("phases", PHASES[:5] + PHASES[6:]),
                           ("viewport", {"width": 960, "height": 640, "textScale": 1.5}), ("savedAndReopened", False)):
            changed = copy.deepcopy(rows); changed[0][key] = value
            self.assertFalse(owner_evidence(changed, self.output, 1.0, "musicvideo")[0])

    def test_submission_keeps_the_exact_inspected_direction_and_review(self):
        for key in ("promptSHA256", "reviewFingerprint"):
            rows = owner_fixture(self.output)
            state = next(item["evidence"] for item in rows[0]["nativeEvidence"]["interactions"]
                         if item.get("label") == "inspected direction bound to submission")
            state[key] = "9" * 64
            self.assertFalse(owner_evidence(rows, self.output, 1.0, "musicvideo")[0])

    def test_movie_poster_receipt_and_review_are_bound_to_actual_bytes(self):
        for name in ("owner-v2-film.mp4", "owner-v2-film.poster.png", "owner-v2-delivery.json", "owner-v2-film-review.json"):
            rows = owner_fixture(self.output)
            (self.output / rows[0]["evidenceDirectory"] / name).write_bytes(b"changed")
            self.assertFalse(owner_evidence(rows, self.output, 1.0, "musicvideo")[0])
        for key, value in (("status", "failed"), ("output_byte_count", 1), ("finished_timeline_sha256", "a" * 64),
                           ("sequence_review_sha256", "a" * 64), ("probe_qc", {"passed": False})):
            rows = owner_fixture(self.output)
            path = self.output / rows[0]["evidenceDirectory"] / "owner-v2-delivery.json"
            receipt = json.loads(path.read_text()); receipt[key] = value; path.write_text(json.dumps(receipt))
            self.assertFalse(owner_evidence(rows, self.output, 1.0, "musicvideo")[0])

    def test_screenshot_and_progress_paths_cannot_escape_the_case_directory(self):
        for value in ("../other.png", "/tmp/other.png"):
            rows = owner_fixture(self.output)
            rows[0]["nativeEvidence"]["screenshots"] = [value]
            self.assertFalse(owner_evidence(rows, self.output, 1.0, "musicvideo")[0])

    def test_repair_and_assembly_decisions_require_actual_negative_evidence(self):
        cases = {"native take repair stop and rescue": [("providerRequestsAfter", 5), ("spendEventsAfter", 2),
            ("stopSHA256", "b" * 64), ("actualGenerationGuardBlocked", False), ("staleContinuationBlocked", False)],
            "native assembly drift keep cancel rebuild": [("keepPreservedTimeline", False), ("cancelPreservedTimeline", False),
                ("rebuildRestoredPlan", False), ("gatesUnchanged", False), ("rebuiltClipIDs", ["same", "same"])]}
        for label, changes in cases.items():
            for key, value in changes:
                rows = owner_fixture(self.output)
                state = next(item["evidence"] for item in rows[0]["nativeEvidence"]["interactions"] if item.get("label") == label)
                state[key] = value
                self.assertFalse(owner_evidence(rows, self.output, 1.0, "musicvideo")[0], (label, key))
