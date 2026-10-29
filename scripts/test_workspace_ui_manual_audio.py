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
    evidence, result = archive("upscale", p, {"image_url": "https://media.invalid/stage.png"}, b"source-image", image=True)
    evidence.update(outputSHA256=hashlib.sha256(result).hexdigest(), uploadedSHA256=hashlib.sha256(b"source-image").hexdigest(),
        discardDidNotDispatch=True, nativeUndoRedo=True, originalRetained=True)
    states.append(state(LABELS[0], evidence))
    direction = "A quiet rhythmic pulse for the actual two-second cut."
    composed = "Ambient, Sparse, Warm, " + direction
    for index, name in enumerate(("sfx", "lyrics", "timeline")):
        model = "native-acceptance-video-sfx" if index == 0 else "native-acceptance-video-music"
        p = payload(model, "music" if index == 2 else "audio")
        submit = {"model": model, "prompt": p["prompt"], "duration_seconds": 2, "video_url": "https://media.invalid/native-audio-input.mov"}
        if index == 0:
            p["generationInput"]["sourceRange"] = {"trim": {"fps": 30, "trimStartFrame": 30, "sourceFramesConsumed": 60}}
        if index == 1:
            p["generationInput"]["lyrics"] = submit["lyrics"] = "[Verse] The city wakes in morning light."
        if index == 2:
            p["intent"] = composed
            p["generationInput"]["intent"] = composed
        source = ("real-upload-" + name).encode()
        evidence, result = archive(name, p, submit, source)
        if index == 0:
            evidence.update(sourceTrimStartFrames=30, sourceFramesConsumed=60, nativeDiscardAndApproval=True,
                originalClipRetained=True, inputSHA256=hashlib.sha256(source).hexdigest(), outputSHA256=hashlib.sha256(result).hexdigest())
        elif index == 1:
            evidence.update(lyricsPreserved=True, compiledDirectionMatched=True, originalRetained=True)
        else:
            evidence.update(previewDurationSeconds=2, previewHasNoAudio=True, sourceAndPriorSFXRetained=True,
                previewSHA256=hashlib.sha256(source).hexdigest(), composedIntent=composed, direction=direction,
                mood="Ambient", character=["Sparse", "Warm"])
        states.append(state(LABELS[index + 1], evidence))
    p = payload("actual-voice", destination="media_library"); p["generationInput"]["voice"] = "Actual voice"
    evidence, result = archive("speech", p, {"text": p["prompt"], "voice": "Actual voice"})
    evidence.update(voice="Actual voice", outputSHA256=hashlib.sha256(result).hexdigest())
    states.append(state(LABELS[4], evidence))
    p = payload("fal-ai/elevenlabs/music", destination="media_library")
    p["generationInput"].update(duration=3, instrumental=True)
    evidence, _ = archive("instrumental", p, {"prompt": p["prompt"], "music_length_ms": 3000, "force_instrumental": True}, seconds=3)
    evidence.update(requestedDurationSeconds=3, instrumental=True, decodedFixtureDurationSeconds=3)
    states.append(state(LABELS[5], evidence))
    counts = {"ai-edit.scope.Replace clip source": 1, "generation.review.discard": 1, "generation.review.approve": 2,
        "generation.review.package.details": 2, "generation.review.package.copy-package": 2, "ai-edit.generateSFX": 1,
        "ai-edit.generateMusic": 1, "generation.edit.review": 5, "generation.edit.discard": 1, "generation.edit.approve": 4,
        "generation.edit.package.details": 5, "generation.edit.package.copy-package": 5, "media.tab.Music": 1,
        "media.tab.Assets": 1, "music.actions": 1, "agent.dialog.choice.character.sparse": 1, "agent.dialog.choice.character.warm": 1, "agent.dialog.confirm": 1, "generation.edit.settings": 1}
    inputs = states + [{"kind": "pointer", "id": key} for key, count in counts.items() for _ in range(count)]
    inputs += [{"kind": "keyboard", "characters": key} for key in ("z", "Z")]
    inputs += [{"kind": "menu", "id": key, "closed": True, "path": ["Actual choice"]}
        for key, count in {"ai-edit.upscale": 2, "music.model": 1, "music.input": 1, "generation.edit.model": 2, "generation.edit.voice": 1}.items()
        for _ in range(count)]
    inputs += [{"kind": "menu", "id": "music.actions", "closed": True, "path": ["Mood", "Ambient"]}]
    inputs += [{"kind": "text", "field": {"id": key, "expected": direction if key == "agent.dialog.direction" else "Actual user text", "actual": direction if key == "agent.dialog.direction" else "Actual user text",
        "stage": "commit-requested", "commitInput": "Tab"}}
        for key, count in {"generation.edit.intent": 4, "generation.edit.lyrics": 1, "agent.dialog.direction": 1, "generation.edit.duration": 1}.items()
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

    def test_every_native_decision_and_source_field_is_required(self):
        self.assertTrue(self.accepts())
        for index in range(3, len(self.row["interactions"])):
            changed = copy.deepcopy(self.row); changed["interactions"].pop(index)
            with self.subTest(index=index): self.assertFalse(self.accepts(changed))
        for index in range(3, len(self.row["screenshots"])):
            changed = copy.deepcopy(self.row); changed["screenshots"].pop(index)
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


if __name__ == "__main__":
    unittest.main()
