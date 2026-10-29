import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from musicvideo_intake_evidence import validate


def intake_fixture(directory):
    directory.mkdir(parents=True, exist_ok=True)
    source = b"\x89PNG\r\n\x1a\n" + b"unit-location" * 200
    digest = hashlib.sha256(source).hexdigest()
    for name in ("intake-location.png", "intake-confirmed-location.png"):
        (directory / name).write_bytes(source)
    manifest = {"schema": "confirmed-identity-assets/v1", "project": "unit-project", "entries": {"location-one": {
        "id": "location-one", "role": "location", "identity_name": "Stage", "identity_slug": "stage", "sha256": digest}}}
    for name in ("intake-before-partial.json", "intake-after-partial.json"):
        (directory / name).write_text(json.dumps(manifest))
    track = b"supplied unit audio bytes"
    for name in ("intake-track-source.bin", "intake-track-assigned.bin"):
        (directory / name).write_bytes(track)
    startup = [
        {"kind": "file-panel", "path": "Song.wav", "selectedURLVerified": True, "nativePathEditorVerified": True},
        {"kind": "verified-state", "label": "native Track and optional Lyrics intake", "evidence": {
            "trackName": "Song.wav", "trackSHA256": hashlib.sha256(track).hexdigest(), "lyricsSupplied": False,
            "creativeIntakeAbsent": True, "nextPhase": "project_init"}}]
    startup += [{"kind": "pointer", "id": "agent.dialog.confirm"}] * 2
    repeated = [{"kind": "pointer", "id": item} for item in (
        "agent.dialog.choose-file", "agent.dialog.choose-file", "agent.dialog.direction", "agent.dialog.confirm",
        "agent.dialog.direction", "agent.dialog.clear-item", "agent.dialog.complete")]
    repeated += [{"kind": "text", "field": {"id": "agent.dialog.direction", "expected": value, "actual": value,
        "commitInput": "Tab"}} for value in ("Stage", "Unfinished location")]
    repeated += [{"kind": "file-panel-cancel"}, {"kind": "file-panel", "path": "Stage.png",
        "selectedURLVerified": True, "nativePathEditorVerified": True},
        {"kind": "visible-group", "ids": ["agent.dialog.confirm", "agent.dialog.complete", "agent.dialog.clear-item"]},
        {"kind": "verified-state", "label": "native incomplete repeated location", "evidence": {
            "firstName": "Stage", "nextTitle": "Prepared location 2", "partialName": "Unfinished location",
            "sourceSHA256": digest, "confirmedID": "location-one", "fileWithoutNameBlocked": True,
            "partialAttachBlocked": True, "partialDoneBlocked": True,
            "clearPreservedConfirmedIdentity": True, "doneAdvancedToStyle": True}}]
    names = []
    for name, actions in (("hostflow-track-lyrics", startup), ("hostflow-repeatable-intake", repeated)):
        image = name + ".png"
        (directory / image).write_bytes(source)
        result = {"interactions": actions, "screenshots": [image], "progress": name + ".json"}
        (directory / (name + ".json")).write_text(json.dumps(result))
        (directory / (name + "-result.json")).write_text(json.dumps(result))
        names.append(name + "-result.json")
    return {"nativeIntakeEvidence": names}


class MusicvideoIntakeEvidenceTests(unittest.TestCase):
    def test_exact_intake_and_required_native_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = intake_fixture(directory)
            self.assertEqual(len(validate(directory, report)), 2)
            for filename in report["nativeIntakeEvidence"]:
                original = json.loads((directory / filename).read_text())
                for index in range(len(original["interactions"])):
                    changed = copy.deepcopy(original)
                    changed["interactions"].pop(index)
                    for name in (filename, changed["progress"]):
                        (directory / name).write_text(json.dumps(changed))
                    with self.assertRaises(ValueError):
                        validate(directory, report)
                for name in (filename, original["progress"]):
                    (directory / name).write_text(json.dumps(original))

    def test_partial_item_cannot_change_confirmed_material_or_use_flags_alone(self):
        for defect in ("changed-after", "lost-file", "wrong-name", "partial-done", "missing-stage", "unsafe-image", "song-bytes", "typed-name"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                report = intake_fixture(directory)
                if defect == "changed-after":
                    path = directory / "intake-after-partial.json"
                    value = json.loads(path.read_text()); value["entries"] = {}
                    path.write_text(json.dumps(value))
                elif defect == "lost-file":
                    (directory / "intake-confirmed-location.png").write_bytes(b"wrong bytes")
                elif defect == "wrong-name":
                    for name in ("intake-before-partial.json", "intake-after-partial.json"):
                        path = directory / name
                        value = json.loads(path.read_text()); value["entries"]["location-one"]["identity_name"] = "Unfinished location"
                        path.write_text(json.dumps(value))
                elif defect == "song-bytes":
                    (directory / "intake-track-assigned.bin").write_bytes(b"other song")
                elif defect == "missing-stage":
                    report["nativeIntakeEvidence"].pop()
                else:
                    filename = report["nativeIntakeEvidence"][1]
                    result = json.loads((directory / filename).read_text())
                    if defect == "typed-name":
                        next(item for item in result["interactions"] if item.get("kind") == "text")["field"]["actual"] = "Other name"
                    elif defect == "partial-done":
                        result["interactions"][-1]["evidence"]["partialDoneBlocked"] = False
                    else:
                        result["screenshots"] = ["../foreign.png"]
                    for name in (filename, result["progress"]):
                        (directory / name).write_text(json.dumps(result))
                with self.assertRaises(ValueError):
                    validate(directory, report)


if __name__ == "__main__":
    unittest.main()
