import Foundation
import NexGenEngine

/// A pattern's authored fit profile — the mandatory `fit_profile` block of a
/// Pattern YAML. Swift mirror of `pattern-fit/1.0`
/// (`schemas/pattern-fit-profile.schema.json`). Describes sweet spots,
/// compatible uses, deliberate stretches, avoidances, hard production
/// requirements and adaptations. Every operative axis references evidence IDs.
public struct PatternFitProfile: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var patternId: String
    public var patternKind: FitPatternKind
    public var styleFamilies: [StyleFamily]
    public var evidence: [FitEvidence]
    public var affectEnergy: AffectEnergyFit
    public var conceptStory: ConceptStoryFit
    public var subjectPerformance: SubjectPerformanceFit
    public var mediumAesthetic: MediumAestheticFit
    public var rhythmEdit: RhythmEditFit
    public var production: ProductionFit
    public var hardConstraints: HardConstraints
    public var adaptations: [AdaptationRule]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case patternId = "pattern_id"
        case patternKind = "pattern_kind"
        case styleFamilies = "style_families"
        case evidence
        case affectEnergy = "affect_energy"
        case conceptStory = "concept_story"
        case subjectPerformance = "subject_performance"
        case mediumAesthetic = "medium_aesthetic"
        case rhythmEdit = "rhythm_edit"
        case production
        case hardConstraints = "hard_constraints"
        case adaptations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "pattern-fit/1.0"
        patternId = try c.decode(String.self, forKey: .patternId)
        patternKind = try c.decode(FitPatternKind.self, forKey: .patternKind)
        styleFamilies = try c.decode([StyleFamily].self, forKey: .styleFamilies)
        evidence = try c.decode([FitEvidence].self, forKey: .evidence)
        affectEnergy = try c.decode(AffectEnergyFit.self, forKey: .affectEnergy)
        conceptStory = try c.decode(ConceptStoryFit.self, forKey: .conceptStory)
        subjectPerformance = try c.decode(SubjectPerformanceFit.self, forKey: .subjectPerformance)
        mediumAesthetic = try c.decode(MediumAestheticFit.self, forKey: .mediumAesthetic)
        rhythmEdit = try c.decode(RhythmEditFit.self, forKey: .rhythmEdit)
        production = try c.decode(ProductionFit.self, forKey: .production)
        hardConstraints = try c.decode(HardConstraints.self, forKey: .hardConstraints)
        adaptations = try c.decodeIfPresent([AdaptationRule].self, forKey: .adaptations) ?? []
    }
}

// MARK: - Evidence, conditions, adaptations, hard constraints

public struct FitEvidence: Codable, Sendable, Equatable {
    public var evidenceId: String
    public var basis: EvidenceBasis
    public var sources: [String]
    public var measurementArtifactSha256: [String]
    public var measurementFieldPaths: [String]
    public var note: String?

    private enum CodingKeys: String, CodingKey {
        case evidenceId = "evidence_id"
        case basis
        case sources
        case measurementArtifactSha256 = "measurement_artifact_sha256"
        case measurementFieldPaths = "measurement_field_paths"
        case note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        evidenceId = try c.decode(String.self, forKey: .evidenceId)
        basis = try c.decode(EvidenceBasis.self, forKey: .basis)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        measurementArtifactSha256 = try c.decodeIfPresent([String].self, forKey: .measurementArtifactSha256) ?? []
        measurementFieldPaths = try c.decodeIfPresent([String].self, forKey: .measurementFieldPaths) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

public struct FitCondition: Codable, Sendable, Equatable {
    public enum Operator: String, Codable, Sendable, CaseIterable {
        case equals
        case `in`
        case below
        case above
    }

    public var axis: FitAxis
    public var op: Operator
    public var values: [String]
    public var threshold: Double?

    private enum CodingKeys: String, CodingKey {
        case axis
        case op = "operator"
        case values
        case threshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        axis = try c.decode(FitAxis.self, forKey: .axis)
        op = try c.decode(Operator.self, forKey: .op)
        values = try c.decodeIfPresent([String].self, forKey: .values) ?? []
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold)
    }
}

public struct AdaptationAction: Codable, Sendable, Equatable {
    public var lever: PipelineLever
    public var directive: String
}

public struct AdaptationRule: Codable, Sendable, Equatable {
    public var adaptationId: String
    public var when: FitCondition
    public var actions: [AdaptationAction]
    public var maximumRecommendedFit: Double
    public var evidenceIds: [String]

    private enum CodingKeys: String, CodingKey {
        case adaptationId = "adaptation_id"
        case when
        case actions
        case maximumRecommendedFit = "maximum_recommended_fit"
        case evidenceIds = "evidence_ids"
    }
}

public struct HardConstraints: Codable, Sendable, Equatable {
    public var requiredVisualMediums: [VisualMedium]
    public var requiredCapabilities: [ProductionCapability]
    public var incompatibleProjectConstraints: [ProjectConstraint]
    public var evidenceIds: [String]

    private enum CodingKeys: String, CodingKey {
        case requiredVisualMediums = "required_visual_mediums"
        case requiredCapabilities = "required_capabilities"
        case incompatibleProjectConstraints = "incompatible_project_constraints"
        case evidenceIds = "evidence_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requiredVisualMediums = try c.decodeIfPresent([VisualMedium].self, forKey: .requiredVisualMediums) ?? []
        requiredCapabilities = try c.decodeIfPresent([ProductionCapability].self, forKey: .requiredCapabilities) ?? []
        incompatibleProjectConstraints =
            try c.decodeIfPresent([ProjectConstraint].self, forKey: .incompatibleProjectConstraints) ?? []
        evidenceIds = try c.decodeIfPresent([String].self, forKey: .evidenceIds) ?? []
    }
}

// MARK: - Fit primitives

public struct NumericRange: Codable, Sendable, Equatable {
    public var min: Double
    public var max: Double

    public func contains(_ value: Double) -> Bool { value >= min && value <= max }
}

/// The five categorical buckets a value can land in, in resolution order.
public enum FitBucket: String, Sendable, Equatable {
    case ideal, compatible, stretch, avoid, unlisted
}

/// A categorical axis fit: nested `ideal ⊇ compatible ⊇ stretch ⊇ avoid` lists
/// over the axis's enum, plus evidence. Unlisted values fall through to
/// `unlisted`. Contract `CategoricalFit[T]`.
public struct CategoricalFit<Element: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var ideal: [Element]
    public var compatible: [Element]
    public var stretch: [Element]
    public var avoid: [Element]
    public var evidenceIds: [String]

    private enum CodingKeys: String, CodingKey {
        case ideal, compatible, stretch, avoid
        case evidenceIds = "evidence_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ideal = try c.decodeIfPresent([Element].self, forKey: .ideal) ?? []
        compatible = try c.decodeIfPresent([Element].self, forKey: .compatible) ?? []
        stretch = try c.decodeIfPresent([Element].self, forKey: .stretch) ?? []
        avoid = try c.decodeIfPresent([Element].self, forKey: .avoid) ?? []
        evidenceIds = try c.decode([String].self, forKey: .evidenceIds)
    }

    /// Resolve a value against this axis in the fixed order ideal → compatible →
    /// stretch → avoid → unlisted. Empty overlap is `unlisted`, never `ideal`.
    public func bucket(for value: Element) -> FitBucket {
        if ideal.contains(value) { return .ideal }
        if compatible.contains(value) { return .compatible }
        if stretch.contains(value) { return .stretch }
        if avoid.contains(value) { return .avoid }
        return .unlisted
    }
}

/// A continuous axis fit: `ideal ⊆ compatible ⊆ usable` numeric ranges plus
/// evidence. Contract `ContinuousFit`.
public struct ContinuousFit: Codable, Sendable, Equatable {
    public var ideal: NumericRange
    public var compatible: NumericRange
    public var usable: NumericRange
    public var evidenceIds: [String]

    private enum CodingKeys: String, CodingKey {
        case ideal, compatible, usable
        case evidenceIds = "evidence_ids"
    }

    /// `ideal` → ideal; else within `compatible` → compatible; else within
    /// `usable` → stretch; else outside `usable` → avoid (a conflict).
    public func bucket(for value: Double) -> FitBucket {
        if ideal.contains(value) { return .ideal }
        if compatible.contains(value) { return .compatible }
        if usable.contains(value) { return .stretch }
        return .avoid
    }
}

// MARK: - Dimension fit blocks

public struct AffectEnergyFit: Codable, Sendable, Equatable {
    public var affects: CategoricalFit<AffectTag>
    public var energyLevel: ContinuousFit
    public var energyArc: CategoricalFit<EnergyArc>

    private enum CodingKeys: String, CodingKey {
        case affects
        case energyLevel = "energy_level"
        case energyArc = "energy_arc"
    }
}

public struct ConceptStoryFit: Codable, Sendable, Equatable {
    public var conceptType: CategoricalFit<ConceptType>
    public var lyricsIntegration: CategoricalFit<LyricsIntegration>
    public var narrativeClarity: ContinuousFit

    private enum CodingKeys: String, CodingKey {
        case conceptType = "concept_type"
        case lyricsIntegration = "lyrics_integration"
        case narrativeClarity = "narrative_clarity"
    }
}

public struct SubjectPerformanceFit: Codable, Sendable, Equatable {
    public var figures: CategoricalFit<FigurePresence>
    public var performanceIntensity: CategoricalFit<OrdinalLevel>
    public var choreography: CategoricalFit<OrdinalLevel>
    public var directAddress: CategoricalFit<OrdinalLevel>
    public var crowdEnergy: CategoricalFit<OrdinalLevel>

    private enum CodingKeys: String, CodingKey {
        case figures
        case performanceIntensity = "performance_intensity"
        case choreography
        case directAddress = "direct_address"
        case crowdEnergy = "crowd_energy"
    }
}

public struct MediumAestheticFit: Codable, Sendable, Equatable {
    public var visualMedium: CategoricalFit<VisualMedium>
    public var abstraction: ContinuousFit
    public var polish: CategoricalFit<PolishLevel>
    public var emotionalDistance: CategoricalFit<EmotionalDistance>

    private enum CodingKeys: String, CodingKey {
        case visualMedium = "visual_medium"
        case abstraction
        case polish
        case emotionalDistance = "emotional_distance"
    }
}

public struct RhythmEditFit: Codable, Sendable, Equatable {
    public var perceivedBpm: ContinuousFit
    public var beatSalience: CategoricalFit<OrdinalLevel>
    public var onsetDensityHz: ContinuousFit
    public var rhythmicRegularity: CategoricalFit<RhythmicRegularity>
    public var sectionContrast: ContinuousFit

    private enum CodingKeys: String, CodingKey {
        case perceivedBpm = "perceived_bpm"
        case beatSalience = "beat_salience"
        case onsetDensityHz = "onset_density_hz"
        case rhythmicRegularity = "rhythmic_regularity"
        case sectionContrast = "section_contrast"
    }
}

public struct ProductionFit: Codable, Sendable, Equatable {
    public var budgetTier: CategoricalFit<BudgetTier>
    public var locationComplexity: CategoricalFit<OrdinalLevel>
    public var castScale: CategoricalFit<OrdinalLevel>
    public var choreographyComplexity: CategoricalFit<OrdinalLevel>
    public var vfxComplexity: CategoricalFit<OrdinalLevel>
    public var postComplexity: CategoricalFit<OrdinalLevel>

    private enum CodingKeys: String, CodingKey {
        case budgetTier = "budget_tier"
        case locationComplexity = "location_complexity"
        case castScale = "cast_scale"
        case choreographyComplexity = "choreography_complexity"
        case vfxComplexity = "vfx_complexity"
        case postComplexity = "post_complexity"
    }
}
