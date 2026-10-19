"""Independent checks for native actions, HTTP bytes and canonical MCP arguments."""
from collections import Counter
import hashlib
import json
import math
import re
from pathlib import Path
import struct


LABELS = (
    "native upscale package and source replacement",
    "native clip to SFX exact source range",
    "native video music preserves separate lyrics",
    "native timeline video to music",
    "native speech voice reaches actual Fal client",
    "native range duration and instrumental reach actual Fal client",
)
IMAGES = (
    "upscale-review-before-discard", "upscale-replaced-and-redone", "upscale-rerun-before-discard", "upscale-rerun-discarded", "audio-sfx-native-review",
    "native-video-music-lyrics-review", "timeline-music-native-review", "native-audio-results-on-timeline",
    "native-speech-voice-review", "native-instrumental-duration-review", "native-music-mood-direction",
)


def _file(output, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute() or ".." in Path(name).parts:
        raise ValueError("Invalid evidence path")
    path = Path(output) / name
    path.resolve().relative_to(Path(output).resolve())
    parts = Path(name).parts
    if any((Path(output).joinpath(*parts[:index])).is_symlink() for index in range(1, len(parts) + 1)) or not path.is_file():
        raise ValueError("Missing or aliased evidence")
    return path


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _wav_duration(data):
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE" or len(data) < 44:
        raise ValueError("No actual WAVE output")
    position, sample_rate, alignment, data_size = 12, None, None, None
    while position + 8 <= len(data):
        tag, size = data[position:position + 4], struct.unpack_from("<I", data, position + 4)[0]
        start = position + 8
        if start + size > len(data):
            raise ValueError("Truncated WAVE output")
        if tag == b"fmt ":
            if size < 16:
                raise ValueError("Invalid WAVE format")
            kind, channels, sample_rate, _, alignment, bits = struct.unpack_from("<HHIIHH", data, start)
            if kind not in (1, 3, 0xFFFE) or channels != 1 or sample_rate != 48000 or bits != 32 or alignment != 4:
                raise ValueError("Unexpected native PCM fixture")
        if tag == b"data":
            if data_size is not None:
                raise ValueError("Ambiguous audio payload")
            data_size = size
        position = start + size + size % 2
    if not sample_rate or not alignment or not data_size or data_size % alignment:
        raise ValueError("Missing PCM samples")
    return data_size / alignment / sample_rate


def _fixture_lyric_leak(prompt, lyrics):
    body = re.findall(r"\w+", re.sub(r"\[[^]]*\]", "", lyrics).casefold())
    words = re.findall(r"\w+", prompt.casefold())
    fragments = {tuple(body[index:index + 3]) for index in range(len(body) - 2)}
    return any(tuple(words[index:index + 3]) in fragments for index in range(len(words) - 2))


def _artifact(evidence, output, *, source):
    paths = evidence.get("artifacts")
    expected = {"package", "submit", "output"} | ({"input"} if source else set())
    if not isinstance(paths, dict) or set(paths) != expected or len(set(paths.values())) != len(paths):
        raise ValueError("Incomplete native byte evidence")
    package = json.loads(_file(output, paths["package"]).read_bytes())
    submit = json.loads(_file(output, paths["submit"]).read_bytes())
    result = _file(output, paths["output"]).read_bytes()
    payload = package["payload"]
    identity = package.get("id")
    if (not isinstance(identity, str) or len(identity) != 64 or any(char not in "0123456789abcdef" for char in identity)
        or package.get("schema") != "generation-package/v1" or identity != evidence.get("packageID")
        or not isinstance(submit, dict) or payload["generationInput"]["model"] != payload["target"]["modelId"]
        or payload["generationInput"]["prompt"] != payload["prompt"]):
        raise ValueError("Wrong reviewed request")
    references = payload["references"]
    if source:
        data = _file(output, paths["input"]).read_bytes()
        if len(references) != 1 or _sha(data) != references[0]["submittedSHA256"]:
            raise ValueError("Uploaded bytes differ from approval")
    elif references:
        raise ValueError("Text audio invented a source")
    return payload, submit, result


def manual_generation_extended_evidence(row, output):
    try:
        inputs, images = row["interactions"], row["screenshots"]
        if not isinstance(inputs, list) or any(not isinstance(item, dict) for item in inputs):
            return False
        states = [item for item in inputs if item.get("kind") == "verified-state"]
        if tuple(item.get("label") for item in states[3:]) != LABELS or len(states) != 9:
            return False
        evidence = [item["evidence"] for item in states[3:]]
        pointers = Counter(item.get("id") for item in inputs if item.get("kind") == "pointer")
        upscale = evidence[0]
        if type(upscale.get("rerunScopeRetoggled")) is not bool:
            return False
        required = {"ai-edit.scope.Replace clip source": 1 + int(upscale["rerunScopeRetoggled"]), "generation.review.discard": 2,
            "generation.review.approve": 2, "generation.review.package.details": 3,
            "generation.review.package.copy-package": 3, "ai-edit.generateSFX": 1, "ai-edit.generateMusic": 1,
            "generation.edit.review": 5, "generation.edit.discard": 1, "generation.edit.approve": 4,
            "generation.edit.package.details": 5, "generation.edit.package.copy-package": 5,
            "media.tab.Music": 1, "media.tab.Assets": 1, "music.actions": 5, "agent.dialog.choice.character.sparse": 1, "agent.dialog.choice.character.warm": 1, "agent.dialog.confirm": 2, "generation.edit.settings": 1,
            "editing.add-text": 1}
        if any(pointers[key] != count for key, count in required.items()):
            return False
        rerun_indices = [index for index, item in enumerate(inputs) if item.get("kind") == "pointer" and item.get("id") == "ai-edit.rerun"]
        if not rerun_indices:
            return False
        rerun_actions = [item.get("id") for item in inputs[rerun_indices[-1] + 1:]
            if item.get("kind") == "pointer" and isinstance(item.get("id"), str) and item["id"].startswith("generation.review.")]
        if rerun_actions[:3] != ["generation.review.package.details", "generation.review.package.copy-package", "generation.review.discard"]:
            return False
        if sum(item.get("kind") == "keyboard" and item.get("characters", "").lower() == "z" for item in inputs) != 3:
            return False
        menus = [item for item in inputs if item.get("kind") == "menu"]
        for identifier, count in {"ai-edit.upscale": 2, "music.model": 1, "music.input": 1,
                                  "generation.edit.model": 2, "generation.edit.voice": 1}.items():
            selected = [item for item in menus if item.get("id") == identifier]
            if len(selected) != count or any(item.get("closed") is not True or len(item.get("path", [])) != 1 for item in selected):
                return False
        moods = [item for item in menus if item.get("id") == "music.actions"]
        if ([item.get("path") for item in moods] != [["Use Timeline Video"], ["Mood", "Ambient"], ["Mood", "Ambient"]]
            or any(item.get("closed") is not True for item in moods)):
            return False
        fields = [item["field"] for item in inputs if item.get("kind") == "text" and isinstance(item.get("field"), dict)]
        for identifier, count in {"generation.edit.intent": 4, "generation.edit.lyrics": 1,
                                  "agent.dialog.direction": 1, "music.intent": 1, "generation.edit.duration": 1}.items():
            selected = [field for field in fields if field.get("id") == identifier]
            if len(selected) != count or any(not field.get("expected") or field.get("expected") != field.get("actual")
                or field.get("stage") != "commit-requested" or field.get("commitInput") != "Tab" for field in selected):
                return False
        if len(images) != 14 or len(set(images)) != 14 or any(not any(name.endswith("-" + label + ".png") for name in images) for label in IMAGES):
            return False
        upscale, sfx, lyrical, timeline, speech, instrumental = evidence
        if any(not isinstance(item, dict) for item in evidence):
            return False
        initial_instrumental = instrumental.get("initialInstrumental")
        if initial_instrumental not in ("on", "off") or pointers["generation.edit.instrumental"] != (2 if initial_instrumental == "on" else 3):
            return False
        p, submit, result = _artifact(upscale, output, source=True)
        if (p["operation"] != "upscale" or p["destination"]["kind"] != "replace_clip" or not p["destination"].get("linkedSourcesSHA256")
            or submit.get("image_url") != "https://media.invalid/stage.png" or result[:8] != b"\x89PNG\r\n\x1a\n"
            or _sha(result) != upscale["outputSHA256"] or p["references"][0]["submittedSHA256"] != upscale["uploadedSHA256"]
            or not all(upscale.get(key) is True for key in ("discardDidNotDispatch", "nativeUndoRedo", "originalRetained"))):
            return False
        rerun_bytes = _file(output, upscale["rerunDiscardPackage"]).read_bytes()
        rerun = json.loads(rerun_bytes)
        rp = rerun["payload"]
        if (rerun.get("schema") != "generation-package/v1" or rerun.get("id") != upscale.get("rerunDiscardPackageID")
            or not isinstance(rerun["id"], str) or len(rerun["id"]) != 64
            or any(char not in "0123456789abcdef" for char in rerun["id"])
            or rerun["id"] == upscale["packageID"] or _sha(rerun_bytes) != upscale.get("rerunDiscardPackageSHA256")
            or rp.get("operation") != "upscale" or rp.get("target") != p["target"] or rp.get("references") != p["references"]
            or rp.get("requestParametersJSON") != p.get("requestParametersJSON")
            or rp["destination"].get("kind") != "replace_clip" or not p["destination"].get("clipID")
            or rp["destination"].get("clipID") != p["destination"]["clipID"]
            or not rp["destination"].get("linkedSourcesSHA256")
            or rp["destination"]["linkedSourcesSHA256"] == p["destination"]["linkedSourcesSHA256"]
            or not all(upscale.get(key) is True for key in ("rerunDiscardDidNotDispatch", "rerunDiscardNoError"))):
            return False
        seconds = upscale.get("rerunQuiescenceSeconds")
        checks = upscale.get("rerunQuiescenceChecks")
        if (type(seconds) not in (int, float) or not math.isfinite(seconds) or seconds < 1
            or type(checks) is not int or checks < 2):
            return False
        for key in ("Requests", "Spend"):
            before, after = upscale.get("rerun" + key + "Before"), upscale.get("rerun" + key + "After")
            if type(before) is not int or before < 1 or type(after) is not int or before != after:
                return False
        for index, item in enumerate((sfx, lyrical, timeline)):
            p, submit, result = _artifact(item, output, source=True)
            if (p["modality"] != "audio" or p["operation"] != ("music" if index == 2 else "audio")
                or submit.get("model") != ("native-acceptance-video-sfx" if index == 0 else "native-acceptance-video-music")
                or submit.get("prompt") != p["prompt"] or submit.get("duration_seconds") != 2
                or submit.get("video_url") != "https://media.invalid/native-audio-input.mov"
                or p["destination"]["kind"] != "timeline" or p["destination"]["startFrame"] != 0
                or p["destination"]["durationSeconds"] != 2 or _wav_duration(result) != 2):
                return False
            if item.get("submitFormat") != "canonical-mcp-arguments":
                return False
            if index in (0, 1):
                trim = p["generationInput"]["sourceRange"]["trim"]
                fps = item.get("sourceFPS")
                if (type(fps) is not int or fps <= 0 or trim["fps"] != fps
                    or trim["trimStartFrame"] != fps or trim["sourceFramesConsumed"] != fps * 2
                    or item["sourceTrimStartFrames"] != fps or item["sourceFramesConsumed"] != fps * 2
                    or type(item.get("decodedSourceDurationSeconds")) not in (int, float)
                    or not math.isfinite(item["decodedSourceDurationSeconds"])
                    or abs(item["decodedSourceDurationSeconds"] - 2) >= 0.02):
                    return False
            if index == 0:
                seconds, checks = item.get("discardQuiescenceSeconds"), item.get("discardQuiescenceChecks")
                if (type(seconds) not in (int, float) or not math.isfinite(seconds) or seconds < 1
                    or type(checks) is not int or checks < 2 or item.get("discardCallsAfter") != 0
                    or item.get("discardUploadsAfter") != 0
                    or type(item.get("discardCallsAfter")) is not int or type(item.get("discardUploadsAfter")) is not int
                    or type(submit.get("instrumental")) is not bool
                    or submit["instrumental"] != p["generationInput"].get("instrumental", False)
                    or item["inputSHA256"] != p["references"][0]["submittedSHA256"] or _sha(result) != item["outputSHA256"]
                    or item.get("nativeDiscardAndApproval") is not True or item.get("originalClipRetained") is not True):
                    return False
            if index == 1 and (submit.get("lyrics") != "[Verse] The city wakes in morning light."
                or p["generationInput"].get("lyrics") != submit["lyrics"]
                or _fixture_lyric_leak(p["prompt"], submit["lyrics"])
                or submit.get("instrumental") is not False or item.get("additionalAudioTrack") is not True
                or not all(item.get(key) is True for key in ("lyricsPreserved", "compiledDirectionMatched", "originalRetained"))):
                return False
            if index == 2 and (type(item.get("previewDurationSeconds")) not in (int, float)
                or not math.isfinite(item["previewDurationSeconds"]) or abs(item["previewDurationSeconds"] - 2) >= 0.02 or item.get("previewHasNoAudio") is not True
                or item.get("sourceAndPriorSFXRetained") is not True or item.get("previewSHA256") != p["references"][0]["submittedSHA256"]):
                return False
            if index == 2:
                panel_direction = "Solo piano for the visible movement."
                direction = panel_direction + " A quiet rhythmic pulse for the actual two-second cut."
                intent = p.get("intent", "")
                if (intent != ", ".join(["Ambient", "Sparse", "Warm", direction]) or not p["prompt"].startswith(intent)
                    or p["generationInput"].get("intent") != intent or item.get("composedIntent") != intent
                    or item.get("direction") != direction or item.get("mood") != "Ambient" or item.get("character") != ["Sparse", "Warm"]
                    or item.get("panelDirection") != panel_direction or item.get("compiledDirectionMatched") is not True
                    or item.get("dialogModelAndInputDisabled") is not True or item.get("nativeStaleBindingUndo") is not True
                    or "input changed" not in item.get("staleBindingError", "")
                    or item.get("menuAvailability") != [
                        {"kind": "empty", "trackTypes": [], "inputMode": "Video to Music", "useTimelineVideoEnabled": False, "moodEnabled": False, "prepareEnabled": False},
                        {"kind": "audioOnly", "trackTypes": ["audio"], "inputMode": "Video to Music", "useTimelineVideoEnabled": False, "moodEnabled": False, "prepareEnabled": False}]
                    or not any(field.get("id") == "agent.dialog.direction" and field.get("actual") == direction for field in fields)
                    or not any(field.get("id") == "music.intent" and field.get("actual") == panel_direction for field in fields)):
                    return False
        for item, is_music in ((speech, False), (instrumental, True)):
            p, submit, result = _artifact(item, output, source=False)
            if item.get("submitFormat") != "raw-http-body":
                return False
            if p["operation"] != "audio" or p["modality"] != "audio" or p["destination"]["kind"] != "media_library":
                return False
            if is_music:
                duration, decoded = item.get("requestedDurationSeconds"), item.get("decodedFixtureDurationSeconds")
                if (type(duration) is not int or not 3 <= duration <= 8
                    or type(decoded) not in (int, float) or not math.isfinite(decoded) or abs(decoded - duration) >= 0.02
                    or p["target"]["modelId"] != "fal-ai/elevenlabs/music" or p["generationInput"].get("duration") != duration
                    or p["generationInput"].get("instrumental") is not True or submit.get("prompt") != p["prompt"]
                    or submit.get("music_length_ms") != duration * 1000 or submit.get("force_instrumental") is not True
                    or item.get("instrumental") is not True or _wav_duration(result) != duration
                    or abs(decoded - _wav_duration(result)) >= 0.02):
                    return False
            elif (not item.get("voice") or not isinstance(item.get("defaultVoice"), str)
                  or item["voice"] == item["defaultVoice"] or p["generationInput"].get("voice") != item["voice"]
                  or submit.get("voice") != item["voice"] or submit.get("text") != p["prompt"]
                  or _sha(result) != item.get("outputSHA256") or _wav_duration(result) != 2):
                return False
        return True
    except (AttributeError, KeyError, TypeError, ValueError, OSError, struct.error, OverflowError):
        return False
