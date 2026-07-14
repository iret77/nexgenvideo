import Foundation
import NexGenEngine

/// Deterministic Pattern-fit scorer (`pattern-fit-scorer/1.0`). Pure functions
/// over the frozen policy, a pattern's `fit_profile` and the runtime
/// `ProjectFitProfile`. No hidden weights: every constant comes from the loaded
/// `PatternFitPolicy`. The normative semantics this implements live in
/// `docs/PATTERN_FIT_CONTRACT.md` §1–6; `contracts/pattern-fit-golden-vectors.v1.json`
/// pins the numeric behaviour cross-language.
public enum PatternFitScorer {
    /// One axis's contribution, before it is folded into a dimension/pattern.
    struct AxisEval: Sendable {
        var score: Double?  // nil ⇒ unscored (missing project input)
        var resolution: AxisResolution
        var inputConfidence: Double?
        var evidenceConfidence: Double?
        var explanation: String

        static let unscored = AxisEval(
            score: nil, resolution: .unscored, inputConfidence: nil, evidenceConfidence: nil,
            explanation: "no project input")
    }

    // MARK: - Public entry points

    /// Score every pattern, rank the qualified ones and fill the recommendation
    /// slots. `patterns` pairs each profile with its human-facing name.
    public static func rank(
        patterns: [(profile: PatternFitProfile, name: String)], project: ProjectFitProfile,
        policy: PatternFitPolicy, projectProfileSha256: String, policySha256: String, maxResults: Int? = nil
    ) -> PatternRecommendationSet {
        let cap = maxResults ?? policy.defaultMaxResults
        var recs = patterns.map { score(pattern: $0.profile, patternName: $0.name, project: project, policy: policy) }

        // Qualified (rankable) results sort by fit desc, confidence desc, id asc.
        var qualified = recs.filter { !$0.excluded && $0.fitBand != .provisional }
        qualified.sort { lhs, rhs in
            let l = lhs.fitScore ?? -1, r = rhs.fitScore ?? -1
            if l != r { return l > r }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.patternId < rhs.patternId
        }
        for (i, rec) in qualified.enumerated() {
            if let idx = recs.firstIndex(where: { $0.patternId == rec.patternId }) {
                recs[idx].rank = i + 1
                qualified[i].rank = i + 1
            }
        }

        let slots = fillSlots(qualified: qualified, patterns: patterns)

        // Present qualified (ranked) first, then provisional by diagnostic score, then excluded.
        let provisional = recs.filter { $0.fitBand == .provisional }
            .sorted { lhs, rhs in
                let l = lhs.fitScore ?? -1, r = rhs.fitScore ?? -1
                return l != r ? l > r : lhs.patternId < rhs.patternId
            }
        let excluded = recs.filter { $0.excluded }.sorted { $0.patternId < $1.patternId }
        let ordered = qualified + provisional + excluded
        let results = Array(ordered.prefix(cap))

        let (missing, questionsRequired) = missingInputs(project: project, policy: policy)

        return PatternRecommendationSet(
            projectProfileSha256: projectProfileSha256, policySha256: policySha256, results: results,
            slots: slots, missingHighImpactInputs: missing, questionsRequiredBeforeRanking: questionsRequired)
    }

    /// Score a single pattern against the project. Applies hard gates, axis
    /// resolution, weighting, evidence-aware confidence, conflicts, adaptations
    /// and qualification — the full §1–6 pipeline.
    public static func score(
        pattern: PatternFitProfile, patternName: String, project: ProjectFitProfile, policy: PatternFitPolicy
    ) -> PatternFitRecommendation {
        // §1 Hard gates.
        let exclusions = hardGateReasons(pattern: pattern, project: project)

        // §2–3 Axis resolution, weighting and dimension roll-up.
        var dimensionScores: [DimensionFitScore] = []
        var scoredWeights: [Double] = []
        var scores: [Double] = []
        var inputConfidences: [Double] = []
        var evidenceConfidences: [Double] = []
        var conflictCount = 0
        var strengths: [String] = []
        var conflicts: [String] = []

        for dim in policy.dimensions {
            var axisScores: [AxisFitScore] = []
            var dimWeights: [Double] = []
            var dimScores: [Double] = []
            for aw in dim.axes {
                let gw = dim.weight * aw.weight
                let eval = axisEval(aw.axis, pattern: pattern, project: project, policy: policy)
                axisScores.append(AxisFitScore(
                    axis: aw.axis, score: eval.score, globalWeight: gw, inputConfidence: eval.inputConfidence,
                    evidenceConfidence: eval.evidenceConfidence, resolution: eval.resolution,
                    explanation: eval.explanation))
                guard let s = eval.score else { continue }  // unscored: excluded from coverage and roll-up
                scoredWeights.append(gw)
                scores.append(s)
                inputConfidences.append(eval.inputConfidence ?? 0)
                evidenceConfidences.append(eval.evidenceConfidence ?? 0)
                dimWeights.append(gw)
                dimScores.append(s)
                switch eval.resolution {
                case .conflict:
                    conflictCount += 1
                    conflicts.append("\(aw.axis.rawValue): \(eval.explanation)")
                case .ideal:
                    strengths.append("\(aw.axis.rawValue): \(eval.explanation)")
                default:
                    break
                }
            }
            let dimScoredWeight = dimWeights.reduce(0, +)
            let dimScore = dimScoredWeight > 0 ? FitMath.rawFit(scoredWeights: dimWeights, scores: dimScores) : nil
            dimensionScores.append(DimensionFitScore(
                dimension: dim.dimension, score: dimScore, configuredWeight: dim.weight,
                scoredWeight: dimScoredWeight, axes: axisScores))
        }

        let coverage = scoredWeights.reduce(0, +)
        let rawFit = FitMath.rawFit(scoredWeights: scoredWeights, scores: scores)
        let confidence = FitMath.confidence(
            scoredWeights: scoredWeights, inputConfidence: inputConfidences, evidenceConfidence: evidenceConfidences)

        // §5 Conflicts, adaptations and final score.
        let mode = policy.matchMode(project.matchMode)
        var finalScore = FitMath.applyConflicts(
            startPoints: 100 * rawFit, conflictCount: conflictCount,
            penaltyPoints: mode?.avoidPenaltyPoints ?? 0, cap: mode?.conflictFitCap ?? nil)
        let triggered = triggeredAdaptations(pattern: pattern, project: project)
        for adaptation in triggered { finalScore = min(finalScore, adaptation.fitCap) }

        // §1 Excluded patterns carry no numeric fit_score.
        if !exclusions.isEmpty {
            return PatternFitRecommendation(
                patternId: pattern.patternId, patternName: patternName, rank: nil, fitScore: nil,
                fitBand: .excluded, confidence: confidence, inputCoverage: coverage, excluded: true,
                exclusionReasons: exclusions, dimensions: dimensionScores, strengths: strengths,
                conflicts: conflicts, adaptations: triggered,
                why: "Excluded: \(exclusions.joined(separator: "; "))")
        }

        // §6 Qualification and banding.
        let provisional = FitMath.isProvisional(coverage: coverage, confidence: confidence, policy: policy)
        let band: FitBand = provisional ? .provisional : policy.band(forScore: finalScore)
        let why = recommendationSummary(
            band: band, score: finalScore, coverage: coverage, confidence: confidence,
            strengths: strengths, conflicts: conflicts, triggered: triggered, provisional: provisional)

        return PatternFitRecommendation(
            patternId: pattern.patternId, patternName: patternName, rank: nil, fitScore: finalScore,
            fitBand: band, confidence: confidence, inputCoverage: coverage, excluded: false,
            exclusionReasons: [], dimensions: dimensionScores, strengths: strengths, conflicts: conflicts,
            adaptations: triggered, why: why)
    }

    // MARK: - §1 Hard gates

    private static func hardGateReasons(pattern: PatternFitProfile, project: ProjectFitProfile) -> [String] {
        var reasons: [String] = []
        let hc = pattern.hardConstraints

        if let excluded = project.excludedPatternIds, excluded.canVeto,
            excluded.value.contains(pattern.patternId) {
            reasons.append("user excluded this pattern")
        }
        // Required visual mediums: veto only on user-/Brief-confirmed medium data.
        if !hc.requiredVisualMediums.isEmpty, let vm = project.visual.visualMedium, vm.canVeto,
            !hc.requiredVisualMediums.contains(vm.value) {
            reasons.append("requires visual medium in \(hc.requiredVisualMediums.map(\.rawValue).joined(separator: "/"))")
        }
        // Required capabilities: missing capability data is unknown, never absent — only veto when the
        // project explicitly lists its available capabilities (user/Brief) and a required one is absent.
        if !hc.requiredCapabilities.isEmpty, let caps = project.production.availableCapabilities, caps.canVeto {
            let absent = hc.requiredCapabilities.filter { !caps.value.contains($0) }
            if !absent.isEmpty {
                reasons.append("missing required capability: \(absent.map(\.rawValue).joined(separator: ", "))")
            }
        }
        // Incompatible project constraints intersect the project's confirmed constraints.
        if !hc.incompatibleProjectConstraints.isEmpty, let cons = project.production.constraints, cons.canVeto {
            let clash = Set(cons.value).intersection(hc.incompatibleProjectConstraints)
            if !clash.isEmpty {
                reasons.append("incompatible with constraint: \(clash.map(\.rawValue).sorted().joined(separator: ", "))")
            }
        }
        return reasons
    }

    // MARK: - §2 Axis resolution

    private static func axisEval(
        _ axis: FitAxis, pattern: PatternFitProfile, project: ProjectFitProfile, policy: PatternFitPolicy
    ) -> AxisEval {
        switch axis {
        case .affect:
            return evalAffects(project.creative.affects, pattern.affectEnergy.affects, pattern: pattern, policy: policy)
        case .energyLevel:
            return evalContinuous(project.audio.energyLevel, pattern.affectEnergy.energyLevel, pattern: pattern, policy: policy)
        case .energyArc:
            return evalCategorical(project.audio.energyArc, pattern.affectEnergy.energyArc, pattern: pattern, policy: policy)
        case .conceptType:
            return evalCategorical(project.creative.conceptType, pattern.conceptStory.conceptType, pattern: pattern, policy: policy)
        case .lyricsIntegration:
            return evalCategorical(project.creative.lyricsIntegration, pattern.conceptStory.lyricsIntegration, pattern: pattern, policy: policy)
        case .narrativeClarity:
            return evalContinuous(project.creative.narrativeClarity, pattern.conceptStory.narrativeClarity, pattern: pattern, policy: policy)
        case .figures:
            return evalCategorical(project.creative.figures, pattern.subjectPerformance.figures, pattern: pattern, policy: policy)
        case .performanceIntensity:
            return evalCategorical(project.creative.performanceIntensity, pattern.subjectPerformance.performanceIntensity, pattern: pattern, policy: policy)
        case .choreography:
            return evalCategorical(project.creative.choreography, pattern.subjectPerformance.choreography, pattern: pattern, policy: policy)
        case .directAddress:
            return evalCategorical(project.creative.directAddress, pattern.subjectPerformance.directAddress, pattern: pattern, policy: policy)
        case .crowdEnergy:
            return evalCategorical(project.creative.crowdEnergy, pattern.subjectPerformance.crowdEnergy, pattern: pattern, policy: policy)
        case .visualMedium:
            return evalCategorical(project.visual.visualMedium, pattern.mediumAesthetic.visualMedium, pattern: pattern, policy: policy)
        case .abstraction:
            return evalContinuous(project.visual.abstraction, pattern.mediumAesthetic.abstraction, pattern: pattern, policy: policy)
        case .polish:
            return evalCategorical(project.visual.polish, pattern.mediumAesthetic.polish, pattern: pattern, policy: policy)
        case .emotionalDistance:
            return evalCategorical(project.visual.emotionalDistance, pattern.mediumAesthetic.emotionalDistance, pattern: pattern, policy: policy)
        case .perceivedBpm:
            return evalContinuous(project.audio.perceivedBpm, pattern.rhythmEdit.perceivedBpm, pattern: pattern, policy: policy)
        case .beatSalience:
            return evalCategorical(project.audio.beatSalience, pattern.rhythmEdit.beatSalience, pattern: pattern, policy: policy)
        case .onsetDensityHz:
            return evalContinuous(project.audio.onsetDensityHz, pattern.rhythmEdit.onsetDensityHz, pattern: pattern, policy: policy)
        case .rhythmicRegularity:
            return evalCategorical(project.audio.rhythmicRegularity, pattern.rhythmEdit.rhythmicRegularity, pattern: pattern, policy: policy)
        case .sectionContrast:
            return evalContinuous(project.audio.sectionContrast, pattern.rhythmEdit.sectionContrast, pattern: pattern, policy: policy)
        case .budgetTier:
            return evalCategorical(project.production.budgetTier, pattern.production.budgetTier, pattern: pattern, policy: policy)
        case .locationComplexity:
            return evalCategorical(project.production.locationComplexity, pattern.production.locationComplexity, pattern: pattern, policy: policy)
        case .castScale:
            return evalCategorical(project.production.castScale, pattern.production.castScale, pattern: pattern, policy: policy)
        case .choreographyComplexity:
            return evalCategorical(project.production.choreographyComplexity, pattern.production.choreographyComplexity, pattern: pattern, policy: policy)
        case .vfxComplexity:
            return evalCategorical(project.production.vfxComplexity, pattern.production.vfxComplexity, pattern: pattern, policy: policy)
        case .postComplexity:
            return evalCategorical(project.production.postComplexity, pattern.production.postComplexity, pattern: pattern, policy: policy)
        }
    }

    private static func evalCategorical<V: Codable & Sendable & Equatable & RawRepresentable>(
        _ input: FitInput<V>?, _ fit: CategoricalFit<V>, pattern: PatternFitProfile, policy: PatternFitPolicy
    ) -> AxisEval where V.RawValue == String {
        guard let input else { return .unscored }
        let bucket = fit.bucket(for: input.value)
        return AxisEval(
            score: FitMath.score(for: bucket, policy.categoryScores), resolution: FitMath.resolution(for: bucket),
            inputConfidence: input.confidence,
            evidenceConfidence: minEvidenceConfidence(fit.evidenceIds, pattern: pattern, policy: policy),
            explanation: "\(input.value.rawValue) → \(bucket.rawValue)")
    }

    private static func evalContinuous(
        _ input: FitInput<Double>?, _ fit: ContinuousFit, pattern: PatternFitProfile, policy: PatternFitPolicy
    ) -> AxisEval {
        guard let input else { return .unscored }
        let bucket = fit.bucket(for: input.value)
        return AxisEval(
            score: FitMath.score(for: bucket, policy.continuousScores), resolution: FitMath.resolution(for: bucket),
            inputConfidence: input.confidence,
            evidenceConfidence: minEvidenceConfidence(fit.evidenceIds, pattern: pattern, policy: policy),
            explanation: "\(trim(input.value)) → \(bucket.rawValue)")
    }

    /// Weighted affects: score is the weighted mean of the per-affect category
    /// scores (contract §2). The axis resolution mirrors the dominant
    /// (highest-weight, enum-order tiebreak) affect, so a project whose primary
    /// mood is on the pattern's `avoid` list registers a conflict.
    private static func evalAffects(
        _ input: FitInput<[WeightedAffect]>?, _ fit: CategoricalFit<AffectTag>, pattern: PatternFitProfile,
        policy: PatternFitPolicy
    ) -> AxisEval {
        guard let input, !input.value.isEmpty else { return .unscored }
        let totalWeight = input.value.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return .unscored }
        let weightedMean = input.value.reduce(0.0) { acc, wa in
            acc + wa.weight * FitMath.score(for: fit.bucket(for: wa.value), policy.categoryScores)
        } / totalWeight
        let order = AffectTag.allCases
        let dominant = input.value.max {
            $0.weight != $1.weight ? $0.weight < $1.weight
                : (order.firstIndex(of: $0.value) ?? 0) > (order.firstIndex(of: $1.value) ?? 0)
        }!
        let domBucket = fit.bucket(for: dominant.value)
        return AxisEval(
            score: weightedMean, resolution: FitMath.resolution(for: domBucket), inputConfidence: input.confidence,
            evidenceConfidence: minEvidenceConfidence(fit.evidenceIds, pattern: pattern, policy: policy),
            explanation: "dominant \(dominant.value.rawValue) → \(domBucket.rawValue), weighted \(trim(weightedMean))")
    }

    /// §4 The minimum policy confidence over an axis's referenced evidence —
    /// using the minimum prevents a strong measurement reference from concealing
    /// a weaker editorial premise.
    private static func minEvidenceConfidence(
        _ ids: [String], pattern: PatternFitProfile, policy: PatternFitPolicy
    ) -> Double {
        let factors = ids.compactMap { id in
            pattern.evidence.first { $0.evidenceId == id }.map { policy.evidenceConfidence.factor(for: $0.basis) }
        }
        return factors.min() ?? policy.evidenceConfidence.inferred
    }

    // MARK: - §5 Adaptations

    private static func triggeredAdaptations(
        pattern: PatternFitProfile, project: ProjectFitProfile
    ) -> [TriggeredAdaptation] {
        pattern.adaptations.compactMap { rule in
            guard conditionMatches(rule.when, project: project) else { return nil }
            return TriggeredAdaptation(
                adaptationId: rule.adaptationId, actions: rule.actions, fitCap: rule.maximumRecommendedFit)
        }
    }

    private static func conditionMatches(_ cond: FitCondition, project: ProjectFitProfile) -> Bool {
        switch cond.op {
        case .above:
            guard let threshold = cond.threshold, let v = numericInput(cond.axis, project: project) else { return false }
            return v > threshold
        case .below:
            guard let threshold = cond.threshold, let v = numericInput(cond.axis, project: project) else { return false }
            return v < threshold
        case .equals:
            guard let v = categoricalInput(cond.axis, project: project), let target = cond.values.first else { return false }
            return v == target
        case .in:
            guard let v = categoricalInput(cond.axis, project: project) else { return false }
            return cond.values.contains(v)
        }
    }

    private static func numericInput(_ axis: FitAxis, project: ProjectFitProfile) -> Double? {
        switch axis {
        case .energyLevel: return project.audio.energyLevel?.value
        case .perceivedBpm: return project.audio.perceivedBpm?.value
        case .onsetDensityHz: return project.audio.onsetDensityHz?.value
        case .sectionContrast: return project.audio.sectionContrast?.value
        case .narrativeClarity: return project.creative.narrativeClarity?.value
        case .abstraction: return project.visual.abstraction?.value
        default: return nil
        }
    }

    private static func categoricalInput(_ axis: FitAxis, project: ProjectFitProfile) -> String? {
        switch axis {
        case .energyArc: return project.audio.energyArc?.value.rawValue
        case .conceptType: return project.creative.conceptType?.value.rawValue
        case .lyricsIntegration: return project.creative.lyricsIntegration?.value.rawValue
        case .figures: return project.creative.figures?.value.rawValue
        case .performanceIntensity: return project.creative.performanceIntensity?.value.rawValue
        case .choreography: return project.creative.choreography?.value.rawValue
        case .directAddress: return project.creative.directAddress?.value.rawValue
        case .crowdEnergy: return project.creative.crowdEnergy?.value.rawValue
        case .visualMedium: return project.visual.visualMedium?.value.rawValue
        case .polish: return project.visual.polish?.value.rawValue
        case .emotionalDistance: return project.visual.emotionalDistance?.value.rawValue
        case .beatSalience: return project.audio.beatSalience?.value.rawValue
        case .rhythmicRegularity: return project.audio.rhythmicRegularity?.value.rawValue
        case .budgetTier: return project.production.budgetTier?.value.rawValue
        case .locationComplexity: return project.production.locationComplexity?.value.rawValue
        case .castScale: return project.production.castScale?.value.rawValue
        case .choreographyComplexity: return project.production.choreographyComplexity?.value.rawValue
        case .vfxComplexity: return project.production.vfxComplexity?.value.rawValue
        case .postComplexity: return project.production.postComplexity?.value.rawValue
        default: return nil
        }
    }

    // MARK: - Slots, missing inputs, prose

    private static func fillSlots(
        qualified: [PatternFitRecommendation], patterns: [(profile: PatternFitProfile, name: String)]
    ) -> RecommendationSlots {
        let profilesById = Dictionary(patterns.map { ($0.profile.patternId, $0.profile) }, uniquingKeysWith: { a, _ in a })
        let bestOverall = qualified.first

        let productionEfficient = qualified.first { rec in
            let prodScore = rec.dimensions.first { $0.dimension == .production }?.score ?? 0
            let prodConflict = rec.conflicts.contains { conflict in
                FitProductionAxes.contains(where: { conflict.hasPrefix("\($0.rawValue):") })
            }
            return prodScore >= 0.75 && !prodConflict
        }

        let bestFamilies = Set(bestOverall.flatMap { profilesById[$0.patternId]?.styleFamilies } ?? [])
        let creativeStretch = qualified.first { rec in
            guard rec.patternId != bestOverall?.patternId, let score = rec.fitScore, score >= 50 else { return false }
            let families = Set(profilesById[rec.patternId]?.styleFamilies ?? [])
            let differentFamily = bestFamilies.isEmpty || families.isDisjoint(with: bestFamilies)
            let stretchLike = !rec.adaptations.isEmpty || rec.dimensions.contains { dim in
                dim.axes.contains { $0.resolution == .stretch }
            }
            return differentFamily && stretchLike
        }

        return RecommendationSlots(
            bestOverallPatternId: bestOverall?.patternId,
            productionEfficientPatternId: productionEfficient?.patternId,
            creativeStretchPatternId: creativeStretch?.patternId)
    }

    private static let FitProductionAxes: [FitAxis] = [
        .budgetTier, .locationComplexity, .castScale, .choreographyComplexity, .vfxComplexity, .postComplexity,
    ]

    /// High-impact missing inputs, ranked by global weight — the questions worth
    /// asking. `questionsRequired` is true when the known-input weight is below
    /// the policy's minimum coverage (contract §"Runtime project profile").
    private static func missingInputs(
        project: ProjectFitProfile, policy: PatternFitPolicy
    ) -> (missing: [MissingFitInput], questionsRequired: Bool) {
        var knownWeight = 0.0
        var missing: [(axis: FitAxis, weight: Double)] = []
        for dim in policy.dimensions {
            for aw in dim.axes {
                let gw = dim.weight * aw.weight
                if hasInput(aw.axis, project: project) {
                    knownWeight += gw
                } else {
                    missing.append((aw.axis, gw))
                }
            }
        }
        missing.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.axis.rawValue < $1.axis.rawValue }
        let top = missing.prefix(policy.maxAgentQuestions).map {
            MissingFitInput(axis: $0.axis, globalWeight: $0.weight, question: question(for: $0.axis))
        }
        return (Array(top), knownWeight < policy.minimumInputCoverage)
    }

    private static func hasInput(_ axis: FitAxis, project: ProjectFitProfile) -> Bool {
        // Affect is the only list-valued axis; every other axis is present iff its typed input exists.
        if axis == .affect {
            return !(project.creative.affects?.value.isEmpty ?? true)
        }
        return numericInput(axis, project: project) != nil || categoricalInput(axis, project: project) != nil
    }

    private static func question(for axis: FitAxis) -> String {
        switch axis {
        case .affect: return "What is the track's dominant emotional register (and any secondary moods)?"
        case .conceptType: return "Is the video narrative, performance, abstract, documentary or hybrid?"
        case .visualMedium: return "What visual medium — live action, animation, illustration, mixed?"
        case .energyLevel: return "How intense is the track overall, from sparse (0) to relentless (1)?"
        case .narrativeClarity: return "How explicit is the story, from non-narrative (0) to linear (1)?"
        case .budgetTier: return "What production budget tier fits the actual plan — micro, low, medium or high?"
        default: return "Provide the project's \(axis.rawValue) to sharpen the ranking."
        }
    }

    private static func recommendationSummary(
        band: FitBand, score: Double, coverage: Double, confidence: Double, strengths: [String],
        conflicts: [String], triggered: [TriggeredAdaptation], provisional: Bool
    ) -> String {
        var parts: [String] = []
        parts.append("Compatibility Index \(Int(score.rounded())) (\(band.rawValue))")
        parts.append("coverage \(pct(coverage)), confidence \(pct(confidence))")
        if provisional { parts.append("provisional — add high-impact inputs before ranking") }
        if !strengths.isEmpty { parts.append("strengths: \(strengths.prefix(3).joined(separator: ", "))") }
        if !conflicts.isEmpty { parts.append("conflicts: \(conflicts.prefix(3).joined(separator: ", "))") }
        if !triggered.isEmpty {
            parts.append("adaptations: \(triggered.map(\.adaptationId).joined(separator: ", "))")
        }
        return parts.joined(separator: "; ")
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3g", value)
    }

    private static func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
