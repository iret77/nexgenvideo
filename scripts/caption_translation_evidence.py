"""Independent native language choice and selective translated caption evidence."""
import copy
import hashlib
import json
from pathlib import Path

from production_frames_owner_evidence import read, states, visible_group


def require(value, message):
    if not value: raise ValueError(message)


def validate(directory, expected_scale=None):
    directory = Path(directory)
    load = lambda name: json.loads(read(directory, name))
    result = load("translation-result.json")
    scale = result.get("scale")
    require(scale in (1.0, 1.25, 1.5) and (expected_scale is None or scale == expected_scale)
            and result.get("viewport") == [960, 640], "actual translation presentation differs")
    require(result.get("language") == "German" and result.get("liveAgent") is False
            and result.get("savedAndReopened") is True, "native selected translation/reopen missing")
    actions = result["interactions"]
    progress = load(result["progress"])
    require(progress.get("failure") is None and progress.get("interactions") == actions
            and progress.get("screenshots") == result["screenshots"], "actual translation driver log differs")
    before = load("before.json")
    require(before == load("cancelled.json") == load("undo.json"), "Cancel or Undo changed captions/timing")
    applied = copy.deepcopy(before)
    require(before["fps"] == 30 and len(before["tracks"]) == 1, "actual initial caption clock/tracks differ")
    clips = before["tracks"][0]["clips"]
    require([clip["id"] for clip in clips] == ["translate-first", "translate-second"]
            and [clip["textContent"] for clip in clips] == ["Good morning.", "We are ready."]
            and [clip["startFrame"] for clip in clips] == [0, 75]
            and [clip["durationFrames"] for clip in clips] == [60, 45], "existing English caption fixture differs")
    applied["tracks"][0]["clips"][0]["textContent"] = "Guten Morgen."
    require(applied == load("applied.json") == load("redo.json") == load("reopened.json")
            == load("Caption translation.ngv/project.json"), "Selective translated text changed other caption/timing/state or was not saved")
    requests = load("requests.json")
    seen = states(actions, "translated proposal visible")
    require(len(requests) == len(seen) == 2 and [row["index"] for row in seen] == [1, 2], "complete actual translation proposals missing")
    expected_args = {"kind": "captions", "changes": [{"clipId": "translate-first", "text": "Guten Morgen."}, {"clipId": "translate-second", "text": "Wir sind bereit."}]}
    expected_rows = [{"id": "translate-first", "before": "Good morning.", "after": "Guten Morgen.", "timeRange": "0.00–2.00 s"},
                     {"id": "translate-second", "before": "We are ready.", "after": "Wir sind bereit.", "timeRange": "2.50–4.00 s"}]
    sessions, turns, projects, roots, generations = set(), set(), set(), set(), set()
    for index, (request, observed) in enumerate(zip(requests, seen), 1):
        require(request["tool"] == "propose_caption_revision" and request["arguments"] == expected_args
                and request["isError"] is False and any("translate the captions to German" in text for text in request["texts"]),
                "actual runtime task/tool lost the selected target language")
        sessions.add(request["sessionID"]); turns.add(request["turnID"])
        proposal = load(f"proposal-{index}.json")
        scope = proposal["scope"]
        projects.add(scope["projectID"]); roots.add(scope["workingRoot"]); generations.add(scope["generation"])
        require(proposal["rows"] == expected_rows and not proposal.get("wordRemoval") and scope["kind"] == "captions"
                and scope["captionIDs"] == ["translate-first", "translate-second"] and scope["sources"] == []
                and scope["timelineSHA256"] == hashlib.sha256(read(directory, "before.json")).hexdigest(), "canonical translation proposal changed text/time/scope")
        require(observed == {"index": index, "language": "German", "ids": [row["id"] for row in expected_rows],
                    "before": [row["before"] for row in expected_rows], "after": [row["after"] for row in expected_rows],
                    "times": [row["timeRange"] for row in expected_rows], "selected": [], "applyEnabled": False},
                "actual visible translated rows differ or were preselected")
    require(len(sessions) == len(projects) == len(roots) == len(generations) == 1 and len(turns) == 2,
            "translation proposals changed project/session or reused a turn")
    menus = [row for row in actions if row.get("kind") == "menu" and row.get("id") == "captions.actions"]
    require(len(menus) == 2 and all(row.get("path") == ["Translate", "German"] and row.get("closed") is True
            and len(row["menus"]) == 2 and "Translate" in row["menus"][0] and "German" in row["menus"][1] for row in menus),
            "actual native target-language submenu was not selected")
    clicks = [row.get("id") for row in actions if row.get("kind") == "pointer"]
    require(clicks.count("agent.task.run") == 2 and clicks.count("agent.dialog.cancel") == clicks.count("agent.dialog.confirm") == 1
            and clicks.count("captions.revision.choice.translate-first") == 1
            and "captions.revision.choice.translate-second" not in clicks, "actual native selective translation decisions differ")
    for identity in ("translate-first", "translate-second"):
        require(any("captions.revision.choice." + identity in row.get("ids", []) and visible_group(row)
                    for row in actions if row.get("kind") == "visible-group"), "a target-language text row was not fully visible")
    keys = [row for row in actions if row.get("kind") == "keyboard" and row.get("code") == 6]
    require([row["characters"] for row in keys] == ["z", "Z"] and all(row["modifiers"] & (1 << 20) for row in keys)
            and not keys[0]["modifiers"] & (1 << 17) and keys[1]["modifiers"] & (1 << 17), "actual single Undo/Redo missing")
    require(any(row.get("kind") == "keyboard" and row.get("code") == 1 and row.get("characters") == "s"
                and row.get("modifiers", 0) & (1 << 20) for row in actions), "actual native translation Save missing")
    fields = [row["field"] for row in actions if row.get("kind") == "text" and row.get("field", {}).get("id") == "agent.composer.input"]
    require(len(fields) == 2 and result["renderedFontPointSize"] == fields[-1]["fontPointSize"]
            and abs(fields[-1]["fontPointSize"] - 13 * scale) < 0.5, "actual translated task font differs")
    require(len(result["screenshots"]) >= 3 and all(len(read(directory, name)) > 1000
            and read(directory, name).startswith(b"\x89PNG\r\n\x1a\n") for name in result["screenshots"]), "actual translation PNGs missing")
    return result
