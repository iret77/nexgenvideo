import hashlib
import json
import math
import struct
from pathlib import Path


def local(root, relative):
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError("Missing local evidence")
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError("Evidence escapes its directory")
    return path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def number(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def source_operations_evidence(rows, output, scale):
    try:
        records = [row for row in rows if row.get("event") == "source-operations"]
        complete = [row for row in rows if row.get("event") == "completed" and row.get("case") == "sourceoperations"]
        if (len(records) != 1 or len(complete) != 1 or any(row.get("event") == "failed" for row in rows)
            or any(row.get("scale") != scale for row in records + complete)):
            return False, []
        row = records[0]
        if (row.get("viewport") != [960, 640] or row.get("effectiveScale") != scale
            or row.get("typographyBaseSize") != 13 or not number(row.get("renderedFontSize"))
            or abs(row["renderedFontSize"] - 13 * scale) >= .5):
            return False, []
        directory = local(output, row["directory"])
        package = local(directory, row["project"])
        before = json.loads(local(directory, "before.json").read_text())
        saved = json.loads(local(package, "project.json").read_text())
        if len(before["tracks"]) != 4 or len(saved["tracks"]) != 4:
            return False, []
        expected = json.loads(json.dumps(before))
        original = expected["tracks"][0]["clips"][0]
        if (original["id"] != "picture" or original["mediaRef"] != "original" or original["trimStartFrame"] != 60
            or original["speed"] != 2 or original["durationFrames"] != 60 or before["fps"] != 30
            or expected["tracks"][2]["clips"][0]["startFrame"] != 60):
            return False, []
        original["mediaRef"] = "replacement"
        expected["tracks"][2]["clips"][0]["startFrame"] = 0
        if saved != expected or row.get("refusal") != "Audio contains no usable non-silent anchors.":
            return False, []
        manifest = json.loads(local(package, "media.json").read_text())
        entries = {entry["id"]: entry for entry in manifest["entries"]}
        initial = json.loads(local(directory, "before-media.json").read_text())
        initial_entries = {entry["id"]: entry for entry in initial["entries"]}
        added = {row["clipID"], row["rangeID"]}
        if (len(added) != 2 or len(entries) != len(manifest["entries"])
            or len(initial_entries) != len(initial["entries"]) or added.intersection(initial_entries)
            or len(entries) != len(initial_entries) + 2
            or {key: value for key, value in entries.items() if key not in added} != initial_entries):
            return False, []
        for kind, frames, first_source in (("clip", 60, 60), ("range", 30, 90)):
            item = row[kind]
            entry = entries[row[kind + "ID"]]
            source = local(package, entry["source"]["project"]["relativePath"])
            movie = local(directory, kind + ".mp4")
            pixels_path = local(directory, item["pixels"])
            pixels = pixels_path.read_bytes()
            motion = json.loads(local(directory, item["motion"]).read_text())
            if (source.stat().st_size < 1000 or sha(source) != sha(movie) or sha(movie) != item["sha256"]
                or sha(pixels_path) != item["pixelsSHA256"] or len(pixels) != frames * 4
                or item["frames"] != frames or not number(item["duration"]) or abs(item["duration"] - frames / 30) >= .05
                or not number(entry["duration"]) or abs(entry["duration"] - frames / 30) >= .05
                or len(motion) != frames):
                return False, []
            for index in range(frames):
                blue, green, red, alpha = pixels[index * 4:index * 4 + 4]
                target = 104.5 + 120 * (first_source + 2 * index) / 239
                if not (blue > 180 and red < 35 and 25 < green < 90 and alpha == 255
                    and number(motion[index]) and abs(motion[index] - target) < 3):
                    return False, []
        if entries[row["rangeID"]].get("hasAudio") is not True:
            return False, []
        audio = row["range"]["audio"]
        audio_path = local(directory, audio["file"])
        raw = audio_path.read_bytes()
        if (len(raw) % 4 or audio.get("sampleRate") != 16000 or sha(audio_path) != audio["sha256"]
            or audio.get("sampleCount") != len(raw) // 4 or not 14400 <= audio["sampleCount"] <= 17600):
            return False, []
        samples = [value[0] for value in struct.iter_unpack("<f", raw)]
        if not all(number(value) for value in samples):
            return False, []
        rms = math.sqrt(sum(value * value for value in samples) / len(samples))
        if not number(audio.get("rms")) or abs(rms - audio["rms"]) > 1e-6 or not .01 < rms < 1:
            return False, []
        actions = row["interactions"]
        menus = [tuple(item.get("path", [])) for item in actions if item.get("kind") == "context-menu" and item.get("closed") is True]
        if (menus.count(("Swap Media",)) != 2 or menus.count(("Synchronize", "Audio")) != 2
            or any(path not in menus for path in (("Save as Media",), ("Save Range as Media",), ("Clear Range",)))):
            return False, []
        fonts = [item.get("evidence", {}) for item in actions if item.get("kind") == "verified-state" and item.get("label") == "rendered typography"]
        if (len(fonts) != 1 or fonts[0].get("id") != "inspector.value.Speed"
            or fonts[0].get("pointSize") != row["renderedFontSize"] or fonts[0].get("baseSize") != 13 or fonts[0].get("scale") != scale):
            return False, []
        for action in actions:
            if action.get("kind") == "verified-state" and action.get("label") == "source-operation-wheel":
                wheel = action.get("evidence", {})
                if not number(wheel.get("beforeY")) or not number(wheel.get("afterY")) or wheel["beforeY"] == wheel["afterY"]:
                    return False, []
        pointers = [item.get("id") for item in actions if item.get("kind") == "pointer"]
        gestures = [item.get("evidence", {}).get("target") for item in actions if item.get("kind") == "verified-state"
            and item.get("label") == "source-operation-gesture" and item.get("evidence", {}).get("shift") is True]
        keys = [item.get("characters") for item in actions if item.get("kind") == "keyboard"]
        if ("media.swap.cancel" not in pointers or "media.asset.replacement" not in pointers
            or any(target not in gestures for target in ("range-15-45", "select-recorder", "select-silence"))
            or keys.count("z") < 2 or keys.count("Z") < 2 or "s" not in keys):
            return False, []
        images = row["screenshots"]
        if len(images) != 5 or len(set(images)) != 5:
            return False, []
        for label in ("swap-source", "saved-clip", "saved-range", "synchronized-audio", "sync-refused"):
            paths = [local(output, image) for image in images if image.endswith("-" + label + ".png")]
            if len(paths) != 1 or paths[0].stat().st_size < 1000 or not paths[0].read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
                return False, []
        return True, images
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        return False, []
