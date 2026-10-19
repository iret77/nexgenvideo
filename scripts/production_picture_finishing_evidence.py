"""Bind the retained native picture transform to its reviewed and decoded export."""
import copy
import hashlib
import json
import math


def validate(native, directory, delivery, review, attempt):
    receipt = delivery.get("pictureFinishing", {})
    clip_id = receipt.get("clipID")
    if not isinstance(clip_id, str) or not clip_id:
        raise ValueError("Music Video needs its retained native picture correction")
    snapshots = []
    for key in ("before", "after"):
        name = "owner-v2-picture-" + key + ".json"
        if receipt.get(key) != name:
            raise ValueError("Picture snapshots must identify the actual captured timeline")
        raw = (directory / name).read_bytes()
        if hashlib.sha256(raw).hexdigest() != receipt.get(key + "SHA256"):
            raise ValueError("Picture snapshot bytes changed")
        snapshots.append(json.loads(raw))
    before_sha, after_sha = receipt["beforeSHA256"], receipt["afterSHA256"]
    if (before_sha == after_sha or review.get("timeline", {}).get("sha256") != after_sha
        or attempt.get("finished_timeline_sha256") != after_sha):
        raise ValueError("The film review and export must retain the changed picture")
    expected = copy.deepcopy(snapshots[0])
    clips = [clip for track in expected["tracks"] for clip in track["clips"] if clip["id"] == clip_id]
    if len(clips) != 1 or clips[0]["transform"].get("flipHorizontal") is not False:
        raise ValueError("The actual starting clip must be unmirrored")
    clips[0]["transform"]["flipHorizontal"] = True
    if expected != snapshots[1]:
        raise ValueError("Only the native horizontal picture flip may change the assembly")
    events = native["interactions"]
    before = [(i, event["evidence"]) for i, event in enumerate(events)
              if event.get("kind") == "verified-state" and event.get("label") == "native Music Video picture before"]
    finished = [(i, event["evidence"]) for i, event in enumerate(events)
                if event.get("kind") == "verified-state" and event.get("label") == "native Music Video picture finishing"]
    if len(before) != 1 or len(finished) != 1:
        raise ValueError("The native before and finished picture states are required")
    first, initial = before[0]
    last, state = finished[0]
    difference = state.get("previewDifference")
    if (initial != {"clipID": clip_id, "timelineSHA256": before_sha}
        or any(state.get(key) != value for key, value in receipt.items())
        or type(difference) not in (int, float) or not math.isfinite(difference) or difference <= 2
        or type(state.get("frame")) is not int
        or not any(first < i < last and event.get("kind") == "pointer"
                   and event.get("id") == "inspector.transform.arrow.left.and.right" for i, event in enumerate(events))
        or not any(i > last and event.get("kind") == "pointer" and event.get("id") == "sequence.build"
                   for i, event in enumerate(events))):
        raise ValueError("The actual native picture control must precede the current film review")
    image = receipt.get("screenshot")
    if (image not in native["screenshots"] or not isinstance(image, str)
        or "/" in image or "\\" in image or not image.endswith("musicvideo-picture-finished.png")
        or not (directory / image).read_bytes().startswith(b"\x89PNG\r\n\x1a\n")):
        raise ValueError("The retained picture needs its native screenshot")
    decoded = delivery.get("decodedMedia", {})
    original_difference = decoded.get("minimumOriginalDifference")
    if (decoded.get("mirroredClipID") != clip_id or decoded.get("mirroredFrames") != 3
        or type(decoded.get("asymmetricFrames")) is not int or not 1 <= decoded["asymmetricFrames"] <= 3
        or type(original_difference) not in (int, float) or not math.isfinite(original_difference)
        or original_difference <= 0.02):
        raise ValueError("Decoded export must distinguish mirrored and original source pixels")
