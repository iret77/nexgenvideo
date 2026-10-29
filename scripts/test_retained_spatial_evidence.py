import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from retained_spatial_evidence import validate


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


def ref(directory, path, value=b"isolated validator fixture"):
    target = directory / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(value)
    return {"id": path, "role": "fixture", "path": path, "sha256": hashlib.sha256(value).hexdigest()}


def native(directory, name, scale, label, evidence):
    actions = [{"kind": "pointer", "id": "fixture.control"}, {"kind": "save-panel", "filename": evidence.get("export"),
                "nativeDirectoryAndFilenameTyped": True, "exactURLVerified": True}, {"kind": "verified-state", "label": label, "evidence": evidence}]
    screenshot = name + ".png"
    (directory / screenshot).write_bytes(b"isolated screenshot fixture")
    progress = name + ".json"
    put(directory / progress, {"interactions": actions, "screenshots": [screenshot], "failure": None})
    return {"interactions": actions, "screenshots": [screenshot], "progress": progress, "scale": scale,
            "viewport": [960, 640], "backingScale": 2}


def fixture(directory):
    for imported in (False, True):
        entries = []
        kind = "import" if imported else "plan"
        for scale in (1.0, 1.25, 1.5):
            name = f"native-blockout-{kind}-{int(scale * 100)}.mov"
            media = ref(directory, name)
            ref(directory, name.replace(".mov", "-export.mov"))
            closure = directory / (name + ".evidence")
            output = ref(closure, "execution/blockout/ns/native-owner/blockout.mov")
            output["role"] = "core.shot-blockout-video" if imported else "host.plan-elevation-video"
            receipt = {"schema": "native-blockout-selection/v1", "shotID": "shot", "kind": "importedGeometry" if imported else "planElevation",
                       "recordedAt": "fixture", "observation": "fixture", "output": output,
                       "draft": ref(closure, "shot-planning/v1.v1.json"), "timing": ref(closure, "storyboard/timing/v1.json"),
                       "stateReferences": [ref(closure, "state.json")]}
            if imported:
                receipt.update(original=ref(closure, "execution/blockout/ns/native-owner/original.mov"), originalName="Original.mov",
                               sourceStartValue=0, sourceDurationValue=24, sourceTimescale=24, sourceDurationTimescale=24)
            put(directory / (name + ".receipt.json"), receipt)
            fields = {"media": name, "kind": receipt["kind"], "shotID": "shot", "outputSHA256": media["sha256"],
                      "receiptSHA256": hashlib.sha256((directory / (name + ".receipt.json")).read_bytes()).hexdigest(),
                      "appearanceRejected": True, "nativeUndoRedo": True, "nativeFileExport": True, "export": name.replace(".mov", "-export.mov"), "durationValue": 24, "durationTimescale": 24}
            entries.append(native(directory, name, scale, "native retained blockout", fields))
        put(directory / f"native-blockout-{kind}-result.json", entries)
    source = ref(directory, "native-owner-panorama.png")
    entries = []
    for scale in (1.0, 1.25, 1.5):
        prefix = f"native-panorama-{int(scale * 100)}-"
        views = []
        for name in ("wide_front", "wide_right", "wide_back", "wide_left", "owner_reverse"):
            image = ref(directory, prefix + name + ".png")
            image["path"] = "bible/ns/native-panorama-owner/" + name + ".png"
            views.append({"geometry": {"name": name, "yaw": 180 if name == "owner_reverse" else 0,
                                       "pitch": 0, "fov": 60}, "image": image})
        put(directory / (prefix + "receipt.v1.json"), {"schema": "native-panorama-selection/v1", "locationID": "room",
            "panorama": source, "recordedAt": "fixture", "views": views})
        fields = {"panoramaSHA256": source["sha256"], "viewCount": 5, "invalidAspectRejected": True,
                  "appearanceSheetsPreserved": True, "nativeUndoRedo": True, "bibleChanged": True, "locationID": "room"}
        entries.append(native(directory, prefix + "driver", scale, "native panorama selection", fields))
    put(directory / "native-panorama-result.json", entries)


class RetainedSpatialEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.root = Path(self.temp.name)
        fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_complete_isolated_validator_fixture(self):
        self.assertEqual(set(validate(self.root)), {"plan", "import", "panorama"})

    def test_changed_movie_rejected(self):
        (self.root / "native-blockout-import-100.mov").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_missing_state_source_rejected(self):
        (self.root / "native-blockout-plan-100.mov.evidence/state.json").unlink()
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_changed_receipt_rejected(self):
        (self.root / "native-blockout-plan-100.mov.receipt.json").write_text("{}")
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_actual_scale_required(self):
        path = self.root / "native-blockout-plan-result.json"
        data = json.loads(path.read_text())
        data[0]["scale"] = 1.5
        put(path, data)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_failed_driver_rejected(self):
        path = self.root / "native-blockout-plan-100.mov.json"
        data = json.loads(path.read_text())
        data["failure"] = "focus failed"
        put(path, data)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_panorama_camera_change_rejected(self):
        path = self.root / "native-panorama-100-receipt.v1.json"
        data = json.loads(path.read_text())
        data["views"][-1]["geometry"]["yaw"] = 0
        put(path, data)
        with self.assertRaises(ValueError):
            validate(self.root)

    def test_changed_pov_bytes_rejected(self):
        (self.root / "native-panorama-100-owner_reverse.png").write_bytes(b"different viewpoint")
        with self.assertRaises(ValueError):
            validate(self.root)
