"""Check native caption decisions against exact timelines and decoded export bytes."""
from array import array
from collections import Counter
import copy
import hashlib
import json
import math
import sys
import uuid

from production_frames_owner_evidence import read, states, visible_group


def require(value, reason):
    if not value:
        raise ValueError(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def linked_cut(before, after):
    require(before["fps"] == after["fps"] == 30 and before["width"] == after["width"] == 320
            and before["height"] == after["height"] == 180, "Speech cut changed the actual canvas or clock")
    require(len(before["tracks"]) == len(after["tracks"]) == 3, "Speech cut changed track count")
    expected = copy.deepcopy(before)
    expected["tracks"] = copy.deepcopy(after["tracks"])
    require(expected == after, "Speech cut changed unrelated timeline metadata")
    pairs = []
    for index in (1, 2):
        original, track = before["tracks"][index], after["tracks"][index]
        expected_track = copy.deepcopy(original)
        expected_track["clips"] = track["clips"]
        require(expected_track == track and len(original["clips"]) == 1 and len(track["clips"]) == 2,
                "Speech cut changed track state or lost a surviving source range")
        source = original["clips"][0]
        require(source["startFrame"] == source["trimStartFrame"] == source["trimEndFrame"] == 0
                and source["durationFrames"] == 180 and source["speed"] == source["volume"] == 1,
                "Speech fixture does not bind the full six-second original")
        clips = sorted(track["clips"], key=lambda clip: clip["startFrame"])
        for part, start, duration, trim_start, trim_end in zip(clips, (0, 30), (30, 120), (0, 60), (150, 0)):
            expected_part = copy.deepcopy(source)
            expected_part.update(id=part["id"], linkGroupId=part.get("linkGroupId"), startFrame=start,
                                 durationFrames=duration, trimStartFrame=trim_start, trimEndFrame=trim_end)
            actual_part = copy.deepcopy(part)
            effects = actual_part.pop("effects", [])
            require(not source.get("effects") and len(effects) == 1, "Speech fixture gained an unrelated effect")
            effect = effects[0]
            uuid.UUID(effect["id"])
            require(set(effect) == {"id", "type", "enabled", "params"} and effect["type"] == "core.clip-envelope.v1"
                    and effect["enabled"] is True and set(effect["params"]) == {"definition"}
                    and set(effect["params"]["definition"]) == {"string"}, "Speech split changed its actual reserved envelope")
            envelope = json.loads(effect["params"]["definition"]["string"])
            require(envelope == {"start": -trim_start, "end": 180 - trim_start,
                "head": {"anchor": -trim_start, "length": 0, "interpolation": "linear"},
                "tail": {"anchor": 180 - trim_start, "length": 0, "interpolation": "linear"}},
                "Speech split altered the original unity-gain envelope clock")
            if "effects" in source:
                actual_part["effects"] = source["effects"]
            require(expected_part == actual_part and part.get("linkGroupId"),
                    "Speech cut changed clip content or used the wrong original trim")
        require(clips[0]["id"] == source["id"] and clips[1]["id"] != source["id"],
                "Speech cut lost its original left clip or reused its identity")
        pairs.append([part["linkGroupId"] for part in clips])
    original_group = before["tracks"][1]["clips"][0].get("linkGroupId")
    require(original_group and before["tracks"][2]["clips"][0].get("linkGroupId") == original_group
            and pairs[0] == pairs[1] and pairs[0][0] == original_group and pairs[0][0] != pairs[0][1],
            "Surviving video/audio source ranges are not linked to their actual matching partners")
    require(len({clip["id"] for track in after["tracks"] for clip in track["clips"]}) == 6,
            "Speech cut reused a clip identity")
    expected_captions = copy.deepcopy(before["tracks"][0])
    expected_first = expected_captions["clips"][0]
    require(expected_first["textContent"] == "Hello um world" and expected_first["startFrame"] == 0
            and expected_first["durationFrames"] == 90 and not expected_first.get("effects"),
            "The actual caption does not span the speech interval before removal")
    expected_first.update(textContent="Hello world", durationFrames=60)
    expected_captions["clips"][1]["startFrame"] -= 30
    actual_captions = copy.deepcopy(after["tracks"][0])
    effects = actual_captions["clips"][0].pop("effects", [])
    require(len(effects) == 1 and effects[0]["id"] == before["tracks"][0]["clips"][0]["id"] + ".speech-envelope"
            and effects[0]["type"] == "core.clip-envelope.v1" and effects[0]["enabled"] is True
            and set(effects[0]["params"]) == {"definition"}
            and set(effects[0]["params"]["definition"]) == {"string"}
            and json.loads(effects[0]["params"]["definition"]["string"]) == {
                "start": 0, "end": 90, "head": {"anchor": 0, "length": 0, "interpolation": "linear"},
                "tail": {"anchor": 90, "length": 0, "interpolation": "linear"}},
            "Speech caption duration changed its retained unity-gain appearance envelope")
    if "effects" in before["tracks"][0]["clips"][0]:
        actual_captions["clips"][0]["effects"] = before["tracks"][0]["clips"][0]["effects"]
    require(actual_captions == expected_captions,
            "Speech cut left deleted words in a spanning caption, failed to ripple its follower, or changed its styling")


def fixture_geometry(timeline):
    require([track["id"] for track in timeline["tracks"]] == ["caption-track", "picture-track", "voice-track"],
            "Caption fixture must composite its visible captions above the opaque picture")
    require(timeline["width"] == 320 and timeline["height"] == 180, "Caption fixture marker geometry changed")
    for caption in timeline["tracks"][0]["clips"]:
        transform = caption["transform"]
        require(all(transform[key] == value for key, value in {"centerX": .5, "centerY": .7, "width": .9, "height": .15}.items()),
                "Caption fixture placement changed")
        top = (transform["centerY"] - transform["height"] / 2) * 180
        bottom = (transform["centerY"] + transform["height"] / 2) * 180
        require(top > 32 + 4 and bottom < 148 - 4,
                "Visible caption bounds and shadow must stay outside both physical identity bands")


def row_centers(data, width, count):
    require(type(width) is int and 0 < width <= 8192 and type(count) is int and count > 0
            and len(data) == width * count * 4, "Decoded picture row dimensions differ from physical bytes")
    values = []
    for frame in range(count):
        row = data[frame * width * 4:(frame + 1) * width * 4]
        white = [x for x in range(width) if min(row[x * 4:x * 4 + 3]) > 220]
        require(len(white) >= 3, "The actual decoded moving marker is missing")
        values.append(sum(white) / (len(white) * width))
    return values


def picture_cut(original, final):
    require(len(original) == 180 and len(final) == 150
            and all(type(x) in (int, float) and math.isfinite(x) and 0 <= x <= 1 for x in original + final),
            "Decoded picture times or positions are invalid")
    expected = original[:30] + original[60:]
    require(max(abs(a - b) for a, b in zip(expected, final)) <= 2 / 320,
            "The exported moving marker differs from the planned picture cut")
    require(final[30] - final[29] > 0.04 and original[-1] - original[0] > 0.3,
            "A static or uncut picture was substituted for actual moving output")


def frame_ids(data, count):
    require(type(count) is int and count > 0 and len(data) == count * 2 * 320 * 4,
            "Decoded frame-identity rows differ from physical bytes")
    identities = []
    for frame in range(count):
        decoded = []
        for band in range(2):
            row = data[(frame * 2 + band) * 1280:(frame * 2 + band + 1) * 1280]
            bits = []
            for cell in range(18):
                samples = [row[(32 + cell * 14 + x) * 4 + channel] for x in range(4, 10) for channel in range(3)]
                mean = sum(samples) / len(samples)
                if mean < 64: bits.append(0)
                elif mean > 191: bits.append(1)
                else: break
            if len(bits) == 18 and bits[:2] == [1, 0] and all(bits[i + 2] + bits[i + 10] == 1 for i in range(8)):
                decoded.append(sum(bits[i + 2] << i for i in range(8)))
        require(len(decoded) == 2 and len(set(decoded)) == 1, "Both physical frame-identity bands must decode and agree")
        identities.append(decoded[0])
    return identities


def frame_cut(original, final):
    require(original == list(range(180)) and final == list(range(30)) + list(range(60, 180)),
            "Decoded frame identities do not remove precisely original frames 30…59")


def float_samples(data):
    require(data and len(data) % 4 == 0, "Decoded PCM bytes are incomplete")
    samples = array("f")
    samples.frombytes(data)
    if sys.byteorder != "little":
        samples.byteswap()
    require(all(math.isfinite(value) for value in samples), "Decoded PCM contains nonfinite samples")
    return samples


def alignment(original, final, source_start, output_start, count, *, max_lag=1024):
    positions = range(0, count, 8)
    target = [final[output_start + index] for index in positions]
    mean = sum(target) / len(target)
    target = [value - mean for value in target]
    energy = sum(value * value for value in target)
    require(energy > 1e-5, "Actual exported sound is silent")
    best, best_lag = -1.0, None
    for lag in range(-max_lag, max_lag + 1):
        if source_start + lag < 0 or source_start + count + lag > len(original):
            continue
        source = [original[source_start + lag + index] for index in positions]
        center = sum(source) / len(source)
        source = [value - center for value in source]
        source_energy = sum(value * value for value in source)
        if source_energy > 1e-5:
            score = sum(a * b for a, b in zip(source, target)) / math.sqrt(source_energy * energy)
            if score > best:
                best, best_lag = score, lag
    require(best_lag is not None, "Actual exported sound has no source alignment")
    return best, best_lag


def correlation(original, final, source_start, output_start, count):
    return alignment(original, final, source_start, output_start, count, max_lag=512)[0]


def audio_cut(original, final):
    require(len(original) == 96_000 and 79_000 <= len(final) <= 81_024,
            "Actual PCM duration is not six seconds before and five seconds after removal")
    scores, global_lag = [], None
    for source, output, wrong in ((0.1, 0.1, 1.1), (2.2, 1.2, 1.2), (5.2, 4.2, 4.2)):
        args = (round(source * 16_000), round(output * 16_000), 11_200)
        correct, lag = alignment(original, final, *args)
        if global_lag is None: global_lag = lag
        require(abs(lag - global_lag) <= 8,
                "Exported audio changes its source alignment across the speech cut by more than eight samples")
        incorrect = correlation(original, final, round(wrong * 16_000), args[1], args[2])
        require(correct > 0.86 and correct > incorrect + 0.25,
                "Actual exported PCM does not preserve the source around the canonical one-second cut")
        scores.append({"sourceSeconds": source, "outputSeconds": output,
                       "correlation": correct, "wrongRangeCorrelation": incorrect, "lagSamples": lag,
                       "globalLagSamples": global_lag, "relativeLagToleranceSamples": 8})
    for side, source_start, output_start, wrong_start in (("before", 16_000 - 512, 16_000 - 512, 32_000 - 512),
                                                         ("after", 32_000, 16_000, 16_000)):
        aligned_output = output_start - global_lag
        require(0 <= aligned_output and aligned_output + 512 <= len(final), "The actual cut-boundary PCM is missing")
        correct, relative_lag = alignment(original, final, source_start, aligned_output, 512, max_lag=8)
        incorrect, _ = alignment(original, final, wrong_start, aligned_output, 512, max_lag=8)
        require(correct > .86 and correct > incorrect,
                "Actual exported PCM uses the removed source at the canonical cut boundary")
        scores.append({"boundarySide": side, "sourceSeconds": source_start / 16_000, "outputSeconds": aligned_output / 16_000,
                       "correlation": correct, "wrongRangeCorrelation": incorrect, "lagSamples": global_lag + relative_lag,
                       "globalLagSamples": global_lag, "relativeLagToleranceSamples": 8, "windowSamples": 512})
    return scores


def validate(directory, expected_scale=None):
    def load(name):
        return json.loads(read(directory, name))

    result = load("result.json")
    require(result["schema"] == "caption-revision-owner/v1" and result["liveAgent"] is False
            and result["liveTranscription"] is False and result["proposalCount"] == 5 and result["speechCalls"] >= 4,
            "Caption evidence makes an unsupported agent or speech-recognition claim")
    for flag in ("nativeCancel", "nativeSelectiveApply", "nativeSingleUndoRedo", "nativeTimelineStaleRefusal",
                 "nativeSourceStaleRefusal", "nativeSpeechCuts", "nativeSaveAndReopen"):
        require(result.get(flag) is True, "Native operation was not reached: " + flag)
    before, applied, cut = load("before.json"), load("caption-applied.json"), load("speech-after.json")
    fixture_geometry(before)
    require([row["id"] for row in before["tracks"][0]["clips"]] == ["caption-one", "caption-two"]
            and [(row["startFrame"], row["durationFrames"], row["textContent"]) for row in before["tracks"][0]["clips"]]
                == [(0, 90, "Hello um wurld"), (90, 30, "Fal cloud")]
            and before["tracks"][1]["clips"][0]["mediaRef"] == "picture"
            and before["tracks"][2]["clips"][0]["mediaRef"] == "voice",
            "The native proposal did not begin with the two existing captions")
    expected = copy.deepcopy(before)
    expected["tracks"][0]["clips"][0]["textContent"] = "Hello um world"
    require(applied == expected and load("after-cancel.json") == before and load("caption-undo.json") == before
            and load("caption-redo.json") == applied, "Cancel, selective caption apply or one native Undo/Redo changed unrelated state")
    require(load("speech-before.json") == applied and load("speech-undo.json") == applied
            and load("speech-redo.json") == cut and load("reopened.json") == cut
            and load("Caption revision.ngv/project.json") == cut,
            "Speech cut, native Undo/Redo or save/reopen lost its exact timeline")
    linked_cut(applied, cut)
    changed = load("stale-timeline-before-apply.json")
    require(changed != applied and load("stale-timeline-refused.json") == changed
            and load("stale-source-refused.json") == applied, "A stale native caption proposal partially applied")
    original_ids = {clip["id"] for track in applied["tracks"] for clip in track["clips"]}
    changed_originals = [clip for track in changed["tracks"] for clip in track["clips"] if clip["id"] in original_ids]
    require(changed_originals == [clip for track in applied["tracks"] for clip in track["clips"]]
            and len([clip for track in changed["tracks"] for clip in track["clips"]]) == len(original_ids) + 1,
            "The independent native Add Text did not preserve the existing media and captions")
    source_hash = digest(read(directory, "original-voice.wav"))
    require(source_hash == result["sourceSHA256"] and read(directory, "changed-source.bin") == read(directory, "original-voice.wav")[::-1],
            "The controlled source fault has no independently checked original bytes")
    project_ids, generations, roots = set(), set(), set()
    for index in range(1, 6):
        plan = load(f"proposal-{index}.json")
        scope = plan["scope"]
        project_ids.add(scope["projectID"]); generations.add(scope["generation"]); roots.add(scope["workingRoot"])
        require(scope["timelineSHA256"] == digest(read(directory, "before.json" if index <= 2 else "caption-applied.json"))
                and scope["captionIDs"] == ["caption-one", "caption-two"],
                "A native proposal is not bound to the exact current project timeline bytes")
        rows = plan["rows"]
        if index <= 3:
            require(scope["kind"] == "captions" and scope["sources"] == [] and not plan.get("wordRemoval")
                    and [row["id"] for row in rows] == ["caption-one", "caption-two"]
                    and [row["timeRange"] for row in rows] == ["0.00–3.00 s", "3.00–4.00 s"]
                    and [row["before"] for row in rows] == (["Hello um wurld", "Fal cloud"] if index <= 2 else ["Hello um world", "Fal cloud"])
                    and [row["after"] for row in rows] == (["Hello um world", "fal.ai"] if index <= 2 else ["Hello um world!", "fal.ai!"]),
                    "Native caption proposal lost its exact visible before/after or unchanged timing")
        else:
            removal = plan["wordRemoval"]
            edits = removal["edits"]
            require(scope["kind"] == "speech_cuts" and removal["scope"] == scope and edits["trackID"] == "voice-track"
                    and edits["fps"] == 30 and edits["ranges"] == [{"start": 30, "end": 60}] and edits["removedTexts"] == ["um"]
                    and edits["ignored"] == [] and edits["aggressiveness"] == "balanced"
                    and edits["contexts"] == [{"start": 30, "end": 60, "before": "Hello um world", "after": "Hello world"}]
                    and rows == [{"id": "speech-cuts", "before": "Hello um world", "after": "Hello world", "timeRange": "1.00–2.00 s"}],
                    "The canonical speech proposal does not remove actual transcript word index one")
            require([source["assetID"] for source in scope["sources"]] == ["picture", "voice"]
                    and [source["sha256"] for source in scope["sources"]] == [digest(read(directory, "original-movement.mov")), source_hash]
                    and scope["sources"] == load("proposal-4.json")["scope"]["sources"],
                    "Speech approval is not bound to both actual linked video and audio source bytes")
            caption_edits = edits["captionEdits"]
            require(caption_edits["primaryTrackID"] == "voice-track" and caption_edits["ranges"] == edits["ranges"]
                    and caption_edits["timelineSHA256"] == scope["timelineSHA256"]
                    and caption_edits["changes"] == [{"trackID": "caption-track", "before": a, "after": [b]}
                        for a, b in zip(applied["tracks"][0]["clips"], cut["tracks"][0]["clips"])],
                    "Actual caption timing/text changes differ from the complete native speech proposal")
    require(len(project_ids) == len(generations) == len(roots) == 1,
            "Proposals belong to different native project sessions")
    manifest = load("manifest.json")
    require(load("Caption revision.ngv/media.json") == manifest, "Native save/reopen did not persist the captured media manifest")
    entries = {entry["id"]: entry for entry in manifest["entries"]}
    require(set(entries) == {"picture", "voice"}, "Save/reopen replaced the original media identities")
    for asset, filename in (("picture", "Movement.mov"), ("voice", "Voice.wav")):
        relative = entries[asset]["source"]["project"]["relativePath"]
        require(relative == "media/" + filename, "Save/reopen changed an original project source path")
        captured = read(directory, "Caption revision.ngv/" + relative)
        require(digest(captured) == digest(read(directory, "original-movement.mov" if asset == "picture" else "original-voice.wav")),
                "The actual saved project no longer contains its original media bytes")
    interactions = result["interactions"]
    clicks = Counter(row.get("id") for row in interactions if row.get("kind") == "pointer")
    require(clicks["agent.task.run"] == 5 and clicks["agent.dialog.cancel"] == 3
            and clicks["agent.dialog.confirm"] == 4 and clicks["editing.add-text"] == 1
            and clicks["captions.revision.choice.caption-one"] == 3
            and clicks["captions.revision.choice.caption-two"] == 0
            and clicks["captions.revision.choice.speech-cuts"] == 1
            and clicks["export.start"] == 1, "Native menu, selective decision or export pointer evidence is incomplete")
    menus = [row for row in interactions if row.get("kind") == "menu" and row.get("id") == "captions.actions"]
    require([row["item"] for row in menus] == ["Fix names & jargon"] * 3 + ["Propose speech cuts…"] * 2
            and all(row.get("closed") is True and row["item"] in row["titles"] for row in menus),
            "The actual native Caption actions were not tracked and selected")
    keys = [row for row in interactions if row.get("kind") == "keyboard" and row.get("code") == 6]
    require([row["characters"] for row in keys] == ["z", "Z", "z", "z", "Z"]
            and all(row["modifiers"] & (1 << 20) for row in keys)
            and [bool(row["modifiers"] & (1 << 17)) for row in keys] == [False, True, False, False, True],
            "Single native Cmd-Z/Cmd-Shift-Z did not operate on the actual project")
    seen = states(interactions, "native caption proposal visible")
    require(len(seen) == 5 and all(row["applyEnabled"] is False and row["selected"] == [] for row in seen),
            "A native proposal started with changes selected or an enabled Apply action")
    for index, row in enumerate(seen, 1):
        proposal = load(f"proposal-{index}.json")
        require(row["kind"] == proposal["scope"]["kind"]
                and row["ids"] == [part["id"] for part in proposal["rows"]]
                and row["before"] == [part["before"] for part in proposal["rows"]]
                and row["after"] == [part["after"] for part in proposal["rows"]]
                and row["times"] == [part["timeRange"] for part in proposal["rows"]],
                "Visible native caption choices differ from their canonical proposal")
    impacts = states(interactions, "native speech caption impacts visible")
    require(len(impacts) == 2 and [row["proposal"] for row in impacts] == [4, 5]
            and all(row["ids"] == ["caption-track/caption-one", "caption-track/caption-two"] and row["before"] == ["Hello um world", "Fal cloud"]
                and row["after"] == ["Hello world", "Fal cloud"]
                and row["times"] == ["0.00–3.00 s → 0.00–2.00 s", "3.00–4.00 s → 2.00–3.00 s"] for row in impacts),
            "The spanning caption and its follower were not explicitly shown before native speech approval")
    for label in ("stale caption timeline refused", "stale caption source refused"):
        errors = states(interactions, label)
        require(len(errors) == 1 and "changed" in errors[0]["error"], "Stale Apply did not show an actual user-visible refusal")
    source_error = states(interactions, "stale caption source refused")[0]
    require(source_error["originalSHA256"] == source_hash
            and source_error["changedSHA256"] == digest(read(directory, "changed-source.bin")), "Source-fault refusal did not bind the actual changed bytes")
    visible = [row for row in interactions if row.get("kind") == "visible-group"]
    for row_id in ("caption-one", "caption-two", "speech-cuts"):
        require(any("captions.revision.choice." + row_id in row.get("ids", []) and visible_group(row) for row in visible),
                "A proposed native choice was not fully visible")
    for row_id in ("caption-one", "caption-two"):
        require(any("captions.revision.impact.caption-track/" + row_id in row.get("ids", []) and visible_group(row) for row in visible),
                "An actual speech caption impact was not fully visible")
    screenshots = result["screenshots"]
    require(len(screenshots) >= 9 and len(set(screenshots)) == len(screenshots)
            and all(read(directory, name).startswith(b"\x89PNG\r\n\x1a\n") for name in screenshots),
            "Actual native proposal, failure, Undo or export screenshots are absent")
    tools = load("tools.json")
    counts = Counter(row["label"] for row in tools)
    require(counts["native-proposal"] == counts["wrong-kind"] == counts["read-timeline"] == 5
            and counts["real-transcript"] == 2 and counts["completed-reproposal"] == 5
            and counts["direct-mutation"] == 20, "Actual scoped runtime tool evidence is incomplete")
    for row in tools:
        expected_tools = {"direct-mutation": {"set_clip_properties", "remove_words"},
                          "wrong-kind": {"propose_caption_revision"}, "native-proposal": {"propose_caption_revision"},
                          "completed-reproposal": {"propose_caption_revision"}, "read-timeline": {"get_timeline"},
                          "real-transcript": {"get_transcript"}}
        require(row["tool"] in expected_tools.get(row["label"], set()), "A different tool was substituted for the scoped caption check")
        if row["label"] in ("direct-mutation", "completed-reproposal", "wrong-kind"):
            phrase = "kind must match" if row["label"] == "wrong-kind" else "caption revision task"
            require(row["isError"] is True and phrase in row["result"], "A scoped agent mutation or invalid proposal was not rejected")
        else:
            require(row["isError"] is False, "The actual scoped read or canonical proposal failed")
    require(Counter(row["tool"] for row in tools if row["label"] == "direct-mutation")
            == {"set_clip_properties": 10, "remove_words": 10}, "Both direct agent text mutation and destructive cuts were not independently rejected")
    proposals = [row["args"] for row in tools if row["label"] == "native-proposal"]
    for index, args in enumerate(proposals, 1):
        if index <= 3:
            require(args == {"kind": "captions", "changes": [
                {"clipId": "caption-one", "text": "Hello um world" + ("!" if index >= 3 else "")},
                {"clipId": "caption-two", "text": "fal.ai" + ("!" if index >= 3 else "")}]},
                "The actual bounded agent request differs from the native caption proposal")
        else:
            require(args == {"kind": "speech_cuts", "words": [1], "cutAggressiveness": "balanced"},
                    "The actual native speech cut does not originate from transcript index one")
    for transcript in [json.loads(row["result"]) for row in tools if row["label"] == "real-transcript"]:
        require(transcript["fps"] == 30 and transcript["timing"] == "projectFrames"
                and len(transcript["clips"]) == 1 and transcript["clips"][0]["clipId"] == "voice-clip"
                and transcript["clips"][0]["words"] == [[0, "Hello", 0, 30], [1, "um", 30, 60], [2, "world", 60, 90]],
                "Actual get_transcript did not map the frozen source words to the canonical timeline")
    decoded = result["decoded"]
    bindings = (("original-movement.mov", "originalVideoSHA256"), ("original-voice.wav", "originalAudioSHA256"),
                (result["movie"], "movieSHA256"), ("original-centers.json", "originalCentersSHA256"),
                ("movie-centers.json", "movieCentersSHA256"), ("original.f32le", "originalPCMSHA256"),
                ("movie.f32le", "moviePCMSHA256"), ("original.rows.bgra", "originalRowsSHA256"),
                ("movie.rows.bgra", "movieRowsSHA256"),
                ("original.frame-ids.bgra", "originalIdentityRowsSHA256"), ("movie.frame-ids.bgra", "movieIdentityRowsSHA256"),
                ("original-frame-ids.json", "originalFrameIDsSHA256"), ("movie-frame-ids.json", "movieFrameIDsSHA256"))
    for filename, key in bindings:
        require(digest(read(directory, filename)) == decoded[key], "Actual decoded output evidence bytes changed: " + filename)
    require(decoded["durationTimescale"] > 0 and decoded["durationValue"] == 5 * decoded["durationTimescale"]
            and decoded["originalFrames"] == 180 and decoded["movieFrames"] == 150 and decoded["sampleRate"] == 16_000,
            "Actual export clock or visual frame coverage is wrong")
    original = row_centers(read(directory, "original.rows.bgra"), decoded["originalRowWidth"], 180)
    final = row_centers(read(directory, "movie.rows.bgra"), decoded["movieRowWidth"], 150)
    require(original == load("original-centers.json") and final == load("movie-centers.json"),
            "Claimed marker positions do not match independently inspected decoded pixels")
    picture_cut(original, final)
    original_ids = frame_ids(read(directory, "original.frame-ids.bgra"), 180)
    final_ids = frame_ids(read(directory, "movie.frame-ids.bgra"), 150)
    require(original_ids == load("original-frame-ids.json") and final_ids == load("movie-frame-ids.json"),
            "Claimed frame identities do not match independently decoded physical pixels")
    frame_cut(original_ids, final_ids)
    source_pcm, final_pcm = float_samples(read(directory, "original.f32le")), float_samples(read(directory, "movie.f32le"))
    require(len(source_pcm) == decoded["originalAudioSamples"] and len(final_pcm) == decoded["movieAudioSamples"],
            "Actual decoded PCM byte counts differ")
    scores = audio_cut(source_pcm, final_pcm)
    delivery = load("delivery.json")
    qc = delivery["probe_qc"]
    require(delivery["schema"] == "delivery-attempt/v1" and delivery["status"] == "succeeded"
            and delivery["output_sha256"] == decoded["movieSHA256"]
            and delivery["finished_timeline_sha256"] == digest(read(directory, "speech-after.json"))
            and delivery["output_byte_count"] == len(read(directory, result["movie"]))
            and delivery["failures"] == [] and qc["passed"] is True and qc["audio_channels"] > 0
            and qc["fps_numerator"] == 30 * qc["fps_denominator"]
            and qc["duration_value"] == 5 * qc["duration_timescale"], "Actual native export receipt or audio/video QC failed")
    from caption_translation_evidence import validate as validate_translation
    from pathlib import Path
    translation = validate_translation(Path(directory) / "translation", expected_scale=expected_scale)
    require(result.get("translation") == translation, "Native translation result differs from its retained artifact")
    return {"nativeTranslation": True, "nativeCaptionDecisions": True, "exactLinkedRipple": True, "physicalPictureCut": True,
            "physicalAudioCut": True, "physicalFrameIdentities": True, "audioRelativeLagToleranceSamples": 8, "audioCorrelations": scores,
            "liveAgent": False, "liveTranscription": False}
