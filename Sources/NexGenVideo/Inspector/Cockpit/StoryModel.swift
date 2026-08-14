import Foundation

// Mirrors the engine's `brief` / `treatment` / `contract` read kinds. Defensive decoding: the app
// shows what exists and never invents fields; enums arrive as raw strings.

/// The complete engine `Brief`, field for field. The user approves this artifact, so the app must be
/// able to show all of it — a partial mirror silently hides decisions the pipeline acts on.
struct BriefData: Decodable, Sendable, Equatable {
    var schema: String?
    var generated: String?
    var generator: String?

    var project: String
    var mission: String
    var missionOther: String?
    var targetPlatform: String
    var targetAudience: String?

    var aspectRatio: String
    var aspectRatioOther: String?
    var lengthMode: String

    var projectMode: String
    var modelPreference: String?
    var modelPreferenceOther: String?
    var frameImageModel: String?
    var frameImageModelOther: String?
    var bibleImageModel: String?
    var compositeImageModel: String?
    var budgetEur: Double
    var budgetStopEur: Double?

    var conceptType: String?
    var conceptTypeOther: String?

    var visualMedium: String
    var visualMediumOther: String?
    var visualMediumNotes: String?

    var tone: [String]
    var toneOther: String?
    var styleReferences: [String]

    var figures: String?
    var figuresOther: String?
    var figureCountHint: String?

    var lyricsIntegration: String?
    var lyricsIntegrationOther: String?

    var enableChordAnalysis: Bool?
    var stemsProvider: String?
    var finalResolution: String?
    var previewMode: String?
    var cutHandlesMode: String?
    var directorPattern: String?
    var allowGenreCrossPatterns: Bool?
    var allowTextOverlays: Bool?

    var notes: String?

    enum CodingKeys: String, CodingKey {
        case schema, project, generated, generator, mission, tone, figures, notes
        case missionOther = "mission_other"
        case targetPlatform = "target_platform"
        case targetAudience = "target_audience"
        case aspectRatio = "aspect_ratio"
        case aspectRatioOther = "aspect_ratio_other"
        case lengthMode = "length_mode"
        case projectMode = "project_mode"
        case modelPreference = "model_preference"
        case modelPreferenceOther = "model_preference_other"
        case frameImageModel = "frame_image_model"
        case frameImageModelOther = "frame_image_model_other"
        case bibleImageModel = "bible_image_model"
        case compositeImageModel = "composite_image_model"
        case budgetEur = "budget_eur"
        case budgetStopEur = "budget_stop_eur"
        case conceptType = "concept_type"
        case conceptTypeOther = "concept_type_other"
        case visualMedium = "visual_medium"
        case visualMediumOther = "visual_medium_other"
        case visualMediumNotes = "visual_medium_notes"
        case toneOther = "tone_other"
        case styleReferences = "style_references"
        case figuresOther = "figures_other"
        case figureCountHint = "figure_count_hint"
        case lyricsIntegration = "lyrics_integration"
        case lyricsIntegrationOther = "lyrics_integration_other"
        case enableChordAnalysis = "enable_chord_analysis"
        case stemsProvider = "stems_provider"
        case finalResolution = "final_resolution"
        case previewMode = "preview_mode"
        case cutHandlesMode = "cut_handles_mode"
        case directorPattern = "director_pattern"
        case allowGenreCrossPatterns = "allow_genre_cross_patterns"
        case allowTextOverlays = "allow_text_overlays"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant ONLY for the display-only additions: one odd extra field shouldn't cost the whole
        // brief. The core below stays STRICT — `briefUnreadable` fires on a decode failure, and that
        // banner is the only thing standing between a legacy/corrupt brief and a Story tab that shows
        // it as nearly empty, which reads as "the brief says almost nothing" instead of "unreadable".
        func str(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func num(_ key: CodingKeys) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil }
        func flag(_ key: CodingKeys) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil }
        func list(_ key: CodingKeys) -> [String] {
            ((try? c.decodeIfPresent([String].self, forKey: key)) ?? nil) ?? []
        }

        schema = str(.schema)
        generated = str(.generated)
        generator = str(.generator)

        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        mission = try c.decodeIfPresent(String.self, forKey: .mission) ?? ""
        missionOther = str(.missionOther)
        targetPlatform = try c.decodeIfPresent(String.self, forKey: .targetPlatform) ?? ""
        targetAudience = str(.targetAudience)

        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio) ?? ""
        aspectRatioOther = str(.aspectRatioOther)
        lengthMode = try c.decodeIfPresent(String.self, forKey: .lengthMode) ?? ""

        projectMode = try c.decodeIfPresent(String.self, forKey: .projectMode) ?? ""
        modelPreference = str(.modelPreference)
        modelPreferenceOther = str(.modelPreferenceOther)
        frameImageModel = str(.frameImageModel)
        frameImageModelOther = str(.frameImageModelOther)
        bibleImageModel = str(.bibleImageModel)
        compositeImageModel = str(.compositeImageModel)
        budgetEur = try c.decodeIfPresent(Double.self, forKey: .budgetEur) ?? 0
        budgetStopEur = num(.budgetStopEur)

        conceptType = str(.conceptType)
        conceptTypeOther = str(.conceptTypeOther)

        visualMedium = try c.decodeIfPresent(String.self, forKey: .visualMedium) ?? ""
        visualMediumOther = str(.visualMediumOther)
        visualMediumNotes = str(.visualMediumNotes)

        tone = list(.tone)
        toneOther = str(.toneOther)
        styleReferences = list(.styleReferences)

        figures = str(.figures)
        figuresOther = str(.figuresOther)
        figureCountHint = str(.figureCountHint)

        lyricsIntegration = str(.lyricsIntegration)
        lyricsIntegrationOther = str(.lyricsIntegrationOther)

        enableChordAnalysis = flag(.enableChordAnalysis)
        stemsProvider = str(.stemsProvider)
        finalResolution = str(.finalResolution)
        previewMode = str(.previewMode)
        cutHandlesMode = str(.cutHandlesMode)
        directorPattern = str(.directorPattern)
        allowGenreCrossPatterns = flag(.allowGenreCrossPatterns)
        allowTextOverlays = flag(.allowTextOverlays)

        notes = str(.notes)
    }
}

struct TreatmentData: Decodable, Sendable, Equatable {
    var version: Int
    var bodyMarkdown: String

    enum CodingKeys: String, CodingKey {
        case meta
        case bodyMarkdown = "body_markdown"
    }

    private struct Meta: Decodable {
        var version: Int?
        enum CodingKeys: String, CodingKey { case version }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try? c.decodeIfPresent(Int.self, forKey: .version)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? c.decodeIfPresent(Meta.self, forKey: .meta)) ?? nil)?.version ?? 1
        bodyMarkdown = try c.decodeIfPresent(String.self, forKey: .bodyMarkdown) ?? ""
    }
}

/// The per-phase UI contract (surface + task class) — drives phase routing in the Pipeline panel —
/// plus any pack-contributed cockpit surfaces.
struct ContractData: Decodable, Sendable, Equatable {
    var phases: [String: ContractEntry]
    var cockpitSurfaces: [CockpitSurfaceData]

    enum CodingKeys: String, CodingKey { case phases; case cockpitSurfaces = "cockpit_surfaces" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phases = try c.decodeIfPresent([String: ContractEntry].self, forKey: .phases) ?? [:]
        let declared = try c.decodeIfPresent(
            [CockpitSurfaceData].self,
            forKey: .cockpitSurfaces
        ) ?? []
        cockpitSurfaces = Array(declared.prefix(1))
    }
}

struct CockpitSurfaceData: Decodable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var symbol: String
    var phase: String
    var dataFile: String
    var layout: [CockpitSurfacePrimitiveData]

    enum CodingKeys: String, CodingKey {
        case id, title, symbol, phase, layout
        case dataFile = "data_file"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.dashed"
        phase = try c.decode(String.self, forKey: .phase)
        dataFile = try c.decode(String.self, forKey: .dataFile)
        layout = try c.decode([CockpitSurfacePrimitiveData].self, forKey: .layout)
        guard !id.isEmpty, !title.isEmpty, !phase.isEmpty,
              !dataFile.isEmpty, !layout.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .layout,
                in: c,
                debugDescription: "A cockpit surface requires identity, data, and layout."
            )
        }
    }
}

enum CockpitValueFormatData: String, Decodable, Sendable, Equatable {
    case text
    case fileName
    case duration
    case bpm
    case count
}

enum CockpitBindingVisibilityData: String, Decodable, Sendable, Equatable {
    case always
    case whenPresent
    case whenCanonicalSections
}

struct CockpitValueBindingData: Decodable, Sendable, Equatable {
    var label: String
    var field: String
    var format: CockpitValueFormatData
    var factorField: String?
    var visibility: CockpitBindingVisibilityData

    enum CodingKeys: String, CodingKey {
        case label, field, format, visibility
        case factorField = "factor_field"
    }
}

enum CockpitSurfacePrimitiveData: Decodable, Sendable, Equatable {
    case statRow(items: [CockpitValueBindingData])
    case beatTimeline(
        title: String,
        durationField: String,
        beatsField: String,
        downbeatsField: String,
        sectionsField: String,
        sectionsVisibility: CockpitBindingVisibilityData
    )
    case sectionList(
        title: String,
        sectionsField: String,
        visibility: CockpitBindingVisibilityData
    )
    case keyValue(title: String?, items: [CockpitValueBindingData])

    private enum PrimitiveType: String, Decodable {
        case statRow
        case beatTimeline
        case sectionList
        case keyValue
    }

    private enum CodingKeys: String, CodingKey {
        case type, title, items, visibility
        case durationField = "duration_field"
        case beatsField = "beats_field"
        case downbeatsField = "downbeats_field"
        case sectionsField = "sections_field"
        case sectionsVisibility = "sections_visibility"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(PrimitiveType.self, forKey: .type) {
        case .statRow:
            self = .statRow(items: try c.decode([CockpitValueBindingData].self, forKey: .items))
        case .beatTimeline:
            self = .beatTimeline(
                title: try c.decode(String.self, forKey: .title),
                durationField: try c.decode(String.self, forKey: .durationField),
                beatsField: try c.decode(String.self, forKey: .beatsField),
                downbeatsField: try c.decode(String.self, forKey: .downbeatsField),
                sectionsField: try c.decode(String.self, forKey: .sectionsField),
                sectionsVisibility: try c.decode(
                    CockpitBindingVisibilityData.self,
                    forKey: .sectionsVisibility
                )
            )
        case .sectionList:
            self = .sectionList(
                title: try c.decode(String.self, forKey: .title),
                sectionsField: try c.decode(String.self, forKey: .sectionsField),
                visibility: try c.decode(
                    CockpitBindingVisibilityData.self,
                    forKey: .visibility
                )
            )
        case .keyValue:
            self = .keyValue(
                title: try c.decodeIfPresent(String.self, forKey: .title),
                items: try c.decode([CockpitValueBindingData].self, forKey: .items)
            )
        }
    }
}

struct ContractEntry: Decodable, Sendable, Equatable {
    var surface: String
    var taskClass: String

    enum CodingKeys: String, CodingKey {
        case surface
        case taskClass = "task_class"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decodeIfPresent(String.self, forKey: .surface) ?? ""
        taskClass = try c.decodeIfPresent(String.self, forKey: .taskClass) ?? ""
    }
}
