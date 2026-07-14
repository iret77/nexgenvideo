import CryptoKit
import Foundation
import NexGenEngine

/// Errors from the Pattern-fit recommendation path.
public enum PatternFitError: Swift.Error, Sendable, Equatable {
    /// The frozen policy resource is missing or failed to decode.
    case policyUnavailable(String)
    /// Fail-closed gate: the loaded library is not fully authored. Recommendations
    /// stay unavailable — never a partial ranking. Lists patterns with no
    /// `fit_profile` and patterns whose profile failed validation.
    case recommendationsUnavailable(missing: [String], invalid: [String: [String]])
    /// Neither a Brief nor a prebuilt project profile was supplied.
    case noProjectInput
}

/// Loads the frozen policy and gate-validates the full Pattern library before
/// any ranking. The heart of the fail-closed contract: recommendations are
/// available only when every bundled pattern carries a schema-valid
/// `fit_profile` (`docs/PATTERN_FIT_CONTRACT.md` §"Cutover and content gate").
public enum PatternFitLibrary {
    /// Decode the committed scoring policy from the bundled resource. Weights are
    /// never hardcoded — they come from here.
    public static func loadPolicy() throws -> PatternFitPolicy {
        guard let url = PackKnowledge.patternFitPolicyURL() else {
            throw PatternFitError.policyUnavailable("pattern-fit-policy.v1.json not bundled")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PatternFitPolicy.self, from: data)
        } catch {
            throw PatternFitError.policyUnavailable(String(describing: error))
        }
    }

    /// Hex SHA-256 of the raw policy resource bytes, binding a result to the
    /// exact policy that produced it.
    public static func policySha256() -> String {
        guard let url = PackKnowledge.patternFitPolicyURL(), let data = try? Data(contentsOf: url) else { return "" }
        return sha256Hex(data)
    }

    /// The recommendable library, or a fail-closed error. Every pattern must
    /// carry a valid `fit_profile`; any missing or invalid profile makes the
    /// whole feature unavailable rather than yielding a partial ranking.
    public static func loadRecommendableLibrary() throws -> [(profile: PatternFitProfile, name: String)] {
        let patterns = try Patterns.loadAllPatterns()
        var recommendable: [(PatternFitProfile, String)] = []
        var missing: [String] = []
        var invalid: [String: [String]] = [:]
        for pattern in patterns {
            guard let profile = pattern.fitProfile else {
                missing.append(pattern.id)
                continue
            }
            let issues = validate(profile, expectedId: pattern.id)
            if issues.isEmpty {
                recommendable.append((profile, pattern.name))
            } else {
                invalid[pattern.id] = issues
            }
        }
        guard missing.isEmpty, invalid.isEmpty else {
            throw PatternFitError.recommendationsUnavailable(missing: missing.sorted(), invalid: invalid)
        }
        return recommendable
    }

    /// Structural validation beyond JSON Schema: evidence references resolve,
    /// continuous ranges nest correctly, and identity is consistent.
    public static func validate(_ profile: PatternFitProfile, expectedId: String? = nil) -> [String] {
        var issues: [String] = []
        if profile.schemaVersion != "pattern-fit/1.0" {
            issues.append("unexpected schema_version \(profile.schemaVersion)")
        }
        if let expectedId, profile.patternId != expectedId {
            issues.append("pattern_id \(profile.patternId) does not match \(expectedId)")
        }
        if profile.styleFamilies.isEmpty { issues.append("style_families is empty") }
        if profile.evidence.isEmpty { issues.append("evidence is empty") }

        let declared = Set(profile.evidence.map(\.evidenceId))
        if declared.count != profile.evidence.count { issues.append("duplicate evidence_id") }

        for (axis, ids) in axisEvidenceIds(profile) {
            if ids.isEmpty { issues.append("\(axis): no evidence_ids") }
            for id in ids where !declared.contains(id) {
                issues.append("\(axis): unknown evidence reference '\(id)'")
            }
        }
        for (axis, fit) in continuousFits(profile) {
            issues.append(contentsOf: rangeIssues(fit, axis: axis))
        }
        return issues
    }

    /// Assemble a project profile and rank the recommendable library against it.
    /// Throws `PatternFitError.recommendationsUnavailable` while any profile is
    /// unauthored — the fail-closed state until all 23 ship.
    public static func recommend(
        brief: Brief?, projectOverride: ProjectFitProfile? = nil, perceivedBpm: Double? = nil,
        matchMode: FitMatchMode = .balanced, excludedPatternIds: [String] = [], maxResults: Int? = nil
    ) throws -> PatternRecommendationSet {
        let policy = try loadPolicy()
        let library = try loadRecommendableLibrary()

        let project: ProjectFitProfile
        if let projectOverride {
            project = projectOverride
        } else if let brief {
            project = ProjectProfileAssembler.assemble(
                brief: brief, perceivedBpm: perceivedBpm, matchMode: matchMode,
                excludedPatternIds: excludedPatternIds)
        } else {
            throw PatternFitError.noProjectInput
        }

        let projectSha = sha256Hex(try canonicalJSON(project))
        return PatternFitScorer.rank(
            patterns: library, project: project, policy: policy, projectProfileSha256: projectSha,
            policySha256: policySha256(), maxResults: maxResults)
    }

    // MARK: - Helpers

    static func axisEvidenceIds(_ p: PatternFitProfile) -> [(String, [String])] {
        [
            ("affect", p.affectEnergy.affects.evidenceIds),
            ("energy_level", p.affectEnergy.energyLevel.evidenceIds),
            ("energy_arc", p.affectEnergy.energyArc.evidenceIds),
            ("concept_type", p.conceptStory.conceptType.evidenceIds),
            ("lyrics_integration", p.conceptStory.lyricsIntegration.evidenceIds),
            ("narrative_clarity", p.conceptStory.narrativeClarity.evidenceIds),
            ("figures", p.subjectPerformance.figures.evidenceIds),
            ("performance_intensity", p.subjectPerformance.performanceIntensity.evidenceIds),
            ("choreography", p.subjectPerformance.choreography.evidenceIds),
            ("direct_address", p.subjectPerformance.directAddress.evidenceIds),
            ("crowd_energy", p.subjectPerformance.crowdEnergy.evidenceIds),
            ("visual_medium", p.mediumAesthetic.visualMedium.evidenceIds),
            ("abstraction", p.mediumAesthetic.abstraction.evidenceIds),
            ("polish", p.mediumAesthetic.polish.evidenceIds),
            ("emotional_distance", p.mediumAesthetic.emotionalDistance.evidenceIds),
            ("perceived_bpm", p.rhythmEdit.perceivedBpm.evidenceIds),
            ("beat_salience", p.rhythmEdit.beatSalience.evidenceIds),
            ("onset_density_hz", p.rhythmEdit.onsetDensityHz.evidenceIds),
            ("rhythmic_regularity", p.rhythmEdit.rhythmicRegularity.evidenceIds),
            ("section_contrast", p.rhythmEdit.sectionContrast.evidenceIds),
            ("budget_tier", p.production.budgetTier.evidenceIds),
            ("location_complexity", p.production.locationComplexity.evidenceIds),
            ("cast_scale", p.production.castScale.evidenceIds),
            ("choreography_complexity", p.production.choreographyComplexity.evidenceIds),
            ("vfx_complexity", p.production.vfxComplexity.evidenceIds),
            ("post_complexity", p.production.postComplexity.evidenceIds),
        ]
    }

    private static func continuousFits(_ p: PatternFitProfile) -> [(String, ContinuousFit)] {
        [
            ("energy_level", p.affectEnergy.energyLevel),
            ("narrative_clarity", p.conceptStory.narrativeClarity),
            ("abstraction", p.mediumAesthetic.abstraction),
            ("perceived_bpm", p.rhythmEdit.perceivedBpm),
            ("onset_density_hz", p.rhythmEdit.onsetDensityHz),
            ("section_contrast", p.rhythmEdit.sectionContrast),
        ]
    }

    private static func rangeIssues(_ fit: ContinuousFit, axis: String) -> [String] {
        var out: [String] = []
        for (label, r) in [("ideal", fit.ideal), ("compatible", fit.compatible), ("usable", fit.usable)]
        where r.min > r.max {
            out.append("\(axis).\(label): min \(r.min) > max \(r.max)")
        }
        if fit.ideal.min < fit.compatible.min || fit.ideal.max > fit.compatible.max {
            out.append("\(axis): ideal not within compatible")
        }
        if fit.compatible.min < fit.usable.min || fit.compatible.max > fit.usable.max {
            out.append("\(axis): compatible not within usable")
        }
        return out
    }

    static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
