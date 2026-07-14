import Foundation
import NexGenEngine

/// The musicvideo pack's `PatternProviding` implementation — the live wire from the agent's
/// `suggest_patterns`/`get_pattern` tools to the Pattern-fit contract. `recommend` assembles a
/// `ProjectFitProfile` from the Brief, ranks the library with the deterministic `PatternFitScorer`
/// against the frozen policy, and returns a `PatternRecommendationSet`. Fail-closed: while any of the
/// library's `fit_profile` blocks is missing or invalid it returns an `available:false` envelope, never
/// a partial ranking.
public struct MusicvideoPatternProvider: PatternProviding {
    public init() {}

    /// Options envelope the host serialises from the `suggest_patterns` tool args.
    struct Options: Decodable {
        var projectProfile: ProjectFitProfile?
        var perceivedBpm: Double?
        var matchMode: FitMatchMode?
        var excludedPatternIds: [String]?
        var maxResults: Int?

        private enum CodingKeys: String, CodingKey {
            case projectProfile = "project_profile"
            case perceivedBpm = "perceived_bpm"
            case matchMode = "match_mode"
            case excludedPatternIds = "excluded_pattern_ids"
            case maxResults = "max_results"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            projectProfile = try c.decodeIfPresent(ProjectFitProfile.self, forKey: .projectProfile)
            perceivedBpm = try c.decodeIfPresent(Double.self, forKey: .perceivedBpm)
            matchMode = try c.decodeIfPresent(FitMatchMode.self, forKey: .matchMode)
            excludedPatternIds = try c.decodeIfPresent([String].self, forKey: .excludedPatternIds)
            maxResults = try c.decodeIfPresent(Int.self, forKey: .maxResults)
        }
    }

    public func recommend(briefJSON: Data, optionsJSON: Data) throws -> Data {
        let options = (try? JSONDecoder().decode(Options.self, from: optionsJSON))
            ?? Options(projectProfile: nil, perceivedBpm: nil, matchMode: nil, excludedPatternIds: nil, maxResults: nil)
        let brief = try? JSONDecoder().decode(Brief.self, from: briefJSON)
        do {
            let set = try PatternFitLibrary.recommend(
                brief: brief, projectOverride: options.projectProfile, perceivedBpm: options.perceivedBpm,
                matchMode: options.matchMode ?? .balanced, excludedPatternIds: options.excludedPatternIds ?? [],
                maxResults: options.maxResults)
            return try PatternFitLibrary.canonicalJSON(set)
        } catch PatternFitError.recommendationsUnavailable(let missing, let invalid) {
            return try unavailableEnvelope(missing: missing, invalid: invalid)
        } catch PatternFitError.noProjectInput {
            return try envelope([
                "available": false,
                "reason": "No project to rank against yet. Assemble the Brief first (suggest_patterns builds "
                    + "the project profile from it), then call again.",
            ])
        }
    }

    public func get(id: String) throws -> Data? {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
            let pattern = try Patterns.loadAllPatterns().first(where: { $0.id == trimmed }) else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(pattern)
    }

    /// The fail-closed body: no ranking, an actionable reason and the exact gap.
    private func unavailableEnvelope(missing: [String], invalid: [String: [String]]) throws -> Data {
        let total = missing.count + invalid.count
        return try envelope([
            "available": false,
            "scorer_version": "pattern-fit-scorer/1.0",
            "reason": "Pattern recommendations are disabled until every pattern ships a valid fit_profile. "
                + "\(total) profile(s) still missing or invalid. This is a fail-closed configuration gate, "
                + "not a scoring result — no partial ranking is produced.",
            "missing_profiles": missing,
            "invalid_profiles": invalid.mapValues { $0.sorted() },
        ])
    }

    private func envelope(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

extension MusicvideoPatternProvider.Options {
    init(
        projectProfile: ProjectFitProfile?, perceivedBpm: Double?, matchMode: FitMatchMode?,
        excludedPatternIds: [String]?, maxResults: Int?
    ) {
        self.projectProfile = projectProfile
        self.perceivedBpm = perceivedBpm
        self.matchMode = matchMode
        self.excludedPatternIds = excludedPatternIds
        self.maxResults = maxResults
    }
}
