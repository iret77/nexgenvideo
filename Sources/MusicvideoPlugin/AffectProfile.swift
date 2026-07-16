import Foundation
import NexGenEngine

/// The track's emotional register, detected by the agent from the audio analysis (BPM, key, energy,
/// section dynamics — already computed in the analysis phase) plus the lyrics, and answering the
/// pattern-fit `affect_energy` axis before it has to ask the user (#214). This REPLACES the old
/// tone-tag keyword mapping as the primary source: trigger words over the brief's tone tags are the
/// heuristic the deterministic `pattern-fit` contract set out to retire, so affect now comes from the
/// signal (audio) and the text (lyrics, read by the agent), not from a lookup table.
///
/// `detected` is the automatic read. `override` is the user's deliberate correction — kept alongside
/// `detected`, never overwriting it, so the record stays honest about what the machine thought and what
/// the human decided. A contrary-mood video (a happy song cut dark) is a legitimate and common directing
/// choice, so the override must be able to contradict the detection outright; `effective` is what the
/// pattern-fit profile consumes. Persisted at `analysis/affect.json`.
public struct AffectProfile: Codable, Sendable, Equatable {
    public static let file = "analysis/affect.json"

    /// The automatic detection: weighted affect tags the agent inferred from audio + lyrics.
    public var detected: [WeightedAffect]
    /// The user's deliberate override, when they corrected or deliberately contradicted the detection.
    /// nil means the detection stands.
    public var override: [WeightedAffect]?
    /// One line on what drove the detection (the audio + lyric evidence), so a later reader can see why
    /// the pattern selection came out as it did.
    public var rationale: String
    /// `measured` when the read leans on the DSP analysis, `inferred` when it leans on the lyrics/context.
    public var basis: EvidenceBasis

    public init(
        detected: [WeightedAffect], override: [WeightedAffect]? = nil, rationale: String = "",
        basis: EvidenceBasis = .inferred
    ) {
        self.detected = detected
        self.override = override
        self.rationale = rationale
        self.basis = basis
    }

    private enum CodingKeys: String, CodingKey {
        case detected, override, rationale, basis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detected = try c.decodeIfPresent([WeightedAffect].self, forKey: .detected) ?? []
        override = try c.decodeIfPresent([WeightedAffect].self, forKey: .override)
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        basis = try c.decodeIfPresent(EvidenceBasis.self, forKey: .basis) ?? .inferred
    }

    /// Only positively-weighted tags carry signal: a zero/negative weight scores as nothing (the
    /// affect axis is a weighted mean), so such entries must not count as "present" — otherwise a
    /// `[{dark, 0}]` detection shadows the tone-tag fallback and then goes unscored.
    private static func usable(_ affects: [WeightedAffect]) -> [WeightedAffect] {
        affects.filter { $0.weight > 0 }
    }

    /// True only when the override carries a usable tag. An empty (or all-zero) override is not a
    /// correction — it must not report the detection as overridden, nor discard it.
    public var isOverridden: Bool { !Self.usable(override ?? []).isEmpty }

    /// What pattern-fit actually scores against: the override when it carries usable signal, else the
    /// detection. Empty when neither does — the assembler then falls back to the brief tone tags.
    public var effective: [WeightedAffect] {
        let overridden = Self.usable(override ?? [])
        return overridden.isEmpty ? Self.usable(detected) : overridden
    }

    public static func load(dataRoot: URL) -> AffectProfile? {
        try? JSONArtifactStore(dataRoot: dataRoot).load(AffectProfile.self, at: file)
    }

    public func save(dataRoot: URL) throws {
        try JSONArtifactStore(dataRoot: dataRoot).save(self, to: Self.file)
    }
}
