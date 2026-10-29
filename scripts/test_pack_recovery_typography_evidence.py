import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from pack_recovery_owner_acceptance import require_composer_typography, require_saved_draft, require_session_edit, require_resume_identity, gate_approvals, validate
from prepare_settings_pack_artifacts import PREVIEW_PROFILE, STABLE_PROFILE


class RecoveryTypographyEvidenceTests(unittest.TestCase):
    def test_stable_restart_cannot_be_relabelled_as_approved_preview_continuation(self):
        with TemporaryDirectory() as directory:
            output = Path(directory)
            for scenario in (None, STABLE_PROFILE):
                record = {} if scenario is None else {"scenario": scenario}
                for name in ("pack-recovery-state.json", "pack-recovery-result.json"):
                    (output / name).write_text(json.dumps(record))
                with self.subTest(scenario=scenario), self.assertRaisesRegex(AssertionError, "requested Recovery scenario"):
                    validate(output, expected_scenario=PREVIEW_PROFILE)

    def test_approved_resume_requires_same_uuid_exact_saved_pin_and_native_cut(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            original, saved, reopened = [root / name for name in ("original", "saved", "reopened")]
            source = {"id": "musicvideo", "version": "0.5.16", "projectSchema": "musicvideo/2.0.0"}
            target = {**source, "version": "0.6.0", "projectSchema": "musicvideo/3.0.0"}
            identifier = "2564BA87-9222-4B5E-BA40-000000000001"
            initial = {"width": 320, "height": 180, "fps": 30, "settingsConfigured": True, "markers": [],
                       "tracks": [{"id": "original-video", "type": "video", "clips": [{"id": "retained-cut",
                           "mediaRef": "retained-original", "startFrame": 0, "durationFrames": 180, "trimStartFrame": 30}]}]}
            timeline = copy.deepcopy(initial)
            timeline["tracks"].append({"id": "actual-song", "type": "audio", "clips": [{"id": "song-clip",
                "mediaRef": "song", "startFrame": 0, "durationFrames": 129, "trimStartFrame": 0, "trimEndFrame": 0}]})
            manifest = {"version": 7, "entries": [
                {"id": "retained-original", "type": "video", "name": "Retained original moving shot",
                 "originalFilename": "Retained original moving shot.mov",
                 "source": {"project": {"relativePath": "media/Retained original moving shot.mov"}}, "duration": 8},
                {"id": "song", "type": "audio", "originalFilename": "Retained original song.wav",
                 "source": {"project": {"relativePath": "media/song.wav"}}, "duration": 4.3}],
                "folders": [], "songAnchorAssetId": "song", "songAnchorOwnsAsset": True, "intakeRoleByAssetID": {"song": "song"}}
            state = {"projectID": identifier, "source": source, "target": target,
                     "initialTimeline": initial, "timeline": timeline,
                     "initialVideoEntry": copy.deepcopy(manifest["entries"][0])}
            resume = {"projectID": identifier, "projectURL": str(saved)}
            for home, binding in ((original, source), (saved, target), (reopened, target)):
                home.mkdir()
                (home / "ngv.json").write_text(json.dumps({"id": identifier, "activePlugin": binding["id"],
                    "activePluginVersion": binding["version"], "activePluginProjectSchema": binding["projectSchema"]}))
                (home / "project.json").write_text(json.dumps(timeline))
                (home / "media.json").write_text(json.dumps(manifest))
            require_resume_identity(state, resume, original, saved, reopened)
            (reopened / "project.json").write_text(json.dumps(timeline, indent=2, sort_keys=True))
            (reopened / "media.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
            require_resume_identity(state, resume, original, saved, reopened)
            for home in (original, saved, reopened):
                path = home / "ngv.json"
                before = path.read_bytes()
                for field, value in (("id", "2564BA87-9222-4B5E-BA40-000000000002"),
                                     ("activePluginVersion", "0.5.99"), ("activePluginProjectSchema", "musicvideo/1.0.0")):
                    changed = json.loads(before); changed[field] = value; path.write_text(json.dumps(changed))
                    with self.subTest(home=home.name, field=field), self.assertRaises(AssertionError):
                        require_resume_identity(state, resume, original, saved, reopened)
                    path.write_bytes(before)
            changed_state = {**state, "timeline": initial}
            with self.assertRaisesRegex(AssertionError, "approved legacy baseline"):
                require_resume_identity(changed_state, resume, original, saved, reopened)
            changed = copy.deepcopy(initial); changed["tracks"][0]["clips"][0]["trimStartFrame"] = 0
            with self.assertRaisesRegex(AssertionError, "original native cut"):
                require_resume_identity({**state, "initialTimeline": changed}, resume, original, saved, reopened)
            for defect in ("missing-original", "source-original", "name-original", "filename-original", "type-original", "duplicate-original"):
                changed = copy.deepcopy(manifest)
                if defect == "missing-original": changed["entries"].pop(0)
                elif defect == "source-original": changed["entries"][0]["source"] = {"project": {"relativePath": "media/substitute.mov"}}
                elif defect == "name-original": changed["entries"][0]["name"] = "Substituted original"
                elif defect == "filename-original": changed["entries"][0]["originalFilename"] = "substitute.mov"
                elif defect == "type-original": changed["entries"][0]["type"] = "image"
                elif defect == "duplicate-original": changed["entries"].append(copy.deepcopy(changed["entries"][0]))
                (original / "media.json").write_text(json.dumps(changed))
                with self.subTest(original_source=defect), self.assertRaisesRegex(AssertionError, "independently pinned original source"):
                    require_resume_identity(state, resume, original, saved, reopened)
                (original / "media.json").write_text(json.dumps(manifest))
            for defect in ("missing-anchor", "wrong-duration", "wrong-intake"):
                changed = copy.deepcopy(manifest)
                if defect == "missing-anchor": changed.pop("songAnchorAssetId")
                elif defect == "wrong-duration": changed["entries"][1]["duration"] = 8
                elif defect == "wrong-intake": changed["intakeRoleByAssetID"]["song"] = "style"
                (original / "media.json").write_text(json.dumps(changed))
                with self.subTest(original_song=defect), self.assertRaisesRegex(AssertionError, "genuine song anchor"):
                    require_resume_identity(state, resume, original, saved, reopened)
                (original / "media.json").write_text(json.dumps(manifest))
            for home in (saved, reopened):
                for defect in ("missing-video", "source", "filename", "intake", "ownership"):
                    changed = copy.deepcopy(manifest)
                    if defect == "missing-video": changed["entries"].pop(0)
                    elif defect == "source": changed["entries"][0]["source"] = {"project": {"relativePath": "media/substitute.mov"}}
                    elif defect == "filename": changed["entries"][0]["originalFilename"] = "Substituted source.mov"
                    elif defect == "intake": changed["intakeRoleByAssetID"]["song"] = "style"
                    elif defect == "ownership": changed["songAnchorOwnsAsset"] = False
                    (home / "media.json").write_text(json.dumps(changed))
                    with self.subTest(home=home.name, defect=defect), self.assertRaisesRegex(AssertionError, "media sources or intake manifest"):
                        require_resume_identity(state, resume, original, saved, reopened)
                    (home / "media.json").write_text(json.dumps(manifest))
            (reopened / "project.json").write_bytes(b'{"tracks":[]}')
            with self.assertRaisesRegex(AssertionError, "original native cut"):
                require_resume_identity(state, resume, original, saved, reopened)

    def test_retained_startup_and_reset_production_approvals_remain_distinct(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "gates.yaml"
            path.write_text("project: Fixture\ngates:\n  project_init:\n    approved: true\n  analysis:\n    approved: true\n  storyboard:\n    approved: false\n")
            self.assertEqual(gate_approvals(path), {"project_init": True, "analysis": True, "storyboard": False})
            path.write_text(path.read_text() + "  analysis:\n    approved: false\n")
            with self.assertRaisesRegex(AssertionError, "duplicate"):
                gate_approvals(path)

    def fixture(self, scale):
        return {"interactions": [
            {"kind": "pointer", "id": "agent.task.choose", "window": 21},
            {"kind": "menu", "id": "agent.task.choose", "item": "Apply a project change", "closed": True},
            {"kind": "pointer", "id": "agent.composer.input", "window": 21},
            {"kind": "keyboard", "code": 125, "characters": "\uf701", "modifiers": 1 << 20, "window": 21},
            {"kind": "keyboard", "code": 15, "characters": "R", "modifiers": 0, "window": 21},
            {"kind": "verified-state", "label": "native Recovery composer input", "evidence": {
                "id": "agent.composer.input", "before": "Synthetic draft", "after": "Synthetic draftR", "added": "R",
                "task": "Apply a project change", "controlKind": "text-view", "window": 21}},
            {"kind": "verified-state", "label": "rendered typography", "evidence": {
                "id": "agent.composer.input", "pointSize": 13 * scale, "baseSize": 13, "scale": scale,
                "controlKind": "text-view", "window": 21}},
            {"kind": "verified-state", "label": "viewport", "evidence": {"renderedFontPointSize": 13 * scale}},
        ]}

    def test_synthetic_record_requires_every_ordered_native_step(self):
        for scale in (1, 1.25, 1.5):
            record = self.fixture(scale)
            require_composer_typography(record, "viewport", scale)
            for index in range(len(record["interactions"])):
                changed = copy.deepcopy(record)
                changed["interactions"].pop(index)
                with self.subTest(scale=scale, missing=index), self.assertRaises(AssertionError):
                    require_composer_typography(changed, "viewport", scale)
            starter = self.fixture(scale)
            starter["interactions"][:2] = [{"kind": "verified-state", "label": "native-pointer", "evidence": {
                "target": "button.Apply a project change", "window": 21}}]
            require_composer_typography(starter, "viewport", scale)
            starter["interactions"][0]["evidence"]["window"] = 22
            with self.assertRaises(AssertionError):
                require_composer_typography(starter, "viewport", scale)

    def test_forged_font_window_text_and_keyboard_cannot_replace_native_input(self):
        for defect in ("foreign-window", "wrong-text", "field-editor", "wrong-size", "non-number", "no-command", "wrong-order", "wrong-task", "wrong-task-window"):
            record = self.fixture(1.25)
            rows = record["interactions"]
            if defect == "foreign-window": rows[3]["window"] = 22
            elif defect == "wrong-text": rows[5]["evidence"]["after"] = "R"
            elif defect == "field-editor": rows[6]["evidence"]["controlKind"] = "text-field"
            elif defect == "wrong-size": rows[6]["evidence"]["pointSize"] = 13
            elif defect == "non-number": rows[6]["evidence"]["pointSize"] = "sixteen"
            elif defect == "no-command": rows[3]["modifiers"] = 0
            elif defect == "wrong-task": rows[1]["item"] = "Generate an AI video"
            elif defect == "wrong-task-window": rows[0]["window"] = 22
            else: rows[4], rows[6] = rows[6], rows[4]
            with self.subTest(defect=defect), self.assertRaises(AssertionError):
                require_composer_typography(record, "viewport", 1.25)

    def test_saved_draft_and_later_native_session_edit_keep_migration_bytes_bound(self):
        identifier = "2564BA87-9222-4B5E-BA40-000000000001"
        relative = "chat/" + identifier + ".json"
        session = {"id": identifier, "updatedAt": "2026-01-01T00:00:00Z", "messages": [], "isOpen": True,
                   "draft": {"text": "Synthetic draftR", "mentions": [], "task": {
                       "title": "Apply a project change", "prompt": "Synthetic staged task", "originContext": "before"}}}
        with TemporaryDirectory() as directory:
            output = Path(directory); saved = output / "saved"; recovery = output / "recovery"
            (saved / "chat").mkdir(parents=True); (recovery / "chat").mkdir(parents=True)
            raw = json.dumps(session).encode(); (saved / relative).write_bytes(raw)
            before = self.fixture(1)
            before["interactions"] += [
                {"kind": "verified-state", "label": "application-menu", "evidence": {"path": ["File", "Save"], "window": 21}},
                {"kind": "verified-state", "label": "native Recovery draft saved", "evidence": {
                    "sessionID": identifier, "draft": "Synthetic draftR", "wasEdited": True, "isEdited": False, "window": 21}}]
            self.assertEqual(require_saved_draft(before, saved), identifier)
            missing_save = copy.deepcopy(before); missing_save["interactions"].pop(-2)
            with self.assertRaisesRegex(AssertionError, "native Save"):
                require_saved_draft(missing_save, saved)
            originals = [{"path": relative, "sha256": hashlib.sha256(raw).hexdigest()}]
            (output / "pack-recovery-session-before-input.json").write_bytes(raw)
            for defect in (None, "restored-bytes", "unrelated-message", "wrong-draft", "wrong-current-file"):
                edited = copy.deepcopy(session); edited["updatedAt"] = "2026-01-01T00:00:01Z"
                edited["draft"]["text"] += "R"; edited["draft"]["task"]["originContext"] = "after"
                if defect == "unrelated-message": edited["messages"] = [{"role": "assistant", "content": "Unexpected"}]
                if defect == "wrong-draft": edited["draft"]["text"] = "Not the native edit"
                changed = json.dumps(edited).encode()
                (output / "pack-recovery-session-after-input.json").write_bytes(changed)
                (recovery / relative).write_bytes(b"{}" if defect == "wrong-current-file" else changed)
                after = self.fixture(1)
                after["interactions"][5]["evidence"].update(before="Synthetic draftR", after="Synthetic draftRR")
                after["interactions"].append({"kind": "verified-state", "label": "native Recovery session edit", "evidence": {
                    "sessionID": identifier, "path": relative, "beforeSHA256": hashlib.sha256(raw).hexdigest(),
                    "afterSHA256": hashlib.sha256(changed).hexdigest()}})
                references = [{"path": relative, "sha256": "0" * 64}] if defect == "restored-bytes" else originals
                with self.subTest(defect=defect):
                    if defect is None:
                        self.assertEqual(require_session_edit(after, output, recovery, references, identifier), relative)
                    else:
                        with self.assertRaises(AssertionError):
                            require_session_edit(after, output, recovery, references, identifier)
