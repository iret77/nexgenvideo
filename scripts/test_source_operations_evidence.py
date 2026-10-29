import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from source_operations_evidence import source_operations_evidence


class SourceOperationsEvidenceTests(unittest.TestCase):
    def fixture(self, root):
        directory = root / "source-operations-150"
        package = directory / "Source operations.ngv"
        (package / "media").mkdir(parents=True)
        before = {"fps": 30, "tracks": [{"clips": [{"id": "picture", "mediaRef": "original",
            "trimStartFrame": 60, "speed": 2, "durationFrames": 60}]}] +
            [{"clips": [{"id": name, "startFrame": start}]} for name, start in
             (("reference", 0), ("recorder", 60), ("silence", 90))]}
        (directory / "before.json").write_text(json.dumps(before))
        saved = copy.deepcopy(before)
        saved["tracks"][0]["clips"][0]["mediaRef"] = "replacement"
        saved["tracks"][2]["clips"][0]["startFrame"] = 0
        (package / "project.json").write_text(json.dumps(saved))
        row = {"event": "source-operations", "scale": 1.5, "effectiveScale": 1.5,
               "directory": directory.name, "project": package.name, "viewport": [960, 640],
               "refusal": "Audio could not be matched."}
        entries = []
        for kind, count, first in (("clip", 60, 60), ("range", 30, 90)):
            movie = bytes(kind, "ascii") * 600
            (directory / (kind + ".mp4")).write_bytes(movie)
            (package / "media" / (kind + ".mp4")).write_bytes(movie)
            pixels = bytes((230, 50, 10, 255)) * count
            (directory / (kind + ".bgra")).write_bytes(pixels)
            (directory / (kind + ".motion.json")).write_text(json.dumps(
                [104.5 + 120 * (first + 2 * index) / 239 for index in range(count)]))
            row[kind + "ID"] = kind + "-id"
            row[kind] = {"sha256": hashlib.sha256(movie).hexdigest(), "frames": count, "duration": count / 30,
                "pixels": kind + ".bgra", "pixelsSHA256": hashlib.sha256(pixels).hexdigest(),
                "motion": kind + ".motion.json"}
            entries.append({"id": kind + "-id", "source": {"project": {"relativePath": "media/" + kind + ".mp4"}},
                            "duration": count / 30, "hasAudio": kind == "range"})
        (package / "media.json").write_text(json.dumps({"entries": entries}))
        row["interactions"] = [{"kind": "context-menu", "closed": True, "path": path} for path in (
            ["Swap Media"], ["Swap Media"], ["Synchronize", "Audio"], ["Synchronize", "Audio"],
            ["Save as Media"], ["Save Range as Media"], ["Clear Range"])]
        row["interactions"] += [{"kind": "pointer", "id": key} for key in ("media.swap.cancel", "media.asset.replacement")]
        row["interactions"] += [{"kind": "verified-state", "label": "source-operation-gesture",
            "evidence": {"target": key, "shift": True}} for key in ("range-15-45", "select-recorder", "select-silence")]
        row["interactions"] += [{"kind": "keyboard", "characters": key} for key in ("z", "Z", "z", "Z", "s")]
        row["screenshots"] = ["source-operations-150-" + label + ".png" for label in (
            "swap-source", "saved-clip", "saved-range", "synchronized-audio", "sync-refused")]
        for name in row["screenshots"]:
            (root / name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"fixture" * 200)
        return [row, {"event": "completed", "case": "sourceoperations", "scale": 1.5}], directory, package

    def test_exact_saved_edit_and_required_native_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rows, _, package = self.fixture(root)
            self.assertTrue(source_operations_evidence(rows, root, 1.5)[0])
            for index in range(len(rows[0]["interactions"])):
                changed = copy.deepcopy(rows)
                changed[0]["interactions"].pop(index)
                self.assertFalse(source_operations_evidence(changed, root, 1.5)[0])
            self.assertFalse(source_operations_evidence(rows, root, 1.25)[0])
            path = package / "project.json"
            saved = json.loads(path.read_text())
            saved["tracks"][0]["clips"][0]["speed"] = 1
            path.write_text(json.dumps(saved))
            self.assertFalse(source_operations_evidence(rows, root, 1.5)[0])

    def test_reported_success_cannot_replace_saved_movie_bytes_or_motion(self):
        for defect in ("bytes", "motion", "duration", "sound", "escape", "success-refusal"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                rows, directory, package = self.fixture(root)
                if defect == "bytes":
                    (package / "media/clip.mp4").write_bytes(b"different media" * 100)
                elif defect == "motion":
                    (directory / "clip.motion.json").write_text(json.dumps([120] * 60))
                elif defect == "duration":
                    rows[0]["clip"]["duration"] = 4
                elif defect == "sound":
                    path = package / "media.json"
                    manifest = json.loads(path.read_text())
                    manifest["entries"][1]["hasAudio"] = False
                    path.write_text(json.dumps(manifest))
                elif defect == "escape":
                    rows[0]["project"] = "../../../elsewhere"
                else:
                    rows[0]["refusal"] = "Synchronized by audio"
                self.assertFalse(source_operations_evidence(rows, root, 1.5)[0])


if __name__ == "__main__":
    unittest.main()
