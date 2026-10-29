import hashlib
import json
import math
from pathlib import Path
import struct

from production_bible_entity_evidence import parsed_yaml, require, validate as validate_bible


def wav16(data):
    require(data[:4] == b"RIFF" and data[8:12] == b"WAVE" and len(data) >= 12, "actual PCM WAV")
    position, fmt, samples = 12, None, None
    while position + 8 <= len(data):
        name, size = struct.unpack_from("<4sI", data, position)
        position += 8
        require(position + size <= len(data), "truncated PCM chunk")
        chunk = data[position:position + size]
        if name == b"fmt ":
            require(fmt is None and size >= 16, "unique PCM format")
            fmt = chunk
        elif name == b"data":
            require(samples is None, "unique PCM data")
            samples = chunk
        position += size + size % 2
    require(fmt is not None and samples is not None and len(samples) % 2 == 0, "complete PCM chunks")
    code, channels, rate, byte_rate, align, bits = struct.unpack_from("<HHIIHH", fmt)
    if code == 0xFFFE and len(fmt) >= 40:
        code = struct.unpack_from("<H", fmt, 24)[0]
    require((code, channels, rate, byte_rate, align, bits) == (1, 1, 22050, 44100, 2, 16), "native analysis PCM clock")
    return [x[0] / 32768 for x in struct.iter_unpack("<h", samples)], samples


def validate(directory):
    directory = Path(directory)
    def read(name):
        require(isinstance(name, str) and Path(name).name == name, "local retained role evidence")
        require(not (directory / name).is_symlink(), "unaliasing retained role evidence")
        return (directory / name).read_bytes()
    load = lambda name: json.loads(read(name))
    evidence = load("performance-role-evidence.json")
    require(evidence.get("schema") == "nexgenvideo/performance-role-native-evidence/1"
            and evidence.get("status") == "source-only-pending" and evidence.get("scope") == "technical-dialogue-binding-only"
            and all(evidence.get(key) is False for key in ("performedSongClaim", "lipQualityClaim", "liveProviderClaim")), "honest technical scope")
    require(evidence["viewport"]["width"] == 960 and evidence["viewport"]["height"] == 640
            and evidence["viewport"]["textScale"] in (1, 1.25, 1.5), "actual minimum viewport and text scale")
    voice = load("performance-role-voice.json")
    require(voice == evidence["voice"] and voice["identifier"] in voice["availableVoiceIDs"]
            and voice["language"].startswith("en") and voice["voiceDownloadRequested"] is False
            and voice["utterance"] == "This voice owns this spoken phrase.", "actual available voice selection")
    for name, sha in (("role-speech.wav", voice["speechSHA256"]), ("role-source.wav", voice["sourceSHA256"]),
                      ("role-speech-analysis.wav", voice["normalizedSpeechSHA256"]),
                      ("performance-role-extension.json", evidence["extensionSHA256"]),
                      ("performance-role-phrase.wav", evidence["phraseSHA256"]),
                      ("performance-role-projection.yaml", evidence["projectionSHA256"]),
                      ("performance-role-audio-receipt.json", evidence["audioReceiptSHA256"]),
                      ("performance-role-analysis.json", evidence["analysisSHA256"])):
        require(hashlib.sha256(read(name)).hexdigest() == sha, "actual role source/artifact bytes: " + name)
    require(read("performance-role-extension-reopened.json") == read("performance-role-extension.json"), "actual role Save/Reopen bytes")
    speech, _ = wav16(read("role-speech-analysis.wav"))
    source, source_pcm = wav16(read("role-source.wav"))
    _, phrase_pcm = wav16(read("performance-role-phrase.wav"))
    require(source_pcm == phrase_pcm and len(source) == voice["sourceFrames"] == 22050 * 8
            and len(speech) == voice["speechFrames"] and 22050 < len(speech) < 22050 * 6
            and type(voice["sampleRate"]) is int and voice["sampleRate"] == 22050 and max(map(abs, speech)) > .01, "real whole-phrase PCM export")
    start = 11025
    require(voice["startSeconds"] == .5 and voice["endSeconds"] == (start + len(speech)) / 22050, "actual speech sample interval")
    for i, value in enumerate(source):
        t = i / 22050
        beat = t % .5
        carrier = .01 * math.sin(2 * math.pi * 173 * t) + (.5 * math.exp(-40 * beat) * math.sin(2 * math.pi * 1000 * beat) if beat < .04 else 0)
        spoken = speech[i - start] * .6 if start <= i < start + len(speech) else 0
        require(abs(value - max(-1, min(1, carrier + spoken))) <= 4 / 32768, "actual speech/rhythm source sample")
    extension = load("performance-role-extension.json")
    projection = parsed_yaml(read("performance-role-projection.yaml"))
    receipt = load("performance-role-audio-receipt.json")
    analysis = load("performance-role-analysis.json")
    require(extension["schema"] == "musicvideo-production/v2" and projection["schema"] == "shotlist/v5"
            and extension["header"]["projectID"] == projection["header"]["projectID"] == evidence["projectID"]
            and extension["header"]["revision"] == projection["header"]["revision"] == receipt["revision"], "actual project/projection identity")
    refs = [ref for ref in projection["executionPlan"]["extension_references"] if ref["id"] == "musicvideo.production.v2"]
    require(len(refs) == 1 and refs[0]["sha256"] == evidence["extensionSHA256"], "actual projection extension reference")
    require([shot["id"] for shot in projection["executionPlan"]["shots"]] == evidence["shotIDs"]
            and len(evidence["shotIDs"]) == 2 and all(shot["source_mode"] == "imported" for shot in projection["executionPlan"]["shots"]), "actual imported plan scope")
    require(len(extension["performanceSegments"]) == len(extension["performanceReceipts"]) == 1, "actual phrase ownership")
    materialized = extension["performanceSegments"][0]
    segment = materialized["draft"]
    require(segment["purpose"] == "dialogue_diegetic" and segment["id"] == "native-spoken-owner"
            and segment["shot_ids"] == evidence["shotIDs"] and segment["performer_ids"] == ["owner_performer"]
            and segment["audible_voice_ids"] == [voice["identifier"]] and len(segment["mouth_ownership"]) == 1
            and segment["source_start_sample"] == 0 and segment["source_end_sample"] == len(source)
            and segment["sample_rate"] == 22050, "actual declared performer/voice binding")
    owner = segment["mouth_ownership"][0]
    require(owner == dict(performer_id="owner_performer", voice_id=voice["identifier"], timeline_start_seconds=.5,
                          timeline_end_seconds=voice["endSeconds"]), "actual mouth owner interval")
    require(extension["track"]["sha256"] == voice["sourceSHA256"] == receipt["source"]["sha256"]
            and receipt["schema"] == "native-music-performance-audio/v2" and receipt["projectID"] == evidence["projectID"]
            and receipt["startSample"] == 0 and receipt["endSample"] == receipt["sourceFrameCount"] == len(source)
            and receipt["exportedSampleCount"] == len(source) and receipt["sampleRate"] == 22050 and receipt["channels"] == 1
            and receipt["output"]["sha256"] == materialized["segment_sha256"] == evidence["phraseSHA256"]
            and receipt["byteCount"] == len(read("performance-role-phrase.wav"))
            and extension["performanceReceipts"][0]["sha256"] == evidence["audioReceiptSHA256"], "actual host sample receipt")
    require(receipt["segmentID"] == segment["id"] and receipt["recordedAt"]
            and materialized["segment_byte_count"] == receipt["byteCount"]
            and materialized["exported_sample_count"] == len(source)
            and materialized["source_track_sha256"] == voice["sourceSHA256"], "exact materialized phrase receipt")
    require(extension["analysis"]["sha256"] == evidence["analysisSHA256"], "exact measured analysis bytes")
    ticks = projection["timebase"]["ticksPerSecond"]
    require(type(ticks) is int and ticks > 0 and len(projection["timings"]) == 2, "actual canonical timing")
    end = 0
    for timing in projection["timings"]:
        require(type(timing["startTicks"]) is int and type(timing["durationTicks"]) is int
                and timing["startTicks"] == end and timing["durationTicks"] > 0, "actual continuous coverage timing")
        end += timing["durationTicks"]
    require(end == ticks * 8, "actual complete original source coverage")
    coverage = extension["coverage"]
    require(len(coverage) == 1 and coverage[0]["id"] == "native-spoken-coverage" and coverage[0]["kind"] == "staged_vocal"
            and coverage[0]["required_role_ids"] == ["spoken-owner"] and coverage[0]["approved_exception_role_ids"] == []
            and coverage[0]["section_ids"] == [f"section-{item['index']}" for item in analysis["sections"]]
            and len(coverage[0]["evidence"]) == 1, "actual required coverage role")
    role = coverage[0]["evidence"][0]
    require(role["role_id"] == "spoken-owner" and role["shot_ids"] == evidence["shotIDs"]
            and role["performer_ids"] == ["owner_performer"] and role["reference_demand_ids"] == []
            and role["minimum_continuous_seconds"] == 1, "actual coverage/performer join")
    validate_bible(evidence["native"], directory)
    require(isinstance(evidence.get("projectKey"), str) and evidence["projectKey"].strip()
            and evidence["projectKey"] == load("bible-typed-evidence.json")["projectKey"], "actual package identity distinct from canonical project name")
    require(evidence["native"] != evidence["reopenedNative"]
            and set(evidence["native"]["screenshots"]).isdisjoint(evidence["reopenedNative"]["screenshots"]), "distinct actual reopen native record")
    reopened = [row.get("evidence") for row in evidence["reopenedNative"]["interactions"]
                if row.get("kind") == "verified-state" and row.get("label") == "actual technical role project reopened"]
    require(reopened == [dict(projectKey=evidence["projectKey"], extensionSHA256=evidence["extensionSHA256"])], "actual reopened project and extension join")
    before_save = [row.get("evidence") for row in evidence["native"]["interactions"]
                   if row.get("kind") == "verified-state" and row.get("label") == "actual technical role project before Save"]
    require(before_save == reopened, "actual pre-Save and reopened package identity")
    require(not any(row.get("label") == "actual technical role project reopened"
                    for row in evidence["native"]["interactions"]), "original role record must precede reopen")
    for native in (evidence["native"], evidence["reopenedNative"]):
        require(isinstance(native, dict) and isinstance(native.get("interactions"), list)
                and all(isinstance(event, dict) for event in native["interactions"])
                and isinstance(native.get("screenshots"), list) and native["screenshots"]
                and len(set(native["screenshots"])) == len(native["screenshots"]), "actual native role record structure")
        progress = load(native["progress"])
        require(progress.get("failure") is None and progress.get("interactions") == native["interactions"]
                and progress.get("screenshots") == native["screenshots"], "actual native role progress join")
        events = native["interactions"]
        if native is evidence["reopenedNative"]:
            marker = [i for i, event in enumerate(events) if event.get("kind") == "verified-state"
                      and event.get("label") == "actual technical role project reopened"]
            observations = [i for i, event in enumerate(events) if event.get("kind") == "verified-state"
                and event.get("label") in {"native technical role bindings inspected", "complete compiled direction inspected", "native disclosure pointer"}]
            require(marker == [0] and observations and all(i > marker[0] for i in observations), "actual reopen precedes new native inspection")
        inspected = [row["evidence"] for row in events if row.get("kind") == "verified-state"
                     and row.get("label") == "native technical role bindings inspected"]
        require(len(inspected) == 1 and inspected[0].get("segmentID") == segment["id"]
                and inspected[0]["performerIDs"] == segment["performer_ids"]
                and inspected[0]["audibleVoiceIDs"] == segment["audible_voice_ids"]
                and inspected[0]["performedSongClaim"] is False, "actual native owner/voice inspection")
        readable_voice = voice["identifier"]
        expected_mouth = f"Reference performer → {readable_voice} · 0.500–{voice['endSeconds']:.3f} s"
        expected_coverage = "Shot 1, Shot 2 · at least 1.000 s continuously"
        require(inspected[0]["mouthText"] == expected_mouth and inspected[0]["coverageText"] == expected_coverage, "exact visible role/interval text")
        expected_texts = {"production.musicvideo.performers.native-spoken-owner": "Reference performer",
                          "production.musicvideo.voices.native-spoken-owner": readable_voice,
                          "production.musicvideo.purpose.native-spoken-owner": "Shot 1, Shot 2 · Dialogue / scene audio",
                          "production.musicvideo.mouth.native-spoken-owner.0": expected_mouth,
                          "production.musicvideo.coverage.native-spoken-coverage.spoken-owner": expected_coverage}
        readings = [row["evidence"] for row in events if row.get("kind") == "verified-state"
                    and row.get("label") == "complete compiled direction inspected"]
        for identifier, value in expected_texts.items():
            matches = [row for row in readings if row.get("id") == identifier]
            require(len(matches) == 1 and matches[0]["textSHA256"] == hashlib.sha256(value.encode()).hexdigest()
                    and matches[0]["height"] > 0 and matches[0]["coveredHeight"] >= matches[0]["height"] - 1, "actual complete visible role reading")
        require(any(name.endswith("-role-and-coverage-visible.png") for name in native["screenshots"]), "actual role review screenshot")
        disclosure = {row["evidence"]["id"] for row in events if row.get("kind") == "verified-state"
                      and row.get("label") == "native disclosure pointer"}
        require({"production.musicvideo.performance.open", "production.musicvideo.coverage.open"} <= disclosure, "actual native disclosure input")
        for image in native["screenshots"]:
            require(Path(image).name == image and len(read(image)) > 1000 and read(image).startswith(b"\x89PNG\r\n\x1a\n"), "retained native role screenshot")
    negatives = evidence["negatives"]
    require([row["case"] for row in negatives] == ["foreign-performer", "unowned-voice", "missing-coverage-role"], "role negative coverage")
    inputs = evidence.get("negativeInputs")
    expected_inputs = [projection["draftReference"], projection["storyboardReference"], extension["track"], extension["analysis"], extension["treatment"]]
    require(isinstance(inputs, list) and len(inputs) == len(expected_inputs), "actual pre-promotion role input coverage")
    expected_hashes = {}
    for item, reference in zip(inputs, expected_inputs):
        require(item["path"] == reference["path"] and item["sha256"] == reference["sha256"]
                and hashlib.sha256(read(item["retained"])).hexdigest() == reference["sha256"], "actual pre-promotion role input bytes")
        expected_hashes[reference["path"]] = reference["sha256"]
    outputs = evidence.get("negativeOutputPaths")
    require(outputs == [f"shotlist/v{projection['header']['revision']}.v5.yaml", refs[0]["path"]], "actual absent role output paths")
    expected_errors = {"foreign-performer": "Invalid production planning field: musicvideo.performer.",
        "unowned-voice": f"Music Video segment {segment['id']} has inconsistent performer and voice ownership.",
        "missing-coverage-role": f"Music Video coverage {coverage[0]['id']} is missing a required role."}
    valid = dict(performance_segments=[segment], final_mix=extension["finalMix"], visual_arc=extension["visualArc"], coverage=coverage)
    for row in negatives:
        require(isinstance(row["before"], dict) and row["before"] == row["after"] and row["before"]
                and all(isinstance(path, str) and not Path(path).is_absolute() and ".." not in Path(path).parts
                        and isinstance(sha, str) and len(sha) == 64 and all(c in "0123456789abcdef" for c in sha)
                        for path, sha in row["before"].items())
                and row["before"].get("bible/bible.yaml") == hashlib.sha256(read("bible-typed-source.yaml")).hexdigest()
                and all(row["before"].get(path) == sha for path, sha in expected_hashes.items())
                and all(path not in row["before"] for path in outputs)
                and row["expectedError"] == expected_errors[row["case"]]
                and row["expectedError"] in row["error"], "negative refused without canonical mutation and expected reason")
        require(row["reason"] == {"foreign-performer": "musicvideo.performer", "unowned-voice": "mouthOwnershipMismatch",
                                  "missing-coverage-role": "coverageMissing"}[row["case"]], "actual targeted role refusal")
        expected = json.loads(json.dumps(valid))
        if row["case"] == "foreign-performer":
            expected["performance_segments"][0]["performer_ids"] = ["missing-native-performer"]
            expected["performance_segments"][0]["mouth_ownership"][0]["performer_id"] = "missing-native-performer"
            expected["coverage"][0]["evidence"][0]["performer_ids"] = ["missing-native-performer"]
        elif row["case"] == "unowned-voice":
            expected["performance_segments"][0]["mouth_ownership"][0]["voice_id"] = "missing-native-voice"
        else:
            expected["coverage"][0]["evidence"] = []
        require(row["proposal"] == expected, "negative changes only the declared role fault")
    return evidence
