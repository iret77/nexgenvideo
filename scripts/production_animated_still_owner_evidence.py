"""Check native still delivery against actual artifacts and decoded export pixels."""
from collections import Counter
import binascii
import hashlib
import json
from pathlib import Path
import struct
import zlib

from production_frames_owner_evidence import read, visible_group


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def red_bounds(data):
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), "Not an actual PNG")
    offset, compressed, header, ended = 8, bytearray(), None, False
    while offset < len(data):
        require(offset + 12 <= len(data), "Truncated PNG chunk")
        size = struct.unpack_from(">I", data, offset)[0]
        require(size <= len(data) - offset - 12, "PNG chunk exceeds actual bytes")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        crc = struct.unpack_from(">I", data, offset + 8 + size)[0]
        require(binascii.crc32(kind + payload) & 0xffffffff == crc, "PNG chunk checksum mismatch")
        if kind == b"IHDR":
            require(header is None and size == 13, "Ambiguous PNG header")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            ended = True
            require(size == 0 and offset + size + 12 == len(data), "Trailing PNG bytes")
            break
        offset += size + 12
    require(header is not None and ended, "Incomplete PNG")
    width, height, depth, color, compression, filtering, interlace = header
    require(0 < width < 10000 and 0 < height < 10000 and depth == 8 and color in (2, 6)
            and compression == filtering == interlace == 0, "Unsupported decoded evidence raster")
    channels = 3 if color == 2 else 4
    stride = width * channels
    limit = (stride + 1) * height
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(compressed, limit + 1)
    require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail and len(pixels) == limit,
            "Invalid PNG raster length")
    previous = bytearray(stride)
    bounds = [width, height, -1, -1]
    for y in range(height):
        mode = pixels[y * (stride + 1)]
        require(mode <= 4, "Unknown PNG row filter")
        row = bytearray(pixels[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for index in range(stride):
            left = row[index - channels] if index >= channels else 0
            above = previous[index]
            corner = previous[index - channels] if index >= channels else 0
            if mode == 1:
                predictor = left
            elif mode == 2:
                predictor = above
            elif mode == 3:
                predictor = (left + above) // 2
            elif mode == 4:
                candidate = left + above - corner
                distances = [abs(candidate - left), abs(candidate - above), abs(candidate - corner)]
                predictor = [left, above, corner][distances.index(min(distances))]
            else:
                predictor = 0
            row[index] = (row[index] + predictor) & 255
        for x in range(width):
            red, green, blue = row[x * channels:x * channels + 3]
            if red > 90 and red > green * 2 and red > blue * 2:
                bounds = [min(bounds[0], x), min(bounds[1], y), max(bounds[2], x), max(bounds[3], y)]
        previous = row
    require(bounds[2] >= bounds[0] and bounds[3] >= bounds[1], "No known red source shape")
    return bounds


def validate(directory):
    directory = Path(directory)
    result = json.loads(read(directory, "animated-still-result.json"))
    native = result["nativeEvidence"]
    progress = json.loads(read(directory, "animated-still-owner.json"))
    require(result["schema"] == "animated-still-owner-acceptance/v1" and progress.get("failure") is None,
            "Native still acceptance failed")
    require(native["interactions"] == progress["interactions"], "Final native evidence diverges from actual progress")
    shot = result["shotID"]
    require(result["frameRoles"] == ["start"] and result["finalVideoRoute"] is False
            and result["actualTake"] is False and result["finalProviderGenerations"] == 0
            and result["finalSpendEventsUnchanged"] is True and result["liveProvider"] is False,
            "Still delivery silently entered final provider-video generation")
    files = result["files"]
    required_files = {"actual-projection.v5.yaml", "actual-promotion.json", "actual-frames.yaml",
                      "actual-frame-receipt.json", "actual-still-delivery.json", "actual-assembly.json",
                      "actual-image-package.json", "actual-image-output.json", "actual-selected-frame.png",
                      "actual-frame-audit.yaml", "actual-frame-audit.json", "actual-frame-acceptance.json"}
    require(set(files) == required_files and all(digest(read(directory, path)) == value for path, value in files.items()),
            "Actual canonical artifact bytes differ from their evidence hashes")
    frame = json.loads(read(directory, "actual-frame-receipt.json"))
    still = json.loads(read(directory, "actual-still-delivery.json"))
    package_bytes = read(directory, "actual-image-package.json")
    package = json.loads(package_bytes)
    output = json.loads(read(directory, "actual-image-output.json"))
    promotion = json.loads(read(directory, "actual-promotion.json"))
    assembly = json.loads(read(directory, "actual-assembly.json"))
    selected_image = read(directory, "actual-selected-frame.png")
    image_hash = digest(selected_image)
    require(image_hash == result["actualImageSHA256"] == digest(read(directory, "actual-provider-image.png")),
            "The selected still differs from the actual isolated image response")
    require(frame["shotID"] == still["shotID"] == shot and frame["role"] == "start"
            and frame["generation"] == output and output["modality"] == "image"
            and output["output"]["sha256"] == still["output"]["sha256"] == image_hash
            and still["framesApproval"]["approved"] is True
            and still["frameReceipt"]["sha256"] == digest(read(directory, "actual-frame-receipt.json"))
            and frame["projection"]["sha256"] == still["projection"]["sha256"] == digest(read(directory, "actual-projection.v5.yaml")),
            "The still reuses unapproved or substituted frame bytes")
    require(output["package"]["sha256"] == digest(package_bytes) and output["package"]["id"] == package["id"]
            and package["payload"]["modality"] == "image" and package["payload"]["binding"]["frameRole"] == "start"
            and package["payload"]["binding"]["shotId"] == shot,
            "The actual image generation package is not bound to Frames")
    require(all(value["shotID"] != shot for value in promotion["routes"]), "Still retains a final video route")
    placements = [value for value in assembly["placements"] if value["shotID"] == shot]
    require(len(placements) == 1, "Still is not one exact canonical placement")
    placement = placements[0]
    require(placement["clipID"] == result["timelineClipID"] and placement["sourceKind"] == "still_image"
            and placement.get("takeID") is None and placement.get("nativeRange") is None
            and placement["output"]["sha256"] == image_hash and placement["motion"]["kind"] == "ken_burns_zoom"
            and placement["motion"]["startScale"] == 1 and placement["motion"]["endScale"] == 1.08,
            "Assembly invented a provider take or omitted native timeline animation")
    audit = json.loads(read(directory, "actual-frame-audit.json"))
    acceptance = json.loads(read(directory, "actual-frame-acceptance.json"))
    require(audit["render_sha256"] == acceptance["imageSHA256"] == image_hash
            and acceptance["auditSHA256"] == digest(read(directory, "actual-frame-audit.yaml"))
            and acceptance["reason"].strip(), "Native image deviation decision is not bound to its exact audit")
    interactions = native["interactions"]
    clicks = Counter(row.get("id") for row in interactions if row.get("kind") == "pointer")
    required_clicks = ["production.plan.edit." + shot, "production.technical.apply",
                       "frames.use." + result["candidateID"], "production.input.image.open." + result["candidateID"],
                       "frames.audit.accept." + shot + ".start", "pipeline.overview.approve.frames",
                       "render-review.record-native", "production.assembly.build", "sequence.build", "export.start"]
    require(all(clicks[value] >= 1 for value in required_clicks), "Actual native still decisions were bypassed")
    require(any(row.get("kind") == "visible-group" and visible_group(row) for row in interactions),
            "No actual bounded native controls were observed")
    motion = result["motion"]
    bounds = [red_bounds(read(directory, filename)) for filename in ["still-first-decoded.png", "still-last-decoded.png"]]
    require(bounds == [motion["firstBounds"], motion["lastBounds"]]
            and motion["decodedPNGSHA256"] == [digest(read(directory, filename)) for filename in ["still-first-decoded.png", "still-last-decoded.png"]],
            "Reported zoom bounds differ from actual decoded PNG pixels")
    ratios = [(bounds[1][axis + 2] - bounds[1][axis] + 1) / (bounds[0][axis + 2] - bounds[0][axis] + 1) for axis in (0, 1)]
    require(all(1.03 < value < 1.13 for value in ratios)
            and all(abs(value - motion[key]) < 1e-10 for value, key in zip(ratios, ["widthRatio", "heightRatio"]))
            and motion["lastFrame"] - motion["firstFrame"] + 1 == result["timelineFrames"],
            "The actual exported shape does not demonstrate the native clip zoom")
    delivery = result["delivery"]
    require(delivery["nativeFullFilmReview"] and delivery["nativeExportWorkspace"] and delivery["actualOutputQC"]
            and digest(read(directory, delivery["movie"])) == delivery["outputSHA256"], "The actual exported reviewed movie is missing")
    return {"schema": "independent-animated-still-owner-verification/v1", "nativeDecisions": True,
            "actualSelectedFrameSHA256": image_hash, "actualDecodedWidthRatio": ratios[0], "actualDecodedHeightRatio": ratios[1],
            "finalProviderGeneration": False, "imageQualityClaim": False, "offGridSongEndClaim": False}
