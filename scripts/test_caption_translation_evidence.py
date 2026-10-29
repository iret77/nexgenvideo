import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from caption_translation_evidence import validate


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))


def translation_fixture(directory, scale=1.0):
    """Synthetic independent-parser fixture, never native evidence."""
    directory.mkdir(parents=True, exist_ok=True)
    clips = [{"id": "translate-first", "textContent": "Good morning.", "startFrame": 0, "durationFrames": 60},
             {"id": "translate-second", "textContent": "We are ready.", "startFrame": 75, "durationFrames": 45}]
    before = {"fps": 30, "tracks": [{"id": "translation-track", "clips": clips}]}
    for name in ("before", "cancelled", "undo"): put(directory / (name + ".json"), before)
    applied = copy.deepcopy(before); applied["tracks"][0]["clips"][0]["textContent"] = "Guten Morgen."
    for name in ("applied", "redo", "reopened", "Caption translation.ngv/project"): put(directory / (name + ".json"), applied)
    args = {"kind": "captions", "changes": [{"clipId": "translate-first", "text": "Guten Morgen."}, {"clipId": "translate-second", "text": "Wir sind bereit."}]}
    rows = [{"id": "translate-first", "before": "Good morning.", "after": "Guten Morgen.", "timeRange": "0.00–2.00 s"},
            {"id": "translate-second", "before": "We are ready.", "after": "Wir sind bereit.", "timeRange": "2.50–4.00 s"}]
    scope = {"projectID": "project", "workingRoot": "file:///fixture/project", "generation": "generation", "timelineSHA256": hashlib.sha256((directory / "before.json").read_bytes()).hexdigest(),
             "kind": "captions", "captionIDs": ["translate-first", "translate-second"], "sources": []}
    actions, requests = [], []
    for index in (1, 2):
        put(directory / f"proposal-{index}.json", {"scope": scope, "rows": rows})
        requests.append({"sessionID": "session", "turnID": str(index), "texts": ["Then translate the captions to German, keeping timing unchanged."],
                         "tool": "propose_caption_revision", "arguments": args, "isError": False, "result": "fixture"})
        observed = {"index": index, "language": "German", "ids": [row["id"] for row in rows], "before": [row["before"] for row in rows],
                    "after": [row["after"] for row in rows], "times": [row["timeRange"] for row in rows], "selected": [], "applyEnabled": False}
        actions.extend([{"kind": "menu", "id": "captions.actions", "path": ["Translate", "German"], "closed": True, "menus": [["Translate"], ["French", "German"]]},
                        {"kind": "text", "field": {"id": "agent.composer.input", "fontPointSize": 13 * scale}},
                        {"kind": "pointer", "id": "agent.task.run"}, {"kind": "verified-state", "label": "translated proposal visible", "evidence": observed}])
        for row in rows:
            actions.append({"kind": "visible-group", "ids": ["captions.revision.choice." + row["id"]],
                            "frames": [[10, 10, 120, 30]], "viewport": [0, 0, 960, 640]})
        actions.append({"kind": "pointer", "id": "agent.dialog.cancel" if index == 1 else "agent.dialog.confirm"})
    actions.append({"kind": "pointer", "id": "captions.revision.choice.translate-first"})
    for chars in ("z", "Z"):
        actions.append({"kind": "keyboard", "code": 6, "characters": chars, "modifiers": (1 << 20) | ((1 << 17) if chars == "Z" else 0)})
    actions.append({"kind": "keyboard", "code": 1, "characters": "s", "modifiers": 1 << 20})
    images = ["before.png", "proposal.png", "translated.png"]
    for name in images: (directory / name).write_bytes(b"\x89PNG\r\n\x1a\n" + b"synthetic translation parser fixture" * 40)
    result = {"language": "German", "scale": scale, "viewport": [960, 640], "liveAgent": False, "savedAndReopened": True,
              "renderedFontPointSize": 13 * scale, "interactions": actions, "screenshots": images, "progress": "translation-owner.json"}
    put(directory / "requests.json", requests); put(directory / result["progress"], {**result, "failure": None})
    put(directory / "translation-result.json", result)
    return result


class CaptionTranslationEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory(); self.root = Path(self.temp.name); translation_fixture(self.root)

    def tearDown(self): self.temp.cleanup()

    def test_complete_synthetic_validator_fixture(self):
        self.assertEqual(validate(self.root, 1.0)["language"], "German")

    def test_wrong_target_language_request_rejected(self):
        path = self.root / "requests.json"; value = json.loads(path.read_text()); value[0]["texts"] = ["translate the captions to French"]
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_timing_change_cannot_hide_behind_correct_translation(self):
        path = self.root / "applied.json"; value = json.loads(path.read_text()); value["tracks"][0]["clips"][0]["durationFrames"] = 75
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_unselected_caption_cannot_change(self):
        path = self.root / "applied.json"; value = json.loads(path.read_text()); value["tracks"][0]["clips"][1]["textContent"] = "Wir sind bereit."
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_cancel_and_reopen_must_preserve_full_timeline(self):
        for name in ("cancelled", "reopened"):
            path = self.root / (name + ".json"); old = path.read_bytes(); value = json.loads(old); value["fps"] = 24
            put(path, value)
            with self.assertRaises(ValueError): validate(self.root)
            path.write_bytes(old)

    def test_actual_language_submenu_required(self):
        path = self.root / "translation-result.json"; value = json.loads(path.read_text())
        for row in value["interactions"]:
            if row.get("kind") == "menu": row["path"] = ["Fix names & jargon"]
        put(path, value); put(self.root / value["progress"], {**value, "failure": None})
        with self.assertRaises(ValueError): validate(self.root)

    def test_exact_before_timeline_sha_required(self):
        path = self.root / "proposal-2.json"; value = json.loads(path.read_text()); value["scope"]["timelineSHA256"] = "foreign"
        put(path, value)
        with self.assertRaises(ValueError): validate(self.root)

    def test_wrong_outer_scale_rejected(self):
        with self.assertRaises(ValueError): validate(self.root, 1.5)


if __name__ == "__main__": unittest.main()
