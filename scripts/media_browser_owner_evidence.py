"""Validate native browser actions, exact source ranges and saved package bytes."""
import hashlib
import json
import math
from pathlib import Path
import struct
import uuid


FLAGS = {
    "nativeSelection", "nativeFilteredSelection", "nativeFilteredSortedShiftRange", "nativeMarquee", "nativeFolderGroupDropUndo",
    "nativeThumbnailResize", "nativeMomentSourceAndDrop", "nativeSpokenSourceAndDrop", "nativeSegmentUndoRedoSave",
}
CAPTURES = {"range-selection", "filtered-selection", "filtered-sorted-shift", "marquee-selection", "large-thumbnails",
            "group-folder-drop", "moment-source", "spoken-source", "segment-timeline"}


def local(root, relative, directory=False):
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError("No relative artifact")
    parts = Path(relative).parts
    if any(part in (".", "..") for part in parts):
        raise ValueError("Artifact escape")
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("Symlink artifact")
    if not (current.is_dir() if directory else current.is_file()):
        raise ValueError("Missing artifact")
    return current


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def rectangle(value):
    return isinstance(value, list) and len(value) == 4 and all(number(x) for x in value) and value[2] > 0 and value[3] > 0


def contains(rect, point):
    return rectangle(rect) and isinstance(point, list) and len(point) == 2 and all(number(x) for x in point) and (
        rect[0] <= point[0] < rect[0] + rect[2] and rect[1] <= point[1] < rect[1] + rect[3])


def intersects(a, b):
    return (a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3])


def cache_evidence(directory, sources, caches):
    if set(caches) != {source["id"] for source in sources.values()}:
        return False
    for name, source in sources.items():
        evidence = caches[source["id"]]
        file = local(directory, evidence["file"])
        if evidence["sourceSHA256"] != source["sha256"] or sha(file) != evidence["sha256"]:
            return False
        if name == "C.wav":
            expected = {"text": "The harbor lights.", "language": "en-US", "words": [],
                        "segments": [{"text": "The harbor lights.", "start": 0.5, "end": 1.5}]}
            if file.name != "isolated-transcript.json" or json.loads(file.read_text()) != expected:
                return False
            continue
        data = file.read_bytes()
        if file.name != name + ".embed" or data[:8] != b"PALMEMB1" or len(data) < 12:
            return False
        length = struct.unpack_from("<I", data, 8)[0]
        if not 0 < length <= 65536 or len(data) != 12 + length + 28:
            return False
        header = json.loads(data[12:12 + length])
        if any(header.get(key) != value for key, value in {"model": "native-search-fixture", "modelVersion": 1, "dim": 2, "count": 1}.items()) or header.get("samplerVersion", 0) <= 0:
            return False
        actual = struct.unpack_from("<dddee", data, 12 + length)
        expected = (0, 0, 0, -1, 0) if name == "D.png" else (1.5, 1, 2, 1 if name == "A.mov" else -1, 0)
        if actual != expected:
            return False
    return True


def validate(row, output, scale):
    try:
        if (scale not in (1, 1.25, 1.5) or row["scale"] != scale or row["effectiveScale"] != scale
            or row["viewport"] != [960, 640] or not number(row["backingScale"]) or row["backingScale"] <= 0
            or not all(row.get(flag) is True for flag in FLAGS) or row.get("isolatedQueryEncoder") is not True
            or row.get("isolatedTranscriptInput") is not True or row.get("liveSearchModel") is not False):
            return False
        uuid.UUID(row["projectID"])
        sources = {source["filename"]: source for source in row["sources"]}
        if len(row["sources"]) != 4 or set(sources) != {"A.mov", "B.mov", "C.wav", "D.png"}:
            return False
        ids = {name: source["id"] for name, source in sources.items()}
        if len(set(ids.values())) != 4 or not all(isinstance(value, str) and value for value in ids.values()):
            return False
        a, b, c, d = (ids[name] for name in ("A.mov", "B.mov", "C.wav", "D.png"))
        for name, kind, duration in (("A.mov", "video", 4), ("B.mov", "video", 3), ("C.wav", "audio", 2), ("D.png", "image", 5)):
            source = sources[name]
            if source["type"] != kind or not number(source["duration"]) or abs(source["duration"] - duration) >= (1 / 48000 if kind == "audio" else 1 / 30):
                return False
        project = local(output, row["project"], directory=True)
        directory = project.parent
        if json.loads(local(project, "ngv.json").read_text()).get("id") != row["projectID"]:
            return False
        if project.name != "Browser.ngv" or directory.name != "media-browser-" + str(round(scale * 100)):
            return False
        timeline_file, manifest_file = local(project, "project.json"), local(project, "media.json")
        if row["saved"] != {"timelineSHA256": sha(timeline_file), "manifestSHA256": sha(manifest_file)}:
            return False
        timeline, manifest = json.loads(timeline_file.read_text()), json.loads(manifest_file.read_text())
        if any(timeline.get(key) != value for key, value in {"width": 320, "height": 180, "fps": 30, "settingsConfigured": True}.items()):
            return False
        entries = {entry["id"]: entry for entry in manifest["entries"]}
        if len(manifest["entries"]) != 4 or set(entries) != set(ids.values()):
            return False
        for name, source in sources.items():
            entry = entries[source["id"]]
            media = local(project, entry["source"]["project"]["relativePath"])
            if entry["originalFilename"] != name or sha(media) != source["sha256"] or entry["type"] != source["type"]:
                return False
        if not cache_evidence(directory, sources, row["searchCaches"]):
            return False
        clips = [{"id": clip["id"], "trackID": track["id"], "type": track["type"], "sourceID": clip["mediaRef"],
                  "startFrame": clip["startFrame"], "durationFrames": clip["durationFrames"], "trimStartFrame": clip["trimStartFrame"]}
                 for track in timeline["tracks"] for clip in track["clips"]]
        if row["clips"] != clips or len(clips) != 2 or len({clip["id"] for clip in clips}) != 2 or len({clip["trackID"] for clip in clips}) != 2:
            return False
        by_source = {clip["sourceID"]: clip for clip in clips}
        if set(by_source) != {a, c}:
            return False
        for source, kind, start, trim in ((a, "video", 0, 30), (c, "audio", 45, 15)):
            if any(by_source[source][key] != value for key, value in {"type": kind, "startFrame": start, "trimStartFrame": trim, "durationFrames": 30}.items()):
                return False
        interactions = row["interactions"]
        states = {}
        for item in interactions:
            if item.get("kind") == "verified-state":
                states.setdefault(item["label"], []).append(item["evidence"])
        def state(label):
            values = states[label]
            if len(values) != 1:
                raise ValueError("Ambiguous native state")
            return values[0]
        for label, expected in (("command selection", [a, c]), ("command deselection", [c]),
                                ("shift range", [a, b, c]), ("filtered select all", [d]),
                                ("filtered sorted shift range", [d, a]), ("marquee selection", [a, b])):
            evidence = state(label)
            if evidence["ids"] != sorted(expected) or evidence["filenames"] != sorted(name for name, value in ids.items() if value in expected):
                return False
        if state("name order")["ids"] != [a, b, c, d] or state("duration order")["ids"] != [d, a, b, c]:
            return False
        if (state("filtered name order") != {"ids": [a, b, d]}
            or state("filtered duration order") != {"ids": [d, a, b]}
            or state("filtered range context") != {"beforeOrder": [a, b, d], "visibleIDs": [d, a, b],
                "selectedIDs": sorted([a, d]), "anchorID": d, "targetID": a, "hiddenIDs": [c]}):
            return False
        cursor = -1
        range_anchor = None
        for kind, identifier, item, label in (
            ("menu", "media.menu.Filter", "Image", None),
            ("verified-state", None, None, "filtered selection pruned"),
            ("pointer", "media.asset." + d, None, None),
            ("keyboard", None, None, None),
            ("verified-state", None, None, "filtered select all"),
            ("menu", "media.menu.Filter", "Video", None),
            ("verified-state", None, None, "filtered name order"),
            ("menu", "media.menu.Sort", "Duration", None),
            ("verified-state", None, None, "filtered duration order"),
            ("pointer", "media.asset." + d, None, None),
            ("modified-pointer", "media.asset." + a, None, None),
            ("verified-state", None, None, "filtered sorted shift range"),
            ("verified-state", None, None, "filtered range context")):
            matches = [index for index, interaction in enumerate(interactions) if index > cursor
                and interaction.get("kind") == kind and (identifier is None or interaction.get("id") == identifier)
                and (item is None or interaction.get("item") == item and interaction.get("closed") is True)
                and (label is None or interaction.get("label") == label)
                and (kind != "keyboard" or interaction.get("characters") == "a" and interaction.get("modifiers") == 1 << 20)
                and (kind != "modified-pointer" or interaction.get("shift") is True and interaction.get("command") is False)]
            if not matches:
                return False
            cursor = matches[0]
            if kind == "pointer":
                range_anchor = cursor
            if kind == "modified-pointer" and (range_anchor is None or any(
                row.get("kind") in ("pointer", "modified-pointer", "keyboard", "menu", "context-menu", "cross-view-drag")
                for row in interactions[range_anchor + 1:cursor])):
                return False
        if state("filtered selection pruned") != {"visibleIDs": [d], "selectedIDs": []} or state("AI filter excludes imported files") != {"visibleIDs": [], "selectedIDs": []}:
            return False
        geometry = state("marquee geometry")
        if (geometry["ids"] != sorted([a, b]) or geometry["emptyStart"] is not True
            or not all(rectangle(geometry[key]) for key in ("first", "last", "selection", "surface"))
            or not all(contains(geometry["surface"], geometry[key]) for key in ("start", "end"))
            or any(contains(geometry[key], geometry["start"]) for key in ("first", "last"))
            or not all(intersects(geometry[key], geometry["selection"]) for key in ("first", "last"))):
            return False
        thumbs = state("thumbnail dimensions")
        if (thumbs["id"] != a or not rectangle(thumbs["small"]) or not rectangle(thumbs["large"])
            or thumbs["large"][2] <= thumbs["small"][2] or thumbs["large"][3] <= thumbs["small"][3]):
            return False
        moved, undo = state("group folder drop"), state("group folder drop undo")
        if (moved["ids"] != sorted([a, b]) or moved["from"] == moved["to"] or moved["folder"] != "Selected"
            or undo != {"ids": sorted([a, b]), "restoredFolder": moved["from"], "destinationRetained": True}
            or not all(entries[value].get("folderId") == moved["from"] for value in (a, b))):
            return False
        folders = {folder["id"]: folder for folder in manifest["folders"]}
        if folders[moved["to"]]["name"] != "Selected" or folders[moved["to"]].get("parentFolderId") != moved["from"]:
            return False
        for label, filename, frame in (("moment source time", "A.mov", 30), ("spoken source time", "C.wav", 15)):
            if state(label) != {"filename": filename, "frame": frame}:
                return False
        moment = [by_source[a]]
        if (state("moment drop binding")["clips"] != moment or state("spoken drop binding")["clips"] != clips
            or state("segment undo redo") != {"undoClips": moment, "redoClips": clips, "unsaved": True}
            or state("native browser save") != {"projectID": row["projectID"], "clips": clips, "hashes": row["saved"]}):
            return False
        drops = states["segment drop geometry"]
        if len(drops) != 2:
            return False
        moment_id, spoken_id = "media.moment." + a + ".1.0", "media.spoken." + c + ".0.5"
        for evidence, identifier, frame, track in zip(drops, (moment_id, spoken_id), (0, 45), (0, 1)):
            if (evidence["id"] != identifier or evidence["frame"] != frame or evidence["newTrackIndex"] != track
                or not number(evidence["pixelsPerFrame"]) or evidence["pixelsPerFrame"] <= 0
                or int(evidence["point"][0] / evidence["pixelsPerFrame"]) != frame
                or not contains(evidence["viewport"], evidence["point"])):
                return False
        pointers = {item.get("id") for item in interactions if item.get("kind") == "pointer"}
        if not {"editor.workspace.media", "editor.workspace.edit", "media.action.Import", "media.action.New Folder",
                "media.asset." + a, "media.asset." + d, moment_id, spoken_id}.issubset(pointers):
            return False
        modified = {(item.get("id"), item.get("command"), item.get("shift")) for item in interactions if item.get("kind") == "modified-pointer"}
        if not {("media.asset." + c, True, False), ("media.asset." + a, True, False),
                ("media.asset." + c, False, True), ("media.asset." + b, True, False)}.issubset(modified):
            return False
        menus = {(item.get("id"), item.get("item")) for item in interactions if item.get("kind") == "menu" and item.get("closed") is True}
        if not {(prefix + name, title) for prefix, name, title in (
            ("media.menu.", "View", "List"), ("media.menu.", "View", "Grid"), ("media.menu.", "View", "Folders"),
            ("media.menu.", "View", "Small"), ("media.menu.", "View", "Extra Large"), ("media.menu.", "Sort", "Name"),
            ("media.menu.", "Sort", "Duration"), ("media.menu.", "Filter", "Image"), ("media.menu.", "Filter", "AI Generated"),
            ("media.menu.", "Filter", "Clear Filters"))}.issubset(menus):
            return False
        drag_rows = [item for item in interactions if item.get("kind") == "cross-view-drag"]
        if len(drag_rows) != 4 or {(item.get("id"), item.get("destination")) for item in drag_rows} != {
            ("media.selection-surface", "marquee"), ("media.asset." + a, "Selected folder"), (moment_id, "timeline frame 0"), (spoken_id, "timeline frame 45")}:
            return False
        if any(item.get("queuedEvents") != 14 or item["sourcePoint"] == item["destinationPoint"] for item in drag_rows):
            return False
        keys = [item for item in interactions if item.get("kind") == "keyboard"]
        if any(sum(item.get("characters") == text and item.get("modifiers", 0) & (1 << 20) != 0 for item in keys) < count
               for text, count in (("a", 1), ("z", 2), ("Z", 1), ("s", 1))):
            return False
        fields = [item["field"] for item in interactions if item.get("kind") == "text"]
        for identifier, value in (("media.search", "harbor"), ("media.folder-rename." + moved["to"], "Selected")):
            matches = [field for field in fields if field.get("id") == identifier]
            if len(matches) != 1:
                return False
            field = matches[0]
            if (field.get("actual") != value or field.get("expected") != value
                or field.get("stage") != "commit-requested" or field.get("owner") in (None, "none")
                or not (field.get("ownsEditor") is True or field.get("focusLeftTarget") is True)
                or (identifier.startswith("media.folder-rename.") and not (field.get("requiresFocusExit") is True and field.get("focusLeftTarget") is True))
                or field.get("commitInput") != "Tab" or not number(field.get("fontPointSize"))
                or abs(field["fontPointSize"] - 13 * scale) >= 0.5):
                return False
        visible = [item for item in interactions if item.get("kind") == "visible-group"]
        if not any(set(item.get("ids", [])) == {"media.menu.View", "media.menu.Sort", "media.menu.Filter"} for item in visible):
            return False
        for group in visible:
            viewport, frames = group["viewport"], group["frames"]
            if not rectangle(viewport) or len(frames) != len(group["ids"]):
                return False
            for index, frame in enumerate(frames):
                if (not rectangle(frame) or frame[0] < viewport[0] or frame[1] < viewport[1]
                    or frame[0] + frame[2] > viewport[0] + viewport[2] or frame[1] + frame[3] > viewport[1] + viewport[3]
                    or any(intersects(frame, previous) for previous in frames[:index])):
                    return False
        images = row["screenshots"]
        if (len(images) != len(CAPTURES) or len(set(images)) != len(CAPTURES) or not all(any(name.endswith("-" + label + ".png") for name in images) for label in CAPTURES)):
            return False
        for name in images:
            file = local(output, name)
            if Path(name).name != name or file.stat().st_size <= 1000 or not file.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
                return False
        progress = json.loads(local(output, row["progress"]).read_text())
        return not progress.get("failure") and progress.get("interactions") == interactions and progress.get("screenshots") == images
    except (KeyError, TypeError, ValueError, OSError, AttributeError, IndexError, struct.error):
        return False


def media_browser_owner_evidence(rows, output, scale):
    reports = [row for row in rows if row.get("event") == "media-browser-owner" and row.get("scale") == scale]
    completed = [row for row in rows if row.get("event") == "completed" and row.get("case") == "mediabrowser" and row.get("scale") == scale]
    if len(reports) != 1 or len(completed) != 1 or any(row.get("event") == "failed" for row in rows) or not validate(reports[0], output, scale):
        return False, []
    return True, reports[0]["screenshots"]
