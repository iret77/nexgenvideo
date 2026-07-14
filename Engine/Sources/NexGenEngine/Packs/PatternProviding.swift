import Foundation

/// A pack-provided, agent-callable director-pattern query surface. The generic engine declares the
/// seam; a format pack (e.g. musicvideo) registers a concrete provider that reads its own pattern
/// library and returns JSON the host's agent tools relay. JSON (`Data`) is the currency so the engine
/// stays agnostic of the pack's `Pattern` schema — the same dependency-inversion the audio-ML seams use.
///
/// This is the sanctioned path to the pattern library the predecessor had and the port lost (#185): the
/// agent recommends patterns via `recommend` and loads one via `get`, instead of the ported YAMLs sitting
/// as dead data with no caller.
public protocol PatternProviding: Sendable {
    /// Rank the pack's patterns against a project using the frozen Pattern-fit contract. `briefJSON` is
    /// the persisted Brief as JSON; `optionsJSON` carries `{perceived_bpm, match_mode,
    /// excluded_pattern_ids, project_profile?, max_results?}`. Returns a `PatternRecommendationSet` JSON
    /// on success, or a `{available:false, …}` envelope while the library is not fully authored
    /// (fail-closed — never a partial ranking). JSON is the currency so the engine stays agnostic of the
    /// pack's fit schema. Throws only on a genuine configuration error (missing policy, no project input).
    func recommend(briefJSON: Data, optionsJSON: Data) throws -> Data

    /// The full pattern for `id` as JSON (framing_mix, asl_range, camera vocabulary, lighting signature,
    /// section arc, references, and the fit_profile when authored), or nil when no pattern has that id.
    func get(id: String) throws -> Data?
}
