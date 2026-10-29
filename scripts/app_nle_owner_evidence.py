"""Validate prepared APP/NLE owner evidence without treating screenshots as execution."""
import hashlib
import json
import math
from pathlib import Path
import uuid


ROOT_FLAGS = {
    "nativeNewCancelAndCreate", "nativeSaveAsIndependentIdentity", "nativeFileAndHomeOpen",
    "recentRemovalPreservesFile", "deleteCancelPreservesFile", "confirmedDeleteMovesExactCopyToTrash",
    "nativeRecentOpen", "finderExactProjectSelection", "projectSettingsAndFPSUndo", "genericWithoutPipeline",
}
EDIT_FLAGS = {
    "sourceMemoryAndHistory", "nativeRangeInsertOverwrite", "nativeLinkedAudioAndLinkUndo",
    "nativeTrackControls", "nativeTrackHeight", "sourceCloseAndClear", "textAndTimelineClipboard", "mismatchKeptPortrait",
}
VIEW_FLAGS = {
    "independentPanels", "nativeSplitter", "maximizedViewerRestored", "theaterRestored", "fullScreenRestored",
    "viewerZoomFit", "anchoredCanvasWheel", "freePanPreservesOutput", "transformAndCropRemainInteractive",
    "frameStepPlayback", "timelineZoom",
}
HELP_FLAGS = {
    "shortcutsAndMCP", "tutorialOpenSkip", "feedbackOpenedSendDisabled", "feedbackNotSent",
    "updateOpenedWithoutInstall", "diagnosticFinderExactDirectory", "diagnosticEntryDecisionsPreserveRecordings",
    "recordingsPreserved", "timelinePreserved",
}
APP_MENUS = {
    ("File", "New"), ("File", "Open…"), ("File", "Save"), ("File", "Save As…"),
    ("View", "Layout", "Default"), ("View", "Layout", "Media"), ("View", "Layout", "Vertical"),
    ("View", "Maximize Focused Panel"), ("View", "Theater"), ("View", "Enter Full Screen"),
    ("Help", "Tutorial"), ("Help", "Keyboard Shortcuts"), ("Help", "MCP Instructions"), ("Help", "Send Feedback…"),
    ("NexGenVideo", "Check for Updates…"), ("Help", "Reveal Diagnostics"),
    ("Help", "Configure Hang Recording…"), ("Help", "Export Hang Recording…"), ("Help", "Delete Hang Recordings…"),
}
CAPTURES = {
    "new-cancel", "project-settings", "source-memory", "source-format-mismatch", "track-resized",
    "insert-overwrite-linking", "layout-default", "layout-media", "layout-vertical", "viewer-maximized",
    "theater", "full-screen", "viewer-panned", "canvas-crop-interactive", "view-restored", "shortcuts", "mcp-help",
    "tutorial", "feedback-empty-not-sent", "update-check-no-install", "diagnostic-configure",
    "diagnostic-export-cancel", "diagnostic-delete-cancel", "portrait-export-qc", "file-open-original",
    "delete-confirmation", "recent-removed-file-preserved",
}


def sha(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def local(directory, name):
    if not isinstance(name, str) or Path(name).name != name or name.startswith("."):
        return None
    file = directory / name
    return file if file.is_file() and not file.is_symlink() else None


def validate(row, output, scale):
    try:
        if row["scale"] != scale or scale not in (1, 1.25, 1.5) or row["viewport"] != [960, 640]:
            return False
        if row["homeViewport"] != [960, 720] or not all(row.get(key) is True for key in ROOT_FLAGS):
            return False
        original, copied = uuid.UUID(row["originalID"]), uuid.UUID(row["copyID"])
        if original == copied or not sha(row["timelineSHA256"]):
            return False
        editing, viewing, help_row = row["editing"], row["viewing"], row["help"]
        for value, required in ((editing, EDIT_FLAGS), (viewing, VIEW_FLAGS), (help_row, HELP_FLAGS)):
            if not all(value.get(key) is True for key in required):
                return False
        if (viewing["nativeWorkspaces"] != ["media", "production", "postproduction", "export", "edit"]
            or viewing["nativeLayouts"] != ["default", "media", "vertical"] or editing["fps"] != 25
            or editing["insertFrames"] != 125 or editing["overwriteFrames"] != 100
            or not sha(editing["timelineSHA256"]) or viewing["unchangedTimelineSHA256"] != row["timelineSHA256"]):
            return False
        sources = editing["sourceIDs"]
        hashes = row["mediaHashes"]
        if len(sources) != 2 or len(set(sources)) != 2 or not all(sha(hashes.get(key)) for key in sources):
            return False
        typography = editing["typography"]
        if (typography["id"] != "media.rename." + sources[0] or typography["effectiveScale"] != scale
            or typography["viewport"] != row["viewport"] or typography["ownsEditor"] is not True
            or not math.isfinite(typography["backingScale"]) or typography["backingScale"] <= 0
            or any(not math.isfinite(typography[key]) or abs(typography[key] - 13 * scale) >= 0.5
                for key in ("ownerFontPointSize", "editorFontPointSize"))):
            return False
        interactions = row["interactions"]
        pointers = {item.get("id") for item in interactions if item.get("kind") == "pointer"}
        required = {"home.new", "home.open", "project.settings.open", "preview.capture-frame", "preview.canvas",
            "preview.transport.play.fill", "preview.transport.pause.fill", "timeline.zoom.in", "timeline.zoom.out",
            "inspector.crop.edit", "project.mismatch.keep", "editor.panel.sidebar", "editor.panel.inspector"}
        required |= {"editor.workspace." + key for key in ("media", "production", "postproduction", "export", "edit")}
        required |= {"source." + kind + "." + asset for asset in sources for kind in ("in", "out", "insert")}
        required |= {"source.overwrite." + sources[1], "source.clear." + sources[1]}
        if not required.issubset(pointers) or not any(key and key.startswith("home.project.") for key in pointers):
            return False
        states = [item for item in interactions if item.get("kind") == "verified-state"]
        app_menus = {tuple(item["evidence"].get("path", [])) for item in states
            if item.get("label") == "application-menu" and item["evidence"].get("closed") is True}
        if not APP_MENUS.issubset(app_menus):
            return False
        menus = {(item.get("id"), item.get("item")) for item in interactions
            if item.get("kind") == "menu" and item.get("closed") is True}
        if not {("project.settings.Aspect Ratio", "9:16"), ("project.settings.Resolution", "720p"),
            ("project.settings.Frame Rate", "25 fps"), ("project.settings.Frame Rate", "30 fps"),
            ("preview.zoom", "200%"), ("preview.zoom", "50%"), ("preview.zoom", "Fit")}.issubset(menus):
            return False
        contexts = {tuple(item.get("path", [])) for item in interactions
            if item.get("kind") == "context-menu" and item.get("closed") is True}
        if not {("Reveal in Finder",), ("Remove from Recents",), ("Delete Project",),
            ("Previous Preview",), ("Next Preview",), ("Close Source",), ("Clear Source History",), ("Rename",)}.issubset(contexts):
            return False
        keys = [item.get("characters") for item in interactions if item.get("kind") == "keyboard"]
        if not all(keys.count(key) >= count for key, count in {"a": 2, "x": 2, "c": 1, "v": 2, "z": 8, "Z": 6}.items()):
            return False
        drags = {item["evidence"].get("target") for item in states if item.get("label") == "native-drag"
            and item["evidence"].get("from") != item["evidence"].get("to")}
        if not {"editor.splitter", "track.height", "preview.transform.move", "preview.crop.corner"}.issubset(drags):
            return False
        clip_menus = {item["evidence"].get("item") for item in states
            if item.get("label") == "native-clip-menu" and item["evidence"].get("closed") is True}
        if not {"Link", "Unlink"}.issubset(clip_menus):
            return False
        state = {item["label"]: item["evidence"] for item in states}
        if state.get("native-interface-typography") != typography:
            return False
        if not all(state["text-versus-timeline-clipboard"].get(key) is True
            for key in ("textUndoIsolated", "cutUndoRedo", "pastePreservedSourceAndLink")):
            return False
        if state["finder-project-selection"].get("exactSelectedURL") is not True:
            return False
        wheels = state["native-viewer-wheel"]
        if (wheels["input"] != "command-wheel-then-plain-wheel" or wheels["zoom"] <= 1
            or wheels["anchoredOffset"] == wheels["pannedOffset"] or wheels["timelineUnchanged"] is not True):
            return False
        overlay = state["native-pan-overlay-isolation"]
        if (not all(overlay.get(key) is True for key in ("transformDragged", "cropDragged", "exactUndo"))
            or overlay["restoredTimelineSHA256"] != row["timelineSHA256"]):
            return False
        track = state["native-track-controls"]
        if not all(track.get(key) is True for key in ("visibility", "mute", "syncLock", "exactUndoRedo")) or track["heightAfter"] <= track["heightBefore"]:
            return False
        persistence = state["native-project-persistence"]
        if persistence["newID"] != row["originalID"] or persistence["saveAsID"] != row["copyID"] or not all(
            persistence.get(key) is True for key in ("originalPreserved", "copyReadbackEqual", "removedRecentFilePreserved", "confirmedCopyInTrash")):
            return False
        progress = local(output, row["progress"])
        if progress is None:
            return False
        recorded = json.loads(progress.read_text())
        images = row["screenshots"]
        if recorded.get("failure") or recorded.get("interactions") != interactions or recorded.get("screenshots") != images:
            return False
        if len(images) != len(set(images)) or not all(any(name.endswith("-" + label + ".png") for name in images) for label in CAPTURES):
            return False
        for name in images:
            file = local(output, name)
            if file is None or file.stat().st_size <= 1000 or not file.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
                return False
        directory = output / Path(row["progress"]).stem
        if directory.is_symlink() or not directory.is_dir():
            return False
        capture = editing["capture"]
        image = local(directory, capture["file"])
        if (capture["sourceID"] != sources[0] or capture["newAssetID"] in sources or capture["frame"] != 50
            or capture["fps"] != 25 or not sha(capture["pixelsSHA256"]) or hashes.get(capture["newAssetID"]) != capture["fileSHA256"] or image is None
            or hashlib.sha256(image.read_bytes()).hexdigest() != capture["fileSHA256"]):
            return False
        movie = row["portraitExport"]
        file = local(directory, movie["file"])
        if (not all(movie[key] == value for key, value in {"width": 720, "height": 1280, "fps": 30, "frames": 150, "qc": True}.items())
            or file is None or hashlib.sha256(file.read_bytes()).hexdigest() != movie["sha256"]):
            return False
        return True
    except (KeyError, TypeError, ValueError, OSError, AttributeError):
        return False


def app_nle_owner_evidence(rows, output, scale):
    matches = [row for row in rows if row.get("event") == "app-nle-owner" and row.get("scale") == scale]
    complete = [row for row in rows if row.get("event") == "completed" and row.get("case") == "appnle" and row.get("scale") == scale]
    if len(matches) != 1 or len(complete) != 1 or any(row.get("event") == "failed" for row in rows) or not validate(matches[0], output, scale):
        return False, []
    return True, matches[0]["screenshots"]
