import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from workspace_ui_acceptance import (
    ALL_CASES, main, native_film_screenshots, run_scale,
    valid_musicvideo_review, valid_production_workbench,
)


class FilmReviewEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        movie = b"\x00\x00\x00\x20ftyp" + b"fixture" * 200
        digest = hashlib.sha256(movie).hexdigest()
        (self.output / "film.mp4").write_bytes(movie)
        self.receipt = {
            "schema": "delivery-attempt/v1", "status": "succeeded", "output_sha256": digest,
            "output_byte_count": len(movie), "probe_qc": {"passed": True}, "sequence_review_sha256": "b" * 64,
        }
        self.write_receipt()
        frame = {"x": 0, "y": 0, "width": 960, "height": 640}
        ids = [
            "pipeline.overview.select.render", "sequence.disclosure", "sequence.build", "sequence.play",
            "sequence.shots", "sequence.start", "sequence.end", "sequence.evidence", "sequence.severity",
            "sequence.action", "sequence.add", "sequence.adjacent", "sequence.whole", "sequence.record",
            "style.disclosure", "style.begin", "style.record", "production.export", "style.choice.test",
            "style.observation.test",
        ]
        self.row = {
            "route": "mixed-musicvideo", "viewport": frame,
            "generation": {
                "providerEvidence": "Real FalClient against a simulator; no live provider evidence.",
                "batchID": "batch", "packageID": "e" * 64, "takeID": "take", "generationAssetID": "asset",
                "compiledPromptSHA256": "a" * 64, "referenceSHA256": "b" * 64,
                "outputSHA256": "c" * 64, "selectedSourceSHA256": "c" * 64,
                "generatedShotIDs": ["s001"], "importedShotIDs": ["s002"],
                "submitCount": 1, "pollCount": 1, "resultCount": 1, "downloadCount": 1, "uploadCount": 1,
                "unexpectedRequestCount": 0, "requestMethods": ["POST", "PUT", "POST", "GET", "GET", "GET"],
                "spendEvents": ["reserved", "submitted", "settled"],
                "generatedSourceStartFrame": 30, "generatedSourceEndFrame": 90, "totalFrames": 129,
                "plannedCutSeconds": 2.0, "requestedDurationSeconds": 4,
                "providerDurationFrames": 120, "importedSourceEndFrame": 69,
            },
            "controls": [{"id": key, "control": {"x": 10, "y": 10, "width": 200, "height": 30},
                          "viewport": frame.copy()} for key in ids],
            "pickerTransitions": [
                {"id": "sequence.severity", "before": "warning", "after": "info"},
                {"id": "sequence.action", "before": "local_repair", "after": "accept"},
                {"id": "style.choice.test", "before": "unreviewed", "after": "accepted_deviation"},
            ],
            "recordedSequenceSelection": {"severity": "info", "action": "accept"},
            "expectedDurationFrames": 129, "shotIDs": ["s001", "s002"], "verifiedShotImages": 2,
            "verifiedMovingShots": 2, "verifiedFrames": 4, "decodedAudioCorrelation": 0.999,
            "sequenceFindingCount": 1, "styleFindingCount": 1, "screenshots": [f"{i}.png" for i in range(7)],
            "playbackSeconds": 4.3, "decodedAudioSamples": 206400, "decodedAudioRMS": 0.1,
            "movie": "film.mp4", "deliveryReceipt": "receipt.json", "outputSHA256": digest,
            "nativeGateApprovals": [],
            "nativeBibleBlocker": {
                "phase": "bible", "reason": "Bible is incomplete: it needs a valid document with reference images for every subject.",
                "status": "Incomplete", "futureStatus": "Upcoming", "approvalUnavailable": True,
                "diagnosticOpenedByControl": "pipeline.overview.dock.diagnostics",
                "diagnosticMatchesReadiness": True, "diagnosticHiddenByDefault": True,
                "invalidArtifactPresent": True,
                "diagnosticSHA256": "d" * 64, "gatesUnchanged": True,
                "screenshots": ["bible-incomplete.png", "bible-diagnostics.png"],
            },
        }
        phases = ["project_init", "analysis", "brief", "production_design", "treatment", "storyboard",
                  "bible", "shotlist", "sanity", "frames", "render"]
        titles = ["Project", "Analysis", "Project Brief", "Production Design", "Treatment", "Storyboard",
                  "Bible", "Shotlist", "Review", "Review", "Review"]
        for index, phase in enumerate(phases):
            next_phase = phases[index + 1] if index + 1 < len(phases) else "complete"
            self.row["nativeGateApprovals"].append({
                "phase": phase, "nextPhase": next_phase, "controlID": "agent.gate.approve",
                "openControlID": "agent.gate.open", "artifactTitle": titles[index], "surface": "production",
                "openedFromPhase": "brief" if phase == "project_init" else "project_init",
                "blockedBeforeApproval": True, "readyBeforeClick": True, "approvedPersisted": True,
                "selectedPhaseAfter": "render" if next_phase == "complete" else next_phase,
                "handoffPhase": next_phase, "handoffHidden": True, "packagedInstructions": next_phase != "complete",
                "handoffTurnID": f"00000000-0000-4000-8000-{index:012d}",
                "handoffInstructionsSHA256": None if next_phase == "complete" else "f" * 64,
                "blockedReason": "Complete the required artifact", "artifactSHA256": "a" * 64,
                "gatesBeforeSHA256": "b" * 64, "gatesAfterSHA256": "c" * 64,
                "screenshots": [f"{phase}-{state}.png" for state in ("blocked", "ready", "approved")],
            })
        generation = self.row["generation"]
        generation["nativeScreenshots"] = ["native-approval.png", "native-take-review.png", "native-take-selected.png"]
        generation["nativeApproval"] = {
            "authorityBefore": False, "journalCountBefore": 0, "requestCountBefore": 0, "spendCountBefore": 0,
            "authorityAfterID": "authority", "approvedPackageSHA256": generation["packageID"], "pricingOverrideItemIDs": ["item"],
            "continuationPhases": ["render"], "continuationHidden": True,
        }
        findings = [
            {"pass": pass_name, "verdict": "conforms" if index == 0 else "acceptedDeviation",
             "observation": f"Supplied acceptance decision: {pass_name} uses a deterministic moving marker.",
             "startSeconds": 1.0, "endSeconds": 3.0}
            for index, pass_name in enumerate(["identity", "continuity", "timing", "camera", "audio", "style"])
        ]
        generation["nativeTakeReview"] = {
            "takeIDBefore": "", "takeIDAfter": "take", "findingsBefore": 0, "findings": findings,
            "selectedTakeIDAfter": "take", "reviewSHA256": "f" * 64,
        }
        actions = [("generation-batch.approve", "unapproved", "authority"), ("take.open", "closed", "open"),
                   ("take.picker", "", "take")]
        for index, finding in enumerate(findings):
            if index == 0:
                actions.extend([("take.verdict", "conforms", "rejected"), ("take.verdict", "rejected", "conforms")])
            else:
                actions.append(("take.verdict", "conforms", "acceptedDeviation"))
            actions.extend([("take.observation", "", finding["observation"]), ("take.start", "0.0", "1.0"),
                            ("take.end", "4.0", "3.0"), ("take.record-pass", str(index), str(index + 1))])
        actions.extend([("take.save", "0", "6"), ("take.use", "none", "take"), ("take.close", "open", "closed")])
        generation["nativeInteractions"] = [
            {"index": index, "controlID": control, "before": before, "after": after,
             "windowNumber": 100 if index < 2 else 200, "documentWindowNumber": 100,
             "frame": [10, 10, 200, 30], "viewport": [0, 0, 960, 640]}
            for index, (control, before, after) in enumerate(actions)
        ]
        for key in (
            "nativeSequenceReview", "nativeStyleReview", "recordDisabledUntilReviewed", "reviewInputsPersisted",
            "timelineUnchangedByReview", "nativeExportSubmitted", "exportCompleted", "sequenceReviewBound",
            "styleReviewBound", "fullSongDuration", "reviewReelHasAudio",
        ):
            self.row[key] = True

    def write_receipt(self):
        (self.output / "receipt.json").write_text(json.dumps(self.receipt))

    def test_accepts_complete_bound_delivery(self):
        self.assertTrue(valid_musicvideo_review(self.row, self.output))

    def film_rows(self, scale=1.0):
        return [{**self.row, "event": "musicvideo-film-review", "scale": scale},
                {"event": "completed", "case": "filmreview", "scale": scale}]

    def write_film_images(self):
        for name in self.row["screenshots"] + native_film_screenshots(self.row):
            (self.output / name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"pixels" * 200)

    def test_film_scope_runs_all_scales_without_claiming_full_workspace_acceptance(self):
        self.write_film_images()

        def launch(command, **kwargs):
            self.assertEqual(command, ["fixture-app", "-ApplePersistenceIgnoreState", "YES"])
            self.assertEqual(kwargs["env"]["NGV_WORKSPACE_UI_CASE"], "filmreview")
            self.assertEqual(kwargs["timeout"], 180)
            scale = float(kwargs["env"]["NGV_WORKSPACE_UI_SCALE"])
            return SimpleNamespace(returncode=0, stdout="\n".join(map(json.dumps, self.film_rows(scale))))

        with patch("workspace_ui_acceptance.subprocess.run", side_effect=launch) as process, patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(main(["fixture-app", str(self.output), "--scope", "filmreview"]), 0)
        self.assertEqual(process.call_count, 3)
        report = json.loads((self.output / "result.json").read_text())
        self.assertTrue(report["completed"])
        self.assertFalse(report["fullWorkspaceAcceptance"])
        self.assertEqual(report["scope"], "filmreview")
        self.assertEqual(report["selectedCases"], ["filmreview"])
        self.assertEqual(report["unexecutedCases"], list(ALL_CASES[:-1]))
        self.assertEqual([run["scale"] for run in report["runs"]], [1.0, 1.25, 1.5])
        self.assertTrue(all(run["scope"] == "filmreview" and len(run["screenshots"]) == 45 for run in report["runs"]))

    def test_film_scope_requires_exit_completion_native_actions_and_all_delivery_files(self):
        for failure in ("exit", "missing-completion", "wrong-case", "wrong-scale", "duplicate-review",
                        "failed-event", "native-action", "film-image", "gate-image", "generation-image", "movie", "receipt"):
            with self.subTest(failure=failure):
                self.write_film_images()
                rows = copy.deepcopy(self.film_rows())
                code = 1 if failure == "exit" else 0
                if failure == "missing-completion":
                    rows.pop()
                elif failure == "wrong-case":
                    rows[-1]["case"] = "workspace"
                elif failure == "wrong-scale":
                    rows[-1]["scale"] = 1.5
                elif failure == "duplicate-review":
                    rows.append(copy.deepcopy(rows[0]))
                elif failure == "failed-event":
                    rows.append({"event": "failed", "scale": 1.0})
                elif failure == "native-action":
                    rows[0]["generation"]["nativeInteractions"].pop()
                elif failure in ("movie", "receipt"):
                    rows[0]["movie" if failure == "movie" else "deliveryReceipt"] = "missing"
                elif failure == "film-image":
                    (self.output / rows[0]["screenshots"][0]).write_bytes(b"invalid")
                elif failure == "gate-image":
                    (self.output / rows[0]["nativeGateApprovals"][0]["screenshots"][0]).write_bytes(b"invalid")
                elif failure == "generation-image":
                    (self.output / rows[0]["generation"]["nativeScreenshots"][0]).write_bytes(b"invalid")
                output = "\n".join(map(json.dumps, rows))
                with patch("workspace_ui_acceptance.subprocess.run", return_value=SimpleNamespace(returncode=code, stdout=output)):
                    result = run_scale("fixture-app", self.output, 1.0, "filmreview")
                self.assertFalse(result["completed"])

    def test_default_scope_keeps_every_case_and_requires_non_film_evidence(self):
        self.write_film_images()
        output = "\n".join(map(json.dumps, self.film_rows()))
        with patch("workspace_ui_acceptance.subprocess.run", return_value=SimpleNamespace(returncode=0, stdout=output)) as process:
            result = run_scale("fixture-app", self.output, 1.0)
        self.assertEqual([call.kwargs["env"]["NGV_WORKSPACE_UI_CASE"] for call in process.call_args_list], list(ALL_CASES))
        self.assertEqual(result["scope"], "all")
        self.assertFalse(result["completed"])

    def test_unknown_scope_fails_before_launch(self):
        with patch("workspace_ui_acceptance.subprocess.run") as process, patch("sys.stderr", new=io.StringIO()):
            with self.assertRaises(ValueError):
                run_scale("fixture-app", self.output, 1.0, "unknown")
            with self.assertRaises(SystemExit) as error:
                main(["fixture-app", str(self.output), "--scope", "unknown"])
        self.assertEqual(error.exception.code, 2)
        process.assert_not_called()

    def test_rejects_missing_or_programmatic_phase_approval_evidence(self):
        for key, value in (("controlID", "NativeGateWriter.approve"), ("readyBeforeClick", False),
                           ("approvedPersisted", False), ("handoffPhase", "bible"),
                           ("artifactTitle", "Pipeline"), ("gatesAfterSHA256", "b" * 64),
                           ("openedFromPhase", "project_init"), ("handoffTurnID", ""),
                           ("handoffInstructionsSHA256", None)):
            with self.subTest(key=key):
                row = copy.deepcopy(self.row)
                row["nativeGateApprovals"][0][key] = value
                self.assertFalse(valid_musicvideo_review(row, self.output))
        row = copy.deepcopy(self.row)
        del row["nativeGateApprovals"][6]
        self.assertFalse(valid_musicvideo_review(row, self.output))
        row = copy.deepcopy(self.row)
        row["nativeGateApprovals"][1:3] = reversed(row["nativeGateApprovals"][1:3])
        self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_raw_or_unreviewed_bible_failure(self):
        for key, value in (("reason", "Cannot load bible/bible.yaml"), ("status", "Not started"),
                           ("diagnosticHiddenByDefault", False), ("diagnosticMatchesReadiness", False),
                           ("diagnosticOpenedByControl", ""), ("gatesUnchanged", False), ("invalidArtifactPresent", False)):
            with self.subTest(key=key):
                row = copy.deepcopy(self.row)
                row["nativeBibleBlocker"][key] = value
                self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_generation_before_native_approval(self):
        for key, value in (("authorityBefore", True), ("journalCountBefore", 1), ("requestCountBefore", 1),
                           ("spendCountBefore", 1), ("approvedPackageSHA256", "a" * 64), ("pricingOverrideItemIDs", []),
                           ("continuationPhases", []), ("continuationHidden", False)):
            row = copy.deepcopy(self.row)
            row["generation"]["nativeApproval"][key] = value
            self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_missing_reordered_clipped_or_wrong_window_take_actions(self):
        for change in ("missing", "reordered", "clipped", "wrong-window", "unchanged-picker"):
            row = copy.deepcopy(self.row)
            actions = row["generation"]["nativeInteractions"]
            if change == "missing":
                del actions[-2]
            elif change == "reordered":
                actions[-3:-1] = reversed(actions[-3:-1])
            elif change == "clipped":
                actions[3]["frame"][1] = 630
            elif change == "wrong-window":
                actions[3]["windowNumber"] = 300
            else:
                actions[2]["before"] = actions[2]["after"]
            self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_unpersisted_or_default_take_review(self):
        for change in ("wrong-take", "missing-pass", "default-range", "empty-observation"):
            row = copy.deepcopy(self.row)
            review = row["generation"]["nativeTakeReview"]
            if change == "wrong-take":
                review["selectedTakeIDAfter"] = "another-take"
            elif change == "missing-pass":
                review["findings"].pop()
            elif change == "default-range":
                review["findings"][0]["startSeconds"] = 0
            else:
                review["findings"][0]["observation"] = ""
            self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_accepts_native_take_duration_rounding_within_one_frame(self):
        for original_end in ("4.0000000001", "3.9999999999", "4.03", "3.97"):
            with self.subTest(original_end=original_end):
                row = copy.deepcopy(self.row)
                for action in row["generation"]["nativeInteractions"]:
                    if action["controlID"] == "take.end":
                        action["before"] = original_end
                self.assertTrue(valid_musicvideo_review(row, self.output))

    def measured_cut_row(self, cut, source_end, imported_end, duration, provider_frames, review_end):
        row = copy.deepcopy(self.row)
        generation = row["generation"]
        generation.update(plannedCutSeconds=cut, generatedSourceEndFrame=source_end,
                          importedSourceEndFrame=imported_end, requestedDurationSeconds=duration,
                          providerDurationFrames=provider_frames)
        for finding in generation["nativeTakeReview"]["findings"]:
            finding["endSeconds"] = review_end
        for action in generation["nativeInteractions"]:
            if action["controlID"] == "take.end":
                action["before"] = str(float(duration))
                action["after"] = str(review_end)
        return row

    def test_accepts_measured_cut_and_exact_rounded_provider_handles(self):
        for values in ((1.974, 89, 70, 4, 120, 89 / 30), (2.020, 91, 68, 5, 150, 91 / 30)):
            with self.subTest(cut=values[0]):
                self.assertTrue(valid_musicvideo_review(self.measured_cut_row(*values), self.output))

    def test_rejects_wrong_trimming_missing_frames_and_short_provider_result(self):
        valid = self.measured_cut_row(2.020, 91, 68, 5, 150, 91 / 30)
        for key, value in (("generatedSourceStartFrame", 29), ("generatedSourceEndFrame", 90),
                           ("importedSourceEndFrame", 69), ("providerDurationFrames", 149),
                           ("providerDurationFrames", 120), ("requestedDurationSeconds", 4),
                           ("totalFrames", 128), ("totalFrames", 130), ("plannedCutSeconds", 2.1),
                           ("plannedCutSeconds", float("nan")), ("plannedCutSeconds", True)):
            with self.subTest(key=key, value=value):
                row = copy.deepcopy(valid)
                row["generation"][key] = value
                self.assertFalse(valid_musicvideo_review(row, self.output))
        row = copy.deepcopy(valid)
        row["generation"].update(requestedDurationSeconds=4, providerDurationFrames=120)
        self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_missing_measured_generation_timing(self):
        for key in ("plannedCutSeconds", "requestedDurationSeconds", "providerDurationFrames", "importedSourceEndFrame"):
            row = copy.deepcopy(self.row)
            del row["generation"][key]
            self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_invalid_or_out_of_tolerance_native_take_duration(self):
        for original_end in ("4.04", "3.96", "0", "NaN", "Inf", "-Inf", "duration", "", None, 4.0):
            with self.subTest(original_end=original_end):
                row = copy.deepcopy(self.row)
                action = next(item for item in row["generation"]["nativeInteractions"] if item["controlID"] == "take.end")
                action["before"] = original_end
                self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_take_duration_tolerance_does_not_relax_other_native_states(self):
        for control, key, value in (("take.end", "after", "3.000"), ("take.start", "before", "0.001")):
            row = copy.deepcopy(self.row)
            action = next(item for item in row["generation"]["nativeInteractions"] if item["controlID"] == control)
            action[key] = value
            self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_clipped_control_even_when_all_actions_claim_success(self):
        self.row["controls"][0]["control"]["y"] = 630
        self.assertFalse(valid_musicvideo_review(self.row, self.output))

    def test_storyboard_inspector_requires_rendered_fields_for_both_native_selections(self):
        fields = [
            ("verse1.01", [("Section", "Verse 1"), ("Section timing", "0.0–12.0 s"), ("Camera", "Slow dolly"),
                           ("Framing", "Wide"), ("Angle", "Frontal"), ("Height", "Eye Level")]),
            ("chorus1.01", [("Section", "Chorus 1"), ("Section timing", "12.0–24.0 s"), ("Camera", "Slow push in"),
                            ("Framing", "Medium"), ("Angle", "Frontal"), ("Lens Hint", "Wide"), ("Location view", "Wide · Noon")]),
        ]
        row = {key: True for key in ("threeColumns", "noTimelineOrEmptyPreview", "shotInspectorBound",
                                    "twoStoryboardSections", "statusVisible")}
        row["screenshots"] = ["init.png", "brief.png", "storyboard.png"]
        row["shotInspectorSelections"] = [
            {"shotID": shot, "controlID": f"storyboard.shot.{shot}", "rawFieldsAbsent": True,
             "previousSelectionAbsent": True,
             "renderedFields": [{"label": label, "value": value} for label, value in values]}
            for shot, values in fields
        ]
        self.assertTrue(valid_production_workbench(row))
        for change in ("missing-fields", "stale-selection", "raw-key"):
            broken = copy.deepcopy(row)
            second = broken["shotInspectorSelections"][1]
            if change == "missing-fields":
                second["renderedFields"] = []
            elif change == "stale-selection":
                second["shotID"] = "verse1.01"
            else:
                second["renderedFields"][-1] = {"label": "location_view_request", "value": "wide.noon"}
            self.assertFalse(valid_production_workbench(broken))

    def test_rejects_larger_window_or_missing_native_input(self):
        row = copy.deepcopy(self.row)
        row["viewport"]["width"] = 1470
        self.assertFalse(valid_musicvideo_review(row, self.output))
        self.row["controls"] = [item for item in self.row["controls"] if item["id"] != "sequence.evidence"]
        self.assertFalse(valid_musicvideo_review(self.row, self.output))

    def test_rejects_short_silent_or_unplayed_movie_claim(self):
        for key, value in (("playbackSeconds", 0), ("decodedAudioSamples", 100), ("decodedAudioRMS", 0),
                           ("verifiedShotImages", 1), ("decodedAudioRMS", float("nan"))):
            with self.subTest(key=key, value=value):
                row = {**self.row, key: value}
                self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_unchanged_unobserved_or_unpersisted_picker_selections(self):
        for key in ("pickerTransitions", "recordedSequenceSelection"):
            row = copy.deepcopy(self.row)
            del row[key]
            self.assertFalse(valid_musicvideo_review(row, self.output))
        for index in range(3):
            row = copy.deepcopy(self.row)
            row["pickerTransitions"][index]["before"] = row["pickerTransitions"][index]["after"]
            self.assertFalse(valid_musicvideo_review(row, self.output))
        row = copy.deepcopy(self.row)
        row["recordedSequenceSelection"]["severity"] = "warning"
        self.assertFalse(valid_musicvideo_review(row, self.output))
        row = copy.deepcopy(self.row)
        row["pickerTransitions"] = row["pickerTransitions"][:2]
        self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_wrong_song_despite_nonzero_audio(self):
        for correlation in (0, 0.97, float("nan"), float("inf"), 1.2, None, True):
            with self.subTest(correlation=correlation):
                self.assertFalse(valid_musicvideo_review(
                    {**self.row, "decodedAudioCorrelation": correlation}, self.output))
        missing = self.row.copy()
        del missing["decodedAudioCorrelation"]
        self.assertFalse(valid_musicvideo_review(missing, self.output))

    def test_rejects_still_or_single_frame_comparison(self):
        for key, value in (("verifiedMovingShots", 1), ("verifiedMovingShots", 0),
                           ("verifiedFrames", 3), ("verifiedFrames", 2), ("verifiedFrames", None)):
            with self.subTest(key=key, value=value):
                self.assertFalse(valid_musicvideo_review({**self.row, key: value}, self.output))
        for key in ("verifiedMovingShots", "verifiedFrames"):
            missing = self.row.copy()
            del missing[key]
            self.assertFalse(valid_musicvideo_review(missing, self.output))

    def test_rejects_imported_only_or_missing_generation_chain(self):
        self.assertFalse(valid_musicvideo_review({**self.row, "route": "imported-musicvideo"}, self.output))
        missing = self.row.copy()
        del missing["generation"]
        self.assertFalse(valid_musicvideo_review(missing, self.output))
        for key, value in (
            ("submitCount", 0), ("pollCount", 0), ("resultCount", 0), ("downloadCount", 0),
            ("uploadCount", 0), ("unexpectedRequestCount", 1), ("takeID", ""),
            ("generatedSourceStartFrame", 0), ("generatedSourceEndFrame", 120),
            ("selectedSourceSHA256", "d" * 64), ("compiledPromptSHA256", "none"),
            ("spendEvents", ["reserved", "settled"]), ("requestMethods", []),
        ):
            with self.subTest(key=key, value=value):
                row = copy.deepcopy(self.row)
                row["generation"][key] = value
                self.assertFalse(valid_musicvideo_review(row, self.output))

    def test_rejects_changed_movie_and_unbound_review_receipt(self):
        self.receipt["sequence_review_sha256"] = None
        self.write_receipt()
        self.assertFalse(valid_musicvideo_review(self.row, self.output))
        self.receipt["sequence_review_sha256"] = "b" * 64
        self.write_receipt()
        (self.output / "film.mp4").write_bytes(b"changed bytes")
        self.assertFalse(valid_musicvideo_review(self.row, self.output))


if __name__ == "__main__":
    unittest.main()
