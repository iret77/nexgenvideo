import Foundation
import NexGenEngine

/// Director-Pattern schema (v0.12.0+). Port of
/// `nexgen_pack_musicvideo/patterns_schema.py`.
///
/// Shot-/cut-/tempo planning takes cues from known references (films, music
/// videos, directors, DOPs) where they fit the project type. Patterns are
/// suggested in the brief, used in the storyboard as a compose backbone, and
/// mirrored against the real plan in the sanity phase via a PATTERN_DRIFT
/// check.
///
/// Every pattern entry MUST carry `references[].sources[]` with verifiable
/// URLs — no invented data without a source. Pattern values (`aslRange`,
/// `framingMix`) are approximations, not Cinemetrics-grade precision. A
/// pattern describes a LANGUAGE, not a straitjacket — escape via
/// `pattern_override:` in the brief or a shot's notes.

/// Coarse BPM bands (parallel to the pack's tempo classification). Port of
/// `patterns_schema.py::TempoBand`.
public enum PatternTempoBand: String, Codable, Sendable, CaseIterable {
    case slow      // < 80 BPM
    case medium    // 80-110 BPM
    case uptempo   // 110-140 BPM
    case fast      // > 140 BPM
}

/// Port of `patterns_schema.py::_tempo_band`.
func patternTempoBand(_ perceivedBPM: Double) -> PatternTempoBand {
    if perceivedBPM < 80 { return .slow }
    if perceivedBPM < 110 { return .medium }
    if perceivedBPM < 140 { return .uptempo }
    return .fast
}

/// A verifiable source for a pattern reference. Port of
/// `patterns_schema.py::ReferenceSource`.
public struct ReferenceSource: Codable, Sendable, Equatable {
    /// Short description of the source, e.g. "Wikipedia: Hype Williams videography".
    public var label: String
    /// Full URL, https preferred.
    public var url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

/// A concrete reference — director / film / music video / DOP. Port of
/// `patterns_schema.py::PatternReference`.
public struct PatternReference: Codable, Sendable, Equatable {
    /// Name of the referenced artifact/person, e.g. "Anton Corbijn — Depeche
    /// Mode, Joy Division videography".
    public var name: String
    /// Role: "director", "dop", "editor", "film", "music_video".
    public var role: String
    /// Example works, a short (non-exhaustive) list.
    public var notableWorks: [String]
    /// At least one source, otherwise the reference is fiction.
    public var sources: [ReferenceSource]

    private enum CodingKeys: String, CodingKey {
        case name
        case role
        case notableWorks = "notable_works"
        case sources
    }

    public init(name: String, role: String, notableWorks: [String] = [], sources: [ReferenceSource]) {
        self.name = name
        self.role = role
        self.notableWorks = notableWorks
        self.sources = sources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decode(String.self, forKey: .role)
        notableWorks = try container.decodeIfPresent([String].self, forKey: .notableWorks) ?? []
        sources = try container.decode([ReferenceSource].self, forKey: .sources)
    }
}

/// One step in the ideal section arc (Intro/Verse/Chorus/Bridge). Port of
/// `patterns_schema.py::SectionArcStep`.
public struct SectionArcStep: Codable, Sendable, Equatable {
    /// Function name: "establishing", "reveal", "detail", "cutaway",
    /// "performance", "reaction", "transition", "resolve".
    public var role: String
    /// Which framings typically carry this function.
    public var framingHint: [Framing]
    public var notes: String

    private enum CodingKeys: String, CodingKey {
        case role
        case framingHint = "framing_hint"
        case notes
    }

    public init(role: String, framingHint: [Framing], notes: String = "") {
        self.role = role
        self.framingHint = framingHint
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        framingHint = try container.decode([Framing].self, forKey: .framingHint)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

/// Target distribution of framings, in percent (sums to ~100). Port of
/// `patterns_schema.py::FramingMix`.
public struct FramingMix: Codable, Sendable, Equatable {
    public var widePct: Int
    public var fullPct: Int
    public var msPct: Int
    public var mcuPct: Int
    public var cuPct: Int
    public var ecuPct: Int
    public var otsPct: Int
    public var povPct: Int
    public var insertPct: Int
    public var aerialPct: Int

    private enum CodingKeys: String, CodingKey {
        case widePct = "wide_pct"
        case fullPct = "full_pct"
        case msPct = "ms_pct"
        case mcuPct = "mcu_pct"
        case cuPct = "cu_pct"
        case ecuPct = "ecu_pct"
        case otsPct = "ots_pct"
        case povPct = "pov_pct"
        case insertPct = "insert_pct"
        case aerialPct = "aerial_pct"
    }

    public init(
        widePct: Int = 0, fullPct: Int = 0, msPct: Int = 0, mcuPct: Int = 0, cuPct: Int = 0, ecuPct: Int = 0,
        otsPct: Int = 0, povPct: Int = 0, insertPct: Int = 0, aerialPct: Int = 0
    ) {
        self.widePct = widePct
        self.fullPct = fullPct
        self.msPct = msPct
        self.mcuPct = mcuPct
        self.cuPct = cuPct
        self.ecuPct = ecuPct
        self.otsPct = otsPct
        self.povPct = povPct
        self.insertPct = insertPct
        self.aerialPct = aerialPct
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        widePct = try container.decodeIfPresent(Int.self, forKey: .widePct) ?? 0
        fullPct = try container.decodeIfPresent(Int.self, forKey: .fullPct) ?? 0
        msPct = try container.decodeIfPresent(Int.self, forKey: .msPct) ?? 0
        mcuPct = try container.decodeIfPresent(Int.self, forKey: .mcuPct) ?? 0
        cuPct = try container.decodeIfPresent(Int.self, forKey: .cuPct) ?? 0
        ecuPct = try container.decodeIfPresent(Int.self, forKey: .ecuPct) ?? 0
        otsPct = try container.decodeIfPresent(Int.self, forKey: .otsPct) ?? 0
        povPct = try container.decodeIfPresent(Int.self, forKey: .povPct) ?? 0
        insertPct = try container.decodeIfPresent(Int.self, forKey: .insertPct) ?? 0
        aerialPct = try container.decodeIfPresent(Int.self, forKey: .aerialPct) ?? 0
    }

    /// Port of `FramingMix.by_framing`.
    public func byFraming() -> [Framing: Int] {
        [
            .wide: widePct, .full: fullPct, .ms: msPct, .mcu: mcuPct, .cu: cuPct, .ecu: ecuPct, .ots: otsPct,
            .pov: povPct, .insert: insertPct, .aerial: aerialPct,
        ]
    }
}

/// Average Shot Length: range in seconds. Port of `patterns_schema.py::AslRange`.
public struct AslRange: Codable, Sendable, Equatable {
    public var minS: Double
    public var maxS: Double
    public var typicalS: Double

    private enum CodingKeys: String, CodingKey {
        case minS = "min_s"
        case maxS = "max_s"
        case typicalS = "typical_s"
    }

    public init(minS: Double, maxS: Double, typicalS: Double) {
        self.minS = minS
        self.maxS = maxS
        self.typicalS = typicalS
    }
}

/// Director pattern: a positive compose backbone for the shotlist. Port of
/// `patterns_schema.py::Pattern`.
///
/// The unshipped integer `triggers` scorer was removed in the pattern-fit
/// cutover (`docs/PATTERN_FIT_CONTRACT.md`). Recommendation now runs off the
/// mandatory `fit_profile` block via `PatternFitScorer`; the fields below stay
/// as the compose backbone (`framing_mix`, `asl_range`, camera vocabulary,
/// lighting signature, section arc) that the storyboard and PATTERN_DRIFT read.
public struct Pattern: Codable, Sendable, Equatable {
    /// Slug id, e.g. "narrative-folk-static-long-takes".
    public var id: String
    /// User-facing readable name, e.g. "Narrative Folk — static long takes".
    public var name: String
    /// 1-3 sentences describing what distinguishes this pattern (for user display).
    public var description: String
    /// The mandatory Pattern-fit block, or nil until it is authored. A nil or
    /// invalid profile keeps the pattern out of recommendations (fail-closed);
    /// the compose/style path via `get`/`PATTERN_DRIFT` still works without it.
    public var fitProfile: PatternFitProfile?
    /// Verifiable references with sources — at least one.
    public var references: [PatternReference]
    /// Recommended internal structure of a section.
    public var sectionArc: [SectionArcStep]
    /// Target distribution of framings across the whole shotlist.
    public var framingMix: FramingMix
    public var aslRange: AslRange
    /// Preferred movement vocabulary, e.g. ["static hold", "slow push-in", "lateral track"].
    public var cameraVocabulary: [String]
    /// Short lighting-style summary, e.g. "warm natural daylight, soft shadows, golden-hour bias".
    public var lightingSignature: String
    /// Source discipline: where do the framing_mix / asl_range values come
    /// from? E.g. "qualitative aggregation from cited videography pages, not
    /// Cinemetrics-grade; refine via real shot counts."
    public var approximationBasis: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case fitProfile = "fit_profile"
        case references
        case sectionArc = "section_arc"
        case framingMix = "framing_mix"
        case aslRange = "asl_range"
        case cameraVocabulary = "camera_vocabulary"
        case lightingSignature = "lighting_signature"
        case approximationBasis = "approximation_basis"
    }

    public init(
        id: String, name: String, description: String, references: [PatternReference],
        sectionArc: [SectionArcStep], framingMix: FramingMix, aslRange: AslRange, cameraVocabulary: [String],
        lightingSignature: String, approximationBasis: String, fitProfile: PatternFitProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.fitProfile = fitProfile
        self.references = references
        self.sectionArc = sectionArc
        self.framingMix = framingMix
        self.aslRange = aslRange
        self.cameraVocabulary = cameraVocabulary
        self.lightingSignature = lightingSignature
        self.approximationBasis = approximationBasis
    }
}

// MARK: - Loader

public enum PatternLibraryError: Swift.Error, Sendable {
    case decodingFailed(file: String, underlying: String)
}

/// Loads the pattern library. Recommendation scoring lives in
/// `PatternFitScorer` (the fit contract); this type only decodes YAMLs.
public enum Patterns {
    /// Loads a `Pattern` from a single YAML string. Port of `load_pattern`
    /// (Swift takes YAML text + a name for error messages, since resource
    /// loading is `Bundle.module`-based rather than filesystem `Path`-based).
    public static func loadPattern(yaml: String, fileName: String) throws -> Pattern {
        do {
            return try YAMLCoding.decode(Pattern.self, from: yaml)
        } catch {
            throw PatternLibraryError.decodingFailed(file: fileName, underlying: String(describing: error))
        }
    }

    /// Loads every pattern YAML in `PackKnowledge.patternLibraryURLs`, sorted
    /// by filename (mirrors `sorted(pdir.glob("*.yaml"))`). Port of
    /// `load_all_patterns`.
    public static func loadAllPatterns() throws -> [Pattern] {
        var out: [Pattern] = []
        for url in PackKnowledge.patternLibraryURLs().sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append(try loadPattern(yaml: text, fileName: url.lastPathComponent))
        }
        return out
    }
}
