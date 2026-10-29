"""Synthetic parser shapes only; not native runs, model quality or OCR acceptance."""
import base64
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

from production_cover_owner_evidence import FORMATS, KEYS, digest, validate


def data(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def png(width, height, text=False):
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value))
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            color = (240, 235, 220)
            if width // 2 <= x < 5 * width // 6 and height // 3 <= y < 2 * height // 3: color = (25, 115, 165)
            if text and 24 <= x < 300 and (30 <= y < 40 or height - 65 <= y < height - 55): color = (0, 0, 0)
            row.extend(color)
        rows.append(b"\0" + bytes(row))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")


def cover_fixture(directory, native):
    root = Path(directory); folder = root / "cover-evidence"; folder.mkdir(exist_ok=True)
    rows, images = native["interactions"], native["screenshots"]
    def write(name, raw):
        target = folder / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(raw)
        return digest(raw)
    def record(label, value):
        rows.append({"kind": "verified-state", "label": label, "evidence": value})
    def pointer(name): rows.append({"kind": "pointer", "id": name})
    def turn(value, label, typed=False):
        identifier = "message-" + str(len(rows))
        message = {"id": identifier, "role": "user", "userPresentation": {"typedText": value} if typed else {"choiceRecord": {"confirmed": True, "selections": [{"label": label, "values": value}]}}}
        raw = data(message); name = "turn-" + identifier + ".json"
        return identifier, {"turnFile": name, "turnSHA256": write(name, raw)}
    def decision(section, selected, title, labels):
        for value in selected: pointer("agent.dialog.choice." + section + "." + value)
        pointer("agent.dialog.confirm")
        identifier, files = turn(labels, title)
        record("native cover decision", {"section": section, "selected": selected, "labels": labels, "messageID": identifier, "turn": files})
    pipeline = {name: write("before/" + name, raw) for name, raw in {"gates.yaml": b"render: approved\n", "lineage.json": b"{}",
        "project.yaml": b"name: fixture\n", "brief.yaml": b"story: fixture\n", "planning/storyboard.v1.json": b"{\"revision\":1}"}.items()}
    for name in pipeline: write("after/" + name, (folder / ("before/" + name)).read_bytes())
    record("native cover formats begin", {"pipeline": pipeline, "liveProvider": False})
    record("native cover catalog", {"liveProvider": False, "endpointIDs": ["fal-ai/flux/dev", "fal-ai/flux/schnell", "fal-ai/gemini-25-flash-image/edit"],
        "requests": ["https://api.fal.ai/v1/models?category=" + category + "&status=active&limit=100" for category in ("text-to-image", "image-to-image")]})
    pointer("export.cover.start"); decision("format", ["square", "landscape", "portrait"], "Which platforms need cover artwork?", ["Square — 1:1", "Landscape — 16:9", "Portrait — 9:16"])
    kept = []
    def output(fmt, typography=False):
        name, aspect, width, height = fmt; key = name + ("-typography" if typography else "-clean")
        identifier = "asset-" + key
        decision("model", ["selected"], "Choose the " + name + (" typography model" if typography else " cover model"),
            ["Nano Banana (Gemini 2.5 Flash)" if typography else "FLUX.1 [schnell]"])
        image = png(width, height, typography); sha = digest(image)
        clean = kept[1] if typography else None
        model = "fal-ai/gemini-25-flash-image/edit" if typography else "fal-ai/flux/schnell"
        prompt = 'Integrate "NATIVE ARTIST" and "NIGHT SIGNAL" into the reference cover.' if typography else "Abstract clean cover, no lettering."
        references = [{"assetID": clean["assetID"], "sourceSHA256": clean["sha256"], "submittedSHA256": clean["sha256"]}] if typography else []
        gen_input = {"prompt": prompt, "aspectRatio": aspect}
        payload = {"prompt": prompt, "binding": {"shotId": "none"}, "destination": {"kind": "media_library"}, "generationInput": gen_input,
            "references": references, "target": {"modelId": model, "endpoint": model}}
        package = {"schema": "generation-package/v1", "id": digest(data(payload)), "payload": payload}
        package_raw = data(package)
        asset = {"id": identifier, "name": key, "type": "image", "source": {"project": {"relativePath": key + ".png"}},
            "generationInput": dict(gen_input, generationPackageID=package["id"])}
        receipt = {"schema": "generation-output-receipt/v1", "assetID": identifier, "output": {"sha256": sha, "path": key + ".png"},
            "package": {"id": package["id"], "sha256": digest(package_raw)}, "input": gen_input, "spendEvents": [{"kind": "submitted"}]}
        batch = {"batch": {"payload": {"items": [{"package": package}]}}, "journal": {"executions": [{"state": "complete", "outputAssetIDs": [identifier]}]}}
        wire = {"prompt": prompt}
        if typography: wire.update(image_urls=["https://media.invalid/frame-input-0.png"], aspect_ratio=aspect)
        else: wire["image_size"] = {"square": "square_hd", "landscape": "landscape_16_9", "portrait": "portrait_16_9"}[name]
        http = [{"method": "POST", "url": "https://queue.fal.run/" + model, "bodyBase64": base64.b64encode(data(wire)).decode()}]
        ocr = ["NATIVE ARTIST", "NIGHT SIGNAL"] if typography else []
        actual = {key + ".png": image, key + "-asset.json": data(asset), key + "-receipt.json": data(receipt), key + "-package.json": package_raw,
            key + "-batch.json": data(batch), key + "-ocr.json": data(ocr)}
        if typography:
            reference = (folder / "landscape-clean.png").read_bytes()
            actual[key + "-reference.png"] = reference
            http.append({"method": "PUT", "url": "https://upload.invalid/frame-input-0.png", "bodyBase64": base64.b64encode(reference).decode()})
        actual[key + "-http.json"] = data(http)
        files = {name: write(name, raw) for name, raw in actual.items()}; write(key + "-reopened.json", data(asset)); write(key + "-reopened.png", image)
        pointer("generation-batch.approve"); pointer("media.asset." + identifier)
        decision("review", ["keep"], "Keep Cover — " + name.title() + (" — Artist + Title?" if typography else " — Clean?"), ["Keep"])
        item = {"key": key, "format": name, "aspect": aspect, "width": width, "height": height, "assetID": identifier, "name": key,
            "sha256": sha, "packageSHA256": package["id"], "files": files, "artist": "NATIVE ARTIST" if typography else None,
            "title": "NIGHT SIGNAL" if typography else None, "referenceAssetID": clean["assetID"] if typography else None,
            "referenceSHA256": clean["sha256"] if typography else None, "recognizedText": ocr, "liveProvider": False}
        kept.append(item); record("native cover output kept", item)
        for suffix in ("-unapproved", "-preview"):
            screenshot = "unit-cover-" + key + suffix + ".png"
            (root / screenshot).write_bytes(b"\x89PNG\r\n\x1a\n" + b"unit-screenshot" * 200); images.append(screenshot)
    for fmt in FORMATS:
        decision("subject", ["abstract"], "Choose the " + fmt[0] + " cover subject", ["Abstract style image"])
        output(fmt)
        decision("typography", ["yes" if fmt[0] == "landscape" else "no"], "Create a second " + fmt[0] + " variant with artist and title?",
            ["Yes" if fmt[0] == "landscape" else "No — keep the clean cover"])
        if fmt[0] == "landscape":
            for label, value in (("Artist", "NATIVE ARTIST"), ("Title", "NIGHT SIGNAL")):
                rows.append({"kind": "text", "field": {"id": "agent.dialog.direction", "expected": value, "actual": value, "focusLeftTarget": True}})
                pointer("agent.dialog.confirm"); identifier, files = turn(value, label, True)
                record("native explicit cover wording", {"label": label, "value": value, "messageID": identifier, "turn": files})
            output(fmt, True)
    record("native cover formats completed", {"pipeline": pipeline, "kept": kept, "liveProvider": False})
    record("native optional cover completed", {"assetID": kept[0]["assetID"], "packageSHA256": kept[0]["packageSHA256"],
        "imageSHA256": kept[0]["sha256"], "format": "square", "cleanCoverKept": True, "typographyExplicitlyDeclined": True})
    return {"kept": kept, "liveProvider": False, "nativeThreeFormats": True, "nativeExplicitTypography": True,
        "assetID": kept[0]["assetID"], "sha256": kept[0]["sha256"], "typographyExplicitlyDeclined": True}


class CoverEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.native = {"interactions": [], "screenshots": []}
        self.cover = cover_fixture(self.root, self.native)

    def check(self): return validate(self.native, self.root, self.cover)

    def edit(self, key, suffix, change):
        name = key + suffix; path = self.root / "cover-evidence" / name
        value = json.loads(path.read_bytes()); change(value); raw = data(value); path.write_bytes(raw)
        next(v for v in self.cover["kept"] if v["key"] == key)["files"][name] = digest(raw)

    def test_complete_synthetic_parser_example(self): self.assertTrue(self.check())

    def test_each_format_is_required(self):
        self.cover["kept"].pop()
        self.native["interactions"] = [v for v in self.native["interactions"] if not (v.get("label") == "native cover output kept" and v["evidence"]["key"] == "portrait-clean")]
        self.assertFalse(self.check())

    def test_single_landscape_cannot_claim_all_formats(self):
        key = "square-clean"
        item = self.cover["kept"][0]; item.update(format="landscape", aspect="16:9", width=640, height=360)
        self.replace_image(key, png(640, 360))
        self.edit(key, "-package.json", lambda v: v["payload"]["generationInput"].update(aspectRatio="16:9"))
        self.rebind_package(key)
        def wire(value):
            body = json.loads(base64.b64decode(value[0]["bodyBase64"])); body["image_size"] = "landscape_16_9"
            value[0]["bodyBase64"] = base64.b64encode(data(body)).decode()
        self.edit(key, "-http.json", wire)
        self.assertFalse(self.check())

    def test_native_typography_yes_is_required(self):
        rows = self.native["interactions"]; rows.pop(next(i for i, v in enumerate(rows) if v.get("id") == "agent.dialog.choice.typography.yes")); self.assertFalse(self.check())

    def test_explicit_artist_cannot_come_from_project_name(self):
        rows = self.native["interactions"]; rows.pop(next(i for i, v in enumerate(rows) if v.get("kind") == "text")); self.assertFalse(self.check())

    def test_actual_uploaded_reference_cannot_change(self):
        self.edit("landscape-typography", "-http.json", lambda value: value[1].update(bodyBase64=base64.b64encode(b"other image").decode()))
        self.assertFalse(self.check())

    def test_reference_role_cannot_omit_clean_image(self):
        self.edit("landscape-typography", "-package.json", lambda value: value["payload"].update(references=[]))
        self.rebind_package("landscape-typography")
        self.assertFalse(self.check())

    def test_clean_bitmap_cannot_claim_typography(self):
        self.replace_image("landscape-typography", (self.root / "cover-evidence/landscape-clean.png").read_bytes())
        self.assertFalse(self.check())

    def test_ocr_requires_exact_entered_title(self):
        self.edit("landscape-typography", "-ocr.json", lambda value: value.__setitem__(1, "WRONG TITLE")); self.assertFalse(self.check())

    def test_reopened_variant_must_remain_project_media(self):
        path = self.root / "cover-evidence/portrait-clean-reopened.json"; value = json.loads(path.read_bytes()); value["source"] = {"external": {"absolutePath": "/elsewhere"}}; path.write_bytes(data(value)); self.assertFalse(self.check())

    def test_changed_pipeline_cannot_be_covered_by_ui_flags(self):
        (self.root / "cover-evidence/after/gates.yaml").write_bytes(b"render: pending\n"); self.assertFalse(self.check())

    def test_unchanged_gates_cannot_hide_changed_storyboard(self):
        raw = b'{"revision":2}'
        (self.root / "cover-evidence/after/planning/storyboard.v1.json").write_bytes(raw)
        end = next(v["evidence"] for v in self.native["interactions"] if v.get("label") == "native cover formats completed")
        end["pipeline"] = dict(end["pipeline"], **{"planning/storyboard.v1.json": digest(raw)})
        self.assertFalse(self.check())

    def test_typography_yes_cover_cannot_claim_explicit_decline(self):
        self.cover.update(assetID=self.cover["kept"][1]["assetID"], sha256=self.cover["kept"][1]["sha256"])
        self.assertFalse(self.check())

    def test_one_batch_click_cannot_cover_four_requests(self):
        rows = self.native["interactions"]; rows.pop(next(i for i, v in enumerate(rows) if v.get("id") == "generation-batch.approve")); self.assertFalse(self.check())

    def test_no_live_model_quality_claim_from_fixture(self):
        self.cover["liveProvider"] = True; self.assertFalse(self.check())

    def rebind_package(self, key):
        folder = self.root / "cover-evidence"
        package = json.loads((folder / (key + "-package.json")).read_bytes())
        package["id"] = digest(data(package["payload"]))
        raw = data(package); (folder / (key + "-package.json")).write_bytes(raw)
        item = next(v for v in self.cover["kept"] if v["key"] == key)
        item["files"][key + "-package.json"] = digest(raw); item["packageSHA256"] = package["id"]
        self.edit(key, "-receipt.json", lambda v: v.update(package={"id": package["id"], "sha256": digest(raw)}, input=package["payload"]["generationInput"]))
        self.edit(key, "-batch.json", lambda v: v["batch"]["payload"]["items"][0].update(package=package))
        self.edit(key, "-asset.json", lambda v: v.update(generationInput=dict(package["payload"]["generationInput"], generationPackageID=package["id"])))
        (folder / (key + "-reopened.json")).write_bytes((folder / (key + "-asset.json")).read_bytes())

    def replace_image(self, key, raw):
        folder = self.root / "cover-evidence"; item = next(v for v in self.cover["kept"] if v["key"] == key)
        (folder / (key + ".png")).write_bytes(raw); (folder / (key + "-reopened.png")).write_bytes(raw)
        item["sha256"] = digest(raw); item["files"][key + ".png"] = digest(raw)
        self.edit(key, "-receipt.json", lambda v: v["output"].update(sha256=digest(raw)))

    def test_no_turn_cannot_be_called_explicit_yes(self):
        event = next(v["evidence"] for v in self.native["interactions"] if v.get("label") == "native cover decision" and v["evidence"]["selected"] == ["yes"])
        event["labels"] = ["No — keep the clean cover"]
        path = self.root / "cover-evidence" / event["turn"]["turnFile"]
        value = json.loads(path.read_bytes()); value["userPresentation"]["choiceRecord"]["selections"][0]["values"] = event["labels"]
        raw = data(value); path.write_bytes(raw); event["turn"]["turnSHA256"] = digest(raw)
        self.assertFalse(self.check())

    def test_selection_label_must_name_the_actual_question(self):
        event = next(v["evidence"] for v in self.native["interactions"] if v.get("label") == "native cover decision")
        path = self.root / "cover-evidence" / event["turn"]["turnFile"]
        value = json.loads(path.read_bytes()); value["userPresentation"]["choiceRecord"]["selections"][0]["label"] = "Unrelated choice"
        raw = data(value); path.write_bytes(raw); event["turn"]["turnSHA256"] = digest(raw)
        self.assertFalse(self.check())

    def test_upload_to_unrelated_location_does_not_bind_submitted_reference(self):
        self.edit("landscape-typography", "-http.json", lambda v: v[1].update(url="https://upload.invalid/unrelated.png"))
        self.assertFalse(self.check())

    def test_native_decisions_cannot_be_reordered(self):
        rows = self.native["interactions"]
        first = next(i for i, v in enumerate(rows) if v.get("id") == "generation-batch.approve")
        second = next(i for i, v in enumerate(rows) if v.get("id") == "media.asset.square-clean" or v.get("id") == "media.asset.asset-square-clean")
        rows[first], rows[second] = rows[second], rows[first]
        self.assertFalse(self.check())

    def test_clean_model_and_exact_single_batch_are_required(self):
        self.edit("square-clean", "-package.json", lambda v: v["payload"]["target"].update(modelId="fal-ai/flux/dev"))
        self.rebind_package("square-clean")
        self.assertFalse(self.check())

    def test_extra_reopened_artifact_is_rejected(self):
        (self.root / "cover-evidence/unknown-reopened.json").write_bytes(b"{}")
        self.assertFalse(self.check())
