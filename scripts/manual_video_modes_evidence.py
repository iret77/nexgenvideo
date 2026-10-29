"""Compare native video assignments with saved requests and captured provider input bytes."""
from collections import Counter
import hashlib
import json
import re
from pathlib import Path

from manual_generation_extended_evidence import _file


def manual_video_modes_evidence(rows, output, scale):
    try:
        records = [row for row in rows if row.get("event") == "manual-video-modes"]
        completed = [row for row in rows if row.get("event") == "completed" and row.get("case") == "manualvideomodes"]
        if (len(records) != 1 or len(completed) != 1 or any(row.get("event") == "failed" for row in rows)
            or any(row.get("scale") != scale for row in records + completed)):
            return False, []
        row = records[0]
        if row.get("viewport") != [960, 640] or row.get("effectiveScale") != scale or row.get("liveProvider") is not False:
            return False, []
        directory = row["directory"]
        project = directory + "/" + row["project"]
        manifest = json.loads(_file(output, project + "/media.json").read_bytes())
        entries = {entry["id"]: entry for entry in manifest["entries"]}
        timeline = json.loads(_file(output, project + "/project.json").read_bytes())
        if (timeline["fps"] != 30 or timeline["width"] != 320 or timeline["height"] != 180
            or any(track["clips"] for track in timeline["tracks"])):
            return False, []
        results = row["results"]
        if [item["kind"] for item in results] != ["free", "frames", "references"] or len(entries) != 7:
            return False, []
        expected = [("text-to-video", {}, []),
                    ("image-to-video", {"first": "start_frame", "last": "end_frame"}, ["image_url", "end_image_url"]),
                    ("reference-to-video", {"first": "image_reference", "motion": "video_reference", "timing": "audio_reference"},
                     ["image_urls", "video_urls", "audio_urls"])]
        for item, (endpoint, roles, keys) in zip(results, expected):
            artifacts = item["artifacts"]
            package = json.loads(_file(output, artifacts["package"]).read_bytes())
            payload = package["payload"]
            submit = json.loads(_file(output, artifacts["submit"]).read_bytes())
            result = _file(output, artifacts["output"]).read_bytes()
            generation = payload["generationInput"]
            if (package.get("schema") != "generation-package/v1" or package["id"] != item["packageID"]
                or payload["target"]["modelId"] != "bytedance/seedance-2.5/" + endpoint
                or payload["target"]["endpoint"] != payload["target"]["modelId"]
                or payload["modality"] != "video" or payload["destination"]["kind"] != "media_library"
                or generation["model"] != payload["target"]["modelId"] or generation["duration"] != 4 or generation.get("videoDuration") != 4
                or generation["prompt"] != payload["prompt"] or submit.get("prompt") != payload["prompt"]
                or submit.get("duration") != "4" or item["decodedFrames"] != 120 or len(result) < 1000):
                return False, []
            references = payload["references"]
            if (len(references) != len(roles) or len(payload["referenceRoles"]) != len(roles)
                or dict(zip([ref["assetID"] for ref in references], payload["referenceRoles"])) != roles
                or len(item["uploads"]) != len(roles)):
                return False, []
            uploads = {upload["assetID"]: upload for upload in item["uploads"]}
            for reference in references:
                upload = uploads[reference["assetID"]]
                data = _file(output, directory + "/" + upload["file"]).read_bytes()
                source = entries[reference["assetID"]]["source"]["project"]["relativePath"]
                source_bytes = _file(output, project + "/" + source).read_bytes()
                if (hashlib.sha256(data).hexdigest() != upload["sha256"] or upload["sha256"] != reference["submittedSHA256"]
                    or hashlib.sha256(source_bytes).hexdigest() != reference["sourceSHA256"]
                    or upload["sourceSHA256"] != reference["sourceSHA256"]):
                    return False, []
            expected_urls = {key: uploads[asset]["url"] for key, asset in zip(keys, roles)}
            if item["kind"] == "references":
                expected_urls = {key: [url] for key, url in expected_urls.items()}
                if set(re.findall(r"@(Image|Video|Audio)(\d+)\b", submit["prompt"])) != {("Image", "1"), ("Video", "1"), ("Audio", "1")}:
                    return False, []
            for key in ("image_url", "end_image_url", "image_urls", "video_urls", "audio_urls"):
                if (key in expected_urls and submit.get(key) != expected_urls[key]) or (key not in expected_urls and key in submit):
                    return False, []
            saved = entries[item["assetID"]]
            if (saved["generationInput"]["generationPackageID"] != package["id"]
                or _file(output, project + "/" + saved["source"]["project"]["relativePath"]).read_bytes() != result):
                return False, []
        actions, images = row["interactions"], row["screenshots"]
        progress = json.loads(_file(output, row["progress"]).read_bytes())
        if progress.get("failure") is not None or progress["interactions"] != actions or progress["screenshots"] != images:
            return False, []
        clicks = Counter(action.get("id") for action in actions if action.get("kind") == "pointer")
        for identifier, count in {"media.action.Generate": 1, "generation.media.review": 4, "generation.media.approve": 3,
            "generation.media.package.copy-package": 4, "generation.media.discard": 1,
            "generation.media.pick.First Frame": 1, "generation.media.pick.Last Frame": 1,
            "generation.media.pick.References": 7, "generation.media.reference.remove.motion": 1}.items():
            if clicks[identifier] != count:
                return False, []
        menus = [action for action in actions if action.get("kind") == "menu" and action.get("id") == "generation.media.model"]
        if len(menus) != 4 or any(action.get("closed") is not True for action in menus):
            return False, []
        if (len(images) != 5 or len(set(images)) != 5 or any(not any(name.endswith("-" + label + ".png") for name in images)
            for label in ("free-review", "frames-review", "references-review", "model-reset", "cleared-review"))):
            return False, []
        for image in images:
            data = _file(output, image).read_bytes()
            if len(data) < 1000 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
                return False, []
        return True, images
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        return False, []
