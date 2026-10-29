"""Native cover choices and exact request/output closure; isolated provider, no model-quality claim."""
import base64
import binascii
from collections import Counter
import json
import struct
import zlib

from production_technical_owner_evidence import digest, read, states

FORMATS = [("square", "1:1", 640, 640), ("landscape", "16:9", 640, 360), ("portrait", "9:16", 360, 640)]
KEYS = ["square-clean", "landscape-clean", "landscape-typography", "portrait-clean"]
MODEL_LABELS = {"fal-ai/flux/schnell": "FLUX.1 [schnell]", "fal-ai/gemini-25-flash-image/edit": "Nano Banana (Gemini 2.5 Flash)"}


def decision_specs():
    result = [("format", [v[0] for v in FORMATS], [v[0].title() + " — " + v[1] for v in FORMATS], "Which platforms need cover artwork?")]
    for name, _, _, _ in FORMATS:
        result.append(("subject", ["abstract"], ["Abstract style image"], "Choose the " + name + " cover subject"))
        result.append(("model", ["selected"], [MODEL_LABELS["fal-ai/flux/schnell"]], "Choose the " + name + " cover model"))
        result.append(("review", ["keep"], ["Keep"], "Keep Cover — " + name.title() + " — Clean?"))
        yes = name == "landscape"
        result.append(("typography", ["yes" if yes else "no"], ["Yes" if yes else "No — keep the clean cover"],
            "Create a second " + name + " variant with artist and title?"))
        if yes:
            result.append(("model", ["selected"], [MODEL_LABELS["fal-ai/gemini-25-flash-image/edit"]], "Choose the landscape typography model"))
            result.append(("review", ["keep"], ["Keep"], "Keep Cover — Landscape — Artist + Title?"))
    return result


def payload_sha(raw):
    text, decoder, position, found = raw.decode("utf-8"), json.JSONDecoder(), 1, None
    if not text.startswith("{"):
        raise ValueError("Expected canonical package object")
    while True:
        while text[position].isspace(): position += 1
        if text[position] == "}": break
        key, position = decoder.raw_decode(text, position)
        while text[position].isspace(): position += 1
        if text[position] != ":": raise ValueError("Invalid package property")
        position += 1
        while text[position].isspace(): position += 1
        start = position
        _, position = decoder.raw_decode(text, position)
        if key == "payload":
            if found is not None: raise ValueError("Duplicate payload")
            found = digest(text[start:position].encode("utf-8"))
        while text[position].isspace(): position += 1
        if text[position] == "}": break
        if text[position] != ",": raise ValueError("Invalid package delimiter")
        position += 1
    if found is None: raise ValueError("Missing payload")
    return found


def raster(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Missing actual PNG")
    offset, header, compressed, kind = 8, None, bytearray(), None
    while offset < len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        if size > len(data) - offset - 12:
            raise ValueError("Truncated PNG")
        kind, payload = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + size]
        if binascii.crc32(kind + payload) & 0xffffffff != struct.unpack_from(">I", data, offset + 8 + size)[0]:
            raise ValueError("PNG checksum changed")
        if kind == b"IHDR":
            if header is not None or size != 13 or offset != 8:
                raise ValueError("Duplicate PNG header")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            if header is None: raise ValueError("Image data precedes its header")
            compressed.extend(payload)
        offset += size + 12
        if kind == b"IEND":
            if size != 0 or offset != len(data):
                raise ValueError("Trailing PNG bytes")
            break
    if header is None or kind != b"IEND":
        raise ValueError("Incomplete PNG")
    width, height, depth, color, compression, filtering, interlace = header
    if not (0 < width <= 640 and 0 < height <= 640 and depth == 8 and color in (2, 6) and compression == filtering == interlace == 0):
        raise ValueError("Unexpected cover raster")
    channels = 3 if color == 2 else 4
    stride, limit = width * channels, (width * channels + 1) * height
    decoder = zlib.decompressobj(); raw = decoder.decompress(compressed, limit + 1)
    if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or len(raw) != limit:
        raise ValueError("Invalid cover raster length")
    previous, dark, colors = bytearray(stride), [0, 0, 0], set()
    for y in range(height):
        mode = raw[y * (stride + 1)]
        if mode > 4:
            raise ValueError("Invalid PNG filter")
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            above, corner = previous[i], previous[i - channels] if i >= channels else 0
            p = left + above - corner
            paeth = (left, above, corner)[[abs(p - left), abs(p - above), abs(p - corner)].index(min(abs(p - left), abs(p - above), abs(p - corner))) ]
            row[i] = (row[i] + (0, left, above, (left + above) // 2, paeth)[mode]) & 255
        for x in range(width):
            alpha = row[x * channels + 3] if channels == 4 else 255
            pixel = tuple((v * alpha + 255 * (255 - alpha)) // 255 for v in row[x * channels:x * channels + 3])
            if len(colors) < 256: colors.add(pixel)
            if max(pixel) < 60:
                dark[min(2, y * 3 // height)] += 1
        previous = row
    return width, height, dark, len(colors)


def validate(native, directory, cover):
    try:
        rows = native["interactions"]
        begin, end = states(rows, "native cover formats begin"), states(rows, "native cover formats completed")
        kept = states(rows, "native cover output kept")
        discovery = states(rows, "native cover catalog")
        if (len(begin) != 1 or len(end) != 1 or [value["key"] for value in kept] != KEYS or end[0]["kept"] != kept
            or cover["kept"] != kept or cover["liveProvider"] is not False or end[0]["liveProvider"] is not False
            or cover["nativeThreeFormats"] is not True or cover["nativeExplicitTypography"] is not True
            or len(discovery) != 1 or discovery[0]["liveProvider"] is not False
            or discovery[0]["endpointIDs"] != ["fal-ai/flux/dev", "fal-ai/flux/schnell", "fal-ai/gemini-25-flash-image/edit"]
            or discovery[0]["requests"] != ["https://api.fal.ai/v1/models?category=" + category + "&status=active&limit=100" for category in ("text-to-image", "image-to-image")]
            or begin[0]["pipeline"] != end[0]["pipeline"]
            or not {"project.yaml", "brief.yaml", "gates.yaml", "lineage.json"}.issubset(begin[0]["pipeline"])
            or len(begin[0]["pipeline"]) <= 4):
            return False
        for when in ("before", "after"):
            for name, sha in begin[0]["pipeline"].items():
                if digest(read(directory, "cover-evidence/" + when + "/" + name)) != sha: return False
        start = next(i for i, row in enumerate(rows) if row.get("label") == "native cover formats begin")
        finish = next(i for i, row in enumerate(rows) if row.get("label") == "native cover formats completed")
        scoped = rows[start:finish]
        pointers = Counter(row.get("id") for row in scoped if row.get("kind") == "pointer")
        decisions = states(scoped, "native cover decision")
        specs = decision_specs()
        expected_decisions = [(section, selected) for section, selected, _, _ in specs]
        if [(v["section"], v["selected"]) for v in decisions] != expected_decisions:
            return False
        if pointers["export.cover.start"] != 1 or pointers["generation-batch.approve"] != 4 or pointers["agent.dialog.confirm"] != len(decisions) + 2:
            return False
        expected_clicks = Counter("agent.dialog.choice." + section + "." + value for section, selected in expected_decisions for value in selected)
        if any(pointers[key] != count for key, count in expected_clicks.items()): return False
        wordings = states(scoped, "native explicit cover wording")
        if [(v["label"], v["value"]) for v in wordings] != [("Artist", "NATIVE ARTIST"), ("Title", "NIGHT SIGNAL")]: return False
        fields = [row["field"] for row in scoped if row.get("kind") == "text" and row.get("field", {}).get("id") == "agent.dialog.direction"]
        if [v["actual"] for v in fields] != [v["value"] for v in wordings] or any(v["expected"] != v["actual"] or v.get("focusLeftTarget") is not True for v in fields): return False
        message_ids = set()
        for decision, (_, _, labels, _) in zip(decisions, specs):
            if decision["labels"] != labels: return False
        expected_titles = {decision["messageID"]: spec[3] for decision, spec in zip(decisions, specs)}
        for decision in decisions + wordings:
            raw = read(directory, "cover-evidence/" + decision["turn"]["turnFile"])
            message = json.loads(raw)
            if digest(raw) != decision["turn"]["turnSHA256"] or message["id"].lower() != decision["messageID"].lower() or message["id"] in message_ids or message["role"] != "user": return False
            message_ids.add(message["id"])
            if "section" in decision:
                presentation = message["userPresentation"]["choiceRecord"]
                if presentation["confirmed"] is not True or presentation["selections"] != [
                    {"label": expected_titles[decision["messageID"]], "values": decision["labels"]}]: return False
            elif message["userPresentation"]["typedText"] != decision["value"]: return False
        expected_reopened = {key + suffix for key in KEYS for suffix in ("-reopened.json", "-reopened.png")}
        if {path.name for path in (directory / "cover-evidence").glob("*-reopened.*")} != expected_reopened: return False
        sequence = []
        for row in scoped:
            if row.get("kind") == "pointer" and (row.get("id", "").startswith(("agent.dialog.choice.", "media.asset."))
                or row.get("id") in ("export.cover.start", "generation-batch.approve", "agent.dialog.confirm")):
                sequence.append(("click", row["id"]))
            elif row.get("kind") == "text" and row.get("field", {}).get("id") == "agent.dialog.direction": sequence.append(("text", row["field"]["actual"]))
            elif row.get("kind") == "verified-state" and row.get("label") == "native cover decision": sequence.append(("decision", row["evidence"]["section"]))
            elif row.get("kind") == "verified-state" and row.get("label") == "native explicit cover wording": sequence.append(("wording", row["evidence"]["label"]))
            elif row.get("kind") == "verified-state" and row.get("label") == "native cover output kept": sequence.append(("kept", row["evidence"]["key"]))
        expected_sequence = [("click", "export.cover.start")]
        def choice(section, values):
            expected_sequence.extend(("click", "agent.dialog.choice." + section + "." + value) for value in values)
            expected_sequence.extend([("click", "agent.dialog.confirm"), ("decision", section)])
        def output(key):
            choice("model", ["selected"])
            item = next(value for value in kept if value["key"] == key)
            expected_sequence.extend([("click", "generation-batch.approve"), ("click", "media.asset." + item["assetID"])])
            choice("review", ["keep"]); expected_sequence.append(("kept", key))
        choice("format", [v[0] for v in FORMATS])
        for name, _, _, _ in FORMATS:
            choice("subject", ["abstract"]); output(name + "-clean"); choice("typography", ["yes" if name == "landscape" else "no"])
            if name == "landscape":
                for label, value in (("Artist", "NATIVE ARTIST"), ("Title", "NIGHT SIGNAL")):
                    expected_sequence.extend([("text", value), ("click", "agent.dialog.confirm"), ("wording", label)])
                output("landscape-typography")
        if sequence != expected_sequence: return False
        assets = set()
        for item in kept:
            key = item["key"]; typography = key.endswith("-typography")
            fmt = next(v for v in FORMATS if v[0] == key.rsplit("-", 1)[0])
            if item["format"] != fmt[0]: return False
            if (item["aspect"], item["width"], item["height"]) != fmt[1:] or any(type(item[k]) is not int for k in ("width", "height")) or item["liveProvider"] is not False: return False
            required = {key + suffix for suffix in (".png", "-asset.json", "-batch.json", "-http.json", "-ocr.json", "-receipt.json", "-package.json")}
            if typography: required.add(key + "-reference.png")
            if set(item["files"]) != required: return False
            files = {name: read(directory, "cover-evidence/" + name) for name in required}
            if any(digest(data) != item["files"][name] for name, data in files.items()): return False
            width, height, dark, colors = raster(files[key + ".png"])
            if (width, height) != fmt[2:] or colors < 2 or digest(files[key + ".png"]) != item["sha256"]: return False
            asset, package, receipt, stored, http, ocr = (json.loads(files[key + suffix]) for suffix in ("-asset.json", "-package.json", "-receipt.json", "-batch.json", "-http.json", "-ocr.json"))
            reopened = json.loads(read(directory, "cover-evidence/" + key + "-reopened.json"))
            if read(directory, "cover-evidence/" + key + "-reopened.png") != files[key + ".png"]: return False
            if asset["id"] in assets: return False
            assets.add(asset["id"])
            if (asset["id"] != item["assetID"] or asset["name"] != item["name"] or asset["type"] != "image"
                or any(reopened.get(field) != asset.get(field) for field in ("id", "name", "type", "source", "generationInput", "sourceWidth", "sourceHeight"))
                or receipt["schema"] != "generation-output-receipt/v1" or receipt["assetID"] != asset["id"] or receipt["output"]["sha256"] != item["sha256"]
                or receipt["output"]["path"] != asset["source"]["project"]["relativePath"]
                or receipt["package"]["sha256"] != item["files"][key + "-package.json"] or receipt["package"]["id"] != item["packageSHA256"]
                or package["id"] != payload_sha(files[key + "-package.json"])
                or package["id"] != item["packageSHA256"] or package["schema"] != "generation-package/v1"
                or package["payload"]["binding"]["shotId"] != "none" or package["payload"]["destination"]["kind"] != "media_library"
                or asset["generationInput"]["generationPackageID"] != package["id"] or receipt["input"] != package["payload"]["generationInput"]): return False
            payload = package["payload"]; execution = stored["journal"]["executions"]
            if (len(execution) != 1 or execution[0]["state"] != "complete" or execution[0]["outputAssetIDs"] != [asset["id"]]
                or stored["batch"]["payload"].get("phase") is not None or len(stored["batch"]["payload"]["items"]) != 1
                or stored["batch"]["payload"]["items"][0]["package"] != package
                or payload["generationInput"]["aspectRatio"] != fmt[1] or payload["prompt"] != receipt["input"]["prompt"]
                or not any(v["kind"] == "submitted" for v in receipt["spendEvents"])): return False
            posts = [v for v in http if v["method"] == "POST" and v["url"].startswith("https://queue.fal.run/")]
            uploads = [v for v in http if v["method"] == "PUT"]
            if len(posts) != 1 or posts[0]["url"] != "https://queue.fal.run/" + payload["target"]["endpoint"]: return False
            wire = json.loads(base64.b64decode(posts[0]["bodyBase64"], validate=True))
            if wire["prompt"] != payload["prompt"]: return False
            if typography:
                clean = kept[1]
                if (item["referenceAssetID"] != clean["assetID"] or item["referenceSHA256"] != clean["sha256"]
                    or digest(files[key + "-reference.png"]) != clean["sha256"] or len(uploads) != 1
                    or uploads[0]["url"] != "https://upload.invalid/frame-input-0.png"
                    or base64.b64decode(uploads[0]["bodyBase64"], validate=True) != files[key + "-reference.png"]
                    or wire["image_urls"] != ["https://media.invalid/frame-input-0.png"] or wire["aspect_ratio"] != fmt[1]
                    or payload["target"]["modelId"] != "fal-ai/gemini-25-flash-image/edit"
                    or len(payload["references"]) != 1 or payload["references"][0]["assetID"] != clean["assetID"]
                    or any(payload["references"][0][field] != clean["sha256"] for field in ("sourceSHA256", "submittedSHA256"))
                    or [item["artist"], item["title"]] != [v["value"] for v in wordings]
                    or not all(v["value"] in wire["prompt"] and v["value"] in ocr for v in wordings)
                    or ocr != item["recognizedText"] or min(dark[0], dark[2]) < 100): return False
            elif (payload["target"]["modelId"] != "fal-ai/flux/schnell" or payload["target"]["endpoint"] != "fal-ai/flux/schnell"
                or uploads or payload["references"] or item["referenceAssetID"] is not None or item["referenceSHA256"] is not None
                or item["artist"] is not None or item["title"] is not None or ocr or max(dark) != 0
                or wire["image_size"] != {"square": "square_hd", "landscape": "landscape_16_9", "portrait": "portrait_16_9"}[fmt[0]]): return False
            if pointers["media.asset." + asset["id"]] != 1: return False
            for suffix in ("-unapproved", "-preview"):
                images = [v for v in native["screenshots"] if v.endswith("-cover-" + key + suffix + ".png")]
                if len(images) != 1 or not read(directory, images[0]).startswith(b"\x89PNG\r\n\x1a\n"): return False
        declined = kept[0]
        return (cover["assetID"] == declined["assetID"] and cover["sha256"] == declined["sha256"]
            and cover["typographyExplicitlyDeclined"] is True
            and states(rows, "native optional cover completed") == [{"assetID": declined["assetID"],
                "packageSHA256": declined["packageSHA256"], "imageSHA256": declined["sha256"], "format": "square",
                "cleanCoverKept": True, "typographyExplicitlyDeclined": True}])
    except (KeyError, ValueError, TypeError, OSError, AttributeError, StopIteration, struct.error, zlib.error, IndexError):
        return False
