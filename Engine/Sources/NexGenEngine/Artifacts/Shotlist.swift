import Foundation

/// The technical shot-execution plan bridging song/storyboard to per-shot
/// generation. Port of `shotlist/schema.py`. `Mode` here is the shared core
/// enum (`ProjectMeta.swift`), not a local redefinition — Python's schema.py
/// literally re-exports `core.modes.Mode`.
public let shotlistSchemaVersion = "shotlist/v3"

/// Port of `shotlist/schema.py::SHOT_ID_RE`.
private let shotIDPattern = #"^s\d{3}$"#
/// Port of `shotlist/schema.py::CAMERA_ID_RE`.
private let cameraIDPattern = #"^cam\d{2}$"#
/// Port of `shotlist/schema.py::DURATION_EPSILON`.
public let shotlistDurationEpsilon = 1e-3
/// Port of the literal `0.5` tolerance in `_mode_specific_rules` for
/// multicam `time_end` vs. `song.duration_s` (distinct from `DURATION_EPSILON`).
private let multicamEndToleranceSeconds = 0.5

// MARK: - Enums (9 total: ShotType, ModelSuggestion, KeyframeStrategy,
// SceneVideoProvider, SeedanceInputMode, Framing, CameraHeight, CameraAngle,
// LensHint — re-derived directly from shotlist/schema.py; the task's
// estimate of 11 was incorrect).

/// Port of `shotlist/schema.py::ShotType`.
public enum ShotType: String, Codable, Sendable, CaseIterable {
    case closeUp = "close-up"
    case establishing
    case highMotion = "high-motion"
    case performance
    case bRoll = "b-roll"
}

/// Port of `shotlist/schema.py::ModelSuggestion`.
public enum ModelSuggestion: String, Codable, Sendable, CaseIterable {
    case gen45 = "gen-4.5"
    case seedance20 = "seedance-2.0"
    case veo3
    case veo31Fast = "veo3.1_fast"
    case gen4Turbo = "gen-4-turbo"
}

/// How many keyframes are rendered per shot and handed to the video provider.
/// Port of `shotlist/schema.py::KeyframeStrategy`.
public enum KeyframeStrategy: String, Codable, Sendable, CaseIterable {
    case none
    case start
    case startEnd = "start_end"
}

/// Per-shot selectable video provider. Port of `shotlist/schema.py::SceneVideoProvider`.
public enum SceneVideoProvider: String, Codable, Sendable, CaseIterable {
    case fal
    case runway
}

/// How Seedance anchors are supplied — keyframe and reference are mutually
/// exclusive model properties. Port of `shotlist/schema.py::SeedanceInputMode`.
public enum SeedanceInputMode: String, Codable, Sendable, CaseIterable {
    case keyframe
    case reference
}

/// Framing per shot. Port of `shotlist/schema.py::Framing`.
public enum Framing: String, Codable, Sendable, CaseIterable {
    case wide
    case full
    case ms
    case mcu
    case cu
    case ecu
    case ots
    case pov
    case insert
    case aerial
}

/// Camera height. Port of `shotlist/schema.py::CameraHeight`.
public enum CameraHeight: String, Codable, Sendable, CaseIterable {
    case eyeLevel = "eye_level"
    case low
    case high
    case overhead
    case knee
    case worm
}

/// Camera axis to subject. Port of `shotlist/schema.py::CameraAngle`.
public enum CameraAngle: String, Codable, Sendable, CaseIterable {
    case frontal
    case threeQuarterLeft = "three_quarter_left"
    case threeQuarterRight = "three_quarter_right"
    case profileLeft = "profile_left"
    case profileRight = "profile_right"
    case back
}

/// Lens character — affects compression, not focal length. Port of
/// `shotlist/schema.py::LensHint`.
public enum LensHint: String, Codable, Sendable, CaseIterable {
    case wide
    case normal
    case long
}

/// How a shot's footage is sourced. NexGenVideo is a full NLE: any shot may be
/// AI-generated, imported, or imported-then-AI-post-processed. The default is
/// `.generated` so every pre-existing shotlist decodes unchanged.
///
/// - `generated`: rendered by a provider (the classic image/video pipeline).
/// - `imported`: pre-existing footage the user brings in (usually live action,
///   but any content form: animation, screencast, archive). For material still
///   to be shot the assistant emits directorial specs
///   (framing/camera/light/blocking/style refs), never a generation prompt.
///   Never provider-rendered.
/// - `aiEnhanced`: imported live footage carried through a provider
///   video-to-video pass (the existing "AI Edit" path). Provider-billed.
public enum SourceMode: String, Codable, Sendable, CaseIterable {
    case generated
    case imported
    case aiEnhanced = "ai_enhanced"

    // How the shot's material COMES TO BE — not what its content IS (that's the
    // Brief's visual_medium axis). "live_action" was the 0.7.0 spelling; accept
    // it as a legacy alias so early shotlists keep decoding.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "live_action" { self = .imported; return }
        guard let mode = SourceMode(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown source_mode '\(raw)'"))
        }
        self = mode
    }
}

// MARK: - Structs

/// Camera triplet per shot. Port of `shotlist/schema.py::CameraSetup`.
public struct CameraSetup: Codable, Sendable, Equatable {
    public var height: CameraHeight
    public var angle: CameraAngle
    public var lensHint: LensHint
    public var note: String

    private enum CodingKeys: String, CodingKey {
        case height
        case angle
        case lensHint = "lens_hint"
        case note
    }

    public init(height: CameraHeight, angle: CameraAngle, lensHint: LensHint = .normal, note: String = "") {
        self.height = height
        self.angle = angle
        self.lensHint = lensHint
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        height = try container.decode(CameraHeight.self, forKey: .height)
        angle = try container.decode(CameraAngle.self, forKey: .angle)
        lensHint = try container.decodeIfPresent(LensHint.self, forKey: .lensHint) ?? .normal
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// Structured pose+position+gaze per character per shot. Port of
/// `shotlist/schema.py::CharacterBlocking`.
public struct CharacterBlocking: Codable, Sendable, Equatable {
    /// Must be present in the owning `Shot.characterRefs`.
    public var characterRef: String
    public var position: String
    public var pose: String
    public var gaze: String
    public var relationToSet: String

    private enum CodingKeys: String, CodingKey {
        case characterRef = "character_ref"
        case position
        case pose
        case gaze
        case relationToSet = "relation_to_set"
    }

    public init(
        characterRef: String, position: String, pose: String, gaze: String, relationToSet: String = ""
    ) throws {
        self.characterRef = characterRef
        self.position = position
        self.pose = pose
        self.gaze = gaze
        self.relationToSet = relationToSet
        try Self.validate(position: position, pose: pose, gaze: gaze)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        characterRef = try container.decode(String.self, forKey: .characterRef)
        position = try container.decode(String.self, forKey: .position)
        pose = try container.decode(String.self, forKey: .pose)
        gaze = try container.decode(String.self, forKey: .gaze)
        relationToSet = try container.decodeIfPresent(String.self, forKey: .relationToSet) ?? ""
        try Self.validate(position: position, pose: pose, gaze: gaze)
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case emptyPosition
        case emptyPose
        case emptyGaze
    }

    /// Mirrors pydantic's `Field(min_length=1)` on position/pose/gaze.
    private static func validate(position: String, pose: String, gaze: String) throws {
        guard !position.isEmpty else { throw ValidationError.emptyPosition }
        guard !pose.isEmpty else { throw ValidationError.emptyPose }
        guard !gaze.isEmpty else { throw ValidationError.emptyGaze }
    }
}

/// Port of `shotlist/schema.py::Song`.
public struct Song: Codable, Sendable, Equatable {
    public var title: String
    public var artist: String?
    public var audioPath: String
    public var lyricsPath: String?
    public var analysisPath: String
    public var bpm: Double
    public var tempoMultiplier: Double
    public var durationS: Double

    private enum CodingKeys: String, CodingKey {
        case title
        case artist
        case audioPath = "audio_path"
        case lyricsPath = "lyrics_path"
        case analysisPath = "analysis_path"
        case bpm
        case tempoMultiplier = "tempo_multiplier"
        case durationS = "duration_s"
    }

    public init(
        title: String, artist: String? = nil, audioPath: String, lyricsPath: String? = nil,
        analysisPath: String, bpm: Double, tempoMultiplier: Double = 1.0, durationS: Double
    ) throws {
        self.title = title
        self.artist = artist
        self.audioPath = audioPath
        self.lyricsPath = lyricsPath
        self.analysisPath = analysisPath
        self.bpm = bpm
        self.tempoMultiplier = tempoMultiplier
        self.durationS = durationS
        try Self.validate(bpm: bpm, durationS: durationS)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        audioPath = try container.decode(String.self, forKey: .audioPath)
        lyricsPath = try container.decodeIfPresent(String.self, forKey: .lyricsPath)
        analysisPath = try container.decode(String.self, forKey: .analysisPath)
        bpm = try container.decode(Double.self, forKey: .bpm)
        tempoMultiplier = try container.decodeIfPresent(Double.self, forKey: .tempoMultiplier) ?? 1.0
        durationS = try container.decode(Double.self, forKey: .durationS)
        try Self.validate(bpm: bpm, durationS: durationS)
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case bpmNotPositive(Double)
        case durationNotPositive(Double)
    }

    private static func validate(bpm: Double, durationS: Double) throws {
        guard bpm > 0 else { throw ValidationError.bpmNotPositive(bpm) }
        guard durationS > 0 else { throw ValidationError.durationNotPositive(durationS) }
    }

    /// Port of `Song.perceived_bpm`. Prefer this over `bpm` — the user-confirmed
    /// perceived tempo.
    public var perceivedBpm: Double { bpm * tempoMultiplier }
}

/// One shot. Port of `shotlist/schema.py::Shot`.
public struct Shot: Codable, Sendable, Equatable {
    public var id: String
    /// nil in multicam mode (and optionally in phrase mode).
    public var section: String?
    public var timeStart: Double
    public var timeEnd: Double
    public var durationS: Double
    public var type: ShotType
    public var sourceMode: SourceMode
    public var description: String
    public var visualPrompt: String
    public var motion: String?
    public var mood: String
    public var lyricsExcerpt: String?
    public var characterRefs: [String]
    public var characterViews: [String: String]
    public var locationRef: String?
    public var locationView: String?
    public var modelSuggestion: ModelSuggestion?
    public var keyframeStrategy: KeyframeStrategy
    public var framing: Framing?
    public var visibleZones: [String]
    public var zoneIntroduces: [String]
    public var cameraSetup: CameraSetup?
    public var characterBlocking: [CharacterBlocking]
    public var propRefs: [String]
    public var propViews: [String: String]
    public var cameraId: String?
    public var cameraLabel: String?
    public var redo: Bool
    public var sceneVideoProvider: SceneVideoProvider
    public var seedanceInputMode: SeedanceInputMode
    public var referenceImageRefs: [String]
    public var chainWithPreviousEnd: Bool
    public var notes: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case section
        case timeStart = "time_start"
        case timeEnd = "time_end"
        case durationS = "duration_s"
        case type
        case sourceMode = "source_mode"
        case description
        case visualPrompt = "visual_prompt"
        case motion
        case mood
        case lyricsExcerpt = "lyrics_excerpt"
        case characterRefs = "character_refs"
        case characterViews = "character_views"
        case locationRef = "location_ref"
        case locationView = "location_view"
        case modelSuggestion = "model_suggestion"
        case keyframeStrategy = "keyframe_strategy"
        case framing
        case visibleZones = "visible_zones"
        case zoneIntroduces = "zone_introduces"
        case cameraSetup = "camera_setup"
        case characterBlocking = "character_blocking"
        case propRefs = "prop_refs"
        case propViews = "prop_views"
        case cameraId = "camera_id"
        case cameraLabel = "camera_label"
        case redo
        case sceneVideoProvider = "scene_video_provider"
        case seedanceInputMode = "seedance_input_mode"
        case referenceImageRefs = "reference_image_refs"
        case chainWithPreviousEnd = "chain_with_previous_end"
        case notes
    }

    public init(
        id: String, section: String? = nil, timeStart: Double, timeEnd: Double, durationS: Double,
        type: ShotType, sourceMode: SourceMode = .generated, description: String, visualPrompt: String,
        motion: String? = nil, mood: String,
        lyricsExcerpt: String? = nil, characterRefs: [String] = [], characterViews: [String: String] = [:],
        locationRef: String? = nil, locationView: String? = nil, modelSuggestion: ModelSuggestion? = nil,
        keyframeStrategy: KeyframeStrategy = .start, framing: Framing? = nil, visibleZones: [String] = [],
        zoneIntroduces: [String] = [], cameraSetup: CameraSetup? = nil,
        characterBlocking: [CharacterBlocking] = [], propRefs: [String] = [],
        propViews: [String: String] = [:], cameraId: String? = nil, cameraLabel: String? = nil,
        redo: Bool = false, sceneVideoProvider: SceneVideoProvider = .fal,
        seedanceInputMode: SeedanceInputMode = .keyframe, referenceImageRefs: [String] = [],
        chainWithPreviousEnd: Bool = false, notes: String? = nil
    ) throws {
        self.id = id
        self.section = section
        self.timeStart = timeStart
        self.timeEnd = timeEnd
        self.durationS = durationS
        self.type = type
        self.sourceMode = sourceMode
        self.description = description
        self.visualPrompt = visualPrompt
        self.motion = motion
        self.mood = mood
        self.lyricsExcerpt = lyricsExcerpt
        self.characterRefs = characterRefs
        self.characterViews = characterViews
        self.locationRef = locationRef
        self.locationView = locationView
        self.modelSuggestion = modelSuggestion
        self.keyframeStrategy = keyframeStrategy
        self.framing = framing
        self.visibleZones = visibleZones
        self.zoneIntroduces = zoneIntroduces
        self.cameraSetup = cameraSetup
        self.characterBlocking = characterBlocking
        self.propRefs = propRefs
        self.propViews = propViews
        self.cameraId = cameraId
        self.cameraLabel = cameraLabel
        self.redo = redo
        self.sceneVideoProvider = sceneVideoProvider
        self.seedanceInputMode = seedanceInputMode
        self.referenceImageRefs = referenceImageRefs
        self.chainWithPreviousEnd = chainWithPreviousEnd
        self.notes = notes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        section = try container.decodeIfPresent(String.self, forKey: .section)
        timeStart = try container.decode(Double.self, forKey: .timeStart)
        timeEnd = try container.decode(Double.self, forKey: .timeEnd)
        durationS = try container.decode(Double.self, forKey: .durationS)
        type = try container.decode(ShotType.self, forKey: .type)
        sourceMode = try container.decodeIfPresent(SourceMode.self, forKey: .sourceMode) ?? .generated
        description = try container.decode(String.self, forKey: .description)
        visualPrompt = try container.decode(String.self, forKey: .visualPrompt)
        motion = try container.decodeIfPresent(String.self, forKey: .motion)
        mood = try container.decode(String.self, forKey: .mood)
        lyricsExcerpt = try container.decodeIfPresent(String.self, forKey: .lyricsExcerpt)
        characterRefs = try container.decodeIfPresent([String].self, forKey: .characterRefs) ?? []
        characterViews =
            try container.decodeIfPresent([String: String].self, forKey: .characterViews) ?? [:]
        locationRef = try container.decodeIfPresent(String.self, forKey: .locationRef)
        locationView = try container.decodeIfPresent(String.self, forKey: .locationView)
        modelSuggestion = try container.decodeIfPresent(ModelSuggestion.self, forKey: .modelSuggestion)
        keyframeStrategy =
            try container.decodeIfPresent(KeyframeStrategy.self, forKey: .keyframeStrategy) ?? .start
        framing = try container.decodeIfPresent(Framing.self, forKey: .framing)
        visibleZones = try container.decodeIfPresent([String].self, forKey: .visibleZones) ?? []
        zoneIntroduces = try container.decodeIfPresent([String].self, forKey: .zoneIntroduces) ?? []
        cameraSetup = try container.decodeIfPresent(CameraSetup.self, forKey: .cameraSetup)
        characterBlocking =
            try container.decodeIfPresent([CharacterBlocking].self, forKey: .characterBlocking) ?? []
        propRefs = try container.decodeIfPresent([String].self, forKey: .propRefs) ?? []
        propViews = try container.decodeIfPresent([String: String].self, forKey: .propViews) ?? [:]
        cameraId = try container.decodeIfPresent(String.self, forKey: .cameraId)
        cameraLabel = try container.decodeIfPresent(String.self, forKey: .cameraLabel)
        redo = try container.decodeIfPresent(Bool.self, forKey: .redo) ?? false
        sceneVideoProvider =
            try container.decodeIfPresent(SceneVideoProvider.self, forKey: .sceneVideoProvider) ?? .fal
        seedanceInputMode =
            try container.decodeIfPresent(SeedanceInputMode.self, forKey: .seedanceInputMode) ?? .keyframe
        referenceImageRefs =
            try container.decodeIfPresent([String].self, forKey: .referenceImageRefs) ?? []
        chainWithPreviousEnd =
            try container.decodeIfPresent(Bool.self, forKey: .chainWithPreviousEnd) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case invalidShotId(String)
        case invalidCameraId(String)
        case timeStartNegative(id: String, timeStart: Double)
        case timeEndNotAfterStart(id: String, timeStart: Double, timeEnd: Double)
        case durationInconsistent(id: String, durationS: Double, implied: Double)
        case blockingRefNotInCharacterRefs(id: String, ref: String, characterRefs: [String])
    }

    /// Port of `Shot._shot_id_pattern`, `_camera_id_pattern`, the `time_start`
    /// `Field(ge=0)` constraint, `_check_times`, `_blocking_refs_valid`.
    public func validate() throws {
        guard id.range(of: shotIDPattern, options: .regularExpression) != nil else {
            throw ValidationError.invalidShotId(id)
        }
        if let cameraId, cameraId.range(of: cameraIDPattern, options: .regularExpression) == nil {
            throw ValidationError.invalidCameraId(cameraId)
        }
        guard timeStart >= 0 else {
            throw ValidationError.timeStartNegative(id: id, timeStart: timeStart)
        }
        guard timeEnd > timeStart else {
            throw ValidationError.timeEndNotAfterStart(id: id, timeStart: timeStart, timeEnd: timeEnd)
        }
        let implied = timeEnd - timeStart
        guard abs(implied - durationS) <= shotlistDurationEpsilon else {
            throw ValidationError.durationInconsistent(id: id, durationS: durationS, implied: implied)
        }
        if !characterBlocking.isEmpty {
            let refSet = Set(characterRefs)
            for cb in characterBlocking where !refSet.contains(cb.characterRef) {
                throw ValidationError.blockingRefNotInCharacterRefs(
                    id: id, ref: cb.characterRef, characterRefs: characterRefs
                )
            }
        }
    }
}

/// The shotlist. Port of `shotlist/schema.py::Shotlist`.
public struct Shotlist: Codable, Sendable, Equatable {
    /// No default — Python declares this a required field
    /// (`schema_: str = Field(alias="schema")`, no default value), unlike
    /// Bible/Storyboard's `schema` which do default.
    public var schema_: String
    public var mode: Mode
    public var project: String
    public var song: Song
    public var generated: String
    public var generator: String
    public var budgetEur: Double
    public var shots: [Shot]
    public var notes: String?

    private enum CodingKeys: String, CodingKey {
        case schema_ = "schema"
        case mode
        case project
        case song
        case generated
        case generator
        case budgetEur = "budget_eur"
        case shots
        case notes
    }

    public init(
        schema_: String, mode: Mode, project: String, song: Song, generated: String, generator: String,
        budgetEur: Double = 50.0, shots: [Shot], notes: String? = nil
    ) throws {
        self.schema_ = schema_
        self.mode = mode
        self.project = project
        self.song = song
        self.generated = generated
        self.generator = generator
        self.budgetEur = budgetEur
        self.shots = shots
        self.notes = notes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema_ = try container.decode(String.self, forKey: .schema_)
        mode = try container.decode(Mode.self, forKey: .mode)
        project = try container.decode(String.self, forKey: .project)
        song = try container.decode(Song.self, forKey: .song)
        generated = try container.decode(String.self, forKey: .generated)
        generator = try container.decode(String.self, forKey: .generator)
        budgetEur = try container.decodeIfPresent(Double.self, forKey: .budgetEur) ?? 50.0
        shots = try container.decode([Shot].self, forKey: .shots)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case unknownSchema(String)
        case emptyShots
        case duplicateShotIds([String])
        case nonSequentialShotIds(expected: [String], actual: [String])
        case budgetNotPositive(Double)
        // mode == .multicam
        case multicamMissingCameraId(shotId: String)
        case multicamDuplicateCameraIds([String])
        case multicamTimeStartNotZero(shotId: String, timeStart: Double)
        case multicamTimeEndNotAtSongDuration(shotId: String, timeEnd: Double, songDuration: Double)
        // mode != .multicam
        case cameraFieldsSetOutsideMulticam(shotId: String, mode: Mode)
        case missingSectionLabel(shotId: String, mode: Mode)
    }

    /// Port of `Shotlist._schema_const`, `_shot_ids_sequential`,
    /// `_mode_specific_rules`, and the `budget_eur` `Field(gt=0)` constraint.
    public func validate() throws {
        // v1/v2 are tolerant legacy reads; newer fields (framing, visible_zones,
        // zone_introduces added in v3) are optional, so old files still load.
        guard ["shotlist/v3", "shotlist/v2", "shotlist/v1"].contains(schema_) else {
            throw ValidationError.unknownSchema(schema_)
        }
        guard budgetEur > 0 else { throw ValidationError.budgetNotPositive(budgetEur) }
        guard !shots.isEmpty else { throw ValidationError.emptyShots }

        let ids = shots.map(\.id)
        guard Set(ids).count == ids.count else { throw ValidationError.duplicateShotIds(ids) }
        let expected = (1...ids.count).map { String(format: "s%03d", $0) }
        guard ids == expected else {
            throw ValidationError.nonSequentialShotIds(expected: expected, actual: ids)
        }

        if mode == .multicam {
            var cameraIds: [String] = []
            for shot in shots {
                guard let cameraId = shot.cameraId else {
                    throw ValidationError.multicamMissingCameraId(shotId: shot.id)
                }
                cameraIds.append(cameraId)
                guard abs(shot.timeStart) <= shotlistDurationEpsilon else {
                    throw ValidationError.multicamTimeStartNotZero(shotId: shot.id, timeStart: shot.timeStart)
                }
                guard abs(shot.timeEnd - song.durationS) <= multicamEndToleranceSeconds else {
                    throw ValidationError.multicamTimeEndNotAtSongDuration(
                        shotId: shot.id, timeEnd: shot.timeEnd, songDuration: song.durationS
                    )
                }
            }
            guard Set(cameraIds).count == cameraIds.count else {
                throw ValidationError.multicamDuplicateCameraIds(cameraIds)
            }
        } else {
            for shot in shots {
                guard shot.cameraId == nil, shot.cameraLabel == nil else {
                    throw ValidationError.cameraFieldsSetOutsideMulticam(shotId: shot.id, mode: mode)
                }
                // Phrase mode is the documented exception: not every phrase
                // belongs to an official section label (e.g. instrumental phrases).
                if mode != .phrase, shot.section == nil {
                    throw ValidationError.missingSectionLabel(shotId: shot.id, mode: mode)
                }
            }
        }
    }
}

// MARK: - IO (versioned shotlist/vN.yaml family)

/// Port of `shotlist/schema.py::latest_version`. Highest N among
/// `shotlist/vN.yaml`, or nil if none exist.
public func latestShotlistVersion(dataRoot: URL) -> Int? {
    let dir = PipelineLayout.url(PipelineLayout.shotlistDir, in: dataRoot)
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ) else { return nil }
    return latestShotlistVersion(among: entries.map(\.lastPathComponent))
}

/// Pure helper over filenames, split out for testability without a real
/// filesystem. Mirrors `SHOTLIST_VERSION_RE` matched against `p.stem`.
func latestShotlistVersion(among filenames: [String]) -> Int? {
    let pattern = #"^v(\d+)\.yaml$"#
    let versions: [Int] = filenames.compactMap { name in
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(name[range])
        let digits = matched.dropFirst().dropLast(5)  // strip "v" prefix and ".yaml" suffix
        return Int(digits)
    }
    return versions.max()
}

/// Port of `shotlist/schema.py::save`. With no `version`, writes the next
/// free N (latest + 1, or 1). Writes only `vN.yaml` — shotlist has no
/// `current.yaml` mirror, unlike storyboard/treatment.
@discardableResult
public func saveShotlist(_ shotlist: Shotlist, to dataRoot: URL, version: Int? = nil) throws -> URL {
    let resolvedVersion: Int
    if let version {
        resolvedVersion = version
    } else {
        resolvedVersion = (latestShotlistVersion(dataRoot: dataRoot) ?? 0) + 1
    }
    let relativePath = PipelineLayout.shotlistVersionFile(resolvedVersion)
    try YAMLArtifactStore(dataRoot: dataRoot).save(shotlist, to: relativePath)
    return PipelineLayout.url(relativePath, in: dataRoot)
}

/// Port of `shotlist/schema.py::load`. Loads the highest existing version, or
/// nil if none exist (Optional return, not throwing).
public func loadShotlist(dataRoot: URL) throws -> Shotlist? {
    guard let version = latestShotlistVersion(dataRoot: dataRoot) else { return nil }
    let relativePath = PipelineLayout.shotlistVersionFile(version)
    return try YAMLArtifactStore(dataRoot: dataRoot).load(Shotlist.self, at: relativePath)
}
