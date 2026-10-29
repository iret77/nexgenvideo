import copy
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from manual_generation_extended_evidence import IMAGES, LABELS, manual_generation_extended_evidence


def extended_fixture(output):
    output = Path(output)
    prefix = "manual-generation-150"
    (output / prefix).mkdir(exist_ok=True)
    def wav(seconds):
        samples = b"\0" * (48000 * 4 * seconds)
        fmt = struct.pack("<HHIIHH", 3, 1, 48000, 192000, 4, 32)
        chunks = b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(samples)) + samples
        return b"RIFF" + struct.pack("<I", len(chunks) + 4) + b"WAVE" + chunks
    def archive(name, payload, submit, source=None, seconds=2, image=False):
        identity = hashlib.sha256(name.encode()).hexdigest()
        payload["generationInput"].update(model=payload["target"]["modelId"], prompt=payload["prompt"])
        result = b"\x89PNG\r\n\x1a\n" + b"image" * 300 if image else wav(seconds)
        refs = {"package": {"schema": "generation-package/v1", "id": identity, "payload": payload}, "submit": submit, "output": result}
        if source is not None:
            refs["input"] = source
            payload["references"] = [{"submittedSHA256": hashlib.sha256(source).hexdigest()}]
        else:
            payload["references"] = []
        paths = {}
        for key, value in refs.items():
            filename = name + "." + key + (".json" if key in ("package", "submit") else ".bin")
            data = json.dumps(value).encode() if isinstance(value, dict) else value
            (output / prefix / filename).write_bytes(data)
            paths[key] = prefix + "/" + filename
        return {"packageID": identity, "artifacts": paths}, result
    def payload(model, operation="audio", destination="timeline"):
        return {"modality": "audio", "operation": operation, "prompt": "Actual compiled " + model,
            "target": {"modelId": model}, "generationInput": {},
            "destination": {"kind": destination, "startFrame": 0, "durationSeconds": 2}}
    def state(label, evidence):
        return {"kind": "verified-state", "label": label, "evidence": evidence}
    states = []
    p = payload("upscale", operation="upscale", destination="replace_clip")
    p["destination"]["linkedSourcesSHA256"] = "f" * 64
    p["destination"]["clipID"] = "picture"
    p["requestParametersJSON"] = '{"image_url":"$reference:0"}'
    evidence, result = archive("upscale", p, {"image_url": "https://media.invalid/stage.png"}, b"source-image", image=True)
    evidence.update(outputSHA256=hashlib.sha256(result).hexdigest(), uploadedSHA256=hashlib.sha256(b"source-image").hexdigest(),
        discardDidNotDispatch=True, nativeUndoRedo=True, originalRetained=True)
    rerun = {"schema": "generation-package/v1", "id": "d" * 64, "payload": copy.deepcopy(p)}
    rerun["payload"]["destination"]["linkedSourcesSHA256"] = "e" * 64
    rerun_name = prefix + "/upscale-rerun-discard-package.json"
    rerun_bytes = json.dumps(rerun).encode()
    (output / rerun_name).write_bytes(rerun_bytes)
    evidence.update(rerunDiscardPackage=rerun_name, rerunDiscardPackageSHA256=hashlib.sha256(rerun_bytes).hexdigest(),
        rerunDiscardPackageID=rerun["id"], rerunDiscardDidNotDispatch=True, rerunDiscardNoError=True,
        rerunScopeRetoggled=False, rerunQuiescenceSeconds=1.1, rerunQuiescenceChecks=20,
        rerunRequestsBefore=6, rerunRequestsAfter=6, rerunSpendBefore=3, rerunSpendAfter=3)
    states.append(state(LABELS[0], evidence))
    panel_direction = "Solo piano for the visible movement."
    direction = panel_direction + " A quiet rhythmic pulse for the actual two-second cut."
    composed = "Ambient, Sparse, Warm, " + direction
    for index, name in enumerate(("sfx", "lyrics", "timeline")):
        model = "native-acceptance-video-sfx" if index == 0 else "native-acceptance-video-music"
        p = payload(model, "music" if index == 2 else "audio")
        submit = {"model": model, "prompt": p["prompt"], "duration_seconds": 2, "video_url": "https://media.invalid/native-audio-input.mov", "instrumental": False}
        if index in (0, 1):
            p["generationInput"]["sourceRange"] = {"trim": {"fps": 30, "trimStartFrame": 30, "sourceFramesConsumed": 60}}
        if index == 1:
            p["generationInput"]["lyrics"] = submit["lyrics"] = "[Verse] The city wakes in morning light."
        if index == 2:
            p["intent"] = composed
            p["generationInput"]["intent"] = composed
            p["prompt"] = submit["prompt"] = composed + " Compiled audio."
        source = ("real-upload-" + name).encode()
        evidence, result = archive(name, p, submit, source)
        evidence["submitFormat"] = "canonical-mcp-arguments"
        if index == 0:
            evidence.update(sourceTrimStartFrames=30, sourceFramesConsumed=60, sourceFPS=30, nativeDiscardAndApproval=True,
                discardQuiescenceSeconds=1.1, discardQuiescenceChecks=20, discardCallsAfter=0, discardUploadsAfter=0,
                originalClipRetained=True, decodedSourceDurationSeconds=2, inputSHA256=hashlib.sha256(source).hexdigest(), outputSHA256=hashlib.sha256(result).hexdigest())
        elif index == 1:
            evidence.update(lyricsPreserved=True, compiledDirectionMatched=True, originalRetained=True,
                sourceFPS=30, sourceTrimStartFrames=30, sourceFramesConsumed=60, decodedSourceDurationSeconds=2, additionalAudioTrack=True)
        else:
            evidence.update(previewDurationSeconds=2, previewHasNoAudio=True, sourceAndPriorSFXRetained=True,
                previewSHA256=hashlib.sha256(source).hexdigest(), composedIntent=composed, direction=direction,
                mood="Ambient", character=["Sparse", "Warm"], panelDirection=panel_direction, compiledDirectionMatched=True,
                dialogModelAndInputDisabled=True, nativeStaleBindingUndo=True, staleBindingError="The music input changed. Prepare the direction again.",
                menuAvailability=[{"kind": "empty", "trackTypes": [], "inputMode": "Video to Music", "useTimelineVideoEnabled": False, "moodEnabled": False, "prepareEnabled": False},
                    {"kind": "audioOnly", "trackTypes": ["audio"], "inputMode": "Video to Music", "useTimelineVideoEnabled": False, "moodEnabled": False, "prepareEnabled": False}])
        states.append(state(LABELS[index + 1], evidence))
    p = payload("actual-voice", destination="media_library"); p["generationInput"]["voice"] = "Actual voice"
    evidence, result = archive("speech", p, {"text": p["prompt"], "voice": "Actual voice"})
    evidence.update(submitFormat="raw-http-body", voice="Actual voice", defaultVoice="Default voice", outputSHA256=hashlib.sha256(result).hexdigest())
    states.append(state(LABELS[4], evidence))
    p = payload("fal-ai/elevenlabs/music", destination="media_library")
    p["generationInput"].update(duration=3, instrumental=True)
    evidence, _ = archive("instrumental", p, {"prompt": p["prompt"], "music_length_ms": 3000, "force_instrumental": True}, seconds=3)
    evidence.update(submitFormat="raw-http-body", requestedDurationSeconds=3, instrumental=True, initialInstrumental="off", decodedFixtureDurationSeconds=3)
    states.append(state(LABELS[5], evidence))
    counts = {"ai-edit.scope.Replace clip source": 1, "generation.review.discard": 1, "generation.review.approve": 2,
        "generation.review.package.details": 2, "generation.review.package.copy-package": 2, "ai-edit.generateSFX": 1,
        "ai-edit.generateMusic": 1, "generation.edit.review": 5, "generation.edit.discard": 1, "generation.edit.approve": 4,
        "generation.edit.package.details": 5, "generation.edit.package.copy-package": 5, "media.tab.Music": 1,
        "media.tab.Assets": 1, "music.actions": 5, "agent.dialog.choice.character.sparse": 1, "agent.dialog.choice.character.warm": 1, "agent.dialog.confirm": 2, "generation.edit.settings": 1,
        "editing.add-text": 1, "generation.edit.instrumental": 3}
    inputs = states + [{"kind": "pointer", "id": key} for key, count in counts.items() for _ in range(count)]
    inputs += [{"kind": "pointer", "id": key} for key in ("ai-edit.rerun", "generation.review.package.details",
        "generation.review.package.copy-package", "generation.review.discard")]
    inputs += [{"kind": "keyboard", "characters": key} for key in ("z", "Z", "z")]
    inputs += [{"kind": "menu", "id": key, "closed": True, "path": ["Actual choice"]}
        for key, count in {"ai-edit.upscale": 2, "music.model": 1, "music.input": 1, "generation.edit.model": 2, "generation.edit.voice": 1}.items()
        for _ in range(count)]
    inputs += [{"kind": "menu", "id": "music.actions", "closed": True, "path": path}
        for path in (["Use Timeline Video"], ["Mood", "Ambient"], ["Mood", "Ambient"])]
    inputs += [{"kind": "text", "field": {"id": key, "expected": direction if key == "agent.dialog.direction" else panel_direction if key == "music.intent" else "Actual user text", "actual": direction if key == "agent.dialog.direction" else panel_direction if key == "music.intent" else "Actual user text",
        "stage": "commit-requested", "commitInput": "Tab"}}
        for key, count in {"generation.edit.intent": 4, "generation.edit.lyrics": 1, "agent.dialog.direction": 1, "music.intent": 1, "generation.edit.duration": 1}.items()
        for _ in range(count)]
    images = [prefix + "/native-" + label + ".png" for label in IMAGES]
    for name in images:
        (output / name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"image" * 250)
    return inputs, images


class ManualAudioEvidenceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(); self.addCleanup(directory.cleanup)
        self.output = Path(directory.name)
        inputs, images = extended_fixture(self.output)
        self.row = {"interactions": [{"kind": "verified-state", "label": "baseline", "evidence": {}} for _ in range(3)] + inputs,
                    "screenshots": ["baseline-one.png", "baseline-two.png", "baseline-three.png"] + images}

    def accepts(self, row=None):
        return manual_generation_extended_evidence(row or self.row, self.output)

    def test_upscale_rerun_discard_requires_quiescence_without_request_spend_or_error(self):
        for key, value in (("rerunDiscardDidNotDispatch", False), ("rerunDiscardNoError", False),
            ("rerunQuiescenceSeconds", 0.1), ("rerunQuiescenceSeconds", float("nan")),
            ("rerunQuiescenceChecks", True), ("rerunQuiescenceChecks", 1),
            ("rerunRequestsAfter", 7), ("rerunSpendAfter", 4), ("rerunSpendBefore", True)):
            changed = copy.deepcopy(self.row)
            changed["interactions"][3]["evidence"][key] = value
            with self.subTest(key=key, value=value): self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        start = next(i for i, item in enumerate(changed["interactions"]) if item.get("id") == "ai-edit.rerun")
        changed["interactions"][start + 3]["id"] = "generation.review.approve"
        self.assertFalse(self.accepts(changed))

    def test_upscale_rerun_copy_must_bind_the_same_source_and_new_destination(self):
        evidence = self.row["interactions"][3]["evidence"]
        path = self.output / evidence["rerunDiscardPackage"]
        original_bytes = path.read_bytes()
        original = json.loads(original_bytes)
        for field, value in (("operation", "generate_image"), ("references", []), ("target", {"modelId": "other"}),
            ("requestParametersJSON", "{}"), ("destination", {"kind": "replace_clip", "clipID": "other", "linkedSourcesSHA256": "e" * 64})):
            changed = copy.deepcopy(original); changed["payload"][field] = value
            data = json.dumps(changed).encode(); path.write_bytes(data)
            evidence["rerunDiscardPackageSHA256"] = hashlib.sha256(data).hexdigest()
            with self.subTest(field=field): self.assertFalse(self.accepts())
        path.write_bytes(original_bytes)
        evidence["rerunDiscardPackageSHA256"] = "0" * 64
        self.assertFalse(self.accepts())

    def test_every_native_decision_and_source_field_is_required(self):
        self.assertTrue(self.accepts())
        for index in range(3, len(self.row["interactions"])):
            changed = copy.deepcopy(self.row); changed["interactions"].pop(index)
            with self.subTest(index=index): self.assertFalse(self.accepts(changed))
        for index in range(3, len(self.row["screenshots"])):
            changed = copy.deepcopy(self.row); changed["screenshots"].pop(index)
            self.assertFalse(self.accepts(changed))

    def test_lyrics_trim_and_separation_cannot_be_asserted_without_binding(self):
        evidence = self.row["interactions"][5]["evidence"]
        package_path = self.output / evidence["artifacts"]["package"]
        submit_path = self.output / evidence["artifacts"]["submit"]
        package_bytes, submit_bytes = package_path.read_bytes(), submit_path.read_bytes()
        package = json.loads(package_bytes)
        package["payload"]["generationInput"]["sourceRange"]["trim"]["sourceFramesConsumed"] = 240
        package_path.write_text(json.dumps(package)); self.assertFalse(self.accepts())
        package, submit = json.loads(package_bytes), json.loads(submit_bytes)
        for leak in (submit["lyrics"], "THE CITY WAKES  IN morning light.", "The city wakes", "wakes—in morning", "IN MORNING LIGHT"):
            package, submit = json.loads(package_bytes), json.loads(submit_bytes)
            prompt = package["payload"]["prompt"] + " " + leak
            package["payload"]["prompt"] = package["payload"]["generationInput"]["prompt"] = submit["prompt"] = prompt
            package_path.write_text(json.dumps(package)); submit_path.write_text(json.dumps(submit))
            self.assertFalse(self.accepts())
        package, submit = json.loads(package_bytes), json.loads(submit_bytes)
        prompt = package["payload"]["prompt"] + " Sparse piano and a quiet voice follow the gesture."
        package["payload"]["prompt"] = package["payload"]["generationInput"]["prompt"] = submit["prompt"] = prompt
        package_path.write_text(json.dumps(package)); submit_path.write_text(json.dumps(submit))
        self.assertTrue(self.accepts())
        package_path.write_bytes(package_bytes); submit_path.write_bytes(submit_bytes)

    def test_discard_quiescence_voice_change_and_toggle_are_required(self):
        for index, key, value in ((4, "discardQuiescenceSeconds", 0.1), (4, "discardQuiescenceChecks", 0),
            (4, "discardCallsAfter", 1), (4, "discardUploadsAfter", 1), (7, "defaultVoice", "Actual voice"),
            (8, "initialInstrumental", "on"), (8, "decodedFixtureDurationSeconds", float("nan"))):
            changed = copy.deepcopy(self.row); changed["interactions"][index]["evidence"][key] = value
            with self.subTest(key=key): self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        changed["interactions"] = [item for item in changed["interactions"] if item.get("id") != "generation.edit.instrumental"]
        self.assertFalse(self.accepts(changed))

    def test_decoded_duration_tolerance_matches_native_check(self):
        self.row["interactions"][8]["evidence"]["decodedFixtureDurationSeconds"] = 2.99998
        self.assertTrue(self.accepts())
        self.row["interactions"][8]["evidence"]["decodedFixtureDurationSeconds"] = 2.9
        self.assertFalse(self.accepts())

    def test_source_duration_format_and_audio_placement_are_bound(self):
        for index, key, value in ((4, "decodedSourceDurationSeconds", 1.8),
            (5, "decodedSourceDurationSeconds", float("nan")), (5, "additionalAudioTrack", False),
            (4, "submitFormat", "raw-http-body"), (7, "submitFormat", "canonical-mcp-arguments")):
            changed = copy.deepcopy(self.row); changed["interactions"][index]["evidence"][key] = value
            with self.subTest(index=index, key=key): self.assertFalse(self.accepts(changed))
        self.row["interactions"][5]["evidence"]["decodedSourceDurationSeconds"] = 2.0000001
        self.assertTrue(self.accepts())

    def test_malformed_nested_payloads_fail_closed(self):
        for malformed in (None, 42, []):
            changed = copy.deepcopy(self.row); changed["interactions"].append(malformed)
            self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        changed["interactions"].append({"kind": "keyboard", "characters": None})
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row); changed["interactions"][4]["evidence"] = None
        self.assertFalse(self.accepts(changed))

    def test_wrong_transport_prompt_voice_lyrics_range_or_instrumental_never_pass(self):
        for index, key, value in ((4, "prompt", "wrong prompt"), (5, "lyrics", "replaced words"),
                                   (6, "duration_seconds", 8), (7, "voice", "different voice"),
                                   (8, "music_length_ms", 90000), (8, "force_instrumental", False)):
            evidence = self.row["interactions"][index]["evidence"]
            path = self.output / evidence["artifacts"]["submit"]
            original = path.read_bytes(); payload = json.loads(original); payload[key] = value
            path.write_text(json.dumps(payload)); self.assertFalse(self.accepts()); path.write_bytes(original)
        path = self.output / self.row["interactions"][4]["evidence"]["artifacts"]["package"]
        original = path.read_bytes(); package = json.loads(original)
        package["payload"]["generationInput"]["sourceRange"]["trim"]["trimStartFrame"] = 0
        path.write_text(json.dumps(package)); self.assertFalse(self.accepts()); path.write_bytes(original)

    def test_missing_tampered_or_escaped_bytes_and_wrong_wave_duration_fail(self):
        for index in range(3, 9):
            evidence = self.row["interactions"][index]["evidence"]
            for key, name in evidence["artifacts"].items():
                path = self.output / name; original = path.read_bytes(); path.write_bytes(b"tampered")
                with self.subTest(index=index, key=key): self.assertFalse(self.accepts())
                path.write_bytes(original)
        changed = copy.deepcopy(self.row)
        changed["interactions"][4]["evidence"]["artifacts"]["input"] = "../outside.mov"
        self.assertFalse(self.accepts(changed))
        source = self.output / self.row["interactions"][4]["evidence"]["artifacts"]["output"]
        target = self.output / self.row["interactions"][8]["evidence"]["artifacts"]["output"]
        target.write_bytes(source.read_bytes()); self.assertFalse(self.accepts())

    def test_mood_choices_cannot_be_dropped_before_compilation(self):
        path = self.output / "manual-generation-150/timeline.package.json"
        original = json.loads(path.read_text())
        changed = copy.deepcopy(original); changed["payload"]["intent"] = "Generic music"
        path.write_text(json.dumps(changed)); self.assertFalse(self.accepts())
        path.write_text(json.dumps(original))
        for action in self.row["interactions"]:
            if action.get("label") == "native timeline video to music":
                action["evidence"]["character"] = ["Sparse"]
                break
        self.assertFalse(self.accepts())

    def test_matching_package_and_paid_prompt_still_cannot_drop_mood_or_direction(self):
        evidence = self.row["interactions"][6]["evidence"]
        package_path = self.output / evidence["artifacts"]["package"]
        submit_path = self.output / evidence["artifacts"]["submit"]
        original_package, original_submit = package_path.read_bytes(), submit_path.read_bytes()
        for prompt in ("Generic music", "Ambient, Sparse, Warm", evidence["direction"]):
            package, submit = json.loads(original_package), json.loads(original_submit)
            package["payload"]["prompt"] = package["payload"]["generationInput"]["prompt"] = submit["prompt"] = prompt
            package_path.write_text(json.dumps(package)); submit_path.write_text(json.dumps(submit))
            with self.subTest(prompt=prompt): self.assertFalse(self.accepts())
        package_path.write_bytes(original_package); submit_path.write_bytes(original_submit)

    def test_empty_audio_only_and_changed_binding_cannot_be_claimed_ready(self):
        for field in ("useTimelineVideoEnabled", "moodEnabled", "prepareEnabled"):
            for index in range(2):
                changed = copy.deepcopy(self.row)
                changed["interactions"][6]["evidence"]["menuAvailability"][index][field] = True
                with self.subTest(index=index, field=field): self.assertFalse(self.accepts(changed))
        for field, value in (("dialogModelAndInputDisabled", False), ("nativeStaleBindingUndo", False),
                             ("staleBindingError", ""), ("panelDirection", "Dropped direction")):
            changed = copy.deepcopy(self.row)
            changed["interactions"][6]["evidence"][field] = value
            with self.subTest(field=field): self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        changed["interactions"][6]["evidence"]["menuAvailability"][0]["inputMode"] = "Text to Music"
        self.assertFalse(self.accepts(changed))


if __name__ == "__main__":
    unittest.main()
