import Foundation
import NexGenEngine

/// The numeric core of the fit scorer, isolated as pure functions so
/// `contracts/pattern-fit-golden-vectors.v1.json` can pin exactly the code the
/// scorer runs (cross-language parity). Every constant is passed in from the
/// frozen policy — nothing is hardcoded here.
public enum FitMath {
    /// Unit score for a resolved categorical/continuous bucket (contract §2).
    public static func score(for bucket: FitBucket, _ scores: FitCategoryScores) -> Double {
        switch bucket {
        case .ideal: return scores.ideal
        case .compatible: return scores.compatible
        case .stretch: return scores.stretch
        case .avoid: return scores.avoid
        case .unlisted: return scores.unlisted
        }
    }

    /// Bucket → axis resolution. `avoid` (categorical) and outside-`usable`
    /// (continuous) both surface as `.conflict` (contract §5).
    public static func resolution(for bucket: FitBucket) -> AxisResolution {
        switch bucket {
        case .ideal: return .ideal
        case .compatible: return .compatible
        case .stretch: return .stretch
        case .avoid: return .conflict
        case .unlisted: return .unlisted
        }
    }

    /// `raw_fit = Σ(global_weight · score) / Σ(global_weight)` over scored axes
    /// (contract §3). Missing axes contribute to neither sum. Coverage 0 ⇒ 0.
    public static func rawFit(scoredWeights: [Double], scores: [Double]) -> Double {
        let coverage = scoredWeights.reduce(0, +)
        guard coverage > 0 else { return 0 }
        let weighted = zip(scoredWeights, scores).reduce(0) { $0 + $1.0 * $1.1 }
        return weighted / coverage
    }

    /// `confidence = input_coverage · mean_quality`, which reduces to
    /// `Σ(global_weight · input_confidence · evidence_confidence)` over scored
    /// axes (contract §4). Using the minimum evidence factor per axis is the
    /// caller's job (`PatternFitScorer`).
    public static func confidence(
        scoredWeights: [Double], inputConfidence: [Double], evidenceConfidence: [Double]
    ) -> Double {
        zip(scoredWeights, zip(inputConfidence, evidenceConfidence)).reduce(0) { acc, item in
            acc + item.0 * item.1.0 * item.1.1
        }
    }

    /// Apply the match mode's per-conflict penalty and, when any conflict
    /// remains, its cap; clamp to `[0, 100]` (contract §5).
    public static func applyConflicts(
        startPoints: Double, conflictCount: Int, penaltyPoints: Double, cap: Double?
    ) -> Double {
        var score = min(max(startPoints - penaltyPoints * Double(conflictCount), 0), 100)
        if conflictCount > 0, let cap { score = min(score, cap) }
        return score
    }

    /// A result is provisional (retains its diagnostic score, gets no rank/slot)
    /// below the policy's coverage or confidence floor (contract §6).
    public static func isProvisional(coverage: Double, confidence: Double, policy: PatternFitPolicy) -> Bool {
        coverage < policy.minimumInputCoverage || confidence < policy.minimumConfidence
    }
}
