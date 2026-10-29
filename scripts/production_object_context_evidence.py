"""Independent checks for native production navigation, task scopes and old chat history."""
import hashlib
import json
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text())


def digest(path):
    require(path.is_file() and not path.is_symlink(), "missing regular evidence: " + path.name)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local(directory, relative):
    path = Path(relative)
    require(relative and not path.is_absolute() and all(part not in (".", "..") for part in path.parts), "unsafe evidence path")
    target = directory / path
    require(target.resolve().is_relative_to(directory.resolve()), "evidence escape")
    return target


def observation(entry, name):
    rows = [action for action in entry.get("interactions", []) if action.get("kind") == "verified-state" and action.get("label") == name]
    require(len(rows) == 1, "missing unique native observation: " + name)
    return rows[0].get("evidence", {})


def pointer(entry, identifier):
    return [index for index, action in enumerate(entry.get("interactions", []))
            if action.get("kind") == "pointer" and action.get("id") == identifier]


def selection(raw):
    require(isinstance(raw, str) and raw.startswith("<app-context>") and raw.endswith("</app-context>"), "not an actual app-context request block")
    start = raw.find("{")
    require(start >= 0, "missing serialized selection")
    value, _ = json.JSONDecoder().raw_decode(raw[start:])
    return value


def validate_case(directory, entry, scale):
    require(entry.get("scale") == scale and entry.get("viewport") == [960, 640] and entry.get("backingScale", 0) > 0,
            "actual native presentation differs")
    require(entry.get("liveAgent") is False, "isolated runtime must not claim a live agent")
    log = read(local(directory, entry.get("progress", "")))
    require(log.get("failure") is None and log.get("interactions") == entry.get("interactions")
            and log.get("screenshots") == entry.get("screenshots"), "driver log differs")
    require(entry.get("screenshots"), "native screenshots missing")
    for screenshot in entry["screenshots"]:
        require(local(directory, screenshot).read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "not an actual PNG artifact")
    nav = observation(entry, "verified object navigation")
    history = observation(entry, "older conversation continued and deleted")
    output_sha = digest(directory / "actual-assembled-source.mov")
    reference_sha = digest(directory / "actual-input-reference")
    require(nav.get("outputSHA256") == output_sha and nav.get("referenceSHA256") == reference_sha, "actual media bytes differ")
    require(nav.get("changedOriginalRefused") is True and "original input revision changed" in nav.get("changedOriginalError", ""), "no precise changed-reference refusal")
    require(nav.get("visibleGenerationReceipt") == "Verified" and nav.get("visibleModelID") == nav.get("modelID"), "actual visible source provenance differs")
    proof = read(directory / "actual-assembly.json")
    host = read(directory / "actual-assembly-host.json")
    takes = [item for item in proof.get("placements", []) if item.get("clipID") == nav.get("clipID") and item.get("shotID") == nav.get("shotID")]
    require(len(takes) == 1 and takes[0].get("output", {}).get("sha256") == output_sha, "no actual assembly placement")
    take = read(directory / "actual-take.json")
    receipt = read(directory / "actual-output-receipt.json")
    package = read(directory / "actual-generation-package.json")
    generation = read(directory / "actual-generation-input.json")
    require(take.get("schema") == "production-render-record/v1" and take.get("takeID") == takes[0].get("takeID")
            and take.get("shotID") == nav["shotID"] and take.get("output", {}).get("sha256") == output_sha,
            "foreign take record")
    require(host.get("schema") == "production-assembly-host/v1" and host.get("projectKey") == take.get("projectKey")
            and receipt.get("projectKey") == take.get("projectKey"), "foreign assembly project")
    media = [item for item in host.get("media", []) if item.get("mediaID") == nav.get("mediaID")]
    require(len(media) == 1 and media[0].get("source", {}).get("sha256") == output_sha, "assembly binds other media")
    clips = [clip for track in host.get("tracks", []) for clip in track.get("clips", []) if clip.get("id") == nav.get("clipID")]
    require(len(clips) == 1 and clips[0].get("mediaRef") == nav["mediaID"], "actual assembly clip points elsewhere")
    require(receipt.get("assetID") == take.get("generation", {}).get("id") and receipt.get("output", {}).get("sha256") == output_sha,
            "generation event/output does not bind the actual clip")
    require(package.get("schema") == "generation-package/v1" and package.get("id") == nav.get("generationPackageID")
            == generation.get("generationPackageID") == receipt.get("input", {}).get("generationPackageID"), "foreign generation package")
    require(package.get("payload", {}).get("generationInput", {}).get("model") == nav["modelID"]
            == generation.get("model") == receipt.get("input", {}).get("model"), "source model invented")
    require(package.get("payload", {}).get("prompt") == nav.get("visibleSubmittedPrompt") and nav.get("visibleSubmittedPrompt"), "visible prompt is not the submitted package prompt")
    refs = [ref for ref in package["payload"].get("references", []) if ref.get("assetID") == nav.get("referenceAssetID") and ref.get("sourceSHA256") == reference_sha]
    require(refs, "actual reference is not a submitted input revision")
    for identifier in ["production.plan.select." + nav["shotID"], "production.object.clip." + nav["clipID"],
                       "asset." + nav["mediaID"] + ".original." + nav["referenceAssetID"], "production.object.shot." + nav["shotID"]]:
        require(pointer(entry, identifier), "missing native object navigation: " + identifier)
    require(len(pointer(entry, "asset." + nav["mediaID"] + ".original." + nav["referenceAssetID"])) >= 2,
            "negative and successful original navigation not both exercised")
    plan = read(directory / "actual-production-plan.json")
    shots = plan.get("executionPlan", {}).get("shots", [])
    ids = [shot.get("id") for shot in shots]
    require(nav["shotID"] in ids, "shot not in actual projection")
    expected_label = "Shot " + str(ids.index(nav["shotID"]) + 1)
    first, end = host.get("fps", 0) // 2, host.get("fps", 0) * 3 // 2
    require(first > 0 and end > first, "missing actual editing clock")
    turns = set()
    for kind in ("shot", "timeline", "source"):
        request = read(directory / ("request-" + kind + ".json"))
        require(request == observation(entry, "actual captured task " + kind), "actual runtime request differs from recorded native action")
        captured = selection(request.get("rawAppContext"))
        require(captured == request.get("selection") and captured.get("editingFPS") == host["fps"], "task selection changed in transit")
        require(request.get("kind") == kind and request.get("sessionID") == history.get("sessionID") and request.get("turnID"), "task left the selected old thread")
        turns.add(request["turnID"])
        require(request.get("stagedTitle") == "Revise: " + captured.get("label", ""), "visible title and frozen scope differ")
        if kind == "shot":
            require(captured.get("planningShotID") == nav["shotID"] and captured.get("planningRevision") == plan.get("header", {}).get("revision")
                    and captured.get("label") == expected_label and captured.get("workspace") == "production"
                    and captured.get("timelineRange") is None and captured.get("source") is None, "production shot borrowed a hidden range")
        else:
            require(request.get("workspaceChangedAfterStage") is True and captured.get("workspace") == "edit", "actual edit origin was lost")
            actions = entry.get("interactions", [])
            finish = next(index for index, action in enumerate(actions) if action.get("label") == "actual captured task " + kind)
            start = max([index for index, action in enumerate(actions[:finish]) if action.get("label", "").startswith("actual captured task ")] or [-1])
            stage = [index for index in pointer(entry, "inspector.task.stage") if start < index < finish]
            run = [index for index in pointer(entry, "agent.task.run") if start < index < finish]
            switch = [index for index in pointer(entry, "production.plan.select." + nav["shotID"]) if start < index < finish]
            require(len(stage) == 1 and len(run) == 1 and any(stage[0] < index < run[0] for index in switch), "no actual workspace switch between stage and send")
            if kind == "timeline":
                require(captured.get("timelineRange") == {"start": first, "end": end} and captured.get("source") is None
                        and captured.get("timelineFrame") == end, "wrong actual timeline range")
                bindings = [binding for binding in captured.get("clips", []) if binding.get("clipID") == nav["clipID"]]
                require(len(bindings) == 1 and bindings[0].get("mediaRef") == nav["mediaID"], "range lost its actual clip binding")
                for code in (34, 31):
                    require(any(action.get("kind") == "keyboard" and action.get("code") == code for action in actions[start:finish]), "native IN/OUT key missing")
            else:
                source = captured.get("source", {})
                require(captured.get("timelineRange") is None and source.get("assetID") == nav["mediaID"]
                        and source.get("range") == {"start": first, "end": end} and source.get("playheadFrame") == end
                        and source.get("inSeconds") == first / host["fps"] and source.get("outSeconds") == end / host["fps"], "wrong actual source range/clock")
                for mark in ("in", "out"):
                    require(pointer(entry, "source." + mark + "." + nav["mediaID"]), "native source mark missing")
    require(len(turns) == 3 and history.get("continuedTurns") == 3, "old conversation was not continued with three actual tasks")
    legacy = read(directory / "initial-legacy-conversation.json")
    require(legacy.get("id") == history.get("sessionID") and "isOpen" not in legacy and "draft" not in legacy, "not the actual old-format fixture")
    require(pointer(entry, "agent.history.select." + history["sessionID"]) and len(pointer(entry, "agent.history.delete." + history["sessionID"])) == 2,
            "old history selection/cancel/retry not native")
    require(any(action.get("kind") == "verified-state" and action.get("label") == "native-pointer"
                and action.get("evidence", {}).get("target") == "button.Delete “" + legacy["title"] + "”"
                for action in entry["interactions"]), "native destructive confirmation missing")
    before = read(directory / "history-prefix-before.json")
    require(before == legacy.get("messages") == read(directory / "history-prefix-after.json") and len(before) == history.get("oldMessageCount")
            and {message.get("role") for message in before} >= {"user", "assistant"}, "old conversation prefix changed")
    require(history.get("prefixSHA256") == digest(directory / "history-prefix-before.json"), "old message prefix digest differs")
    retained = read(directory / "other-conversations-before.json")
    reopened = read(directory / "conversations-after-reopen.json")
    require(retained and all(item in reopened for item in retained) and not any(item.get("id") == history["sessionID"] for item in reopened), "reopen lost other history or restored deletion")
    for flag in ("legacyFormatFixture", "deleteCancelled", "nativeDeleteConfirmed", "nativeSaveReopen", "otherConversationsPreserved"):
        require(history.get(flag) is True, "missing actual old-history observation: " + flag)
    require(history.get("liveAgent") is False and history.get("originalPackageSHA256")
            == history.get("originalPackageAfterSHA256") and history.get("originalPackageSHA256"), "original production changed")
    require(read(directory / "canonical-before.json") == read(directory / "canonical-after.json") and read(directory / "canonical-before.json"), "canonical production changed")
    fields = [action.get("field", {}) for action in entry["interactions"] if action.get("kind") == "text" and action.get("field", {}).get("id") == "agent.composer.input"]
    require(fields and history.get("renderedFontPointSize") == fields[-1].get("fontPointSize")
            and abs(fields[-1].get("fontPointSize", 0) - 13 * scale) < 0.5, "rendered composer font differs")
    return entry


def validate(directory, expected_scale=None):
    directory = Path(directory)
    entries = read(directory / "object-context-result.json")
    scales = [1.0, 1.25, 1.5] if expected_scale is None else [expected_scale]
    require(all(scale in (1.0, 1.25, 1.5) for scale in scales) and len(entries) == len(scales), "exact native object/context scales required")
    for entry, scale in zip(entries, scales):
        case = directory / f"object-context-{int(scale * 100)}"
        require(read(case / "object-context-result.json") == entry, "runtime aggregate differs from actual case result")
        validate_case(case, entry, scale)
    return entries


def validate_owner(directory, owner, expected_scale=None):
    actual_scale = owner.get("viewport", {}).get("textScale")
    require(actual_scale in (1.0, 1.25, 1.5) and (expected_scale is None or actual_scale == expected_scale), "owner scale differs from actual object/context case")
    entries = validate(directory, actual_scale)
    require(owner.get("objectContext") == entries, "actual owner report differs from object/context evidence")
    return entries


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--owner", type=Path)
    args = parser.parse_args()
    if args.owner:
        entries = validate_owner(args.evidence, read(args.owner))
    else:
        entries = validate(args.evidence)
