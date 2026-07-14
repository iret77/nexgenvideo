import Foundation
import NexGenEngine

/// The frozen scoring policy. Swift mirror of `pattern-fit-policy/1.0`
/// (`contracts/pattern-fit-policy.v1.json`). Weights, category values, evidence
/// factors, thresholds and match-mode behaviour live here, loaded from the
/// committed JSON — never hardcoded in the scorer or an agent prompt.
public struct PatternFitPolicy: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var policyId: String
    public var scorerVersion: String
    public var categoryScores: FitCategoryScores
    public var continuousScores: FitCategoryScores
    public var evidenceConfidence: FitEvidenceConfidence
    public var dimensions: [FitDimensionPolicy]
    public var matchModes: [FitMatchModePolicy]
    public var fitBands: [FitBandPolicy]
    public var minimumInputCoverage: Double
    public var minimumConfidence: Double
    public var maxAgentQuestions: Int
    public var defaultMaxResults: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case policyId = "policy_id"
        case scorerVersion = "scorer_version"
        case categoryScores = "category_scores"
        case continuousScores = "continuous_scores"
        case evidenceConfidence = "evidence_confidence"
        case dimensions
        case matchModes = "match_modes"
        case fitBands = "fit_bands"
        case minimumInputCoverage = "minimum_input_coverage"
        case minimumConfidence = "minimum_confidence"
        case maxAgentQuestions = "max_agent_questions"
        case defaultMaxResults = "default_max_results"
    }
}

/// Category → unit score, shared by categorical and continuous resolution.
public struct FitCategoryScores: Codable, Sendable, Equatable {
    public var ideal: Double
    public var compatible: Double
    public var stretch: Double
    public var avoid: Double
    public var unlisted: Double
}

/// Evidence basis → confidence factor.
public struct FitEvidenceConfidence: Codable, Sendable, Equatable {
    public var measured: Double
    public var documented: Double
    public var inferred: Double

    public func factor(for basis: EvidenceBasis) -> Double {
        switch basis {
        case .measured: return measured
        case .documented: return documented
        case .inferred: return inferred
        }
    }
}

public struct FitDimensionPolicy: Codable, Sendable, Equatable {
    public var dimension: FitDimensionName
    public var weight: Double
    public var axes: [FitAxisWeight]
}

public struct FitAxisWeight: Codable, Sendable, Equatable {
    public var axis: FitAxis
    public var weight: Double
}

public struct FitMatchModePolicy: Codable, Sendable, Equatable {
    public var mode: FitMatchMode
    public var conflictFitCap: Double?
    public var avoidPenaltyPoints: Double

    private enum CodingKeys: String, CodingKey {
        case mode
        case conflictFitCap = "conflict_fit_cap"
        case avoidPenaltyPoints = "avoid_penalty_points"
    }
}

public struct FitBandPolicy: Codable, Sendable, Equatable {
    public var band: FitBand
    public var minimumScore: Double

    private enum CodingKeys: String, CodingKey {
        case band
        case minimumScore = "minimum_score"
    }
}

// MARK: - Derived lookups

extension PatternFitPolicy {
    /// `dimension_weight(d) * axis_weight(a | d)` for the axis, or nil if the
    /// policy does not weight it (should not happen for a valid frozen policy).
    public func globalWeight(for axis: FitAxis) -> Double? {
        for dim in dimensions {
            if let aw = dim.axes.first(where: { $0.axis == axis }) {
                return dim.weight * aw.weight
            }
        }
        return nil
    }

    public func dimension(of axis: FitAxis) -> FitDimensionName? {
        for dim in dimensions where dim.axes.contains(where: { $0.axis == axis }) {
            return dim.dimension
        }
        return nil
    }

    public func configuredWeight(of dimension: FitDimensionName) -> Double? {
        dimensions.first { $0.dimension == dimension }?.weight
    }

    public func matchMode(_ mode: FitMatchMode) -> FitMatchModePolicy? {
        matchModes.first { $0.mode == mode }
    }

    /// The qualified band whose `minimum_score` the score clears, scanning the
    /// policy's descending thresholds. Never returns `.excluded`/`.provisional`
    /// — those are decided before banding.
    public func band(forScore score: Double) -> FitBand {
        for entry in fitBands.sorted(by: { $0.minimumScore > $1.minimumScore }) where score >= entry.minimumScore {
            return entry.band
        }
        return .weak
    }
}
