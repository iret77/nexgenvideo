import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from retained_spatial_evidence import validate, validate_report


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
        for name, yaw, pitch, fov in [("wide_front", 0, -5, 75), ("wide_right", 90, -5, 75),
                                       ("wide_back", 180, -5, 75), ("wide_left", -90, -5, 75), ("owner_reverse", 180, 0, 60)]:
            image = ref(directory, prefix + name + ".png")
            image["path"] = "bible/ns/native-panorama-owner/" + name + ".png"
            views.append({"geometry": {"name": name, "yaw": yaw, "pitch": pitch, "fov": fov}, "image": image})
        panorama = ref(directory, prefix + "panorama.png")
        panorama["path"] = "bible/ns/native-panorama-owner/panorama.png"
        receipt_path = "bible/native-panorama-selections/owner.v1.json"
        receipt_file = directory / (prefix + "receipt.v1.json")
        put(receipt_file, {"schema": "native-panorama-selection/v1", "locationID": "room", "panorama": panorama,
                           "recordedAt": "fixture", "views": views})
        receipt_hash = hashlib.sha256(receipt_file.read_bytes()).hexdigest()
        appearance = ref(directory, prefix + "appearance-front.png")
        sheet = {"view": "front", "path": "bible/ns/appearance.png", "sha256": appearance["sha256"], "copy": appearance["path"]}
        for state in ("before", "after", "removed"):
            location = {"id": "room", "sheets": {"front": sheet["path"]}, "attributes": {}, "scene3d": {}}
            if state == "after":
                location["attributes"] = {"core.native-panorama-receipt": receipt_path, "core.native-panorama-receipt-sha256": receipt_hash}
                location["scene3d"] = {"panorama": panorama["path"], "povs": [view["geometry"] for view in views], "provider": "native-import"}
            put(directory / (prefix + "bible-" + state + ".json"), {"locations": [location]})
        fields = {"panoramaSHA256": source["sha256"], "receiptSHA256": receipt_hash, "receiptPath": receipt_path,
                  "viewCount": 5, "appearanceSheets": [sheet], "renderedFontPointSize": 13 * scale,
                  "invalidAspectRejected": True, "appearanceRejected": True, "nativeRemoval": True, "removalUndo": True,
                  "missingReceiptRecovery": True, "tamperedReceiptRecovery": True, "recoveryUndoAfterRestoringOriginalBytes": True,
                  "appearanceSheetsPreserved": True, "nativeUndoRedo": True, "bibleChanged": True, "locationID": "room"}
        entry = native(directory, prefix + "driver", scale, "native panorama selection", fields)
        entry["interactions"] += [{"kind": "pointer", "id": control} for control in
                                  ["bible.panorama.remove", "bible.panorama.remove-invalid", "bible.panorama.remove-invalid"]]
        entry["interactions"].append({"kind": "text", "field": {"id": "bible.panorama.fov", "fontPointSize": 13 * scale}})
        put(directory / entry["progress"], {"interactions": entry["interactions"], "screenshots": entry["screenshots"], "failure": None})
        entries.append(entry)
    put(directory / "native-panorama-result.json", entries)
    put(directory / "result.json", {"productionSpatial": {"nativePlanUI": json.loads((directory / "native-blockout-plan-result.json").read_text()),
        "nativeBlockoutImportUI": json.loads((directory / "native-blockout-import-result.json").read_text()), "nativePanoramaUI": entries}})


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

    def edit_panorama(self, change):
        path = self.root / "native-panorama-result.json"
        data = json.loads(path.read_text())
        change(data)
        put(path, data)
        for entry in data:
            put(self.root / entry["progress"], {"interactions": entry["interactions"], "screenshots": entry["screenshots"], "failure": None})

    def test_panorama_requires_every_scale(self):
        self.edit_panorama(lambda entries: entries.pop())
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_requires_each_observed_action(self):
        for flag in ("invalidAspectRejected", "nativeUndoRedo", "nativeRemoval", "removalUndo", "missingReceiptRecovery", "tamperedReceiptRecovery", "appearanceRejected"):
            with self.subTest(flag=flag):
                fixture(self.root)
                self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].__setitem__(flag, False))
                with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_foreign_location_rejected(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].__setitem__("locationID", "other"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_missing_location_rejected(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].pop("locationID"))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_receipt_bytes_rejected(self):
        path = self.root / "native-panorama-100-receipt.v1.json"
        value = json.loads(path.read_text()); value["recordedAt"] = "changed"; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_requires_unique_receipt(self):
        path = self.root / "native-panorama-100-receipt.v1.json"
        (self.root / "native-panorama-100-extra.v1.json").write_bytes(path.read_bytes())
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_requires_receipt(self):
        (self.root / "native-panorama-100-receipt.v1.json").unlink()
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_in_project_bytes_required(self):
        (self.root / "native-panorama-100-panorama.png").write_bytes(b"changed")
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_cardinal_geometry_not_just_hash(self):
        path = self.root / "native-panorama-100-receipt.v1.json"
        value = json.loads(path.read_text()); value["views"][0]["geometry"]["yaw"] = 12; put(path, value)
        new_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].__setitem__("receiptSHA256", new_hash))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_bible_pointer_hash_required(self):
        path = self.root / "native-panorama-100-bible-after.json"
        value = json.loads(path.read_text()); value["locations"][0]["attributes"]["core.native-panorama-receipt-sha256"] = "foreign"; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_appearance_cannot_be_empty(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"][2]["evidence"].__setitem__("appearanceSheets", []))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_rendered_font_not_defaults(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"][-1]["field"].__setitem__("fontPointSize", 13 * 1.5))
        with self.assertRaises(ValueError): validate(self.root)

    def test_cli_binds_actual_result(self):
        value = json.loads((self.root / "result.json").read_text()); value["productionSpatial"]["nativePanoramaUI"] = []
        put(self.root / "result.json", value)
        with self.assertRaises(ValueError): validate_report(self.root)

    def test_panorama_actual_removal_pointer_required(self):
        self.edit_panorama(lambda entries: entries[0]["interactions"].__setitem__(4, {"kind": "pointer", "id": "wrong.control"}))
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_preserved_appearance_bytes_required(self):
        (self.root / "native-panorama-100-appearance-front.png").write_bytes(b"changed")
        with self.assertRaises(ValueError): validate(self.root)

    def test_panorama_removed_bible_cannot_keep_receipt(self):
        path = self.root / "native-panorama-100-bible-removed.json"
        value = json.loads(path.read_text()); value["locations"][0]["attributes"]["core.native-panorama-receipt"] = "retained"; put(path, value)
        with self.assertRaises(ValueError): validate(self.root)
