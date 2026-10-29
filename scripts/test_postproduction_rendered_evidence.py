"""Synthetic evidence shapes only; no native execution or rendered-effect quality claim."""
import binascii
import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

from postproduction_rendered_evidence import CASES, DEFAULTS, NUMERIC, artifact, difference, gradient_delta, png_pixels, upright_gradient, validate, zone
from production_technical_owner_evidence import digest


def png(pixels, channels=4, mode=0, width=320, height=180):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xffffffff)
    if len(pixels) != width * height * 4: raise ValueError("Fixture dimensions do not match pixels")
    previous, rows = bytes(width * channels), bytearray()
    for y in range(height):
        source = pixels[y * width * 4:(y + 1) * width * 4]
        row = source if channels == 4 else bytes(value for i, value in enumerate(source) if i % 4 != 3)
        rows.append(mode)
        if mode == 0:
            rows.extend(row); previous = row; continue
        for i, value in enumerate(row):
            left, above = row[i - channels] if i >= channels else 0, previous[i]
            corner = previous[i - channels] if i >= channels else 0
            prediction = left + above - corner
            distances = [abs(prediction - v) for v in (left, above, corner)]
            paeth = (left, above, corner)[distances.index(min(distances))]
            rows.append((value - (0, left, above, (left + above) // 2, paeth)[mode]) & 255)
        previous = row
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6 if channels == 4 else 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def rendered_fixture(output, scale=1.5):
    name = f"post-rendered-{int(scale * 100)}"
    directory = output / name; directory.mkdir(exist_ok=True)
    rows, images = [], []
    def state(label, evidence): rows.append({"kind": "verified-state", "label": label, "evidence": evidence})
    def screen(label):
        filename = f"{name}-{len(images)}-{label}.png"
        (output / filename).write_bytes(png(original)); images.append(filename)
    def save(label, pixels, timeline):
        composition = {"width": timeline["width"], "height": timeline["height"], "fps": timeline["fps"],
            "layers": [clip for track in reversed(timeline["tracks"]) for clip in track["clips"]]}
        files = {label + ".rgba": pixels, label + ".png": png(pixels), label + ".json": json.dumps(timeline, sort_keys=True).encode(),
            label + ".composition.json": json.dumps(composition, sort_keys=True).encode()}
        for file, data in files.items(): (directory / file).write_bytes(data)
        return {file: digest(data) for file, data in files.items()}
    original = bytes(value for y in range(180) for x in range(320)
        for value in ([0, 255, 0, 255] if x < 80 else [255, 0, 0, 255] if x < 160 else [min(255, (x - 160) // 2 + y), y, y // 2, 255]))
    background = bytes([0, 0, 255, 255]) * (320 * 180)
    sources = {}
    for label, pixels in (("Foreground", original), ("Background", background)):
        for suffix, data in ((".rgba", pixels), (".png", png(pixels))):
            (directory / (label + suffix)).write_bytes(data); sources[label + suffix] = digest(data)
        screen("file-panel")
        screen("file-selected")
        rows.append({"kind": "file-panel", "path": label + ".png", "selectedURLVerified": True, "nativePathEditorVerified": True})
    assets = ["foreground", "background"]
    baseline = {"width": 320, "height": 180, "fps": 30, "tracks": [{"id": asset + "-track", "clips": [{"id": asset + "-clip", "mediaRef": asset,
        "startFrame": 0, "durationFrames": 150, "trimStartFrame": 0}]} for asset in assets]}
    rows += [{"kind": "pointer", "id": "source.overwrite." + asset} for asset in assets]
    baseline_files = save("baseline", original, baseline)
    state("rendered adjustments begin", {"clipID": "foreground-clip", "assetIDs": assets, "files": baseline_files, "sources": sources,
        "frame": 0, "width": 320, "height": 180})
    screen("baseline")
    for key in CASES:
        numeric = next((value for value in NUMERIC if value[0] == key), None)
        if numeric:
            effect, parameter, text, number = numeric
            params = {name: {"value": value} for name, value in {**DEFAULTS[effect], parameter: number}.items()}
            rows.append({"kind": "pointer", "id": "inspector.adjust.value." + effect + "." + parameter})
            rows.append({"kind": "text", "field": {"id": "inspector.adjust.value." + effect + "." + parameter,
                "expected": text, "actual": text, "requiresFocusExit": True, "focusLeftTarget": True, "ownsEditor": False, "stage": "commit-requested"}})
        elif key.startswith(("wheel-", "level-")):
            kind, wheel = key.split("-"); effect = "color.wheels"
            if kind == "wheel":
                changes = {wheel + "_x": .4, wheel + "_y": .2}
                rows.append({"kind": "drag", "id": "inspector.wheel." + wheel.title(), "start": [.5, .5], "end": [.7, .6]})
            else:
                changes = {wheel + "_m": {"lift": .3, "gamma": 1.7, "gain": 1.3}[wheel]}
                rows.append({"kind": "pointer", "id": "inspector.wheel.level." + wheel.title(), "frame": [100, 120, 80, 20], "point": [164, 130]})
            params = {name: {"value": value} for name, value in {**DEFAULTS[effect], **changes}.items()}
        else:
            prefix, channel = key.rsplit("-", 1)
            mapping = {"Y": "master", "R": "red", "G": "green", "B": "blue"} if prefix == "curve" else {"Hue": "hueVsHue", "Sat": "hueVsSat", "Luma": "hueVsLum"}
            points = [(0, 0), (.5, .75), (1, 1)] if prefix == "curve" else [(i / 6, .75 if i == 3 else .5) for i in range(6)]
            curves = {name: ([{"x": x, "y": y} for x, y in points] if name == mapping[channel] else []) for name in mapping.values()}
            effect = "color.curves" if prefix == "curve" else "color.hueCurves"
            params = {"curve" if prefix == "curve" else "curves": {"string": json.dumps(curves)}}
            rows.append({"kind": "segment-accessibility", "id": "inspector." + prefix + ".channel", "item": channel})
            rows.append({"kind": "drag", "id": "inspector." + prefix + ".canvas", "start": [.5, .5], "end": [.5, .75]})
        actual = copy.deepcopy(baseline)
        actual["tracks"][0]["clips"][0]["effects"] = [{"id": key, "type": effect, "enabled": True, "params": params}]
        pixels = bytes((max(0, value - 20) if i % 4 != 3 else value) for i, value in enumerate(original))
        if key == "key.chroma":
            pixels = bytes(v for y in range(180) for x in range(320)
                for v in ([0, 0, 255, 255] if x < 80 else original[(y * 320 + x) * 4:(y * 320 + x) * 4 + 4]))
        screen(key)
        state("rendered adjustment before undo", {"case": key, "effect": effect, "frame": 0, "files": save(key, pixels, actual)})
        rows.append({"kind": "keyboard", "characters": "z", "modifiers": 1 << 20})
        state("rendered adjustment restored", {"case": key, "files": save(key + "-undo", original, baseline), "frame": 0})
    state("rendered adjustments completed", {"cases": CASES, "baselineFiles": baseline_files})
    value = {"directory": name, "progress": name + ".json", "cases": CASES, "scale": scale, "effectiveScale": scale,
        "backingScale": 2, "viewport": [960, 640], "interactions": rows, "screenshots": images}
    checkpoint(output, value)
    return value


def checkpoint(output, value):
    (output / value["progress"]).write_text(json.dumps({"failure": None, "interactions": value["interactions"], "screenshots": value["screenshots"]}))


class RenderedOutputEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name); self.value = rendered_fixture(self.output)

    def test_complete_synthetic_shape_and_pixels(self):
        self.assertTrue(validate(self.value, self.output, 1.5)[0])

    def test_missing_native_action_or_case_is_rejected(self):
        for index, row in enumerate(self.value["interactions"]):
            if row["kind"] not in ("text", "drag", "segment-accessibility", "keyboard", "file-panel", "pointer"): continue
            changed = copy.deepcopy(self.value); changed["interactions"].pop(index); checkpoint(self.output, changed)
            self.assertFalse(validate(changed, self.output, 1.5)[0], index)

    def test_checkpoint_and_measured_scale_are_required(self):
        for key, bad in (("effectiveScale", 1), ("backingScale", True), ("viewport", [1440, 960]), ("cases", CASES[:-1]), ("screenshots", self.value["screenshots"][:-1])):
            changed = {**self.value, key: bad}
            self.assertFalse(validate(changed, self.output, 1.5)[0], key)
        changed = copy.deepcopy(self.value); changed["interactions"].pop()
        self.assertFalse(validate(changed, self.output, 1.5)[0])

    def replace_artifact(self, label, suffix, data):
        (self.output / self.value["directory"] / (label + suffix)).write_bytes(data)
        for row in self.value["interactions"]:
            files = row.get("evidence", {}).get("files", {})
            if label + suffix in files: files[label + suffix] = digest(data)
        checkpoint(self.output, self.value)

    def replace_timeline(self, label, timeline):
        self.replace_artifact(label, ".json", json.dumps(timeline).encode())
        composition = {"width": timeline["width"], "height": timeline["height"], "fps": timeline["fps"],
            "layers": [clip for track in reversed(timeline["tracks"]) for clip in track["clips"]]}
        self.replace_artifact(label, ".composition.json", json.dumps(composition).encode())

    def entry(self, label):
        return next(row["evidence"] for row in self.value["interactions"] if label + ".rgba" in row.get("evidence", {}).get("files", {}))

    def test_screenshot_cannot_replace_changed_rendered_pixels(self):
        directory = self.output / self.value["directory"]
        for suffix in (".rgba", ".png"):
            self.replace_artifact("blur.motion", suffix, (directory / ("baseline" + suffix)).read_bytes())
        self.assertFalse(validate(self.value, self.output, 1.5)[0])

    def test_chroma_requires_original_underlying_blue_and_untouched_red(self):
        directory = self.output / self.value["directory"]
        pixels = bytearray((directory / "key.chroma.rgba").read_bytes())
        for i in range(0, len(pixels), 4): pixels[i:i + 3] = bytes([0, 0, 0])
        self.replace_artifact("key.chroma", ".rgba", bytes(pixels)); self.replace_artifact("key.chroma", ".png", png(pixels))
        self.assertFalse(validate(self.value, self.output, 1.5)[0])

    def test_png_rgba_source_and_undo_closure(self):
        directory = self.output / self.value["directory"]
        for name in ("Foreground.png", "blur.motion.png", "level-gain-undo.rgba", "curve-R.json"):
            path = directory / name; before = path.read_bytes(); path.write_bytes(before + b"changed")
            self.assertFalse(validate(self.value, self.output, 1.5)[0], name); path.write_bytes(before)

    def test_unrelated_timeline_mutation_is_rejected_even_with_matching_hash(self):
        path = self.output / self.value["directory"] / "blur.gaussian.json"
        timeline = json.loads(path.read_bytes()); timeline["tracks"][1]["clips"][0]["durationFrames"] = 149
        self.replace_timeline("blur.gaussian", timeline)
        retained, _ = artifact(path.parent, self.entry("blur.gaussian"), "blur.gaussian")
        self.assertEqual(retained, timeline)
        self.assertFalse(validate(self.value, self.output, 1.5)[0])

    def test_wrong_channel_and_uncommitted_field_are_rejected(self):
        changed = copy.deepcopy(self.value)
        field = next(r["field"] for r in changed["interactions"] if r["kind"] == "text")
        field["focusLeftTarget"] = False; checkpoint(self.output, changed)
        self.assertFalse(validate(changed, self.output, 1.5)[0])
        changed = copy.deepcopy(self.value)
        selection = next(r for r in changed["interactions"] if r["kind"] == "segment-accessibility")
        selection["item"] = "R"; checkpoint(self.output, changed)
        self.assertFalse(validate(changed, self.output, 1.5)[0])

    def test_bounded_png_rejects_wrong_size_and_trailing_bytes(self):
        data = (self.output / self.value["directory"] / "baseline.png").read_bytes()
        self.assertEqual(len(png_pixels(data)), 320 * 180 * 4)
        for bad in (data + b"tail", data[:100], b"not png"):
            with self.assertRaises(ValueError): png_pixels(bad)

    def test_all_png_filters_and_rgb_channels_decode_exact_pixels(self):
        pixels = (self.output / self.value["directory"] / "baseline.rgba").read_bytes()
        for channels in (3, 4):
            for mode in range(5):
                self.assertEqual(png_pixels(png(pixels, channels=channels, mode=mode)), pixels, (channels, mode))
        with self.assertRaisesRegex(ValueError, "dimensions"):
            png_pixels(png(b"".join(pixels[y * 1280:y * 1280 + 319 * 4] for y in range(180)), width=319))

    def test_png_filters_match_independently_constructed_constant_rgb_vectors(self):
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xffffffff)
        rgb, half, zero = bytes([7, 29, 83]), bytes([4, 15, 42]), bytes(3)
        header = chunk(b"IHDR", struct.pack(">IIBBBBB", 320, 180, 8, 2, 0, 0, 0))
        vectors = [(rgb * 320, rgb * 320), (rgb + zero * 319, rgb + zero * 319),
                   (rgb * 320, zero * 320), (rgb + half * 319, half + zero * 319), (rgb + zero * 319, zero * 320)]
        for mode, (first, later) in enumerate(vectors):
            data = b"\x89PNG\r\n\x1a\n" + header + chunk(b"IDAT", zlib.compress(bytes([mode]) + first + (bytes([mode]) + later) * 179)) + chunk(b"IEND", b"")
            self.assertEqual(png_pixels(data), bytes([7, 29, 83, 255]) * (320 * 180), mode)

    def test_png_header_must_precede_other_chunks(self):
        data = (self.output / self.value["directory"] / "baseline.png").read_bytes()
        kind, payload = b"tEXt", b"label\x00fixture"
        ancillary = struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload) & 0xffffffff)
        with self.assertRaisesRegex(ValueError, "header must be first"):
            png_pixels(data[:8] + ancillary + data[8:])

    def test_intermediate_composition_snapshot_is_rejected_after_hash_rebind(self):
        directory = self.output / self.value["directory"]
        composition = json.loads((directory / "blur.sharpen.composition.json").read_bytes())
        composition["layers"][-1]["effects"][0]["params"]["amount"]["value"] = .4
        self.replace_artifact("blur.sharpen", ".composition.json", json.dumps(composition).encode())
        self.assertFalse(validate(self.value, self.output, 1.5)[0])

    def test_previous_overlapping_pixel_delta_is_neither_changed_nor_restored(self):
        directory = self.output / self.value["directory"]
        original = (directory / "baseline.rgba").read_bytes()
        pixels, remaining = bytearray(original), 20736
        for i, value in enumerate(original):
            if remaining and i % 4 != 3 and value < 255:
                pixels[i] += 1; remaining -= 1
        self.assertEqual(remaining, 0)
        for label in ("blur.motion", "blur.motion-undo"):
            before_rgba, before_png = (directory / (label + ".rgba")).read_bytes(), (directory / (label + ".png")).read_bytes()
            self.replace_artifact(label, ".rgba", bytes(pixels)); self.replace_artifact(label, ".png", png(pixels))
            self.assertFalse(validate(self.value, self.output, 1.5)[0], label)
            self.replace_artifact(label, ".rgba", before_rgba); self.replace_artifact(label, ".png", before_png)

    def test_flipped_baseline_cannot_mask_orientation_error(self):
        directory = self.output / self.value["directory"]
        original = (directory / "baseline.rgba").read_bytes()
        flipped = b"".join(original[y * 1280:(y + 1) * 1280] for y in reversed(range(180)))
        self.replace_artifact("baseline", ".rgba", flipped); self.replace_artifact("baseline", ".png", png(flipped))
        self.assertFalse(validate(self.value, self.output, 1.5)[0])

    def test_flipped_source_baseline_and_all_outputs_cannot_mask_orientation(self):
        directory = self.output / self.value["directory"]
        begin = next(row["evidence"] for row in self.value["interactions"] if row.get("label") == "rendered adjustments begin")
        source = (directory / "Foreground.rgba").read_bytes()
        flipped = b"".join(source[y * 1280:(y + 1) * 1280] for y in reversed(range(180)))
        for suffix, data in ((".rgba", flipped), (".png", png(flipped))):
            (directory / ("Foreground" + suffix)).write_bytes(data); begin["sources"]["Foreground" + suffix] = digest(data)
        for label in ["baseline"] + [label for case in CASES for label in (case, case + "-undo")]:
            pixels = (directory / (label + ".rgba")).read_bytes()
            pixels = b"".join(pixels[y * 1280:(y + 1) * 1280] for y in reversed(range(180)))
            self.replace_artifact(label, ".rgba", pixels); self.replace_artifact(label, ".png", png(pixels))
        self.assertEqual(difference((directory / "baseline.rgba").read_bytes(), flipped), 0)
        self.assertFalse(upright_gradient(flipped))
        self.assertFalse(validate(self.value, self.output, 1.5)[0])

    def test_each_changed_render_must_retain_the_source_orientation(self):
        directory = self.output / self.value["directory"]
        for label in ("blur.motion", "wheel-lift", "level-gain", "curve-R", "hue-curve-Sat", "key.chroma"):
            before = (directory / (label + ".rgba")).read_bytes()
            flipped = b"".join(before[y * 1280:(y + 1) * 1280] for y in reversed(range(180)))
            self.replace_artifact(label, ".rgba", flipped); self.replace_artifact(label, ".png", png(flipped))
            self.assertEqual(artifact(directory, self.entry(label), label)[1], flipped)
            self.assertLess(gradient_delta(flipped), 0)
            self.assertFalse(validate(self.value, self.output, 1.5)[0], label)
            self.replace_artifact(label, ".rgba", before); self.replace_artifact(label, ".png", png(before))

    def test_rehashed_source_pair_still_requires_declared_green_and_red(self):
        directory = self.output / self.value["directory"]
        pixels = bytearray((directory / "Foreground.rgba").read_bytes())
        for y in range(180):
            for x in range(80, 160): pixels[(y * 320 + x) * 4:(y * 320 + x) * 4 + 3] = b"\xff\xff\x00"
        begin = next(row["evidence"] for row in self.value["interactions"] if row.get("label") == "rendered adjustments begin")
        for suffix, data in ((".rgba", bytes(pixels)), (".png", png(pixels))):
            (directory / ("Foreground" + suffix)).write_bytes(data); begin["sources"]["Foreground" + suffix] = digest(data)
        for label in ["baseline"] + [case + "-undo" for case in CASES]:
            self.replace_artifact(label, ".rgba", bytes(pixels)); self.replace_artifact(label, ".png", png(pixels))
        self.assertEqual(difference((directory / "baseline.rgba").read_bytes(), pixels), 0)
        self.assertTrue(upright_gradient(pixels))
        self.assertEqual(zone(pixels, 90, 150), b"\xff\xff\x00" * (160 * 60))
        checkpoint(self.output, self.value)
        self.assertFalse(validate(self.value, self.output, 1.5)[0])

    def test_extra_mutation_input_and_wrong_restored_frame_are_rejected(self):
        for event in ({"kind": "keyboard", "characters": "z", "modifiers": 1 << 20},
                      {"kind": "text", "field": {"id": "foreign", "stage": "commit-requested"}},
                      {"kind": "drag", "id": "foreign"}):
            changed = copy.deepcopy(self.value)
            before = next(i for i, row in enumerate(changed["interactions"]) if row.get("label") == "rendered adjustment before undo")
            changed["interactions"].insert(before, event); checkpoint(self.output, changed)
            self.assertFalse(validate(changed, self.output, 1.5)[0], event)
            changed = copy.deepcopy(self.value)
            before = next(i for i, row in enumerate(changed["interactions"]) if row.get("label") == "rendered adjustment before undo")
            changed["interactions"].insert(before + 1, event); checkpoint(self.output, changed)
            self.assertFalse(validate(changed, self.output, 1.5)[0], event)
        changed = copy.deepcopy(self.value)
        next(row["evidence"] for row in changed["interactions"] if row.get("label") == "rendered adjustment restored")["frame"] = 1
        checkpoint(self.output, changed)
        self.assertFalse(validate(changed, self.output, 1.5)[0])

    def test_hidden_parameters_are_rejected_with_rebound_composition(self):
        directory = self.output / self.value["directory"]
        for label, parameter, value in (("color.highlightsShadows", "highlights", .4), ("wheel-lift", "gain_m", 1.2),
                                        ("level-gain", "gamma_x", .2), ("curve-R", "hidden", .2)):
            path = directory / (label + ".json")
            before = json.loads(path.read_bytes()); timeline = copy.deepcopy(before)
            timeline["tracks"][0]["clips"][0]["effects"][0]["params"][parameter] = {"value": value}
            self.replace_timeline(label, timeline)
            self.assertEqual(artifact(directory, self.entry(label), label)[0], timeline)
            self.assertFalse(validate(self.value, self.output, 1.5)[0], label)
            self.replace_timeline(label, before)

    def test_curve_direction_is_positive_in_both_editors(self):
        directory = self.output / self.value["directory"]
        for label, parameter, channel in (("curve-R", "curve", "red"), ("hue-curve-Sat", "curves", "hueVsSat")):
            before = json.loads((directory / (label + ".json")).read_bytes()); timeline = copy.deepcopy(before)
            params = timeline["tracks"][0]["clips"][0]["effects"][0]["params"]
            curves = json.loads(params[parameter]["string"])
            next(point for point in curves[channel] if point["x"] == .5)["y"] = .25
            params[parameter]["string"] = json.dumps(curves)
            self.replace_timeline(label, timeline)
            self.assertEqual(artifact(directory, self.entry(label), label)[0], timeline)
            self.assertFalse(validate(self.value, self.output, 1.5)[0], label)
            self.replace_timeline(label, before)

    def test_each_input_family_rejects_extra_mutating_pointer_and_unknown_scroll(self):
        for label in ("color.exposure", "wheel-lift", "level-gain", "curve-R", "hue-curve-Sat"):
            for event in ({"kind": "pointer", "id": "inspector.wheel.level.Gain"},
                          {"kind": "wheel", "id": "foreign", "delta": 100, "before": [0, 0], "after": [0, 100]}):
                changed = copy.deepcopy(self.value)
                before = next(i for i, row in enumerate(changed["interactions"]) if row.get("label") == "rendered adjustment before undo" and row["evidence"]["case"] == label)
                changed["interactions"].insert(before, event); checkpoint(self.output, changed)
                self.assertFalse(validate(changed, self.output, 1.5)[0], (label, event))

    def test_level_pointer_must_hit_eighty_percent_of_the_actual_frame(self):
        changed = copy.deepcopy(self.value)
        next(row for row in changed["interactions"] if row.get("id") == "inspector.wheel.level.Lift")["point"] = [140, 130]
        checkpoint(self.output, changed)
        self.assertFalse(validate(changed, self.output, 1.5)[0])

    def test_only_section_closure_can_follow_final_undo(self):
        changed = copy.deepcopy(self.value)
        changed["interactions"].insert(-1, {"kind": "pointer", "id": "inspector.section.Hue Curves"})
        checkpoint(self.output, changed)
        self.assertTrue(validate(changed, self.output, 1.5)[0])
        changed["interactions"].insert(-1, {"kind": "pointer", "id": "inspector.wheel.level.Gain"})
        checkpoint(self.output, changed)
        self.assertFalse(validate(changed, self.output, 1.5)[0])
        changed = copy.deepcopy(self.value)
        changed["interactions"].append({"kind": "pointer", "id": "inspector.section.Hue Curves"})
        checkpoint(self.output, changed)
        self.assertFalse(validate(changed, self.output, 1.5)[0])

    def test_missing_file_panel_capture_shape_is_rejected(self):
        for index in range(4):
            changed = copy.deepcopy(self.value); changed["screenshots"].pop(index); checkpoint(self.output, changed)
            self.assertFalse(validate(changed, self.output, 1.5)[0], index)


if __name__ == "__main__": unittest.main()
