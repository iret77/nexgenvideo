import copy
from pathlib import Path
import tempfile
import unittest

from workspace_ui_acceptance import media_library_evidence


class MediaLibraryEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        images = ["media-library-150-" + label + ".png" for label in (
            "six-file-types", "original-filename-search", "image-filter", "select-all", "nested-folders", "folder-delete-undo")]
        for image in images:
            (self.output / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"image" * 250)
        self.row = {"event": "native-media-library", "scale": 1.5, "effectiveScale": 1.5, "backingScale": 2, "viewport": [960, 640], "screenshots": images,
            **{key: True for key in ("nativeFolderImport", "cancelPreservedLibrary", "importDidNotInsert", "documentNotPlaceable",
                "nativeRenameUndoRedo", "originalFilenamePreserved", "nativeCopyPath", "nativeSearchAndFilter",
                "nativeSelectAll", "nativeUsedDeleteUndo", "nativeNestedMoveDeleteUndo", "nativeSaveAndReopen")},
            "sources": [{"filename": name, "type": kind, "id": str(index), "sha256": "a" * 64}
                for index, (name, kind) in enumerate((
                    ("Original.mov", "video"), ("Ambience.wav", "audio"), ("Reference.png", "image"),
                    ("Brief.txt", "document"), ("Captions.srt", "subtitle"), ("Motion.json", "lottie")))],
            "interactions": [{"kind": "context-menu", "path": path, "closed": True} for path in (
                ["Rename"], ["Copy Path"], ["Delete"], ["Open"], ["Move to Folder", "Selected"], ["Delete"])]
                + [{"kind": "keyboard", "characters": key} for key in ("z", "Z", "a", "s")]
                + [{"kind": "file-panel-cancel"}, {"kind": "file-panel", "path": "Incoming",
                    "selectedURLVerified": True, "nativePathEditorVerified": True}]
                + [{"kind": "text", "field": {"expected": value, "actual": value,
                    "requiresFocusExit": True, "focusLeftTarget": True}} for value in ("Opening movement", "Archive", "Selected")]}
        relink_images = ["media-relink-150-" + name + ".png" for name in
            ("offline-source", "incompatible-source", "ambiguous-folder", "all-relinked")]
        for image in relink_images:
            (self.output / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"image" * 250)
        self.row["screenshots"] += relink_images
        self.row["nativeRelink"] = {
            **{key: True for key in ("cancelPreservedBindings", "incompatibleSourceRejected", "ambiguousFolderRejected",
                "nativeFileUndoRedo", "nativeFolderRelink", "identitiesAndTimelinePreserved", "exactSourceBytes",
                "nativeSaveAndReopen", "originalProjectPreserved")},
            "screenshots": relink_images,
            "interactions": [{"kind": "file-panel", "path": path, "selectedURLVerified": True,
                "nativePathEditorVerified": True} for path in ("Original.mov", "Brief.txt", "Incoming", "media-relink-150-ambiguous")]
                + [{"kind": "file-panel-cancel"}]
                + [{"kind": "keyboard", "characters": key} for key in ("z", "Z", "s")]
        }
        organization_images = ["media-organization-150-" + name + ".png" for name in
            ("proposal", "selected-change", "applied-undo-redo", "stale-proposal")]
        for image in organization_images:
            (self.output / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"image" * 250)
        self.row["screenshots"] += organization_images
        self.row["nativeOrganization"] = {
            **{key: True for key in ("nativeProposal", "nativeCancel", "nativeSelectiveApply", "nativeSingleUndoRedo",
                "nativeStaleRefusal", "nativeSaveAndReopen", "sourceBytesPreserved", "originalProjectPreserved", "stableUndoLabels")},
            "selectedAssetID": "0", "unselectedAssetID": "2", "directMutationRefusals": 6, "completedProposalRefusals": 3, "liveAgent": False,
            "screenshots": organization_images,
            "interactions": [{"kind": "pointer", "id": key} for key in (
                "media.action.Organize", "agent.task.run", "agent.dialog.cancel",
                "media.action.Organize", "agent.task.run", "media.organization.choice.0", "agent.dialog.confirm")]
                + [{"kind": "keyboard", "characters": key} for key in ("z", "Z")]
                + [{"kind": "pointer", "id": key} for key in ("media.action.Organize", "agent.task.run")]
                + [{"kind": "context-menu", "id": "media.asset.2", "path": ["Rename"], "closed": True}]
                + [{"kind": "text", "field": {"id": "media.rename.2", "expected": "Independent edit", "actual": "Independent edit",
                    "requiresFocusExit": True, "focusLeftTarget": True}}]
                + [{"kind": "pointer", "id": key} for key in ("media.organization.choice.0", "agent.dialog.confirm", "agent.dialog.cancel")]
                + [{"kind": "keyboard", "characters": "s"}]}
        self.complete = {"event": "completed", "case": "medialibrary", "scale": 1.5}

    def accepts(self, row):
        return media_library_evidence([row, self.complete], self.output, 1.5)[0]

    def test_actual_viewport_and_scale_are_required(self):
        for key, value in (("viewport", [1440, 960]), ("effectiveScale", 1), ("backingScale", 0), ("backingScale", True)):
            changed = copy.deepcopy(self.row); changed[key] = value
            self.assertFalse(self.accepts(changed), key)

    def test_legacy_workspace_library_event_is_distinct(self):
        legacy = {"event": "media-library", "scale": 1.5, "assetCount": 500}
        self.assertTrue(media_library_evidence([legacy, self.row, self.complete], self.output, 1.5)[0])
        self.assertFalse(media_library_evidence([legacy, self.complete], self.output, 1.5)[0])

    def test_real_inputs_and_each_type_are_required(self):
        self.assertTrue(self.accepts(self.row))
        for key in ("sources", "interactions", "screenshots"):
            for index in range(len(self.row[key])):
                changed = copy.deepcopy(self.row)
                changed[key].pop(index)
                with self.subTest(key=key, index=index):
                    self.assertFalse(self.accepts(changed))

    def test_document_and_filename_must_remain_distinct_from_timeline_and_hash(self):
        changed = copy.deepcopy(self.row)
        changed["sources"][3]["type"] = "text"
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        changed["sources"][0]["filename"] = "c" * 64 + ".mov"
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        changed["sources"][1]["id"] = changed["sources"][0]["id"]
        self.assertFalse(self.accepts(changed))
        for key, value in self.row.items():
            if value is True:
                self.assertFalse(self.accepts({**self.row, key: False}))

    def test_relink_requires_each_native_action_and_result(self):
        for key, value in self.row["nativeRelink"].items():
            if value is True:
                changed = copy.deepcopy(self.row)
                changed["nativeRelink"][key] = False
                self.assertFalse(self.accepts(changed))
        for key in ("interactions", "screenshots"):
            for index in range(len(self.row["nativeRelink"][key])):
                changed = copy.deepcopy(self.row)
                changed["nativeRelink"][key].pop(index)
                self.assertFalse(self.accepts(changed))

    def test_incomplete_or_failed_run_never_passes(self):
        self.assertFalse(media_library_evidence([self.row], self.output, 1.5)[0])
        self.assertFalse(media_library_evidence([self.row, self.complete], self.output, 1.0)[0])
        self.assertFalse(media_library_evidence([self.row, self.complete, {"event": "failed"}], self.output, 1.5)[0])
        (self.output / self.row["screenshots"][0]).write_bytes(b"not an image")
        self.assertFalse(self.accepts(self.row))

    def test_organization_requires_native_selection_cancel_undo_and_stale_refusal(self):
        for key, value in self.row["nativeOrganization"].items():
            if value is True:
                changed = copy.deepcopy(self.row)
                changed["nativeOrganization"][key] = False
                self.assertFalse(self.accepts(changed))
        for key in ("interactions", "screenshots"):
            for index in range(len(self.row["nativeOrganization"][key])):
                changed = copy.deepcopy(self.row)
                changed["nativeOrganization"][key].pop(index)
                self.assertFalse(self.accepts(changed))
        for key, value in (("directMutationRefusals", 3), ("completedProposalRefusals", 0), ("liveAgent", True), ("selectedAssetID", "2"), ("selectedAssetID", "unrelated"), ("unselectedAssetID", "unrelated")):
            changed = copy.deepcopy(self.row)
            changed["nativeOrganization"][key] = value
            self.assertFalse(self.accepts(changed))


    def test_organization_rejects_reordered_inputs_and_unrelated_screenshots(self):
        changed = copy.deepcopy(self.row)
        actions = changed["nativeOrganization"]["interactions"]
        actions[2], actions[6] = actions[6], actions[2]
        self.assertFalse(self.accepts(changed))
        changed = copy.deepcopy(self.row)
        image = "unrelated-proposal.png"
        (self.output / image).write_bytes(b"\x89PNG\r\n\x1a\n" + b"image" * 250)
        changed["screenshots"].append(image)
        changed["nativeOrganization"]["screenshots"][0] = image
        self.assertFalse(self.accepts(changed))


if __name__ == "__main__":
    unittest.main()
