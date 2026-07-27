#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
KNOWN_ATTACH_AS = {"song", "lyrics", "script", "character", "location", "style"}
ENGINE_REGISTRY_STORED_PROPERTIES = [
    "checkRegistry",
    "phases",
    "phasePlacements",
    "durationPolicy",
    "libraries",
    "projectDirs",
    "uiContracts",
    "gateRequirements",
    "deterministicSteps",
    "wiringToken",
    "audioDecoder",
    "transcriber",
    "stemSeparator",
    "beatDetector",
    "chordRecognizer",
    "patternProvider",
    "referencePlanProvider",
    "cockpitSurfaces",
    "phaseLineageProviders",
]


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def load_json(path: Path) -> dict:
    try:
        label = str(path.relative_to(ROOT))
    except ValueError:
        label = str(path)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is unreadable or invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a JSON object")
    return value


def semantic_version(value: object, label: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or re.fullmatch(r"\d+\.\d+\.\d+", value) is None:
        fail(f"{label} must be X.Y.Z")
    return tuple(int(part) for part in value.split("."))


def validate_changelog(version: str) -> None:
    path = ROOT / "Sources/NexGenVideo/Resources/Changelog/changelog.json"
    feed = load_json(path)
    entries = feed.get("entries")
    if not isinstance(entries, list):
        fail("changelog.json entries must be an array")
    matches = [entry for entry in entries if isinstance(entry, dict) and entry.get("version") == version]
    if len(matches) != 1:
        fail(f"changelog.json must contain exactly one entry for {version}")
    sections = matches[0].get("sections")
    if not isinstance(sections, list) or not sections:
        fail(f"changelog entry {version} must contain at least one section")
    for index, section in enumerate(sections):
        items = section.get("items") if isinstance(section, dict) else None
        if not isinstance(items, list) or not items or not all(isinstance(item, str) and item.strip() for item in items):
            fail(f"changelog entry {version} section {index + 1} must contain non-empty items")


def validate_hardsteps() -> None:
    path = ROOT / "Sources/MusicvideoPlugin/Resources/MusicvideoPack/hardsteps.json"
    manifest = load_json(path)
    if manifest.get("schema") != "hardsteps/1.0":
        fail("musicvideo hardsteps.json must declare schema hardsteps/1.0")
    phases = manifest.get("phases")
    if not isinstance(phases, list) or not phases:
        fail("musicvideo hardsteps.json must contain phases")

    ids: set[str] = set()
    by_phase: dict[str, list[dict]] = {}
    for phase in phases:
        if not isinstance(phase, dict) or not isinstance(phase.get("phase"), str):
            fail("every hard-step phase needs a phase id")
        steps = phase.get("steps")
        if not isinstance(steps, list):
            fail(f"hard-step phase {phase['phase']} needs a steps array")
        by_phase.setdefault(phase["phase"], []).extend(steps)
        for step in steps:
            if not isinstance(step, dict):
                fail(f"hard-step phase {phase['phase']} contains a non-object step")
            step_id = step.get("id")
            attach_as = step.get("attachAs")
            if not isinstance(step_id, str) or not step_id.strip() or step_id in ids:
                fail(f"hard-step ids must be non-empty and unique: {step_id!r}")
            ids.add(step_id)
            if attach_as not in KNOWN_ATTACH_AS:
                fail(f"hard step {step_id} uses unsupported attachAs {attach_as!r}")
            if not isinstance(step.get("title"), str) or not step["title"].strip():
                fail(f"hard step {step_id} needs a title")

    startup = by_phase.get("project_init", [])
    songs = [step for step in startup if step.get("attachAs") == "song"]
    if len(songs) != 1 or songs[0].get("required") is not True or "audio" not in songs[0].get("accept", []):
        fail("project_init must contain exactly one required song step accepting audio")

    if [step.get("attachAs") for step in startup] != ["song", "lyrics"]:
        fail("project_init hard steps must be exactly: song, lyrics")
    if by_phase.get("analysis"):
        fail("analysis must not contain file intake")
    creative = by_phase.get("brief", [])
    if [step.get("attachAs") for step in creative] != ["script", "character", "location", "style"]:
        fail("brief hard steps must be exactly: script, character, location, style")
    if any(step.get("required") is True for step in startup[1:] + creative):
        fail("lyrics and every creative-material hard step must remain optional")


def validate_agent_guidance() -> None:
    try:
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        claude = (ROOT / "CLAUDE.md").read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"agent project guidance is unreadable: {error}")
    if agents != claude:
        fail("AGENTS.md and CLAUDE.md must contain the same standalone project guidance")
    if "@AGENTS.md" in agents or "@CLAUDE.md" in agents:
        fail("agent project guidance must not depend on cross-file include directives")


def validate_engine_registry_abi() -> None:
    path = ROOT / "Engine/Sources/NexGenEngine/Packs/EngineRegistry.swift"
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"EngineRegistry.swift is unreadable: {error}")
    class_start = source.find("public final class EngineRegistry")
    typealias_start = source.find("public typealias PhaseRunner", class_start)
    if class_start < 0 or typealias_start < 0:
        fail("EngineRegistry stored-property boundary is unreadable")
    declaration = source[class_start:typealias_start]
    properties = re.findall(
        r"^\s*public(?:\s+private\(set\))?\s+(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)",
        declaration,
        flags=re.MULTILINE,
    )
    if properties != ENGINE_REGISTRY_STORED_PROPERTIES:
        fail(
            "EngineRegistry stored-property order changed; separately compiled packs "
            "require existing properties to stay fixed and new properties to be appended. "
            f"Expected {ENGINE_REGISTRY_STORED_PROPERTIES}, got {properties}"
        )


def validate_release_assets() -> None:
    required = [
        ROOT / "assets/dmg-background.png",
        ROOT / "Sources/NexGenVideo/Resources/AppIcon.icns",
        ROOT / "scripts/dmg-settings.py",
        ROOT / "scripts/NexGenVideo.entitlements",
        ROOT / "plugins/musicvideo.json",
    ]
    missing = [str(path.relative_to(ROOT)) for path in required if not path.is_file()]
    if missing:
        fail(f"release assets are missing: {', '.join(missing)}")
    settings = ROOT / "scripts/dmg-settings.py"
    try:
        compile(settings.read_text(encoding="utf-8"), str(settings), "exec")
    except (OSError, UnicodeError, SyntaxError) as error:
        fail(f"scripts/dmg-settings.py is unreadable or invalid Python: {error}")


def validate_plugin_version(release_version: str, published_catalog: Path) -> None:
    manifest_path = ROOT / "plugins/musicvideo.json"
    manifest = load_json(manifest_path)
    pack_id = manifest.get("id")
    if not isinstance(pack_id, str) or not pack_id:
        fail("plugins/musicvideo.json needs a non-empty id")
    pack_version = semantic_version(
        manifest.get("version"),
        "plugins/musicvideo.json version",
    )
    pack_source = ROOT / "Sources/MusicvideoPlugin/MusicvideoPack.swift"
    try:
        source = pack_source.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"MusicvideoPack.swift is unreadable: {error}")
    source_match = re.search(r'public let version = "(\d+\.\d+\.\d+)"', source)
    if source_match is None or semantic_version(
        source_match.group(1), "MusicvideoPack.version"
    ) != pack_version:
        fail("MusicvideoPack.version must equal plugins/musicvideo.json version")
    min_app_match = re.search(
        r'let musicvideoMinAppVersion = "(\d+\.\d+\.\d+)"',
        source,
    )
    if min_app_match is None or min_app_match.group(1) != manifest.get("minAppVersion"):
        fail(
            "MusicvideoPack minAppVersion must equal "
            "plugins/musicvideo.json minAppVersion"
        )
    if manifest.get("minAppVersion") != release_version:
        fail(
            "plugins/musicvideo.json minAppVersion must equal the release version "
            f"{release_version}; got {manifest.get('minAppVersion')!r}"
        )

    catalog = load_json(published_catalog)
    entries = catalog.get("plugins")
    if not isinstance(entries, list):
        fail("published plugin catalog plugins must be an array")
    published_versions = [
        semantic_version(entry.get("version"), f"published {pack_id} version")
        for entry in entries
        if isinstance(entry, dict) and entry.get("id") == pack_id
    ]
    if published_versions and pack_version <= max(published_versions):
        newest = ".".join(str(part) for part in max(published_versions))
        local = ".".join(str(part) for part in pack_version)
        fail(
            f"{pack_id} pack version {local} must be newer than published {newest}; "
            "published pack versions are immutable"
        )


def main() -> None:
    if len(sys.argv) != 3 or re.fullmatch(r"\d+\.\d+\.\d+", sys.argv[1]) is None:
        fail("usage: release_preflight.py X.Y.Z /path/to/published-catalog.json")
    version = sys.argv[1]
    validate_changelog(version)
    validate_hardsteps()
    validate_agent_guidance()
    validate_engine_registry_abi()
    validate_release_assets()
    validate_plugin_version(version, Path(sys.argv[2]))
    print(
        f"Release preflight passed for {version}: "
        "changelog + agent guidance + pack intake/version + release assets"
    )


if __name__ == "__main__":
    main()
