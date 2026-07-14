import Foundation
import NexGenEngine

/// The runtime project profile, assembled from audio analysis, the persisted
/// Brief, explicit user statements and bounded agent inference. Swift mirror of
/// `project-fit/1.0` (`schemas/project-fit-profile.schema.json`). Every input
/// carries source and confidence; a missing input stays `nil` (never a guessed
/// midpoint).
public struct ProjectFitProfile: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var projectId: String
    public var matchMode: FitMatchMode
    public var audio: ProjectAudioFit
    public var creative: ProjectCreativeFit
    public var visual: ProjectVisualFit
    public var production: ProjectProductionFit
    public var excludedPatternIds: FitInput<[String]>?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case projectId = "project_id"
        case matchMode = "match_mode"
        case audio, creative, visual, production
        case excludedPatternIds = "excluded_pattern_ids"
    }

    public init(
        projectId: String, matchMode: FitMatchMode = .balanced, audio: ProjectAudioFit = .init(),
        creative: ProjectCreativeFit = .init(), visual: ProjectVisualFit = .init(),
        production: ProjectProductionFit = .init(), excludedPatternIds: FitInput<[String]>? = nil
    ) {
        schemaVersion = "project-fit/1.0"
        self.projectId = projectId
        self.matchMode = matchMode
        self.audio = audio
        self.creative = creative
        self.visual = visual
        self.production = production
        self.excludedPatternIds = excludedPatternIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "project-fit/1.0"
        projectId = try c.decode(String.self, forKey: .projectId)
        matchMode = try c.decodeIfPresent(FitMatchMode.self, forKey: .matchMode) ?? .balanced
        audio = try c.decodeIfPresent(ProjectAudioFit.self, forKey: .audio) ?? .init()
        creative = try c.decodeIfPresent(ProjectCreativeFit.self, forKey: .creative) ?? .init()
        visual = try c.decodeIfPresent(ProjectVisualFit.self, forKey: .visual) ?? .init()
        production = try c.decodeIfPresent(ProjectProductionFit.self, forKey: .production) ?? .init()
        excludedPatternIds = try c.decodeIfPresent(FitInput<[String]>.self, forKey: .excludedPatternIds)
    }
}

/// A single provenance-tagged project input.
public struct FitInput<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var value: Value
    public var source: FitInputSource
    public var confidence: Double
    public var userConfirmed: Bool

    private enum CodingKeys: String, CodingKey {
        case value, source, confidence
        case userConfirmed = "user_confirmed"
    }

    public init(value: Value, source: FitInputSource, confidence: Double, userConfirmed: Bool = false) {
        self.value = value
        self.source = source
        self.confidence = confidence
        self.userConfirmed = userConfirmed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(Value.self, forKey: .value)
        source = try c.decode(FitInputSource.self, forKey: .source)
        confidence = try c.decode(Double.self, forKey: .confidence)
        userConfirmed = try c.decodeIfPresent(Bool.self, forKey: .userConfirmed) ?? false
    }

    /// Hard gates and explicit exclusions may only rely on user-/Brief-confirmed
    /// data — agent inference can move a soft score but never veto a pattern.
    public var canVeto: Bool { source == .user || source == .brief }
}

public struct WeightedAffect: Codable, Sendable, Equatable {
    public var value: AffectTag
    public var weight: Double

    public init(value: AffectTag, weight: Double) {
        self.value = value
        self.weight = weight
    }
}

public struct ProjectAudioFit: Codable, Sendable, Equatable {
    public var perceivedBpm: FitInput<Double>?
    public var beatSalience: FitInput<OrdinalLevel>?
    public var onsetDensityHz: FitInput<Double>?
    public var rhythmicRegularity: FitInput<RhythmicRegularity>?
    public var sectionContrast: FitInput<Double>?
    public var energyLevel: FitInput<Double>?
    public var energyArc: FitInput<EnergyArc>?

    private enum CodingKeys: String, CodingKey {
        case perceivedBpm = "perceived_bpm"
        case beatSalience = "beat_salience"
        case onsetDensityHz = "onset_density_hz"
        case rhythmicRegularity = "rhythmic_regularity"
        case sectionContrast = "section_contrast"
        case energyLevel = "energy_level"
        case energyArc = "energy_arc"
    }

    public init(
        perceivedBpm: FitInput<Double>? = nil, beatSalience: FitInput<OrdinalLevel>? = nil,
        onsetDensityHz: FitInput<Double>? = nil, rhythmicRegularity: FitInput<RhythmicRegularity>? = nil,
        sectionContrast: FitInput<Double>? = nil, energyLevel: FitInput<Double>? = nil,
        energyArc: FitInput<EnergyArc>? = nil
    ) {
        self.perceivedBpm = perceivedBpm
        self.beatSalience = beatSalience
        self.onsetDensityHz = onsetDensityHz
        self.rhythmicRegularity = rhythmicRegularity
        self.sectionContrast = sectionContrast
        self.energyLevel = energyLevel
        self.energyArc = energyArc
    }
}

public struct ProjectCreativeFit: Codable, Sendable, Equatable {
    public var affects: FitInput<[WeightedAffect]>?
    public var conceptType: FitInput<ConceptType>?
    public var lyricsIntegration: FitInput<LyricsIntegration>?
    public var narrativeClarity: FitInput<Double>?
    public var figures: FitInput<FigurePresence>?
    public var performanceIntensity: FitInput<OrdinalLevel>?
    public var choreography: FitInput<OrdinalLevel>?
    public var directAddress: FitInput<OrdinalLevel>?
    public var crowdEnergy: FitInput<OrdinalLevel>?

    private enum CodingKeys: String, CodingKey {
        case affects
        case conceptType = "concept_type"
        case lyricsIntegration = "lyrics_integration"
        case narrativeClarity = "narrative_clarity"
        case figures
        case performanceIntensity = "performance_intensity"
        case choreography
        case directAddress = "direct_address"
        case crowdEnergy = "crowd_energy"
    }

    public init(
        affects: FitInput<[WeightedAffect]>? = nil, conceptType: FitInput<ConceptType>? = nil,
        lyricsIntegration: FitInput<LyricsIntegration>? = nil, narrativeClarity: FitInput<Double>? = nil,
        figures: FitInput<FigurePresence>? = nil, performanceIntensity: FitInput<OrdinalLevel>? = nil,
        choreography: FitInput<OrdinalLevel>? = nil, directAddress: FitInput<OrdinalLevel>? = nil,
        crowdEnergy: FitInput<OrdinalLevel>? = nil
    ) {
        self.affects = affects
        self.conceptType = conceptType
        self.lyricsIntegration = lyricsIntegration
        self.narrativeClarity = narrativeClarity
        self.figures = figures
        self.performanceIntensity = performanceIntensity
        self.choreography = choreography
        self.directAddress = directAddress
        self.crowdEnergy = crowdEnergy
    }
}

public struct ProjectVisualFit: Codable, Sendable, Equatable {
    public var visualMedium: FitInput<VisualMedium>?
    public var abstraction: FitInput<Double>?
    public var polish: FitInput<PolishLevel>?
    public var emotionalDistance: FitInput<EmotionalDistance>?

    private enum CodingKeys: String, CodingKey {
        case visualMedium = "visual_medium"
        case abstraction
        case polish
        case emotionalDistance = "emotional_distance"
    }

    public init(
        visualMedium: FitInput<VisualMedium>? = nil, abstraction: FitInput<Double>? = nil,
        polish: FitInput<PolishLevel>? = nil, emotionalDistance: FitInput<EmotionalDistance>? = nil
    ) {
        self.visualMedium = visualMedium
        self.abstraction = abstraction
        self.polish = polish
        self.emotionalDistance = emotionalDistance
    }
}

public struct ProjectProductionFit: Codable, Sendable, Equatable {
    public var budgetTier: FitInput<BudgetTier>?
    public var locationComplexity: FitInput<OrdinalLevel>?
    public var castScale: FitInput<OrdinalLevel>?
    public var choreographyComplexity: FitInput<OrdinalLevel>?
    public var vfxComplexity: FitInput<OrdinalLevel>?
    public var postComplexity: FitInput<OrdinalLevel>?
    public var availableCapabilities: FitInput<[ProductionCapability]>?
    public var constraints: FitInput<[ProjectConstraint]>?

    private enum CodingKeys: String, CodingKey {
        case budgetTier = "budget_tier"
        case locationComplexity = "location_complexity"
        case castScale = "cast_scale"
        case choreographyComplexity = "choreography_complexity"
        case vfxComplexity = "vfx_complexity"
        case postComplexity = "post_complexity"
        case availableCapabilities = "available_capabilities"
        case constraints
    }

    public init(
        budgetTier: FitInput<BudgetTier>? = nil, locationComplexity: FitInput<OrdinalLevel>? = nil,
        castScale: FitInput<OrdinalLevel>? = nil, choreographyComplexity: FitInput<OrdinalLevel>? = nil,
        vfxComplexity: FitInput<OrdinalLevel>? = nil, postComplexity: FitInput<OrdinalLevel>? = nil,
        availableCapabilities: FitInput<[ProductionCapability]>? = nil,
        constraints: FitInput<[ProjectConstraint]>? = nil
    ) {
        self.budgetTier = budgetTier
        self.locationComplexity = locationComplexity
        self.castScale = castScale
        self.choreographyComplexity = choreographyComplexity
        self.vfxComplexity = vfxComplexity
        self.postComplexity = postComplexity
        self.availableCapabilities = availableCapabilities
        self.constraints = constraints
    }
}
