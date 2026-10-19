import copy
import hashlib
import io
import json
import math
from pathlib import Path
import struct
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch
import unittest
import wave

import yaml

from production_performance_role_evidence import validate, wav16
from test_production_bible_entity_evidence import fixture as bible_fixture, put


def wave_bytes(values):
    output = io.BytesIO()
    with wave.open(output, "wb") as writer:
        writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(22050)
        writer.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, round(value * 32768)))) for value in values))
    return output.getvalue()


def fixture(root):
    package_key = "00000000-0000-4000-8000-000000000001"
    native = bible_fixture(root, project_key=package_key)
    speech = [.15 * math.sin(i / 17) for i in range(44100)]
    speech_bytes = wave_bytes(speech)
    source = []
    for i in range(22050 * 8):
        t, beat = i / 22050, (i / 22050) % .5
        carrier = .01 * math.sin(2 * math.pi * 173 * t) + (.5 * math.exp(-40 * beat) * math.sin(2 * math.pi * 1000 * beat) if beat < .04 else 0)
        source.append(carrier + (.6 * speech[i - 11025] if 11025 <= i < 11025 + len(speech) else 0))
    source_bytes = wave_bytes(source)
    for name, data in (("role-speech.wav", speech_bytes), ("role-speech-analysis.wav", speech_bytes),
                       ("role-source.wav", source_bytes), ("performance-role-phrase.wav", source_bytes)):
        (root / name).write_bytes(data)
    digest = lambda value: hashlib.sha256(value).hexdigest()
    voice = dict(identifier="installed.voice", name="Installed fixture voice", language="en-US", availableVoiceIDs=["installed.voice"],
                 utterance="This voice owns this spoken phrase.", speechSHA256=digest(speech_bytes), normalizedSpeechSHA256=digest(speech_bytes),
                 sourceSHA256=digest(source_bytes), sampleRate=22050, speechFrames=len(speech), sourceFrames=len(source),
                 startSeconds=.5, endSeconds=2.5, voiceDownloadRequested=False)
    put(root, "performance-role-voice.json", voice)
    segment = dict(id="native-spoken-owner", purpose="dialogue_diegetic", shot_ids=["shot1", "shot2"], performer_ids=["owner_performer"],
                   audible_voice_ids=["installed.voice"], source_start_sample=0, source_end_sample=len(source), sample_rate=22050,
                   mouth_ownership=[dict(performer_id="owner_performer", voice_id="installed.voice", timeline_start_seconds=.5, timeline_end_seconds=2.5)])
    coverage = [dict(id="native-spoken-coverage", kind="staged_vocal", required_role_ids=["spoken-owner"], approved_exception_role_ids=[],
                    section_ids=["section-0"], evidence=[dict(role_id="spoken-owner", shot_ids=["shot1", "shot2"], performer_ids=["owner_performer"],
                                   reference_demand_ids=[], minimum_continuous_seconds=1)])]
    receipt = dict(schema="native-music-performance-audio/v2", projectID="project", revision=1, segmentID="native-spoken-owner", recordedAt="2026-10-19T12:00:00Z", source=dict(sha256=voice["sourceSHA256"]),
                   startSample=0, endSample=len(source), sourceFrameCount=len(source), exportedSampleCount=len(source), sampleRate=22050,
                   channels=1, output=dict(sha256=digest(source_bytes)), byteCount=len(source_bytes))
    put(root, "performance-role-audio-receipt.json", receipt)
    receipt_sha = digest((root / "performance-role-audio-receipt.json").read_bytes())
    extension = dict(schema="musicvideo-production/v2", header=dict(projectID="project", revision=1), track=dict(path="audio/role-source.wav", sha256=voice["sourceSHA256"]),
                     performanceSegments=[dict(draft=segment, segment_sha256=digest(source_bytes), segment_byte_count=len(source_bytes), exported_sample_count=len(source), source_track_sha256=digest(source_bytes))], performanceReceipts=[dict(sha256=receipt_sha)],
                     finalMix={}, visualArc={}, coverage=coverage)
    put(root, "performance-role-analysis.json", dict(sections=[dict(index=0)]))
    analysis_sha = digest((root / "performance-role-analysis.json").read_bytes())
    extension["analysis"] = dict(path="analysis/current.json", sha256=analysis_sha)
    def retained_input(path, data, name):
        (root / name).write_bytes(data)
        return dict(reference=dict(path=path, sha256=digest(data)), retained=name)
    input_rows = [retained_input("shot-planning/v1.v1.json", b"draft fixture", "negative-draft.bin"),
                  retained_input("storyboard/timing-v1.v1.json", b"timing fixture", "negative-timing.bin"),
                  retained_input(extension["track"]["path"], source_bytes, "negative-track.bin"),
                  retained_input(extension["analysis"]["path"], (root / "performance-role-analysis.json").read_bytes(), "negative-analysis.bin"),
                  retained_input("treatment/v1.md", b"treatment fixture", "negative-treatment.bin")]
    extension["treatment"] = input_rows[4]["reference"]
    negative_inputs = [dict(path=item["reference"]["path"], sha256=item["reference"]["sha256"], retained=item["retained"]) for item in input_rows]
    for name in ("performance-role-extension.json", "performance-role-extension-reopened.json"):
        put(root, name, extension)
    extension_sha = digest((root / "performance-role-extension.json").read_bytes())
    projection = dict(draftReference=input_rows[0]["reference"], storyboardReference=input_rows[1]["reference"], schema="shotlist/v5", header=dict(projectID="project", revision=1), timebase=dict(ticksPerSecond=600), timings=[dict(startTicks=0, durationTicks=2400), dict(startTicks=2400, durationTicks=2400)], executionPlan=dict(extension_references=[dict(id="musicvideo.production.v2", path="execution/planning/v1/musicvideo-production.v2.json", sha256=extension_sha)],
        shots=[dict(id=value, source_mode="imported") for value in ("shot1", "shot2")]))
    (root / "performance-role-projection.yaml").write_text(yaml.safe_dump(projection))
    mouth = "Reference performer → installed.voice · 0.500–2.500 s"
    coverage_text = "Shot 1, Shot 2 · at least 1.000 s continuously"
    inspected = dict(segmentID="native-spoken-owner", performerIDs=["owner_performer"], audibleVoiceIDs=[voice["identifier"]], performedSongClaim=False,
                     mouthText=mouth, coverageText=coverage_text)
    texts = {"production.musicvideo.performers.native-spoken-owner": "Reference performer",
             "production.musicvideo.voices.native-spoken-owner": "installed.voice",
             "production.musicvideo.purpose.native-spoken-owner": "Shot 1, Shot 2 · Dialogue / scene audio",
             "production.musicvideo.mouth.native-spoken-owner.0": mouth,
             "production.musicvideo.coverage.native-spoken-coverage.spoken-owner": coverage_text}
    reopened = dict(interactions=[dict(kind="verified-state", label="actual technical role project reopened",
        evidence=dict(projectKey=package_key, extensionSHA256=extension_sha))], screenshots=[])
    for index, item in enumerate((native, reopened)):
        item["interactions"] += [dict(kind="verified-state", label="native technical role bindings inspected", evidence=inspected)]
        item["interactions"] += [dict(kind="verified-state", label="native disclosure pointer", evidence=dict(id=value)) for value in
                                 ("production.musicvideo.performance.open", "production.musicvideo.coverage.open")]
        item["interactions"] += [dict(kind="verified-state", label="complete compiled direction inspected",
            evidence=dict(id=identifier, textSHA256=digest(value.encode()), height=100, coveredHeight=100)) for identifier, value in texts.items()]
        image = ("fixture-before" if index == 0 else "fixture-reopened") + "-role-and-coverage-visible.png"
        (root / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"parser fixture" * 100)
        item["screenshots"].append(image)
    native["interactions"].append(dict(kind="verified-state", label="actual technical role project before Save",
        evidence=dict(projectKey=package_key, extensionSHA256=extension_sha)))
    negatives = []
    for case in ("foreign-performer", "unowned-voice", "missing-coverage-role"):
        proposal = json.loads(json.dumps(dict(performance_segments=[segment], final_mix={}, visual_arc={}, coverage=coverage)))
        if case == "foreign-performer":
            proposal["performance_segments"][0]["performer_ids"] = ["missing-native-performer"]
            proposal["performance_segments"][0]["mouth_ownership"][0]["performer_id"] = "missing-native-performer"
            proposal["coverage"][0]["evidence"][0]["performer_ids"] = ["missing-native-performer"]
        elif case == "unowned-voice":
            proposal["performance_segments"][0]["mouth_ownership"][0]["voice_id"] = "missing-native-voice"
        else:
            proposal["coverage"][0]["evidence"] = []
        inventory = {"bible/bible.yaml": digest((root / "bible-typed-source.yaml").read_bytes()),
                     **{item["path"]: item["sha256"] for item in negative_inputs}}
        expected = {"foreign-performer": "Invalid production planning field: musicvideo.performer.",
            "unowned-voice": "Music Video segment native-spoken-owner has inconsistent performer and voice ownership.",
            "missing-coverage-role": "Music Video coverage native-spoken-coverage is missing a required role."}[case]
        negatives.append(dict(case=case, proposal=proposal, before=inventory, after=inventory, error=expected, expectedError=expected,
            reason={"foreign-performer": "musicvideo.performer", "unowned-voice": "mouthOwnershipMismatch", "missing-coverage-role": "coverageMissing"}[case]))
    for index, record in enumerate((native, reopened)):
        record["progress"] = f"role-native-{index}.json"
        put(root, record["progress"], dict(**record, failure=None))
    result = dict(schema="nexgenvideo/performance-role-native-evidence/1", status="source-only-pending", scope="technical-dialogue-binding-only",
                  performedSongClaim=False, lipQualityClaim=False, liveProviderClaim=False, viewport=dict(width=960, height=640, textScale=1), voice=voice, projectKey=package_key, projectID="project", shotIDs=["shot1", "shot2"],
                  extensionSHA256=extension_sha, phraseSHA256=digest(source_bytes), audioReceiptSHA256=receipt_sha,
                  projectionSHA256=digest((root / "performance-role-projection.yaml").read_bytes()), analysisSHA256=analysis_sha, native=native, reopenedNative=reopened, negatives=negatives, negativeInputs=negative_inputs,
                  negativeOutputPaths=["shotlist/v1.v5.yaml", "execution/planning/v1/musicvideo-production.v2.json"])
    put(root, "performance-role-evidence.json", result)


class RoleEvidenceTests(unittest.TestCase):
    def test_reopen_marker_must_precede_any_new_pointer_and_preserve_saved_identity(self):
        for fault in ("early-pointer", "changed-package", "missing-save"):
            with self.subTest(fault=fault), TemporaryDirectory() as temp:
                root = Path(temp); fixture(root)
                evidence = json.loads((root / "performance-role-evidence.json").read_bytes())
                record = evidence["reopenedNative"] if fault == "early-pointer" else evidence["native"]
                if fault == "early-pointer":
                    record["interactions"].insert(0, dict(kind="pointer", id="editor.workspace.production"))
                elif fault == "changed-package":
                    record["interactions"][-1]["evidence"]["projectKey"] = "different-pre-save-package"
                else:
                    record["interactions"].pop()
                put(root, record["progress"], dict(**record, failure=None))
                put(root, "performance-role-evidence.json", evidence)
                with self.assertRaisesRegex(ValueError, "actual reopen precedes|actual pre-Save"):
                    validate(root)

    def test_original_record_and_observation_segment_cannot_be_relabelled(self):
        for fault in ("early-reopen", "foreign-segment", "missing-segment"):
            with self.subTest(fault=fault), TemporaryDirectory() as temp:
                root = Path(temp); fixture(root)
                evidence = json.loads((root / "performance-role-evidence.json").read_bytes())
                record = evidence["native"]
                if fault == "early-reopen":
                    record["interactions"].append(copy.deepcopy(evidence["reopenedNative"]["interactions"][0]))
                else:
                    inspected = next(row["evidence"] for row in record["interactions"]
                                     if row.get("label") == "native technical role bindings inspected")
                    if fault == "foreign-segment": inspected["segmentID"] = "another-segment"
                    else: inspected.pop("segmentID")
                put(root, record["progress"], dict(**record, failure=None))
                put(root, "performance-role-evidence.json", evidence)
                with self.assertRaisesRegex(ValueError, "original role record|actual native owner/voice"):
                    validate(root)

    def test_pre_reopen_record_cannot_be_relabelled_as_reopened(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); fixture(root)
            evidence = json.loads((root / "performance-role-evidence.json").read_bytes())
            evidence["reopenedNative"] = evidence["native"]
            put(root, "performance-role-evidence.json", evidence)
            with self.assertRaisesRegex(ValueError, "distinct actual reopen"):
                validate(root)

    def test_reopen_observation_must_precede_fresh_inspection(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); fixture(root)
            evidence = json.loads((root / "performance-role-evidence.json").read_bytes())
            record = evidence["reopenedNative"]
            record["interactions"].append(record["interactions"].pop(0))
            put(root, record["progress"], dict(**record, failure=None))
            put(root, "performance-role-evidence.json", evidence)
            with self.assertRaisesRegex(ValueError, "actual reopen precedes new native inspection"):
                validate(root)

    def test_renamed_old_record_with_reopen_appended_is_not_post_reopen_inspection(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); fixture(root)
            evidence = json.loads((root / "performance-role-evidence.json").read_bytes())
            record = copy.deepcopy(evidence["native"])
            names = ["copied-" + name for name in record["screenshots"]]
            for old, name in zip(record["screenshots"], names): (root / name).write_bytes((root / old).read_bytes())
            record["screenshots"] = names; record["progress"] = "copied-native.json"
            record["interactions"].append(evidence["reopenedNative"]["interactions"][0])
            evidence["reopenedNative"] = record
            put(root, record["progress"], dict(**record, failure=None)); put(root, "performance-role-evidence.json", evidence)
            with self.assertRaisesRegex(ValueError, "actual reopen precedes new native inspection"):
                validate(root)

    def test_identical_views_are_valid_but_package_id_and_input_bytes_are_required(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); fixture(root); evidence = validate(root)
            self.assertNotEqual(evidence["projectKey"], evidence["projectID"])
            before = root / next(n for n in evidence["native"]["screenshots"] if n.endswith("-role-and-coverage-visible.png"))
            after = root / next(n for n in evidence["reopenedNative"]["screenshots"] if n.endswith("-role-and-coverage-visible.png"))
            self.assertEqual(before.read_bytes(), after.read_bytes())
            evidence["projectKey"] = evidence["projectID"]; put(root, "performance-role-evidence.json", evidence)
            with self.assertRaisesRegex(ValueError, "actual package identity distinct"):
                validate(root)
        for fault in ("missing-input", "already-published", "generic-error"):
            with self.subTest(fault=fault), TemporaryDirectory() as temp:
                root = Path(temp); fixture(root); evidence = json.loads((root / "performance-role-evidence.json").read_bytes())
                row = evidence["negatives"][0]
                if fault == "missing-input":
                    row["before"].pop(evidence["negativeInputs"][0]["path"]); row["after"] = dict(row["before"])
                elif fault == "already-published":
                    row["before"][evidence["negativeOutputPaths"][0]] = "a" * 64; row["after"] = dict(row["before"])
                else: row["expectedError"] = "planning"
                put(root, "performance-role-evidence.json", evidence)
                with self.assertRaisesRegex(ValueError, "negative refused"):
                    validate(root)

    def test_sample_mix_is_checked_even_after_rehashing_normalized_pcm(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); fixture(root)
            speech, _ = wav16((root / "role-speech-analysis.wav").read_bytes())
            speech[1000] += .2
            changed = wave_bytes(speech)
            (root / "role-speech-analysis.wav").write_bytes(changed)
            voice = json.loads((root / "performance-role-voice.json").read_bytes())
            voice["normalizedSpeechSHA256"] = hashlib.sha256(changed).hexdigest()
            put(root, "performance-role-voice.json", voice)
            evidence = json.loads((root / "performance-role-evidence.json").read_bytes()); evidence["voice"] = voice
            put(root, "performance-role-evidence.json", evidence)
            with self.assertRaisesRegex(ValueError, "actual speech/rhythm source sample"):
                validate(root)

    def test_arbitrary_equal_inventory_is_not_exact_bible_evidence(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); fixture(root)
            evidence = json.loads((root / "performance-role-evidence.json").read_bytes())
            for row in evidence["negatives"]: row["before"] = row["after"] = {"canonical": "digest"}
            put(root, "performance-role-evidence.json", evidence)
            with self.assertRaisesRegex(ValueError, "negative refused"):
                validate(root)

    def test_actual_artifact_and_pcm_joins(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); fixture(root); validate(root)

    def test_changed_source_phrase_and_reopened_extension(self):
        for name in ("role-source.wav", "role-speech-analysis.wav", "performance-role-phrase.wav", "performance-role-extension-reopened.json"):
            with self.subTest(name=name), TemporaryDirectory() as temp:
                root = Path(temp); fixture(root)
                (root / name).write_bytes((root / name).read_bytes() + b"changed")
                with self.assertRaises(ValueError): validate(root)

    def test_musical_claim_absent_native_action_and_mutating_refusal_rejected(self):
        for mutate in (lambda x: x.update(performedSongClaim=True),
                       lambda x: x["voice"].update(voiceDownloadRequested=True),
                       lambda x: x["reopenedNative"].update(interactions=[]),
                       lambda x: x["negatives"][0].update(after={"canonical": "changed"}),
                       lambda x: x["negatives"][0].update(proposal={})):
            with TemporaryDirectory() as temp:
                root = Path(temp); fixture(root)
                result = json.loads((root / "performance-role-evidence.json").read_bytes()); mutate(result)
                put(root, "performance-role-evidence.json", result)
                put(root, "performance-role-voice.json", result["voice"])
                with self.assertRaises(ValueError): validate(root)

    def test_scoped_dispatch_calls_actual_validator_and_refuses_changed_source(self):
        import workspace_ui_acceptance as workspace
        with TemporaryDirectory() as temp:
            output = Path(temp)
            directory = output / "scale-100-performance-roles"
            directory.mkdir()
            fixture(directory)
            row = json.loads((directory / "performance-role-evidence.json").read_bytes())
            row.update(event="production-performance-roles", scale=1.0, evidenceDirectory=directory.name)
            process = SimpleNamespace(returncode=0, stdout="\n".join(map(json.dumps, [row,
                dict(event="completed", case="performanceroles", scale=1.0)])))
            with patch("workspace_ui_acceptance.subprocess.run", return_value=process), \
                    patch("workspace_ui_acceptance.performance_role_evidence", wraps=workspace.performance_role_evidence) as consume:
                self.assertTrue(workspace.run_scale("isolated-fixture-app", output, 1.0, "performanceroles")["completed"])
                self.assertEqual(consume.call_count, 1)
            from workspace_native_evidence import validate_case
            self.assertTrue(validate_case("performanceroles", [row, dict(event="completed", case="performanceroles", scale=1.0)], output, 1.0)[0])
            with patch.dict(workspace.ACCEPTANCE_SCOPES, {"all": ("performanceroles",)}), \
                    patch("workspace_ui_acceptance.subprocess.run", return_value=process), \
                    patch("workspace_native_evidence.validate_case", wraps=validate_case) as route:
                self.assertTrue(workspace.run_scale("isolated-fixture-app", output, 1.0, "all")["completed"])
                self.assertEqual(route.call_args.args[0], "performanceroles")
                self.assertEqual(route.call_count, 1)
            from workspace_native_case import timeout_for
            self.assertEqual(timeout_for("performanceroles"), 600)
            (directory / "role-source.wav").write_bytes(b"changed")
            self.assertFalse(validate_case("performanceroles", [row, dict(event="completed", case="performanceroles", scale=1.0)], output, 1.0)[0])
            with patch.dict(workspace.ACCEPTANCE_SCOPES, {"all": ("performanceroles",)}), \
                    patch("workspace_ui_acceptance.subprocess.run", return_value=process), \
                    patch("workspace_native_evidence.validate_case", wraps=validate_case) as route:
                self.assertFalse(workspace.run_scale("isolated-fixture-app", output, 1.0, "all")["completed"])
                self.assertEqual(route.call_count, 1)
            with patch("workspace_ui_acceptance.subprocess.run", return_value=process), \
                    patch("workspace_ui_acceptance.performance_role_evidence", wraps=workspace.performance_role_evidence) as consume:
                self.assertFalse(workspace.run_scale("isolated-fixture-app", output, 1.0, "performanceroles")["completed"])
                self.assertEqual(consume.call_count, 1)

    def test_truncated_or_wrong_clock_pcm_rejected(self):
        wrong_clock = bytearray(wave_bytes([.1] * 128)); struct.pack_into("<I", wrong_clock, 24, 44100)
        for data in (b"RIFF", wave_bytes([.1] * 128)[:-1], bytes(wrong_clock)):
            with self.assertRaises(ValueError): wav16(data)


if __name__ == "__main__":
    unittest.main()
