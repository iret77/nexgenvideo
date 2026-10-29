"""Check actual host intake files and native input logs independently of the pack manifest."""
import argparse
import hashlib
import json
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def local(directory, name):
    require(isinstance(name, str) and name and Path(name).name == name and not name.startswith("."), "unsafe intake evidence")
    path = directory / name
    require(path.is_file() and not path.is_symlink(), "missing intake evidence")
    return path


def read(directory, name):
    return json.loads(local(directory, name).read_text())


def observation(result, label):
    entries = [item.get("evidence", {}) for item in result["interactions"]
               if item.get("kind") == "verified-state" and item.get("label") == label]
    require(len(entries) == 1, "missing unique intake observation")
    return entries[0]


def native_steps(actions):
    steps = []
    for action in actions:
        kind = action.get("kind")
        if kind == "pointer" and action.get("id", "").startswith("agent.dialog."):
            steps.append(("pointer", action["id"]))
        elif kind == "file-panel": steps.append(("file", action.get("path")))
        elif kind == "file-panel-cancel": steps.append(("cancel",))
        elif kind == "text": steps.append(("text", action.get("field", {}).get("actual")))
    return steps


def validate(directory, report):
    directory = Path(directory)
    names = ["hostflow-track-lyrics-result.json", "hostflow-repeatable-intake-result.json"]
    require(report.get("nativeIntakeEvidence") == names, "missing native intake stages")
    results = [read(directory, name) for name in names]
    images = []
    for result in results:
        progress = read(directory, result["progress"])
        require(progress.get("failure") is None and progress.get("interactions") == result["interactions"]
                and progress.get("screenshots") == result["screenshots"], "intake interaction log differs")
        require(result["screenshots"], "missing intake images")
        for image in result["screenshots"]:
            path = local(directory, image)
            require(path.stat().st_size > 1000 and path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "invalid native intake image")
        images += result["screenshots"]
    require(len(images) == len(set(images)), "reused intake images")
    startup = observation(results[0], "native Track and optional Lyrics intake")
    require(startup.get("creativeIntakeAbsent") is True and startup.get("nextPhase") == "project_init"
            and type(startup.get("lyricsSupplied")) is bool and startup.get("trackName"), "startup order changed")
    digest = startup.get("trackSHA256", "")
    source_track = local(directory, "intake-track-source.bin").read_bytes()
    assigned_track = local(directory, "intake-track-assigned.bin").read_bytes()
    require(source_track and source_track == assigned_track and hashlib.sha256(source_track).hexdigest() == digest,
            "assigned song differs from the actual supplied bytes")
    require(sum(item.get("kind") == "pointer" and item.get("id") == "agent.dialog.confirm"
                for item in results[0]["interactions"]) == 2, "startup attachment decisions bypassed native input")
    files = [action for action in results[0]["interactions"] if action.get("kind") == "file-panel"]
    require(len(files) == 1 + int(startup["lyricsSupplied"]) and files[0].get("path") == startup["trackName"]
            and all(item.get("selectedURLVerified") is True and item.get("nativePathEditorVerified") is True for item in files), "startup bypassed native file selection")
    lyrics_name = startup.get("lyricsName")
    if startup["lyricsSupplied"]:
        require(isinstance(lyrics_name, str) and lyrics_name and Path(lyrics_name).name == lyrics_name
                and files[1].get("path") == lyrics_name, "lyrics selection differs from the supplied file")
    else:
        require(lyrics_name is None, "empty optional lyrics reported a supplied file")
    expected_start = [("pointer", "agent.dialog.choose-file"), ("file", startup["trackName"]),
                      ("pointer", "agent.dialog.confirm")]
    if startup["lyricsSupplied"]:
        expected_start += [("pointer", "agent.dialog.choose-file"), ("file", lyrics_name)]
    expected_start += [("pointer", "agent.dialog.confirm")]
    require(native_steps(results[0]["interactions"]) == expected_start, "startup file and confirmation order changed")
    repeated = observation(results[1], "native incomplete repeated location")
    require(repeated.get("firstName") == "Stage" and repeated.get("nextTitle") == "Prepared location 2"
            and repeated.get("partialName") == "Unfinished location", "wrong repeatable item")
    require(all(repeated.get(key) is True for key in ("fileWithoutNameBlocked", "partialAttachBlocked", "partialDoneBlocked",
            "clearPreservedConfirmedIdentity", "doneAdvancedToStyle")), "unfinished item bypassed intake")
    actions = results[1]["interactions"]
    pointers = [item.get("id") for item in actions if item.get("kind") == "pointer"]
    require(pointers.count("agent.dialog.choose-file") == 2 and pointers.count("agent.dialog.clear-item") == 1
            and pointers.count("agent.dialog.complete") == 1 and pointers.count("agent.dialog.confirm") == 1,
            "missing repeatable intake input")
    texts = [item.get("field", {}) for item in actions if item.get("kind") == "text"]
    require([(item.get("id"), item.get("expected"), item.get("actual")) for item in texts] == [
        ("agent.dialog.direction", "Stage", "Stage"),
        ("agent.dialog.direction", "Unfinished location", "Unfinished location")]
        and all(item.get("commitInput") == "Tab" for item in texts)
        and pointers.count("agent.dialog.direction") == 2, "identity name bypassed native text input")
    require(sum(item.get("kind") == "file-panel-cancel" for item in actions) == 1, "missing actual file cancellation")
    files = [item for item in actions if item.get("kind") == "file-panel"]
    require(len(files) == 1 and files[0].get("selectedURLVerified") is True
            and files[0].get("nativePathEditorVerified") is True, "missing actual location file selection")
    require(native_steps(actions) == [
        ("pointer", "agent.dialog.choose-file"), ("cancel",),
        ("pointer", "agent.dialog.choose-file"), ("file", files[0]["path"]),
        ("pointer", "agent.dialog.direction"), ("text", "Stage"), ("pointer", "agent.dialog.confirm"),
        ("pointer", "agent.dialog.direction"), ("text", "Unfinished location"),
        ("pointer", "agent.dialog.clear-item"), ("pointer", "agent.dialog.complete")],
        "repeated item confirmation bypassed or preceded native input")
    require(any(item.get("kind") == "visible-group" and set(item.get("ids", [])) == {
        "agent.dialog.confirm", "agent.dialog.complete", "agent.dialog.clear-item"} for item in actions), "incomplete item controls were not visible")
    before = read(directory, "intake-before-partial.json")
    after = read(directory, "intake-after-partial.json")
    require(before == after and before.get("schema") == "confirmed-identity-assets/v1", "partial item changed confirmed material")
    entries = list(before["entries"].values())
    require(len(entries) == 1, "unexpected confirmed identities")
    identity = entries[0]
    source = local(directory, "intake-location.png").read_bytes()
    confirmed = local(directory, "intake-confirmed-location.png").read_bytes()
    require(source == confirmed and hashlib.sha256(source).hexdigest() == repeated.get("sourceSHA256") == identity.get("sha256")
            and identity.get("id") == repeated.get("confirmedID") and identity.get("role") == "location"
            and identity.get("identity_name") == "Stage" and identity.get("identity_slug") == "stage", "confirmed location bytes or identity differ")
    return images


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    validate(args.evidence, read(args.evidence, "hostflow.json"))
