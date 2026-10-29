"""Native effect inputs joined to actual player-composition pixels before Undo."""
import binascii
import copy
import json
import math
import struct
import zlib

from production_technical_owner_evidence import digest, read, states

NUMERIC = [
    ("color.exposure", "ev", "1.00", 1), ("color.contrast", "amount", "1.50", 1.5),
    ("color.highlightsShadows", "shadows", "0.60", .6), ("color.blacksWhites", "blacks", "0.40", .4),
    ("color.temperature", "temperature", "8500", 8500), ("color.vibrance", "amount", "0.80", .8),
    ("color.saturation", "amount", "0.20", .2), ("blur.sharpen", "amount", "0.80", .8),
    ("blur.noiseReduction", "amount", "1.00", 1), ("detail.clarity", "clarity", "0.80", .8),
    ("blur.gaussian", "radius", "10", 10), ("blur.motion", "radius", "10", 10),
    ("stylize.vignette", "amount", "0.70", .7), ("stylize.grain", "amount", "0.60", .6),
    ("stylize.glow", "intensity", "0.80", .8), ("key.chroma", "tolerance", "0.30", .3)]
CASES = [v[0] for v in NUMERIC] + [kind + "-" + wheel for wheel in ("lift", "gamma", "gain") for kind in ("wheel", "level")]
CASES += ["curve-" + channel for channel in ("Y", "R", "G", "B")] + ["hue-curve-" + channel for channel in ("Hue", "Sat", "Luma")]
DEFAULTS = {
    "color.exposure": {"ev": 0}, "color.contrast": {"amount": 1},
    "color.highlightsShadows": {"highlights": 0, "shadows": 0}, "color.blacksWhites": {"blacks": 0, "whites": 0},
    "color.temperature": {"temperature": 6500, "tint": 0}, "color.vibrance": {"amount": 0},
    "color.saturation": {"amount": 1}, "blur.sharpen": {"amount": .4},
    "blur.noiseReduction": {"amount": 0, "chroma": .6, "detail": .5}, "detail.clarity": {"clarity": 0, "dehaze": 0},
    "blur.gaussian": {"radius": 8}, "blur.motion": {"radius": 0, "angle": 0},
    "stylize.vignette": {"amount": 0, "midpoint": .5, "roundness": 0, "feather": .5},
    "stylize.grain": {"amount": 0, "size": 1.5}, "stylize.glow": {"intensity": 0, "radius": 20, "threshold": .6, "warmth": 0},
    "key.chroma": {"keyHue": .333, "tolerance": 0, "softness": .5, "spill": .5},
    "color.wheels": {"lift_x": 0, "lift_y": 0, "lift_m": 0, "gamma_x": 0, "gamma_y": 0, "gamma_m": 1,
                     "gain_x": 0, "gain_y": 0, "gain_m": 1}}
SECTIONS = {"inspector.section." + title for title in ("Basic Correction", "Effects", "Detail", "Blur", "Motion Blur",
    "Vignette", "Film Grain", "Glow", "Chroma Key", "Color Wheels", "Curves", "Hue Curves")}


def numeric_params(params, effect, changes, tolerance=0):
    expected = {**DEFAULTS[effect], **changes}
    if set(params) != set(expected): return False
    for key, number in expected.items():
        if (not isinstance(params[key], dict) or set(params[key]) != {"value"}
            or type(params[key]["value"]) not in (int, float) or not math.isfinite(params[key]["value"])): return False
        allowed = tolerance if key in changes else 0
        if abs(params[key]["value"] - number) > allowed: return False
    return True


def png_pixels(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) > 3_000_000:
        raise ValueError("Missing bounded raster PNG")
    offset, header, compressed, kind = 8, None, bytearray(), None
    while offset < len(data):
        if len(data) - offset < 12: raise ValueError("Truncated PNG chunk")
        size = struct.unpack_from(">I", data, offset)[0]
        if size > len(data) - offset - 12: raise ValueError("Truncated PNG")
        kind, payload = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + size]
        if header is None and kind != b"IHDR": raise ValueError("PNG header must be first")
        if binascii.crc32(kind + payload) & 0xffffffff != struct.unpack_from(">I", data, offset + 8 + size)[0]: raise ValueError("Changed PNG")
        if kind == b"IHDR":
            if header is not None or size != 13: raise ValueError("Repeated PNG header")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT": compressed.extend(payload)
        offset += size + 12
        if kind == b"IEND":
            if size != 0 or offset != len(data): raise ValueError("Trailing PNG")
            break
    if header not in ((320, 180, 8, 6, 0, 0, 0), (320, 180, 8, 2, 0, 0, 0)) or kind != b"IEND": raise ValueError("Wrong raster dimensions or format")
    channels = 4 if header[3] == 6 else 3
    stride, limit = 320 * channels, (320 * channels + 1) * 180
    decoder = zlib.decompressobj(); raw = decoder.decompress(compressed, limit + 1)
    if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or len(raw) != limit: raise ValueError("Wrong raster length")
    previous, result = bytearray(stride), bytearray()
    for y in range(180):
        mode = raw[y * (stride + 1)]
        if mode > 4: raise ValueError("Invalid PNG filter")
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in (range(stride) if mode else ()):
            left = row[i - channels] if i >= channels else 0
            above, corner = previous[i], previous[i - channels] if i >= channels else 0
            p = left + above - corner
            distances = [abs(p - left), abs(p - above), abs(p - corner)]
            paeth = (left, above, corner)[distances.index(min(distances))]
            row[i] = (row[i] + (0, left, above, (left + above) // 2, paeth)[mode]) & 255
        if channels == 4: result.extend(row)
        else:
            for x in range(320): result.extend(row[x * 3:x * 3 + 3] + b"\xff")
        previous = row
    if any(value != 255 for value in result[3::4]): raise ValueError("Actual composited output must be opaque")
    return bytes(result)


def difference(left, right):
    if len(left) != 320 * 180 * 4 or len(right) != len(left): raise ValueError("Wrong RGBA dimensions")
    return sum(abs(a - b) for a, b in zip(left, right)) / len(left)


def artifact(directory, entry, label):
    expected = {label + suffix for suffix in (".png", ".rgba", ".json", ".composition.json")}
    if set(entry["files"]) != expected: raise ValueError("Missing actual timeline/raster closure")
    files = {name: read(directory, name) for name in expected}
    if any(digest(data) != entry["files"][name] for name, data in files.items()): raise ValueError("Changed actual raster bytes")
    pixels = files[label + ".rgba"]
    if png_pixels(files[label + ".png"]) != pixels: raise ValueError("PNG does not depict actual decoded pixels")
    timeline = json.loads(files[label + ".json"])
    composition = json.loads(files[label + ".composition.json"])
    if composition != {"width": timeline["width"], "height": timeline["height"], "fps": timeline["fps"],
                       "layers": [clip for track in reversed(timeline["tracks"]) for clip in track["clips"]]}:
        raise ValueError("The actual player composition is not bound to the retained final timeline")
    return timeline, pixels


def zone(pixels, left, right):
    return bytes(value for y in range(10, 170) for x in range(left, right) for value in pixels[(y * 320 + x) * 4:(y * 320 + x) * 4 + 3])


def gradient_delta(pixels):
    def brightness(top):
        return sum(max(pixels[(y * 320 + x) * 4:(y * 320 + x) * 4 + 3])
                   for y in range(top, top + 20) for x in range(170, 310)) / (20 * 140)
    return brightness(150) - brightness(10)


def upright_gradient(pixels):
    return gradient_delta(pixels) > 100


def validate(value, output, scale):
    try:
        if (not isinstance(value, dict) or value["directory"] != f"post-rendered-{int(scale * 100)}"
            or value["scale"] != scale or value["effectiveScale"] != scale or value["viewport"] != [960, 640]
            or type(value["backingScale"]) not in (int, float) or not math.isfinite(value["backingScale"]) or value["backingScale"] <= 0
            or value["cases"] != CASES): return False, []
        directory = output / value["directory"]
        if value["progress"] != value["directory"] + ".json": return False, []
        progress = json.loads(read(output, value["progress"]))
        rows, images = value["interactions"], value["screenshots"]
        if (progress.get("failure") is not None or progress["interactions"] != rows or progress["screenshots"] != images
            or len(images) != len(CASES) + 5 or len(set(images)) != len(images)): return False, []
        for label, name in zip(["file-panel", "file-selected", "file-panel", "file-selected", "baseline"] + CASES, images):
            if not name.endswith("-" + label + ".png") or "/" in name or not read(output, name).startswith(b"\x89PNG\r\n\x1a\n"): return False, []
        begin, end = states(rows, "rendered adjustments begin"), states(rows, "rendered adjustments completed")
        before, after = states(rows, "rendered adjustment before undo"), states(rows, "rendered adjustment restored")
        if (len(begin) != 1 or len(end) != 1 or end[0]["cases"] != CASES or end[0]["baselineFiles"] != begin[0]["files"]
            or [r["case"] for r in before] != CASES or [r["case"] for r in after] != CASES
            or any(type(begin[0][k]) is not int for k in ("width", "height", "frame"))
            or [begin[0][k] for k in ("width", "height", "frame")] != [320, 180, 0]): return False, []
        baseline, original = artifact(directory, begin[0], "baseline")
        if (baseline["width"], baseline["height"], baseline["fps"]) != (320, 180, 30) or len(baseline["tracks"]) != 2: return False, []
        clips = [track["clips"] for track in baseline["tracks"]]
        if any(len(items) != 1 for items in clips): return False, []
        if [items[0]["mediaRef"] for items in clips] != begin[0]["assetIDs"] or clips[0][0]["id"] != begin[0]["clipID"]: return False, []
        if any(c[0].get("effects") or c[0]["startFrame"] != 0 or c[0]["durationFrames"] != 150 or c[0]["trimStartFrame"] != 0 for c in clips): return False, []
        source_names = {name + suffix for name in ("Foreground", "Background") for suffix in (".png", ".rgba")}
        if set(begin[0]["sources"]) != source_names: return False, []
        sources = {name: read(directory, name) for name in source_names}
        if any(digest(data) != begin[0]["sources"][name] for name, data in sources.items()): return False, []
        for name in ("Foreground", "Background"):
            if png_pixels(sources[name + ".png"]) != sources[name + ".rgba"]: return False, []
        if sources["Background.rgba"] != bytes([0, 0, 255, 255]) * (320 * 180): return False, []
        foreground = sources["Foreground.rgba"]
        if difference(original, foreground) > 3 or not upright_gradient(foreground): return False, []
        if (zone(foreground, 10, 70) != bytes([0, 255, 0]) * (160 * 60)
            or zone(foreground, 90, 150) != bytes([255, 0, 0]) * (160 * 60)
            or len(set(tuple(foreground[i:i + 3]) for i in range(0, len(foreground), 4))) < 50): return False, []
        actions = [row for row in rows if row.get("kind") == "file-panel"]
        if [r.get("path") for r in actions] != ["Foreground.png", "Background.png"] or any(r.get("selectedURLVerified") is not True or r.get("nativePathEditorVerified") is not True for r in actions): return False, []
        for asset in begin[0]["assetIDs"]:
            if sum(r.get("kind") == "pointer" and r.get("id") == "source.overwrite." + asset for r in rows) != 1: return False, []
        boundary = next(i for i, row in enumerate(rows) if row.get("label") == "rendered adjustments begin")
        for key, changed, restored in zip(CASES, before, after):
            changed_index = next(i for i, row in enumerate(rows) if row.get("label") == "rendered adjustment before undo" and row["evidence"]["case"] == key)
            undo_index = next(i for i, row in enumerate(rows) if row.get("label") == "rendered adjustment restored" and row["evidence"]["case"] == key)
            if not boundary < changed_index < undo_index or type(changed["frame"]) is not int or changed["frame"] != 0 or type(restored["frame"]) is not int or restored["frame"] != 0: return False, []
            inputs = rows[boundary + 1:changed_index]
            undos = rows[changed_index + 1:undo_index]
            if len(undos) != 1 or undos[0].get("kind") != "keyboard" or undos[0].get("characters") != "z" or undos[0].get("modifiers") != 1 << 20: return False, []
            timeline, actual = artifact(directory, changed, key)
            undo, undo_pixels = artifact(directory, restored, key + "-undo")
            if undo != baseline or difference(original, undo_pixels) >= .01 or difference(original, actual) <= .1 or gradient_delta(actual) <= 0: return False, []
            clip = timeline["tracks"][0]["clips"][0]
            effects = clip.get("effects", [])
            if len(effects) != 1 or effects[0]["enabled"] is not True or effects[0]["type"] != changed["effect"]: return False, []
            params = effects[0]["params"]
            clean = copy.deepcopy(timeline); clean["tracks"][0]["clips"][0].pop("effects", None)
            expected = copy.deepcopy(baseline); expected["tracks"][0]["clips"][0].pop("effects", None)
            if clean != expected: return False, []
            numeric = next((v for v in NUMERIC if v[0] == key), None)
            texts = [r for r in inputs if r.get("kind") == "text"]
            drags = [r for r in inputs if r.get("kind") == "drag"]
            selections = [r for r in inputs if r.get("kind") == "segment-accessibility"]
            allowed = {"inspector.tab.Adjust"}
            if numeric: allowed.add("inspector.adjust.value." + numeric[0] + "." + numeric[1])
            elif key.startswith("level-"): allowed.add("inspector.wheel.level." + key.split("-")[1].title())
            elif key.startswith("wheel-"): allowed.add("inspector.wheel." + key.split("-")[1].title())
            elif key.startswith(("curve-", "hue-curve-")):
                allowed.update("inspector." + key.rsplit("-", 1)[0] + suffix for suffix in (".channel", ".canvas"))
            for row in inputs:
                kind = row.get("kind")
                if kind == "pointer" and row.get("id") not in allowed | SECTIONS: return False, []
                if kind == "visible-group" and (not isinstance(row.get("ids"), list) or not row["ids"] or any(identifier not in allowed | SECTIONS for identifier in row["ids"])): return False, []
                if kind == "wheel":
                    if row.get("id") not in allowed | SECTIONS or type(row.get("delta")) is not int or row["delta"] == 0: return False, []
                    if (not isinstance(row.get("before"), list) or not isinstance(row.get("after"), list)
                        or len(row["before"]) != 2 or len(row["after"]) != 2 or row["before"] == row["after"]
                        or any(type(v) not in (int, float) or not math.isfinite(v) for v in row["before"] + row["after"])): return False, []
                if kind not in ("pointer", "visible-group", "wheel", "text", "drag", "segment-accessibility"): return False, []
            if (len(texts), len(drags), len(selections)) != ((1, 0, 0) if numeric else (0, 1, 0) if key.startswith("wheel-") else (0, 0, 0) if key.startswith("level-") else (0, 1, 1)): return False, []
            pointers = [row["id"] for row in inputs if row.get("kind") == "pointer" and row.get("id") not in SECTIONS | {"inspector.tab.Adjust"}]
            expected_pointers = (["inspector.adjust.value." + numeric[0] + "." + numeric[1]] if numeric else
                                 ["inspector.wheel.level." + key.split("-")[1].title()] if key.startswith("level-") else [])
            if pointers != expected_pointers: return False, []
            if sum(row.get("kind") == "pointer" and row.get("id") == "inspector.tab.Adjust" for row in inputs) > (1 if key == CASES[0] else 0): return False, []
            if any(sum(row.get("kind") == "pointer" and row.get("id") == section for row in inputs) > 2 for section in SECTIONS): return False, []
            if numeric:
                effect, param, text, number = numeric
                fields = [r["field"] for r in inputs if r.get("kind") == "text" and r.get("field", {}).get("stage") == "commit-requested"]
                if (changed["effect"] != effect or len(fields) != 1 or fields[0].get("id") != "inspector.adjust.value." + effect + "." + param
                    or fields[0].get("actual") != text or fields[0].get("expected") != text or fields[0].get("requiresFocusExit") is not True
                    or fields[0].get("focusLeftTarget") is not True or fields[0].get("ownsEditor") is not False
                    or not numeric_params(params, effect, {param: number})): return False, []
            elif key.startswith(("wheel-", "level-")):
                kind, wheel = key.split("-"); title = wheel.title()
                if changed["effect"] != "color.wheels": return False, []
                if kind == "wheel":
                    drag = [r for r in inputs if r.get("kind") == "drag" and r.get("id") == "inspector.wheel." + title]
                    if (len(drag) != 1 or drag[0].get("start") != [.5, .5] or drag[0].get("end") != [.7, .6]
                        or not numeric_params(params, "color.wheels", {wheel + "_x": .4, wheel + "_y": .2}, .03)): return False, []
                elif (sum(r.get("kind") == "pointer" and r.get("id") == "inspector.wheel.level." + title for r in inputs) != 1
                      or not numeric_params(params, "color.wheels", {wheel + "_m": {"lift": .3, "gamma": 1.7, "gain": 1.3}[wheel]}, .03)): return False, []
                if kind == "level":
                    pointer = next(r for r in inputs if r.get("kind") == "pointer" and r.get("id") == "inspector.wheel.level." + title)
                    frame, point = pointer["frame"], pointer["point"]
                    if (len(frame) != 4 or len(point) != 2 or any(type(v) not in (int, float) or not math.isfinite(v) for v in frame + point)
                        or frame[2] <= 0 or frame[3] <= 0 or abs((point[0] - frame[0]) / frame[2] - .8) > .001
                        or abs((point[1] - frame[1]) / frame[3] - .5) > .001): return False, []
            else:
                prefix, channel = key.rsplit("-", 1)
                effect = "color.curves" if prefix == "curve" else "color.hueCurves"
                drag = [r for r in inputs if r.get("kind") == "drag" and r.get("id") == "inspector." + prefix + ".canvas"]
                selection = [r for r in inputs if r.get("kind") == "segment-accessibility" and r.get("id") == "inspector." + prefix + ".channel"]
                if changed["effect"] != effect or len(drag) != 1 or drag[0].get("start") != [.5, .5] or drag[0].get("end") != [.5, .75] or len(selection) != 1 or selection[0].get("item") != channel: return False, []
                parameter = "curve" if prefix == "curve" else "curves"
                if set(params) != {parameter} or set(params[parameter]) != {"string"}: return False, []
                curves = json.loads(params[parameter]["string"])
                selected = {"Y": "master", "R": "red", "G": "green", "B": "blue", "Hue": "hueVsHue", "Sat": "hueVsSat", "Luma": "hueVsLum"}[channel]
                channels = {"master", "red", "green", "blue"} if prefix == "curve" else {"hueVsHue", "hueVsSat", "hueVsLum"}
                expected_points = [(0, 0), (.5, .75), (1, 1)] if prefix == "curve" else [(i / 6, .75 if i == 3 else .5) for i in range(6)]
                if set(curves) != channels or any(points for name, points in curves.items() if name != selected) or len(curves[selected]) != len(expected_points): return False, []
                for point, (x, y) in zip(curves[selected], expected_points):
                    tolerance = .03 if x == .5 else 0
                    if (set(point) != {"x", "y"} or any(type(v) not in (int, float) or not math.isfinite(v) for v in point.values())
                        or abs(point["x"] - x) > tolerance or abs(point["y"] - y) > tolerance): return False, []
            if key == "key.chroma":
                blue, red = zone(actual, 10, 70), zone(actual, 90, 150)
                if (max(blue[0::3]) > 5 or max(blue[1::3]) > 5 or min(blue[2::3]) < 250
                    or min(red[0::3]) < 250 or max(red[1::3]) > 5 or max(red[2::3]) > 5): return False, []
            boundary = undo_index
        if rows[-1].get("kind") != "verified-state" or rows[-1].get("label") != "rendered adjustments completed": return False, []
        trailing = rows[boundary + 1:-1]
        if sum(row.get("kind") == "pointer" for row in trailing) > 1: return False, []
        for row in trailing:
            if row.get("kind") == "visible-group":
                if row.get("ids") != ["inspector.section.Hue Curves"]: return False, []
            elif row.get("kind") in ("pointer", "wheel"):
                if row.get("id") != "inspector.section.Hue Curves": return False, []
            else: return False, []
        return True, images
    except (KeyError, TypeError, ValueError, OSError, OverflowError, IndexError, StopIteration, AttributeError, struct.error, zlib.error):
        return False, []
