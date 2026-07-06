import Foundation

/// Schema version for `brief.yaml`. Port of `brief/schema.py::BRIEF_SCHEMA_VERSION`.
public let briefSchemaVersion = "brief/v1"

/// Question 1 — mission / distribution intent. Port of `brief/schema.py::Mission`.
public enum Mission: String, Codable, Sendable, CaseIterable {
    case singleRelease = "single_release"
    case socialPost = "social_post"
    case artPiece = "art_piece"
    case demo
    case other
}

/// Question 2 — output aspect ratio. Port of `brief/schema.py::AspectRatio`.
public enum AspectRatio: String, Codable, Sendable, CaseIterable {
    case landscape16x9 = "16:9"
    case vertical9x16 = "9:16"
    case square1x1 = "1:1"
    case portrait4x5 = "4:5"
    case landscape5x4 = "5:4"
    case landscape4x3 = "4:3"
    case portrait3x4 = "3:4"
    case landscape21x9 = "21:9"
    case vertical9x21 = "9:21"
    case other
}

/// Question 4 — concept type. Port of `brief/schema.py::ConceptType`.
public enum ConceptType: String, Codable, Sendable, CaseIterable {
    case narrative
    case performance
    case abstract
    case documentary
    case hybrid
    case other
}

/// Question 6 — figure presence. Port of `brief/schema.py::FigurePresence`.
public enum FigurePresence: String, Codable, Sendable, CaseIterable {
    case artistOnly = "artist_only"
    case artistPlusOthers = "artist_plus_others"
    case othersOnly = "others_only"
    case none
    case other
}

/// Question 7 — lyrics integration. Port of `brief/schema.py::LyricsIntegration`.
public enum LyricsIntegration: String, Codable, Sendable, CaseIterable {
    case literal
    case metaphorical
    case contrastive
    case ignored
    case other
}

/// Question 3 — video generation model preference. Port of `brief/schema.py::ModelPreference`.
public enum ModelPreference: String, Codable, Sendable, CaseIterable {
    case gen3aTurbo = "gen3a_turbo"
    case gen45 = "gen4.5"
    case seedance2
    case veo3
    case veo31Fast = "veo3.1_fast"
    case perShot = "per_shot"
    case other
}

/// Image model for Phase F (stills) and K5 (bible images). Namespaced
/// `<provider>:<internal_model>` so different access paths to the same
/// model stay distinguishable. Port of `brief/schema.py::FrameImageModel`.
public enum FrameImageModel: String, Codable, Sendable, CaseIterable {
    case googleGemini3Pro = "google:gemini-3-pro-image-preview"
    case googleGemini31Flash = "google:gemini-3.1-flash-image-preview"
    case googleImagen4Ultra = "google:imagen-4.0-ultra-generate-001"
    case openaiGptImage2 = "openai:gpt-image-2"
    case openaiGptImage1 = "openai:gpt-image-1"
    case runwayGemini3Pro = "runway:gemini_image3_pro"
    case runwayGemini31Flash = "runway:gemini_image3.1_flash"
    case runwayGemini25Flash = "runway:gemini_2.5_flash"
    case runwayGen4Image = "runway:gen4_image"
    case runwayGen4ImageTurbo = "runway:gen4_image_turbo"
    case falNanoBanana = "fal:fal-ai/nano-banana"
    case falImagen4Ultra = "fal:fal-ai/imagen4/preview/ultra"
    case falGptImage1 = "fal:fal-ai/gpt-image-1"
    case falFluxPro11 = "fal:fal-ai/flux-pro/v1.1"
    case other
}

/// Who performs stem separation. Port of `brief/schema.py::StemsProvider`.
public enum StemsProvider: String, Codable, Sendable, CaseIterable {
    case none
    case demucs
    case lalal
}

/// Visual medium / rendering register. Required, no default — an existing
/// `brief.yaml` without this field must fail to load so the revision loop
/// asks the question. Port of `brief/schema.py::VisualMedium`.
public enum VisualMedium: String, Codable, Sendable, CaseIterable {
    case liveActionRealistic = "live_action_realistic"
    case liveActionStylized = "live_action_stylized"
    case cg3d = "3d_cg"
    case animation2d = "2d_animation"
    case illustration
    case stopMotion = "stop_motion"
    case mixed
    case other
}

/// Final render-pass resolution. Port of `brief/schema.py::VideoResolution`.
public enum VideoResolution: String, Codable, Sendable, CaseIterable {
    case res720p = "720p"
    case res1080p = "1080p"
}

/// Preview render-pass strategy. Port of `brief/schema.py::PreviewMode`.
public enum PreviewMode: String, Codable, Sendable, CaseIterable {
    case skip
    case smallest
}

/// Post-render cut-handles strategy. Port of `brief/schema.py::CutHandlesMode`.
public enum CutHandlesMode: String, Codable, Sendable, CaseIterable {
    case withOverlap = "with_overlap"
    case backToBack = "back_to_back"
}

/// Question 5 — tone tags. Port of `brief/schema.py::ToneTag`.
public enum ToneTag: String, Codable, Sendable, CaseIterable {
    case melancholic
    case ironic
    case euphoric
    case dark
    case surreal
    case poetic
    case energetic
    case quiet
    case other
}

/// Brief (K1): the director's mandatory input before treatment, persisted as
/// `brief.yaml`. Port of `brief/schema.py::Brief`.
public struct Brief: Codable, Sendable, Equatable {
    public var schema: String
    public var project: String
    public var generated: String
    public var generator: String

    // Question 1 — mission / platform
    public var mission: Mission
    public var missionOther: String?
    public var targetPlatform: String
    public var targetAudience: String?

    // Question 2 — format
    public var aspectRatio: AspectRatio
    public var aspectRatioOther: String?
    public var lengthMode: String

    // Question 3 — technique
    public var projectMode: String
    public var modelPreference: ModelPreference
    public var modelPreferenceOther: String?
    public var frameImageModel: FrameImageModel
    public var frameImageModelOther: String?
    public var bibleImageModel: FrameImageModel?
    public var compositeImageModel: FrameImageModel?
    /// Python: `Annotated[float, Field(gt=0)] = 50.0`, enforced in `validate()`.
    public var budgetEur: Double

    // Question 4 — concept type
    public var conceptType: ConceptType
    public var conceptTypeOther: String?

    // Question 4a — visual medium (required, no default)
    public var visualMedium: VisualMedium
    public var visualMediumOther: String?
    public var visualMediumNotes: String?

    // Question 5 — tone & style
    public var tone: [ToneTag]
    public var toneOther: String?
    public var styleReferences: [String]

    // Question 6 — figures
    public var figures: FigurePresence
    public var figuresOther: String?
    public var figureCountHint: String?

    // Question 7 — lyrics integration
    public var lyricsIntegration: LyricsIntegration
    public var lyricsIntegrationOther: String?

    // Question 8 — chord analysis
    public var enableChordAnalysis: Bool

    // Question 9 — stem-separation provider
    public var stemsProvider: StemsProvider

    // Question 10 — final resolution
    public var finalResolution: VideoResolution

    // Question 11 — preview pass
    public var previewMode: PreviewMode

    // Question 12 — cut-handles mode
    public var cutHandlesMode: CutHandlesMode

    // Question 13 — director pattern (optional)
    public var directorPattern: String?

    // Genre-cross escape
    public var allowGenreCrossPatterns: Bool

    // Stylistic constraint
    public var allowTextOverlays: Bool

    public var notes: String?

    private enum CodingKeys: String, CodingKey {
        case schema
        case project
        case generated
        case generator
        case mission
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
        case conceptType = "concept_type"
        case conceptTypeOther = "concept_type_other"
        case visualMedium = "visual_medium"
        case visualMediumOther = "visual_medium_other"
        case visualMediumNotes = "visual_medium_notes"
        case tone
        case toneOther = "tone_other"
        case styleReferences = "style_references"
        case figures
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
        case notes
    }

    public init(
        schema: String = briefSchemaVersion,
        project: String,
        generated: String,
        generator: String = "brief-agent@v0.3",
        mission: Mission,
        missionOther: String? = nil,
        targetPlatform: String,
        targetAudience: String? = nil,
        aspectRatio: AspectRatio,
        aspectRatioOther: String? = nil,
        lengthMode: String = "full_song",
        projectMode: String,
        modelPreference: ModelPreference = .seedance2,
        modelPreferenceOther: String? = nil,
        frameImageModel: FrameImageModel = .googleGemini3Pro,
        frameImageModelOther: String? = nil,
        bibleImageModel: FrameImageModel? = nil,
        compositeImageModel: FrameImageModel? = nil,
        budgetEur: Double = 50.0,
        conceptType: ConceptType,
        conceptTypeOther: String? = nil,
        visualMedium: VisualMedium,
        visualMediumOther: String? = nil,
        visualMediumNotes: String? = nil,
        tone: [ToneTag] = [],
        toneOther: String? = nil,
        styleReferences: [String] = [],
        figures: FigurePresence,
        figuresOther: String? = nil,
        figureCountHint: String? = nil,
        lyricsIntegration: LyricsIntegration,
        lyricsIntegrationOther: String? = nil,
        enableChordAnalysis: Bool = false,
        stemsProvider: StemsProvider = .demucs,
        finalResolution: VideoResolution = .res1080p,
        previewMode: PreviewMode = .skip,
        cutHandlesMode: CutHandlesMode = .withOverlap,
        directorPattern: String? = nil,
        allowGenreCrossPatterns: Bool = false,
        allowTextOverlays: Bool = false,
        notes: String? = nil
    ) throws {
        self.schema = schema
        self.project = project
        self.generated = generated
        self.generator = generator
        self.mission = mission
        self.missionOther = missionOther
        self.targetPlatform = targetPlatform
        self.targetAudience = targetAudience
        self.aspectRatio = aspectRatio
        self.aspectRatioOther = aspectRatioOther
        self.lengthMode = lengthMode
        self.projectMode = projectMode
        self.modelPreference = modelPreference
        self.modelPreferenceOther = modelPreferenceOther
        self.frameImageModel = frameImageModel
        self.frameImageModelOther = frameImageModelOther
        self.bibleImageModel = bibleImageModel
        self.compositeImageModel = compositeImageModel
        self.budgetEur = budgetEur
        self.conceptType = conceptType
        self.conceptTypeOther = conceptTypeOther
        self.visualMedium = visualMedium
        self.visualMediumOther = visualMediumOther
        self.visualMediumNotes = visualMediumNotes
        self.tone = tone
        self.toneOther = toneOther
        self.styleReferences = styleReferences
        self.figures = figures
        self.figuresOther = figuresOther
        self.figureCountHint = figureCountHint
        self.lyricsIntegration = lyricsIntegration
        self.lyricsIntegrationOther = lyricsIntegrationOther
        self.enableChordAnalysis = enableChordAnalysis
        self.stemsProvider = stemsProvider
        self.finalResolution = finalResolution
        self.previewMode = previewMode
        self.cutHandlesMode = cutHandlesMode
        self.directorPattern = directorPattern
        self.allowGenreCrossPatterns = allowGenreCrossPatterns
        self.allowTextOverlays = allowTextOverlays
        self.notes = notes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? briefSchemaVersion
        project = try container.decode(String.self, forKey: .project)
        generated = try container.decode(String.self, forKey: .generated)
        generator = try container.decodeIfPresent(String.self, forKey: .generator) ?? "brief-agent@v0.3"

        mission = try container.decode(Mission.self, forKey: .mission)
        missionOther = try container.decodeIfPresent(String.self, forKey: .missionOther)
        targetPlatform = try container.decode(String.self, forKey: .targetPlatform)
        targetAudience = try container.decodeIfPresent(String.self, forKey: .targetAudience)

        aspectRatio = try container.decode(AspectRatio.self, forKey: .aspectRatio)
        aspectRatioOther = try container.decodeIfPresent(String.self, forKey: .aspectRatioOther)
        lengthMode = try container.decodeIfPresent(String.self, forKey: .lengthMode) ?? "full_song"

        projectMode = try container.decode(String.self, forKey: .projectMode)
        modelPreference = try container.decodeIfPresent(ModelPreference.self, forKey: .modelPreference) ?? .seedance2
        modelPreferenceOther = try container.decodeIfPresent(String.self, forKey: .modelPreferenceOther)
        frameImageModel =
            try container.decodeIfPresent(FrameImageModel.self, forKey: .frameImageModel) ?? .googleGemini3Pro
        frameImageModelOther = try container.decodeIfPresent(String.self, forKey: .frameImageModelOther)
        bibleImageModel = try container.decodeIfPresent(FrameImageModel.self, forKey: .bibleImageModel)
        compositeImageModel = try container.decodeIfPresent(FrameImageModel.self, forKey: .compositeImageModel)
        budgetEur = try container.decodeIfPresent(Double.self, forKey: .budgetEur) ?? 50.0

        conceptType = try container.decode(ConceptType.self, forKey: .conceptType)
        conceptTypeOther = try container.decodeIfPresent(String.self, forKey: .conceptTypeOther)

        visualMedium = try container.decode(VisualMedium.self, forKey: .visualMedium)
        visualMediumOther = try container.decodeIfPresent(String.self, forKey: .visualMediumOther)
        visualMediumNotes = try container.decodeIfPresent(String.self, forKey: .visualMediumNotes)

        tone = try container.decodeIfPresent([ToneTag].self, forKey: .tone) ?? []
        toneOther = try container.decodeIfPresent(String.self, forKey: .toneOther)
        styleReferences = try container.decodeIfPresent([String].self, forKey: .styleReferences) ?? []

        figures = try container.decode(FigurePresence.self, forKey: .figures)
        figuresOther = try container.decodeIfPresent(String.self, forKey: .figuresOther)
        figureCountHint = try container.decodeIfPresent(String.self, forKey: .figureCountHint)

        lyricsIntegration = try container.decode(LyricsIntegration.self, forKey: .lyricsIntegration)
        lyricsIntegrationOther = try container.decodeIfPresent(String.self, forKey: .lyricsIntegrationOther)

        enableChordAnalysis = try container.decodeIfPresent(Bool.self, forKey: .enableChordAnalysis) ?? false
        stemsProvider = try container.decodeIfPresent(StemsProvider.self, forKey: .stemsProvider) ?? .demucs
        finalResolution = try container.decodeIfPresent(VideoResolution.self, forKey: .finalResolution) ?? .res1080p
        previewMode = try container.decodeIfPresent(PreviewMode.self, forKey: .previewMode) ?? .skip
        cutHandlesMode = try container.decodeIfPresent(CutHandlesMode.self, forKey: .cutHandlesMode) ?? .withOverlap
        directorPattern = try container.decodeIfPresent(String.self, forKey: .directorPattern)
        allowGenreCrossPatterns =
            try container.decodeIfPresent(Bool.self, forKey: .allowGenreCrossPatterns) ?? false
        allowTextOverlays = try container.decodeIfPresent(Bool.self, forKey: .allowTextOverlays) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes)

        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case budgetNotPositive(Double)
        case visualMediumNotesRequired(VisualMedium)
    }

    /// Visual mediums other than `.liveActionRealistic` need a concrete style
    /// note (2D anime vs Adult Swim vs Ghibli, CG-Pixar vs CG-Arcane, etc.) —
    /// otherwise the treatment agent invents a generic variant that misses
    /// user intent. Port of `Brief._visual_medium_notes_required_for_stylized`.
    private static let visualMediumsNeedingNotes: Set<VisualMedium> = [
        .liveActionStylized,
        .cg3d,
        .animation2d,
        .illustration,
        .stopMotion,
        .mixed,
        .other,
    ]

    public func validate() throws {
        guard budgetEur > 0 else { throw ValidationError.budgetNotPositive(budgetEur) }
        if Self.visualMediumsNeedingNotes.contains(visualMedium) {
            guard let visualMediumNotes, !visualMediumNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ValidationError.visualMediumNotesRequired(visualMedium)
            }
        }
    }
}
