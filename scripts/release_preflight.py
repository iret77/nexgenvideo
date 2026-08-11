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
    "projectSchemaMigrations",
    "progressPhaseRunners",
    "productionProfiles",
]
ENGINE_BOUNDARY_LAYOUT_CONTRACT = 5
ENGINE_BOUNDARY_COMPATIBILITY_FLOOR = 2
ENGINE_BOUNDARY_LAYOUTS = {
    "Shot": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public struct Shot: Codable, Sendable, Equatable {",
        "end": "    private enum CodingKeys: String, CodingKey {",
        "properties": [
            "id", "section", "timeStart", "timeEnd", "durationS", "type",
            "sourceMode", "description", "visualPrompt", "motion", "mood",
            "lyricsExcerpt", "characterRefs", "characterViews", "locationRef",
            "locationView", "modelSuggestion", "keyframeStrategy", "framing",
            "visibleZones", "zoneIntroduces", "cameraSetup", "characterBlocking",
            "propRefs", "propViews", "cameraId", "cameraLabel", "redo",
            "sceneVideoProvider", "seedanceInputMode", "referenceImageRefs",
            "chainWithPreviousEnd", "transitionIn", "transitionOut", "notes",
            "sourcePath",
        ],
    },
    "AuditContext": {
        "path": "Engine/Sources/NexGenEngine/Sanity/Audit.swift",
        "start": "public struct AuditContext: Sendable {",
        "end": "    public init(",
        "properties": [
            "shotlist", "brief", "bible", "extra",
        ],
    },
}
ENGINE_BOUNDARY_VALUE_LAYOUTS = {
    "CameraSetup": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public struct CameraSetup: Codable, Sendable, Equatable {",
        "end": "    private enum CodingKeys: String, CodingKey {",
        "members": [
            "var height: CameraHeight", "var angle: CameraAngle",
            "var lensHint: LensHint", "var note: String",
        ],
    },
    "CharacterBlocking": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public struct CharacterBlocking: Codable, Sendable, Equatable {",
        "end": "    private enum CodingKeys: String, CodingKey {",
        "members": [
            "var characterRef: String", "var position: String", "var pose: String",
            "var gaze: String", "var relationToSet: String",
        ],
    },
    "Song": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public struct Song: Codable, Sendable, Equatable {",
        "end": "    private enum CodingKeys: String, CodingKey {",
        "members": [
            "var title: String", "var artist: String?", "var audioPath: String",
            "var lyricsPath: String?", "var analysisPath: String", "var bpm: Double",
            "var tempoMultiplier: Double", "var durationS: Double",
        ],
    },
    "ProductionBlockingAnchor": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public struct ProductionBlockingAnchor: Codable, Sendable, Equatable {",
        "end": "    private enum CodingKeys: String, CodingKey {",
        "members": [
            "var characterRef: String", "var setAnchor: String",
        ],
    },
    "ShotProductionPlan": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public struct ShotProductionPlan: Codable, Sendable, Equatable {",
        "end": "    private enum CodingKeys: String, CodingKey {",
        "members": [
            "var primaryAction: String", "var cameraMovement: CameraMovement",
            "var cameraMovementDetail: String?", "var narrativeBeat: NarrativeBeat?",
            "var renderability: RenderabilityRating", "var risks: [RenderabilityRisk]",
            "var rescueCut: String?", "var matchActionCue: String?",
            "var continuityLocks: [String]",
            "var blockingAnchors: [ProductionBlockingAnchor]",
        ],
    },
    "Shotlist": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public struct Shotlist: Codable, Sendable, Equatable {",
        "end": "    private enum CodingKeys: String, CodingKey {",
        "members": [
            "var schema_: String", "var mode: Mode", "var project: String",
            "var song: Song", "var generated: String", "var generator: String",
            "var budgetEur: Double", "var shots: [Shot]", "var notes: String?",
        ],
    },
    "Finding": {
        "path": "Engine/Sources/NexGenEngine/Sanity/Models.swift",
        "start": "public struct Finding: Codable, Sendable, Equatable {",
        "end": "    public init(",
        "members": [
            "var level: Level", "var code: String", "var shotId: String?",
            "var message: String",
        ],
    },
    "ProductionProfileID": {
        "path": "Engine/Sources/NexGenEngine/Production/ProductionProfile.swift",
        "start": "public struct ProductionProfileID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {",
        "end": "    public init(rawValue:",
        "members": ["let rawValue: String"],
    },
    "ProductionProfile": {
        "path": "Engine/Sources/NexGenEngine/Production/ProductionProfile.swift",
        "start": "public struct ProductionProfile: Sendable, Equatable {",
        "end": "    public init(",
        "members": [
            "let id: ProductionProfileID",
            "let activation: ProductionProfileActivation",
        ],
    },
}
ENGINE_BOUNDARY_ENUM_LAYOUTS = {
    "Mode": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/ProjectMeta.swift",
        "start": "public enum Mode: String, Codable, Sendable, CaseIterable {",
        "end": "/// Project metadata",
        "cases": ["beat", "phrase", "section", "multicam", "generic  // Swift-side follow-up (issue #99); Python modes.py has no such case yet."],
    },
    "ShotType": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum ShotType: String, Codable, Sendable, CaseIterable {",
        "end": "/// Port of `shotlist/schema.py::ModelSuggestion`.",
        "cases": [
            "closeUp = \"close-up\"", "establishing", "highMotion = \"high-motion\"",
            "performance", "bRoll = \"b-roll\"",
        ],
    },
    "ModelSuggestion": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum ModelSuggestion: String, Codable, Sendable, CaseIterable {",
        "end": "/// How many keyframes",
        "cases": [
            "gen45 = \"gen-4.5\"", "seedance20 = \"seedance-2.0\"", "veo3",
            "veo31Fast = \"veo3.1_fast\"", "gen4Turbo = \"gen-4-turbo\"",
        ],
    },
    "KeyframeStrategy": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum KeyframeStrategy: String, Codable, Sendable, CaseIterable {",
        "end": "/// Per-shot selectable video provider.",
        "cases": ["none", "start", "startEnd = \"start_end\""],
    },
    "SceneVideoProvider": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum SceneVideoProvider: String, Codable, Sendable, CaseIterable {",
        "end": "/// How Seedance anchors",
        "cases": ["fal", "runway"],
    },
    "SeedanceInputMode": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum SeedanceInputMode: String, Codable, Sendable, CaseIterable {",
        "end": "/// Framing per shot.",
        "cases": ["keyframe", "reference"],
    },
    "Framing": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum Framing: String, Codable, Sendable, CaseIterable {",
        "end": "/// Camera height.",
        "cases": [
            "wide", "full", "ms", "mcu", "cu", "ecu", "ots", "pov", "insert",
            "aerial",
        ],
    },
    "CameraHeight": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum CameraHeight: String, Codable, Sendable, CaseIterable {",
        "end": "/// Camera axis to subject.",
        "cases": ["eyeLevel = \"eye_level\"", "low", "high", "overhead", "knee", "worm"],
    },
    "CameraAngle": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum CameraAngle: String, Codable, Sendable, CaseIterable {",
        "end": "/// Lens character",
        "cases": [
            "frontal", "threeQuarterLeft = \"three_quarter_left\"",
            "threeQuarterRight = \"three_quarter_right\"",
            "profileLeft = \"profile_left\"", "profileRight = \"profile_right\"",
            "back",
        ],
    },
    "LensHint": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum LensHint: String, Codable, Sendable, CaseIterable {",
        "end": "/// How a shot's footage is sourced.",
        "cases": ["wide", "normal", "long"],
    },
    "SourceMode": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum SourceMode: String, Codable, Sendable, CaseIterable {",
        "end": "    // How the shot's material COMES TO BE",
        "cases": ["generated", "imported", "aiEnhanced = \"ai_enhanced\""],
    },
    "TransitionType": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum TransitionType: String, Codable, Sendable, CaseIterable {",
        "end": "    /// A fade/crossfade needs overlap material",
        "cases": ["hardCut = \"hard_cut\"", "fade", "crossfade"],
    },
    "ProductionProfileActivation": {
        "path": "Engine/Sources/NexGenEngine/Production/ProductionProfile.swift",
        "start": "public enum ProductionProfileActivation: Sendable, Equatable {",
        "end": "    public func matches(",
        "cases": [
            "always",
            "metadataValue(key: String, allowedValues: Set<String>)",
        ],
    },
    "CameraMovement": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum CameraMovement: String, Codable, Sendable, CaseIterable {",
        "end": "    public func promptProse(",
        "cases": [
            "`static`", "pan", "tilt", "dollyIn = \"dolly_in\"",
            "dollyOut = \"dolly_out\"", "tracking", "handheld", "crane",
            "orbit", "zoom", "other",
        ],
    },
    "NarrativeBeat": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum NarrativeBeat: String, Codable, Sendable, CaseIterable, Hashable {",
        "end": "public enum RenderabilityRating:",
        "cases": [
            "establish", "action", "reaction", "detail", "transition",
            "performance", "atmosphere",
        ],
    },
    "RenderabilityRating": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum RenderabilityRating: String, Codable, Sendable, CaseIterable {",
        "end": "public enum RenderabilityRisk:",
        "cases": ["green", "yellow", "red"],
    },
    "RenderabilityRisk": {
        "path": "Engine/Sources/NexGenEngine/Artifacts/Shotlist.swift",
        "start": "public enum RenderabilityRisk: String, Codable, Sendable, CaseIterable, Hashable {",
        "end": "public struct ShotProductionPlan:",
        "cases": [
            "readableInFrameText = \"readable_in_frame_text\"",
            "mirrorReflection = \"mirror_reflection\"",
            "fineMotorHands = \"fine_motor_hands\"",
            "closeUpEatingDrinking = \"close_up_eating_drinking\"",
            "denseFaceCrowd = \"dense_face_crowd\"",
            "continuousFight = \"continuous_fight\"",
            "physicsShowcase = \"physics_showcase\"",
            "vehicleMechanics = \"vehicle_mechanics\"",
            "identityDrift = \"identity_drift\"",
            "nonEnglishLipSync = \"non_english_lip_sync\"",
            "longTake = \"long_take\"",
            "aggressiveCameraMove = \"aggressive_camera_move\"",
            "complexInteraction = \"complex_interaction\"",
        ],
    },
    "Level": {
        "path": "Engine/Sources/NexGenEngine/Sanity/Models.swift",
        "start": "public enum Level: String, Codable, Sendable, Equatable {",
        "end": "/// One sanity-check result.",
        "cases": ["info", "warn", "error"],
    },
}


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


def validate_engine_boundary_abi() -> None:
    contract_path = ROOT / "Engine/Sources/NexGenEngine/Packs/EngineContract.swift"
    try:
        contract = contract_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"EngineContract.swift is unreadable: {error}")
    current_match = re.search(r"public static let current = (\d+)", contract)
    minimum_match = re.search(r"public static let minimumCompatible = (\d+)", contract)
    if current_match is None or minimum_match is None:
        fail("EngineContract current/minimumCompatible declarations are unreadable")
    current = int(current_match.group(1))
    minimum = int(minimum_match.group(1))
    if current != ENGINE_BOUNDARY_LAYOUT_CONTRACT:
        fail(
            "Engine boundary layout guard must be reviewed for contract "
            f"{current}; it currently pins contract {ENGINE_BOUNDARY_LAYOUT_CONTRACT}"
        )
    if minimum != ENGINE_BOUNDARY_COMPATIBILITY_FLOOR:
        fail(
            "Engine minimumCompatible must match the public value-layout contract "
            f"{ENGINE_BOUNDARY_COMPATIBILITY_FLOOR}; got {minimum}"
        )

    for type_name, layout in ENGINE_BOUNDARY_LAYOUTS.items():
        path = ROOT / layout["path"]
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            fail(f"{layout['path']} is unreadable: {error}")
        start = source.find(layout["start"])
        end = source.find(layout["end"], start)
        if start < 0 or end < 0:
            fail(f"{type_name} stored-property boundary is unreadable")
        declaration = source[start:end]
        properties = re.findall(
            r"^\s*(?:(?:open|public|package|internal|fileprivate|private)"
            r"(?:\s*\(set\))?\s+)*(?:let|var)\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)\s*:",
            declaration,
            flags=re.MULTILINE,
        )
        if properties != layout["properties"]:
            fail(
                f"{type_name} stored-property layout changed without updating the "
                "engine boundary contract guard. "
                f"Expected {layout['properties']}, got {properties}"
            )

    for type_name, layout in ENGINE_BOUNDARY_VALUE_LAYOUTS.items():
        path = ROOT / layout["path"]
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            fail(f"{layout['path']} is unreadable: {error}")
        start = source.find(layout["start"])
        end = source.find(layout["end"], start)
        if start < 0 or end < 0:
            fail(f"{type_name} value-layout boundary is unreadable")
        declaration = source[start:end]
        members = [
            f"{kind} {name}: {' '.join(value_type.split())}"
            for kind, name, value_type in re.findall(
                r"^\s*(?:(?:open|public|package|internal|fileprivate|private)"
                r"(?:\s*\(set\))?\s+)*(let|var)\s+"
                r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^\n]+)",
                declaration,
                flags=re.MULTILINE,
            )
        ]
        if members != layout["members"]:
            fail(
                f"{type_name} public value layout changed without updating the "
                "engine boundary contract guard. "
                f"Expected {layout['members']}, got {members}"
            )

    for type_name, layout in ENGINE_BOUNDARY_ENUM_LAYOUTS.items():
        path = ROOT / layout["path"]
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            fail(f"{layout['path']} is unreadable: {error}")
        start = source.find(layout["start"])
        end = source.find(layout["end"], start)
        if start < 0 or end < 0:
            fail(f"{type_name} enum-layout boundary is unreadable")
        declaration = source[start:end]
        cases = re.findall(
            r"^    case\s+(.+?)\s*$",
            declaration,
            flags=re.MULTILINE,
        )
        if cases != layout["cases"]:
            fail(
                f"{type_name} cases changed without updating the engine boundary "
                f"contract guard. Expected {layout['cases']}, got {cases}"
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
    project_schema = manifest.get("projectSchema")
    if (
        not isinstance(project_schema, str)
        or re.fullmatch(re.escape(pack_id) + r"/\d+\.\d+\.\d+", project_schema) is None
    ):
        fail("plugins/musicvideo.json projectSchema must be <id>/X.Y.Z")
    migrates_from = manifest.get("migratesFrom")
    if (
        not isinstance(migrates_from, list)
        or not migrates_from
        or not all(
            isinstance(value, str)
            and re.fullmatch(
                re.escape(pack_id) + r"/(?:legacy|\d+\.\d+\.\d+)",
                value,
            )
            for value in migrates_from
        )
        or len(set(migrates_from)) != len(migrates_from)
        or project_schema in migrates_from
    ):
        fail("plugins/musicvideo.json migratesFrom is invalid")
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
    for source_schema in migrates_from:
        declaration = (
            'registerProjectSchemaMigration(\n'
            f'            from: "{source_schema}",\n'
            f'            to: "{project_schema}",'
        )
        if declaration not in source:
            fail(
                "MusicvideoPack must register every migration declared by "
                "plugins/musicvideo.json"
            )
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
    validate_engine_boundary_abi()
    validate_release_assets()
    validate_plugin_version(version, Path(sys.argv[2]))
    print(
        f"Release preflight passed for {version}: "
        "changelog + agent guidance + engine ABI + pack intake/version + release assets"
    )


if __name__ == "__main__":
    main()
