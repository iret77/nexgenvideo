import Foundation
import NexGenEngine

/// The musicvideo pack's `PatternProviding` implementation — the live wire from the agent's
/// `suggest_patterns`/`get_pattern` tools to the Pattern-fit contract. `recommend` assembles a
/// `ProjectFitProfile` from the Brief, ranks the library with the deterministic `PatternFitScorer`
/// against the frozen policy, and returns a `PatternRecommendationSet` plus the library coverage it
/// rests on. A pattern is optional, so an unauthored one is simply not a candidate — never a reason
/// to withhold the ranking.
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
            let (set, coverage) = try PatternFitLibrary.recommend(
                brief: brief, projectOverride: options.projectProfile, perceivedBpm: options.perceivedBpm,
                matchMode: options.matchMode ?? .balanced, excludedPatternIds: options.excludedPatternIds ?? [],
                maxResults: options.maxResults)
            return try rankedEnvelope(set: set, coverage: coverage)
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

    /// A ranking plus what it does and does not cover.
    ///
    /// A pattern is OPTIONAL. Without one, the video's structure comes from the analysis, the
    /// user's intent and the agent-moderated process — so "none of the scored patterns fit" is a
    /// real, usable answer, not a failure. Ranking is therefore never withheld because other
    /// patterns are unauthored; authoring a profile is expensive and deliberate, and the useful
    /// question ("does this one fit?") is answerable with one profile just as well as with 23.
    ///
    /// `library_coverage` keeps that honest: the agent must never present a 1-of-23 ranking as if
    /// it were the whole field.
    private func rankedEnvelope(
        set: PatternRecommendationSet, coverage: PatternFitLibrary.LibraryCoverage
    ) throws -> Data {
        var body: [String: Any] = [
            "available": true,
            "pattern_optional": true,
            "recommendations": try JSONSerialization.jsonObject(
                with: try PatternFitLibrary.canonicalJSON(set)),
            "library_coverage": [
                "scored": coverage.scored,
                "unscored": coverage.unscored,
                "total": coverage.total,
                "note": "Only scored patterns can be ranked. An unscored pattern is not a gap in the "
                    + "answer — a pattern is optional, and without one the structure comes from the "
                    + "analysis, the user's intent and this conversation. Never present this ranking "
                    + "as the whole field: say how many patterns were actually weighed.",
            ],
        ]
        if !coverage.invalid.isEmpty {
            // A present-but-broken profile is a pack defect, not a normal state. Stay loud.
            body["invalid_profiles"] = coverage.invalid.mapValues { $0.sorted() }
        }
        return try envelope(body)
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
