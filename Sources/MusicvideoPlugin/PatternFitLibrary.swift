import CryptoKit
import Foundation
import NexGenEngine

/// Errors from the Pattern-fit recommendation path.
public enum PatternFitError: Swift.Error, Sendable, Equatable {
    /// The frozen policy resource is missing or failed to decode.
    case policyUnavailable(String)
    /// A pattern carries a `fit_profile` that is present but broken. That is a defect in the
    /// pack, not a normal state — unlike an unauthored pattern, which is simply not a candidate.
    case profileInvalid(id: String, issues: [String])
    /// Neither a Brief nor a prebuilt project profile was supplied.
    case noProjectInput
}

/// Loads the frozen policy and the scored part of the Pattern library.
///
/// A pattern is OPTIONAL: without one, a music video's structure comes from the analysis, the
/// user's intent and the agent-moderated process. So an unauthored pattern is not a defect — it is
/// simply not a candidate, and ranking the ones that ARE authored is exactly the useful answer
/// ("does this pattern fit, yes or no"). Refusing to rank until all 23 are authored would withhold
/// a working answer over a pattern nobody is required to take.
///
/// A profile that EXISTS but fails validation is different: that is a defect and stays loud.
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

    /// How much of the library can currently be ranked. Reported alongside every result so the
    /// agent never presents a 1-of-23 ranking as if it were the whole field.
    public struct LibraryCoverage: Sendable, Equatable {
        /// Patterns carrying a valid `fit_profile` — the candidates.
        public var scored: [String]
        /// Patterns with no profile yet. Authoring one is expensive, so this is the normal state,
        /// not a gap to apologise for.
        public var unscored: [String]
        /// Present-but-broken profiles. A real defect.
        public var invalid: [String: [String]]
        public var total: Int { scored.count + unscored.count + invalid.count }
    }

    /// The scored part of the library, plus what it doesn't cover. Never throws over an unauthored
    /// pattern: it is not a candidate, and a pattern is optional anyway.
    public static func loadRecommendableLibrary() throws
        -> (library: [(profile: PatternFitProfile, name: String)], coverage: LibraryCoverage)
    {
        let patterns = try Patterns.loadAllPatterns()
        var recommendable: [(PatternFitProfile, String)] = []
        var scored: [String] = []
        var unscored: [String] = []
        var invalid: [String: [String]] = [:]
        for pattern in patterns {
            guard let profile = pattern.fitProfile else {
                unscored.append(pattern.id)
                continue
            }
            let issues = validate(profile, expectedId: pattern.id)
            if issues.isEmpty {
                recommendable.append((profile, pattern.name))
                scored.append(pattern.id)
            } else {
                invalid[pattern.id] = issues
            }
        }
        return (recommendable, LibraryCoverage(
            scored: scored.sorted(), unscored: unscored.sorted(), invalid: invalid))
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

    /// Assemble a project profile and rank whatever the library can score against it. An empty
    /// ranking is a legitimate answer ("none of the scored patterns fit — go without one"), not an
    /// error.
    public static func recommend(
        brief: Brief?, projectOverride: ProjectFitProfile? = nil, perceivedBpm: Double? = nil,
        matchMode: FitMatchMode = .balanced, excludedPatternIds: [String] = [], maxResults: Int? = nil
    ) throws -> (set: PatternRecommendationSet, coverage: LibraryCoverage) {
        let policy = try loadPolicy()
        let (library, coverage) = try loadRecommendableLibrary()

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
        let set = PatternFitScorer.rank(
            patterns: library, project: project, policy: policy, projectProfileSha256: projectSha,
            policySha256: policySha256(), maxResults: maxResults)
        return (set, coverage)
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
