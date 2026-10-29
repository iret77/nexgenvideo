import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from manual_video_modes_evidence import manual_video_modes_evidence


class ManualVideoModesEvidenceTests(unittest.TestCase):
    def fixture(self, root):
        directory, project = "manual-video-modes-150", "Video modes.ngv"
        package = root / directory / project
        (package / "media").mkdir(parents=True)
        def write(path, value):
            path.write_text(json.dumps(value))
        source = {key: (key + "-validator-source").encode() for key in ("first", "last", "motion", "timing")}
        entries = []
        for key, data in source.items():
            (package / "media" / key).write_bytes(data)
            entries.append({"id": key, "source": {"project": {"relativePath": "media/" + key}}})
        results = []
        for label, endpoint, roles, url_keys in (
            ("free", "text-to-video", {}, []),
            ("frames", "image-to-video", {"first": "start_frame", "last": "end_frame"}, ["image_url", "end_image_url"]),
            ("references", "reference-to-video", {"first": "image_reference", "motion": "video_reference", "timing": "audio_reference"},
                ["image_urls", "video_urls", "audio_urls"])):
            refs, uploads = [], []
            for key in roles:
                data = source[key]
                digest = hashlib.sha256(data).hexdigest()
                refs.append({"assetID": key, "submittedSHA256": digest, "sourceSHA256": digest})
                name = label + "-input-" + key + ".bin"
                (root / directory / name).write_bytes(data)
                uploads.append({"assetID": key, "url": "https://media.invalid/" + key, "file": name,
                                "sha256": digest, "sourceSHA256": digest})
            prompt = "Use @Image1 with @Video1 and @Audio1." if label == "references" else "A quiet scene."
            model = "bytedance/seedance-2.5/" + endpoint
            payload = {"target": {"modelId": model, "endpoint": model}, "modality": "video",
                "destination": {"kind": "media_library"}, "prompt": prompt,
                "generationInput": {"model": model, "prompt": prompt, "duration": 4},
                "references": refs, "referenceRoles": list(roles.values())}
            identity = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
            request = {"prompt": prompt, "duration": "4"}
            for field, key in zip(url_keys, roles):
                url = "https://media.invalid/" + key
                request[field] = [url] if label == "references" else url
            output = b"validator-only-output" * 100
            paths = {kind: directory + "/" + label + "." + kind + (".bin" if kind == "output" else ".json")
                     for kind in ("package", "submit", "output")}
            write(root / paths["package"], {"schema": "generation-package/v1", "id": identity, "payload": payload})
            write(root / paths["submit"], request)
            (root / paths["output"]).write_bytes(output)
            (package / "media" / label).write_bytes(output)
            entries.append({"id": label, "source": {"project": {"relativePath": "media/" + label}},
                            "generationInput": {"generationPackageID": identity}})
            results.append({"kind": label, "assetID": label, "packageID": identity, "artifacts": paths,
                            "uploads": uploads, "decodedFrames": 120})
        write(package / "media.json", {"entries": entries})
        write(package / "project.json", {"fps": 30, "width": 320, "height": 180, "tracks": []})
        clicks = {"media.action.Generate": 1, "generation.media.review": 4, "generation.media.approve": 3,
            "generation.media.package.copy-package": 4, "generation.media.discard": 1,
            "generation.media.pick.First Frame": 1, "generation.media.pick.Last Frame": 1,
            "generation.media.pick.References": 7, "generation.media.reference.remove.motion": 1}
        actions = [{"kind": "pointer", "id": identifier} for identifier, count in clicks.items() for _ in range(count)]
        actions += [{"kind": "menu", "id": "generation.media.model", "closed": True}] * 4
        images = [directory + "-" + label + ".png" for label in
                  ("free-review", "frames-review", "references-review", "model-reset", "cleared-review")]
        for image in images:
            (root / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"validator-only" * 100)
        progress = directory + ".json"
        write(root / progress, {"interactions": actions, "screenshots": images})
        return [{"event": "manual-video-modes", "scale": 1.5, "effectiveScale": 1.5, "viewport": [960, 640],
            "liveProvider": False, "directory": directory, "project": project, "progress": progress,
            "results": results, "interactions": actions, "screenshots": images},
            {"event": "completed", "case": "manualvideomodes", "scale": 1.5}]

    def test_valid_shape_and_changed_owner_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            rows = self.fixture(root)
            self.assertTrue(manual_video_modes_evidence(rows, root, 1.5)[0])
            for key, value in (("liveProvider", True), ("effectiveScale", 1), ("results", []), ("screenshots", [])):
                altered = copy.deepcopy(rows)
                altered[0][key] = value
                self.assertFalse(manual_video_modes_evidence(altered, root, 1.5)[0], key)
            altered = copy.deepcopy(rows)
            altered[0]["results"][1]["decodedFrames"] = 119
            self.assertFalse(manual_video_modes_evidence(altered, root, 1.5)[0])

    def test_consistent_stale_image_tag_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            rows = self.fixture(root)
            item = rows[0]["results"][2]
            stale = "Use @reference1 with @Video1 and @Audio1."
            for kind in ("package", "submit"):
                path = root / item["artifacts"][kind]
                data = json.loads(path.read_text())
                if kind == "package":
                    data["payload"]["prompt"] = stale
                    data["payload"]["generationInput"]["prompt"] = stale
                else:
                    data["prompt"] = stale
                path.write_text(json.dumps(data))
            self.assertFalse(manual_video_modes_evidence(rows, root, 1.5)[0])

    def test_reversed_first_last_and_wrong_reference_media_are_rejected(self):
        for label, field, wrong in (("frames", "image_url", "https://media.invalid/last"),
                                    ("references", "video_urls", ["https://media.invalid/first"]),
                                    ("references", "prompt", "Use @reference1 for the image."),
                                    ("free", "image_url", "https://media.invalid/hidden-source")):
            with self.subTest(label=label, field=field), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                rows = self.fixture(root)
                item = next(item for item in rows[0]["results"] if item["kind"] == label)
                path = root / item["artifacts"]["submit"]
                request = json.loads(path.read_text()); request[field] = wrong
                path.write_text(json.dumps(request))
                self.assertFalse(manual_video_modes_evidence(rows, root, 1.5)[0])

    def test_uploaded_source_replacement_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            rows = self.fixture(root)
            item = rows[0]["results"][1]["uploads"][0]
            (root / rows[0]["directory"] / item["file"]).write_bytes(b"changed after approval")
            self.assertFalse(manual_video_modes_evidence(rows, root, 1.5)[0])


if __name__ == "__main__":
    unittest.main()
