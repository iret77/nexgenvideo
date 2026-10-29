"""Exercise the native approval-reset confirmation, real restart and Recovery open."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid
from urllib.parse import unquote, urlparse

from settings_owner_acceptance import pack_metadata
from prepare_settings_pack_artifacts import PREVIEW_PROFILE, PREVIEW_RELEASE, PREVIEW_COMMIT, STABLE_PROFILE, require_baseline


def file_url(value):
    parsed = urlparse(value)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
        raise AssertionError("The native saved state contains a nonlocal URL")
    return Path(unquote(parsed.path))


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def require_pack_pair(pair, baseline, target, baseline_sha256, target_sha256, scenario):
    require_baseline(scenario, baseline, baseline_sha256)
    if (pair.get("schema") != "actual-settings-pack-pair/v1" or pair.get("rewrittenBundleMetadata") is not False
            or pair.get("baselineProfile") != scenario or pair.get("baseline") != baseline or pair.get("target") != target
            or pair.get("publishedBaselineSHA256") != "sha256:" + baseline_sha256
            or pair.get("targetArchiveSHA256") != target_sha256):
        raise ValueError("The Recovery pair does not bind these exact baseline and target ZIPs")
    producer = pair.get("publishedBaseline", {})
    tag = PREVIEW_RELEASE if scenario == PREVIEW_PROFILE else "plugins"
    if (producer.get("repository") != "iret77/nexgenvideo" or producer.get("releaseTag") != tag
            or producer.get("assetName") != "musicvideo-" + baseline["version"] + ".ngvpack.zip"
            or producer.get("digest") != "sha256:" + baseline_sha256
            or any(type(producer.get(key)) is not int or producer[key] <= 0 for key in ("releaseID", "assetID"))
            or (scenario == PREVIEW_PROFILE and producer.get("sourceCommit") != PREVIEW_COMMIT)):
        raise ValueError("The Recovery baseline has different original release provenance")


def owned_process_alive(pid, executable, owner):
    result = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "state=", "-o", "command="],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5, check=False)
    fields = result.stdout.strip().split(maxsplit=1)
    if result.returncode or len(fields) != 2 or fields[0].startswith("Z"):
        return False
    return str(executable) in fields[1] and "--ngv-pack-recovery-owner=" + owner in fields[1]


def owned_process_ids(executable, owner):
    result = subprocess.run(["/bin/ps", "-ww", "-axo", "pid=,command="], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=5, check=True)
    observed = set()
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if (len(fields) == 2 and str(executable) in fields[1]
                and "--ngv-pack-recovery-owner=" + owner in fields[1]):
            observed.add(int(fields[0]))
    return observed


def cleanup_owned(output, process, executable, owner):
    pids = {process.pid}
    for role in ("initial", "reopener", "resumed"):
        path = output / ("pack-recovery-process-" + role + ".json")
        if path.exists():
            record = json.loads(path.read_text())
            if record.get("owner") == owner:
                pids.add(int(record["pid"]))
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        pids.update(owned_process_ids(executable, owner))
        for pid in pids:
            if owned_process_alive(pid, executable, owner):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        time.sleep(0.1)
    pids.update(owned_process_ids(executable, owner))
    for pid in pids:
        if owned_process_alive(pid, executable, owner):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        raise RuntimeError("The owned native Recovery process did not stop")


def require_composer_typography(record, label, scale):
    try:
        rows = record["interactions"]
        matches = lambda name: [(i, r["evidence"]) for i, r in enumerate(rows)
                                if r.get("kind") == "verified-state" and r.get("label") == name]
        typed, measured, viewport = matches("native Recovery composer input"), matches("rendered typography"), matches(label)
        if len(typed) != 1 or len(measured) != 1 or len(viewport) != 1:
            raise AssertionError("Missing unique actual Recovery composer/typography evidence")
        ti, text = typed[0]; mi, font = measured[0]; vi, view = viewport[0]
        window = text["window"]
        task = "Apply a project change"
        if (not ti < mi < vi or type(window) is not int or window <= 0
                or text.get("id") != "agent.composer.input" or text.get("controlKind") != "text-view"
                or text.get("task") != task
                or not isinstance(text.get("before"), str) or text.get("after") != text["before"] + "R" or text.get("added") != "R"
                or font.get("id") != text["id"] or font.get("controlKind") != "text-view" or font.get("window") != window
                or font.get("baseSize") != 13 or font.get("scale") != scale
                or any(type(v) not in (int, float) or not math.isfinite(v) or abs(v - 13 * scale) >= .5
                       for v in (font.get("pointSize"), view.get("renderedFontPointSize")))
                or abs(font["pointSize"] - view["renderedFontPointSize"]) >= .01):
            raise AssertionError("Recovery typography is not bound to its actual editable composer")
        clicks = [i for i, r in enumerate(rows[:ti]) if r.get("kind") == "pointer"
                  and r.get("id") == text["id"] and r.get("window") == window]
        ends = [i for i, r in enumerate(rows[:ti]) if r.get("kind") == "keyboard" and r.get("window") == window
                and r.get("code") == 125 and type(r.get("modifiers")) is int and r["modifiers"] & (1 << 20)]
        inputs = [i for i, r in enumerate(rows[:ti]) if r.get("kind") == "keyboard" and r.get("window") == window
                  and r.get("code") == 15 and r.get("characters") == "R" and r.get("modifiers") == 0]
        choices = [i for i, r in enumerate(rows[:ti]) if
                   (r.get("kind") == "menu" and r.get("id") == "agent.task.choose" and r.get("item") == task
                    and r.get("closed") is True and any(p.get("kind") == "pointer" and p.get("id") == "agent.task.choose"
                        and p.get("window") == window for p in rows[:i]))
                   or (r.get("kind") == "verified-state" and r.get("label") == "native-pointer"
                       and r.get("evidence", {}).get("target") == "button." + task and r["evidence"].get("window") == window)]
        if (len(choices) != 1 or len(clicks) != 1 or len(ends) != 1 or len(inputs) != 1
                or not choices[0] < clicks[0] < ends[0] < inputs[0] < ti):
            raise AssertionError("Recovery typography has no ordered real native composer input")
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise AssertionError("Malformed actual Recovery composer evidence") from error


def require_saved_draft(record, saved):
    rows = record["interactions"]
    ti, typed = next((i, r["evidence"]) for i, r in enumerate(rows) if r.get("label") == "native Recovery composer input")
    mi = next(i for i, r in enumerate(rows) if r.get("label") == "rendered typography")
    saves = [(i, r["evidence"]) for i, r in enumerate(rows) if r.get("label") == "native Recovery draft saved"]
    menus = [(i, r["evidence"]) for i, r in enumerate(rows) if r.get("label") == "application-menu"
             and r.get("evidence", {}).get("path") == ["File", "Save"]]
    if len(saves) != 1 or len(menus) != 1 or not ti < mi < menus[0][0] < saves[0][0]:
        raise AssertionError("Recovery draft has no actual native Save")
    observed = saves[0][1]
    identifier = observed["sessionID"]
    if str(uuid.UUID(identifier)).upper() != identifier:
        raise AssertionError("Invalid saved composer session")
    session = json.loads((saved / "chat" / (identifier + ".json")).read_bytes())
    if (observed.get("wasEdited") is not True or observed.get("isEdited") is not False
            or observed.get("window") != typed["window"] or menus[0][1].get("window") != typed["window"]
            or session.get("id") != identifier or session.get("draft", {}).get("text") != typed["after"]
            or observed.get("draft") != typed["after"] or session["draft"].get("task", {}).get("title") != typed["task"]):
        raise AssertionError("Recovery Save lost its actual composer draft")
    return identifier


def require_session_edit(record, output, recovery, originals, identifier):
    matches = [r["evidence"] for r in record["interactions"] if r.get("label") == "native Recovery session edit"]
    if len(matches) != 1:
        raise AssertionError("Missing exact native Recovery session edit")
    edit = matches[0]
    path = "chat/" + identifier + ".json"
    typed = next(r["evidence"] for r in record["interactions"] if r.get("label") == "native Recovery composer input")
    before = (output / "pack-recovery-session-before-input.json").read_bytes()
    after = (output / "pack-recovery-session-after-input.json").read_bytes()
    if (edit.get("path") != path or edit.get("sessionID") != identifier
            or edit.get("beforeSHA256") != hashlib.sha256(before).hexdigest()
            or edit.get("afterSHA256") != hashlib.sha256(after).hexdigest()
            or before == after or (recovery / path).read_bytes() != after
            or [v["sha256"] for v in originals if v["path"] == path] != [hashlib.sha256(before).hexdigest()]):
        raise AssertionError("Recovery session edit is not bound to actual restored bytes")
    prior, current = json.loads(before), json.loads(after)
    for session, expected in ((prior, typed["before"]), (current, typed["after"])):
        if session.get("id") != identifier or session.get("draft", {}).get("text") != expected:
            raise AssertionError("Recovery session edit lost its typed draft")
        session.pop("updatedAt", None)
        session["draft"].pop("text")
        task = session["draft"].get("task", {})
        if task.get("title") != typed["task"]:
            raise AssertionError("Recovery session edit lost its native task")
        task.pop("originContext", None)
    if prior != current:
        raise AssertionError("Native composer edit changed unrelated session state")
    return path



def gate_approvals(path):
    values, current = {}, None
    for line in path.read_text().splitlines():
        phase = re.fullmatch(r"\s+([a-z_]+):", line)
        if phase:
            current = phase[1]
        approved = re.fullmatch(r"\s+approved: (true|false)", line)
        if approved:
            if current is None or current in values:
                raise AssertionError("Malformed or duplicate actual gate approval")
            values[current] = approved[1] == "true"
    return values


def require_resume_identity(state, resume, original, saved, reopened):
    identifier = state["projectID"]
    uuid.UUID(identifier)
    if resume.get("projectID") != identifier or Path(resume.get("projectURL", "")) != saved:
        raise AssertionError("The approved continuation changed its original project identity or URL")
    for home, binding in ((original, state["source"]), (saved, state["target"]), (reopened, state["target"])):
        settings = json.loads((home / "ngv.json").read_text())
        if (settings.get("id") != identifier or settings.get("activePlugin") != binding["id"]
                or settings.get("activePluginVersion") != binding["version"]
                or settings.get("activePluginProjectSchema") != binding["projectSchema"]):
            raise AssertionError("The approved continuation changed its original identity or exact pack pin")
    timeline = json.loads((original / "project.json").read_bytes())
    initial = state["initialTimeline"]
    without_song = {**timeline, "tracks": [track for track in timeline["tracks"] if track["type"] != "audio"]}
    clips = [clip for track in initial.get("tracks", []) for clip in track.get("clips", [])]
    if (timeline != state["timeline"] or without_song != initial
            or any(initial.get(key) != value for key, value in {"width": 320, "height": 180, "fps": 30, "settingsConfigured": True}.items())
            or len(initial.get("tracks", [])) != 1 or initial["tracks"][0].get("type") != "video" or len(clips) != 1
            or any(clips[0].get(key) != value for key, value in {"mediaRef": "retained-original", "startFrame": 0,
                       "durationFrames": 180, "trimStartFrame": 30}.items())):
        raise AssertionError("The actual approved legacy baseline changed its original native cut")
    manifest = json.loads((original / "media.json").read_bytes())
    initial_entry = state["initialVideoEntry"]
    original_entries = [entry for entry in manifest["entries"] if entry.get("id") == "retained-original"]
    expected_entry = {"id": "retained-original", "type": "video", "name": "Retained original moving shot",
                      "source": {"project": {"relativePath": "media/Retained original moving shot.mov"}},
                      "originalFilename": "Retained original moving shot.mov", "duration": 8}
    if any(initial_entry.get(key) != value for key, value in expected_entry.items()) or original_entries != [initial_entry]:
        raise AssertionError("The approved legacy baseline changed its independently pinned original source manifest entry")
    song_id = manifest.get("songAnchorAssetId")
    songs = [entry for entry in manifest["entries"] if entry.get("id") == song_id and entry.get("type") == "audio"]
    audio_tracks = [track for track in timeline["tracks"] if track["type"] == "audio"]
    song_clips = [clip for track in audio_tracks for clip in track["clips"]]
    if (not song_id or len(songs) != 1 or len(audio_tracks) != 1 or len(song_clips) != 1
            or manifest.get("intakeRoleByAssetID", {}).get(song_id) != "song"
            or song_clips[0].get("mediaRef") != song_id or song_clips[0].get("startFrame") != 0
            or song_clips[0].get("trimStartFrame") != 0 or song_clips[0].get("trimEndFrame") != 0
            or song_clips[0].get("durationFrames") != math.floor(songs[0]["duration"] * timeline["fps"] + .5)):
        raise AssertionError("The actual approved legacy baseline lost its genuine song anchor")
    if any(json.loads((home / "project.json").read_bytes()) != timeline for home in (saved, reopened)):
        raise AssertionError("The approved continuation changed the original native cut")
    if any(json.loads((home / "media.json").read_bytes()) != manifest for home in (saved, reopened)):
        raise AssertionError("The approved continuation changed its original media sources or intake manifest")


def require_approved_resume(output, state, result, original, history):
    resume = result["approvedResume"]
    saved, reopened = file_url(state["projectURL"]), Path(resume["reopenedRecoveryURL"])
    if not reopened.is_relative_to(output / "isolated-user") or reopened == saved:
        raise AssertionError("The reopened continuation lost its isolated working copy")
    require_resume_identity(state, resume, original, saved, reopened)
    legacy_order = ["project_init", "analysis", "brief", "production_design", "treatment", "storyboard", "bible"]
    if {phase for phase, approved in gate_approvals(original / "pipeline/gates.yaml").items() if approved} != set(legacy_order):
        raise AssertionError("The original preview did not actually approve Storyboard and References")
    rows = json.loads((output / "legacy-approved/legacy-native-approvals.json").read_text())
    if [row.get("phase") for row in rows] != legacy_order:
        raise AssertionError("The original preview has no complete ordered native approval path")
    for index, row in enumerate(rows):
        next_phase = (legacy_order + ["shotlist"])[index + 1]
        if (row.get("nextPhase") != next_phase or row.get("handoffPhase") != next_phase
                or row.get("controlID") != "agent.gate.approve" or row.get("openControlID") != "agent.gate.open"
                or any(row.get(key) is not True for key in ("blockedBeforeApproval", "readyBeforeClick", "approvedPersisted", "handoffHidden", "packagedInstructions"))
                or len(row.get("screenshots", [])) != 3):
            raise AssertionError("The original approval did not exercise its actual blocked/ready/approve controls")
        for name in row["screenshots"]:
            if Path(name).name != name or (output / "legacy-approved" / name).read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                raise AssertionError("An original native approval screenshot is missing")
    old_story = digest(original / "pipeline/treatment/current.md")
    old_identity = state["oldIdentitySHA256"]
    old_manifest = json.loads((original / "pipeline/import/confirmed-identity-assets.v1.json").read_text())
    old_entries = [entry for entry in old_manifest["entries"].values()
                   if entry.get("role") == "location" and entry.get("identity_slug") == "stage"]
    if len(old_entries) != 1 or old_entries[0].get("sha256") != old_identity or digest(original / "pipeline" / old_entries[0]["path"]) != old_identity:
        raise AssertionError("The original approved References lost their actual confirmed identity bytes")
    if old_story != state["oldStorySHA256"] or resume.get("sourceStorySHA256") != old_story or resume.get("sourceIdentitySHA256") != old_identity:
        raise AssertionError("The continuation substituted its original story or identity proof")
    selections = resume.get("selected", [])
    if ([item.get("role") for item in selections] != ["script", "location"]
            or [item.get("sourceSHA256") for item in selections] != [old_story, old_identity]
            or any(item.get("historyFingerprint") != history["intent"]["fingerprint"] or not item.get("materialID") for item in selections)):
        raise AssertionError("The original story and identity were not explicitly selected from this migration history")
    expected_files = resume.get("canonicalFiles", {})
    required = {"script/current.v1.json", "storyboard/current.v2.yaml", "storyboard/timing-current.v1.json",
                "storyboard/causality-current.v2.json", "storyboard/identity-current.v1.json", "gates.yaml", "lineage.json",
                "brief/story-source.v1.json", "brief/story-source-selection.v1.json", "import/script.md",
                "import/confirmed-identity-assets.v1.json"}
    if not required.issubset(expected_files):
        raise AssertionError("The saved continuation omitted its canonical source/approval proof")
    for path, sha in expected_files.items():
        relative = Path(path)
        if relative.is_absolute() or ".." in relative.parts or not re.fullmatch(r"[0-9a-f]{64}", sha):
            raise AssertionError("The continuation canonical inventory is invalid")
        if any(digest(home / "pipeline" / relative) != sha for home in (saved, reopened)):
            raise AssertionError("Native Save/Close/Reopen changed its exact canonical planning bytes")
    if digest(saved / "pipeline/import/script.md") != old_story:
        raise AssertionError("The visible history choice did not persist the original story bytes")
    identity_manifest = json.loads((saved / "pipeline/import/confirmed-identity-assets.v1.json").read_text())
    identities = [entry for entry in identity_manifest["entries"].values()
                  if entry.get("role") == "location" and entry.get("identity_slug") == "stage"]
    if len(identities) != 1 or identities[0].get("sha256") != old_identity:
        raise AssertionError("The real history intake lost its current Stage confirmation")
    for home in (saved, reopened):
        if digest(home / "pipeline" / identities[0]["path"]) != old_identity:
            raise AssertionError("The confirmed historical identity image changed after reopen")
    for item in history["intent"]["files"]:
        path = Path(item["path"])
        if path.suffix.lower() in {".mov", ".png", ".wav"}:
            if any(digest(home / path) != item["sha256"] for home in (saved, reopened)):
                raise AssertionError("The migrated save changed retained original media or cut")
    timing = json.loads((saved / "pipeline/storyboard/timing-current.v1.json").read_text())
    shots = timing.get("shots", [])
    if not shots or len(shots[0].get("moments", [])) < 2:
        raise AssertionError("The migrated Storyboard has no multiple actual sketch moments")
    for shot in shots:
        for moment in shot["moments"]:
            for key in ("image", "proof"):
                reference = moment["asset"][key]
                if expected_files.get(reference["path"]) != reference["sha256"]:
                    raise AssertionError("The reopened sketch asset is absent from its exact canonical inventory")
    final = gate_approvals(saved / "pipeline/gates.yaml")
    if len(final) != 14 or {phase for phase, approved in final.items() if approved} != {
            "project_init", "analysis", "brief", "production_design", "treatment", "script", "storyboard"}:
        raise AssertionError("The saved V2 continuation did not approve its new Script and sketched Storyboard independently")
    for key, expected in (("driver", "v2-resume/resume172-continuation-result.json"),
                          ("materialDriver", "v2-resume/resume172-previous-material-result.json"),
                          ("reopenDriver", "v2-resume/resume172-reopened-result.json")):
        if resume.get(key) != expected:
            raise AssertionError("The continuation evidence driver identity changed")
    drivers = [json.loads((output / resume[key]).read_text()) for key in ("driver", "materialDriver", "reopenDriver")]
    material_rows = drivers[1]["interactions"]
    choices = [row.get("id") for row in material_rows if row.get("kind") == "pointer"]
    for selected in selections:
        if "agent.dialog.previous-workflow.choice." + selected["materialID"] not in choices:
            raise AssertionError("A historical material was injected without its actual visible picker click")
    rows = drivers[0]["interactions"]
    labels = [row.get("label") for row in rows if row.get("kind") == "verified-state"]
    if ("native sketch assignment" not in labels or "two moments within one shot" not in labels
            or "native approval storyboard" not in labels):
        raise AssertionError("The migrated project did not exercise its actual Sketch/Animatic/Storyboard approval path")
    animatic = [row["evidence"] for row in rows if row.get("label") == "two moments within one shot"]
    if (len(animatic) != 1 or animatic[0].get("firstImageSHA256") == animatic[0].get("secondImageSHA256")
            or any(animatic[0].get(key) is not True for key in ("playingWhenLeaving", "stoppedAfterLeaving", "playbackDetached"))):
        raise AssertionError("The migrated Animatic did not visibly play its two distinct original-source frames")
    menus = [row.get("evidence", {}).get("path") for row in rows if row.get("label") == "application-menu"]
    closes = [row for row in rows if row.get("label") == "native-pointer" and row.get("evidence", {}).get("target") == "window.close"]
    if len(closes) != 1 or ["File", "Save"] not in menus or ["File", "Open…"] not in menus:
        raise AssertionError("The migrated document was not natively saved and reopened")
    for driver in drivers:
        if not driver.get("screenshots"):
            raise AssertionError("A continuation surface has no actual screenshot")
        for name in driver["screenshots"]:
            if Path(name).name != name or (output / "v2-resume" / name).read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                raise AssertionError("A migrated native screenshot is missing")
    if resume.get("nextPhase") != "shot_planning":
        raise AssertionError("The new Storyboard did not reach its actual next phase")

def validate(output, expected_scale=1, expected_scenario=STABLE_PROFILE):
    result = json.loads((output / "pack-recovery-result.json").read_text())
    state = json.loads((output / "pack-recovery-state.json").read_text())
    if (state.get("scenario", STABLE_PROFILE) != expected_scenario
            or result.get("scenario", STABLE_PROFILE) != expected_scenario):
        raise AssertionError("The native process did not exercise the requested Recovery scenario")
    if (expected_scale not in (1, 1.25, 1.5) or state.get("scale") != expected_scale
            or result.get("effectiveScale") != expected_scale or result.get("viewport") != [960, 640]
            or not abs(result.get("renderedFontPointSize", 0) - 13 * expected_scale) < .5):
        raise AssertionError("Recovery resumed at a different native interface scale or viewport")
    for role in ("initial", "resumed"):
        process = json.loads((output / ("pack-recovery-process-" + role + ".json")).read_text())
        try:
            actual_scale = float(process["scaleArgument"])
        except (ValueError, TypeError, KeyError) as error:
            raise AssertionError("Recovery lost its actual process scale argument") from error
        if actual_scale != expected_scale:
            raise AssertionError("Recovery process scale argument differs from requested scale")
    if result["initialPID"] != state["initialPID"] or result["resumedPID"] == state["initialPID"]:
        raise AssertionError("A real new process did not resume the upgrade")
    if result.get("requestedSelectionRetained") is not True:
        raise AssertionError("The loaded target selection was cleared while consuming the project-open intent")
    saved = file_url(state["projectURL"])
    recovery = Path(result["recoveryURL"])
    if saved == recovery or not saved.is_relative_to(output) or not recovery.is_relative_to(output / "isolated-user"):
        raise AssertionError("The actual Recovery or saved project escaped isolation")
    actual_saved = saved
    if expected_scenario == PREVIEW_PROFILE:
        resume = result.get("approvedResume", {})
        saved, recovery = output / "original-before-resume-save.ngv", output / "reset-recovery-evidence.ngv"
        if (resume.get("originalBeforeSave") != str(saved) or resume.get("resetRecoveryEvidence") != str(recovery)
                or resume.get("projectURL") != str(actual_saved)):
            raise AssertionError("The approved continuation has no separate original/pre-save and reset evidence")
    before = json.loads((output / "pack-recovery-before-restart.json").read_text())
    after = json.loads((output / "pack-recovery-after-restart.json").read_text())
    if before.get("failure") is not None or after.get("failure") is not None:
        raise AssertionError("A native interaction failed")
    require_composer_typography(before, "native Recovery viewport before restart", expected_scale)
    if expected_scenario == PREVIEW_PROFILE:
        measured = [item["evidence"] for item in after["interactions"] if item.get("label") == "rendered typography"]
        if (len(measured) != 1 or measured[0].get("id") != "agent.dialog.direction" or measured[0].get("controlKind") != "text-field"
                or measured[0].get("scale") != expected_scale or measured[0].get("baseSize") != 13
                or abs(measured[0].get("pointSize", 0) - 13 * expected_scale) >= .5):
            raise AssertionError("The actual restored story intake has no measured native typography")
    else:
        require_composer_typography(after, "native Recovery viewport after restart", expected_scale)
    session_id = require_saved_draft(before, saved)
    for item in state["savedFiles"]:
        if digest(saved / item["path"]) != item["sha256"]:
            raise AssertionError("The native restart changed saved bytes: " + item["path"])
    saved_paths = {str(path.relative_to(saved)) for path in saved.rglob("*") if path.is_file()}
    if saved_paths != {item["path"] for item in state["savedFiles"]}:
        raise AssertionError("The native upgrade changed the saved package inventory")
    archived = recovery / "pipeline/migration-history" / result["historyFingerprint"]
    history = json.loads((archived / "manifest.v1.json").read_text())
    retained = ["project_init", "analysis"] if expected_scenario == PREVIEW_PROFILE else []
    if history.get("completed") is not True or history.get("retainedStartupPhases") != retained:
        raise AssertionError("The actual migration adopted unverified approvals")
    original = history["intent"]
    if original["fingerprint"] != result["historyFingerprint"]:
        raise AssertionError("The immutable history binding changed")
    archived_paths = set(original["archivePaths"])
    required_archive = {"ngv.json", "pipeline/brief.yaml"}
    required_archive |= ({"pipeline/treatment/current.md", "pipeline/storyboard/current.yaml", "pipeline/bible/bible.yaml",
                          "pipeline/import/confirmed-identity-assets.v1.json"}
                         if expected_scenario == PREVIEW_PROFILE else {"pipeline/treatment/v4.md"})
    if not required_archive.issubset(archived_paths):
        raise AssertionError("Canonical legacy planning history was not archived")
    edited_session = (require_session_edit(after, output, recovery, original["files"], session_id)
                      if expected_scenario == STABLE_PROFILE else None)
    if edited_session in archived_paths:
        raise AssertionError("The native composer edited an archived session")
    replaceable = {"ngv.json", "pipeline/gates.yaml", "pipeline/lineage.json"}
    for item in original["files"]:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise AssertionError("An archived reference escaped its Recovery namespace")
        if item["path"] in archived_paths:
            if digest(archived / relative) != item["sha256"]:
                raise AssertionError("Archived exact bytes changed: " + item["path"])
        elif item["path"] not in replaceable and item["path"] != edited_session and digest(recovery / relative) != item["sha256"]:
            raise AssertionError("Retained original media or timeline bytes changed: " + item["path"])
    source, target = state["source"], state["target"]
    for path, binding in ((saved, source), (recovery, target)):
        settings = json.loads((path / "ngv.json").read_text())
        if (settings.get("activePlugin"), settings.get("activePluginVersion"), settings.get("activePluginProjectSchema")) != (
                binding["id"], binding["version"], binding["projectSchema"]):
            raise AssertionError("The real saved/Recovery version binding is incorrect")
    gates = (recovery / "pipeline/gates.yaml").read_text()
    approvals = re.findall(r"^\s+approved:\s*(true|false)\s*$", gates, re.MULTILINE)
    if expected_scenario == PREVIEW_PROFILE:
        reset_gates = gate_approvals(recovery / "pipeline/gates.yaml")
        if len(reset_gates) != 14 or {phase for phase, approved in reset_gates.items() if approved} != set(retained):
            raise AssertionError("The actual V2 reset retained approvals beyond verified Init and Analysis")
        require_approved_resume(output, state, result, saved, history)
    elif len(approvals) != 14 or any(value != "false" for value in approvals):
        raise AssertionError("The actual V2 gates did not all reset")
    namespace = json.loads((recovery / "pipeline/production-output-namespace.v1.json").read_text())
    if (namespace["sourceFingerprint"] != original["fingerprint"] or namespace["id"] != original["namespaceID"]
            or "pipeline/frames/Retained original still.png" not in namespace["protectedPaths"]):
        raise AssertionError("The actual output namespace lost retained-image protection")
    for record, label in ((before, "native Recovery viewport before restart"), (after, "native Recovery viewport after restart")):
        viewports = [item.get("evidence") for item in record["interactions"]
                     if item.get("kind") == "verified-state" and item.get("label") == label]
        if (len(viewports) != 1 or any(viewports[0].get(k) != v for k, v in
                {"scale": expected_scale, "width": 960, "height": 640}.items())
            or not abs(viewports[0].get("renderedFontPointSize", 0) - 13 * expected_scale) < .5):
            raise AssertionError("Missing independently retained before/after native Recovery scale")
    pointers = [item for item in before["interactions"] if item.get("kind") == "pointer"]
    if sum(item["id"] == "settings.pack.apply." + source["id"] for item in pointers) != 3:
        raise AssertionError("Cancel, stale refusal and real restart were not all entered through the actual control")
    dialogs = [item["evidence"]["title"] for item in before["interactions"]
               if item.get("kind") == "verified-state" and item.get("label") == "native-dialog-pointer"]
    if dialogs.count("Cancel") != 1 or dialogs.count("Upgrade and Restart") != 2 or "OK" not in dialogs:
        raise AssertionError("The native decisions were not actually delivered")
    screenshots = before["screenshots"] + after["screenshots"]
    if len(before["screenshots"]) < 4 or not after["screenshots"] or len(set(screenshots)) != len(screenshots):
        raise AssertionError("Distinct native confirmation and Recovery screenshots are missing")
    for name in screenshots:
        if Path(name).name != name or (output / name).read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise AssertionError("A genuine native screenshot is missing")
    return {"schema": "validated-native-pack-recovery/v1", "scenario": expected_scenario, "initialPID": result["initialPID"], "resumedPID": result["resumedPID"],
            "historyFingerprint": original["fingerprint"], "savedFilesVerified": len(state["savedFiles"]),
            "archivedFilesVerified": len(archived_paths), "providerCalls": 0, "scale": expected_scale}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-pack-zip", type=Path, required=True)
    parser.add_argument("--target-pack-zip", type=Path, required=True)
    parser.add_argument("--scale", type=float, choices=(1, 1.25, 1.5), default=1)
    parser.add_argument("--scenario", choices=(STABLE_PROFILE, PREVIEW_PROFILE), default=STABLE_PROFILE)
    parser.add_argument("--pack-pair", type=Path)
    args = parser.parse_args()
    baseline, target = pack_metadata(args.baseline_pack_zip), pack_metadata(args.target_pack_zip)
    if baseline["id"] != target["id"] or target["id"] != "musicvideo" or target["projectSchema"] != "musicvideo/3.0.0":
        raise ValueError("Supply the actual legacy Musicvideo ZIP and current V2 Musicvideo ZIP")
    if args.scenario == PREVIEW_PROFILE and args.pack_pair is None:
        parser.error("The known 1.7.2 resume requires its exact original release pack-pair receipt")
    if args.pack_pair is not None:
        require_pack_pair(json.loads(args.pack_pair.read_text()), baseline, target,
                         digest(args.baseline_pack_zip), digest(args.target_pack_zip), args.scenario)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    home = output / "isolated-user"
    home.mkdir()
    manifest = output / "pack-fixtures.json"
    manifest.write_text(json.dumps({"id": baseline["id"], "displayName": baseline["displayName"],
                                   "baseline": baseline, "target": target}, indent=2))
    safe_keys = {"PATH", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING", "DISPLAY", "TERM"}
    env = {key: value for key, value in os.environ.items() if key in safe_keys}
    env.update({"CFFIXED_USER_HOME": str(home), "NGV_PACK_RECOVERY_ACCEPTANCE": "1",
                "NGV_WORKSPACE_UI_ACCEPTANCE": "1", "NGV_PACK_RECOVERY_EVIDENCE": str(output),
                "NGV_SETTINGS_PACK_FIXTURE": str(manifest), "NGV_PACK_RECOVERY_SCALE": str(args.scale),
                "NGV_PACK_RECOVERY_SCENARIO": args.scenario})
    if args.pack_pair is not None:
        (output / "pack-pair.json").write_bytes(args.pack_pair.read_bytes())
    timeout = 720 if args.scenario == PREVIEW_PROFILE else 360
    deadline = time.monotonic() + timeout
    owner = str(uuid.uuid4())
    executable = args.executable.resolve(strict=True)
    with (output / "pack-recovery.log").open("w") as log:
        process = subprocess.Popen([str(executable), "--ngv-pack-recovery-owner=" + owner,
                                    "-ApplePersistenceIgnoreState", "YES", "-interfaceTextScale", str(args.scale)],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        try:
            returncode = process.wait(timeout=timeout)
            if returncode:
                failure = output / "pack-recovery-failure.txt"
                detail = failure.read_text() if failure.exists() else "No native failure detail was written"
                raise RuntimeError("The actual initial native pack-upgrade process failed: " + detail)
            while time.monotonic() < deadline:
                if (output / "pack-recovery-failure.txt").exists():
                    raise RuntimeError((output / "pack-recovery-failure.txt").read_text())
                if (output / "pack-recovery-result.json").exists():
                    break
                time.sleep(0.1)
            else:
                raise TimeoutError("No actual Recovery result followed the real process restart")
            resumed = json.loads((output / "pack-recovery-result.json").read_text())["resumedPID"]
            resumed_process = json.loads((output / "pack-recovery-process-resumed.json").read_text())
            reopener_process = json.loads((output / "pack-recovery-process-reopener.json").read_text())
            if (resumed_process.get("owner") != owner or reopener_process.get("owner") != owner
                    or resumed_process["pid"] != resumed or reopener_process["pid"] != resumed):
                raise AssertionError("The actual executable reopener did not become the reported resumed process")
            while time.monotonic() < deadline and owned_process_alive(resumed, executable, owner):
                time.sleep(0.1)
            if owned_process_alive(resumed, executable, owner):
                raise TimeoutError("The actual resumed Recovery process did not exit before validation")
            result = validate(output, expected_scale=args.scale, expected_scenario=args.scenario)
            (output / "pack-recovery-validation.json").write_text(json.dumps(result, indent=2))
        finally:
            cleanup_owned(output, process, executable, owner)


if __name__ == "__main__":
    main()
