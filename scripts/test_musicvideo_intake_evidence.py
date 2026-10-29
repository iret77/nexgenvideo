import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from musicvideo_intake_evidence import validate


def intake_fixture(directory, lyrics_name=None):
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
    # Synthetic parser records are not native input or private-song evidence.
    def pointer(identifier): return {"kind": "pointer", "id": "agent.dialog." + identifier}
    def file(name): return {"kind": "file-panel", "path": name, "selectedURLVerified": True, "nativePathEditorVerified": True}
    def text(value): return {"kind": "text", "field": {"id": "agent.dialog.direction", "expected": value, "actual": value, "commitInput": "Tab"}}
    startup = [pointer("choose-file"), file("Song.wav"), pointer("confirm")]
    if lyrics_name is not None: startup += [pointer("choose-file"), file(lyrics_name)]
    startup += [pointer("confirm"), {"kind": "verified-state", "label": "native Track and optional Lyrics intake", "evidence": {
        "trackName": "Song.wav", "trackSHA256": hashlib.sha256(track).hexdigest(), "lyricsSupplied": lyrics_name is not None,
        "lyricsName": lyrics_name, "creativeIntakeAbsent": True, "nextPhase": "project_init"}}]
    repeated = [pointer("choose-file"), {"kind": "file-panel-cancel"}, pointer("choose-file"), file("Stage.png"),
        pointer("direction"), text("Stage"), pointer("confirm"), pointer("direction"), text("Unfinished location"),
        {"kind": "visible-group", "ids": ["agent.dialog.confirm", "agent.dialog.complete", "agent.dialog.clear-item"]},
        pointer("clear-item"), pointer("complete"),
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

    def test_order_and_actual_lyrics_filename_are_required(self):
        for defect in ("early-confirm", "text-before-pointer", "wrong-lyrics"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                report = intake_fixture(directory, lyrics_name="Actual lyrics.txt")
                self.assertEqual(len(validate(directory, report)), 2)
                filename = report["nativeIntakeEvidence"][0 if defect == "wrong-lyrics" else 1]
                result = json.loads((directory / filename).read_text())
                actions = result["interactions"]
                if defect == "early-confirm":
                    index = next(i for i, a in enumerate(actions) if a.get("id") == "agent.dialog.confirm")
                    actions.insert(index - 1, actions.pop(index))
                elif defect == "text-before-pointer":
                    index = next(i for i, a in enumerate(actions) if a.get("kind") == "text")
                    actions[index - 1], actions[index] = actions[index], actions[index - 1]
                else:
                    [a for a in actions if a.get("kind") == "file-panel"][1]["path"] = "Other lyrics.txt"
                for name in (filename, result["progress"]):
                    (directory / name).write_text(json.dumps(result))
                with self.assertRaises(ValueError): validate(directory, report)

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
