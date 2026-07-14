import Foundation
import NexGenEngine

/// The agent-facing ranking result. Swift mirror of `pattern-recommendations/1.0`
/// (`schemas/pattern-fit-result.schema.json`). Nullable-but-required fields
/// (`score`, `rank`, `fit_score`, the slot ids) are always emitted — `null`
/// when absent — so a strict cross-language validator round-trips the payload.
public struct PatternRecommendationSet: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var projectProfileSha256: String
    public var policySha256: String
    public var scorerVersion: String
    public var scoreSemantics: String
    public var results: [PatternFitRecommendation]
    public var slots: RecommendationSlots
    public var missingHighImpactInputs: [MissingFitInput]
    public var questionsRequiredBeforeRanking: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case projectProfileSha256 = "project_profile_sha256"
        case policySha256 = "policy_sha256"
        case scorerVersion = "scorer_version"
        case scoreSemantics = "score_semantics"
        case results, slots
        case missingHighImpactInputs = "missing_high_impact_inputs"
        case questionsRequiredBeforeRanking = "questions_required_before_ranking"
    }

    public init(
        projectProfileSha256: String, policySha256: String, results: [PatternFitRecommendation],
        slots: RecommendationSlots, missingHighImpactInputs: [MissingFitInput],
        questionsRequiredBeforeRanking: Bool
    ) {
        schemaVersion = "pattern-recommendations/1.0"
        self.projectProfileSha256 = projectProfileSha256
        self.policySha256 = policySha256
        scorerVersion = "pattern-fit-scorer/1.0"
        scoreSemantics = "compatibility_index_not_probability"
        self.results = results
        self.slots = slots
        self.missingHighImpactInputs = missingHighImpactInputs
        self.questionsRequiredBeforeRanking = questionsRequiredBeforeRanking
    }
}

public struct PatternFitRecommendation: Codable, Sendable, Equatable {
    public var patternId: String
    public var patternName: String
    public var rank: Int?
    public var fitScore: Double?
    public var fitBand: FitBand
    public var confidence: Double
    public var inputCoverage: Double
    public var excluded: Bool
    public var exclusionReasons: [String]
    public var dimensions: [DimensionFitScore]
    public var strengths: [String]
    public var conflicts: [String]
    public var adaptations: [TriggeredAdaptation]
    public var why: String

    private enum CodingKeys: String, CodingKey {
        case patternId = "pattern_id"
        case patternName = "pattern_name"
        case rank
        case fitScore = "fit_score"
        case fitBand = "fit_band"
        case confidence
        case inputCoverage = "input_coverage"
        case excluded
        case exclusionReasons = "exclusion_reasons"
        case dimensions, strengths, conflicts, adaptations, why
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(patternId, forKey: .patternId)
        try c.encode(patternName, forKey: .patternName)
        try c.encode(rank, forKey: .rank)  // explicit null when unranked
        try c.encode(fitScore, forKey: .fitScore)  // explicit null when excluded
        try c.encode(fitBand, forKey: .fitBand)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(inputCoverage, forKey: .inputCoverage)
        try c.encode(excluded, forKey: .excluded)
        try c.encode(exclusionReasons, forKey: .exclusionReasons)
        try c.encode(dimensions, forKey: .dimensions)
        try c.encode(strengths, forKey: .strengths)
        try c.encode(conflicts, forKey: .conflicts)
        try c.encode(adaptations, forKey: .adaptations)
        try c.encode(why, forKey: .why)
    }
}

public struct DimensionFitScore: Codable, Sendable, Equatable {
    public var dimension: FitDimensionName
    public var score: Double?
    public var configuredWeight: Double
    public var scoredWeight: Double
    public var axes: [AxisFitScore]

    private enum CodingKeys: String, CodingKey {
        case dimension, score
        case configuredWeight = "configured_weight"
        case scoredWeight = "scored_weight"
        case axes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dimension, forKey: .dimension)
        try c.encode(score, forKey: .score)  // explicit null when nothing scored
        try c.encode(configuredWeight, forKey: .configuredWeight)
        try c.encode(scoredWeight, forKey: .scoredWeight)
        try c.encode(axes, forKey: .axes)
    }
}

public struct AxisFitScore: Codable, Sendable, Equatable {
    public var axis: FitAxis
    public var score: Double?
    public var globalWeight: Double
    public var inputConfidence: Double?
    public var evidenceConfidence: Double?
    public var resolution: AxisResolution
    public var explanation: String

    private enum CodingKeys: String, CodingKey {
        case axis, score
        case globalWeight = "global_weight"
        case inputConfidence = "input_confidence"
        case evidenceConfidence = "evidence_confidence"
        case resolution, explanation
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(axis, forKey: .axis)
        try c.encode(score, forKey: .score)
        try c.encode(globalWeight, forKey: .globalWeight)
        try c.encode(inputConfidence, forKey: .inputConfidence)
        try c.encode(evidenceConfidence, forKey: .evidenceConfidence)
        try c.encode(resolution, forKey: .resolution)
        try c.encode(explanation, forKey: .explanation)
    }
}

public struct TriggeredAdaptation: Codable, Sendable, Equatable {
    public var adaptationId: String
    public var actions: [AdaptationAction]
    public var fitCap: Double

    private enum CodingKeys: String, CodingKey {
        case adaptationId = "adaptation_id"
        case actions
        case fitCap = "fit_cap"
    }
}

public struct MissingFitInput: Codable, Sendable, Equatable {
    public var axis: FitAxis
    public var globalWeight: Double
    public var question: String

    private enum CodingKeys: String, CodingKey {
        case axis
        case globalWeight = "global_weight"
        case question
    }
}

public struct RecommendationSlots: Codable, Sendable, Equatable {
    public var bestOverallPatternId: String?
    public var productionEfficientPatternId: String?
    public var creativeStretchPatternId: String?

    private enum CodingKeys: String, CodingKey {
        case bestOverallPatternId = "best_overall_pattern_id"
        case productionEfficientPatternId = "production_efficient_pattern_id"
        case creativeStretchPatternId = "creative_stretch_pattern_id"
    }

    public init(
        bestOverallPatternId: String? = nil, productionEfficientPatternId: String? = nil,
        creativeStretchPatternId: String? = nil
    ) {
        self.bestOverallPatternId = bestOverallPatternId
        self.productionEfficientPatternId = productionEfficientPatternId
        self.creativeStretchPatternId = creativeStretchPatternId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bestOverallPatternId, forKey: .bestOverallPatternId)
        try c.encode(productionEfficientPatternId, forKey: .productionEfficientPatternId)
        try c.encode(creativeStretchPatternId, forKey: .creativeStretchPatternId)
    }
}
