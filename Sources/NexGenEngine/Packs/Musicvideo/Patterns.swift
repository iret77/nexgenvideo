import Foundation

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

/// Coarse mood classification, used for pattern triggers. Port of
/// `patterns_schema.py::MoodBand`.
public enum MoodBand: String, Codable, Sendable, CaseIterable {
    case introspective
    case melancholic
    case euphoric
    case highEnergy = "high_energy"
    case aggressive
    case dreamy
    case intimate
    case narrative
    case cinematic
}

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

/// Which brief properties activate this pattern. Empty list = wildcard (all
/// values pass). Port of `patterns_schema.py::PatternTriggers`.
public struct PatternTriggers: Codable, Sendable, Equatable {
    public var visualMediums: [VisualMedium]
    public var moods: [MoodBand]
    public var tempoBands: [PatternTempoBand]
    public var conceptTypes: [ConceptType]
    public var figures: [FigurePresence]
    public var aspectRatios: [AspectRatio]

    private enum CodingKeys: String, CodingKey {
        case visualMediums = "visual_mediums"
        case moods
        case tempoBands = "tempo_bands"
        case conceptTypes = "concept_types"
        case figures
        case aspectRatios = "aspect_ratios"
    }

    public init(
        visualMediums: [VisualMedium] = [], moods: [MoodBand] = [], tempoBands: [PatternTempoBand] = [],
        conceptTypes: [ConceptType] = [], figures: [FigurePresence] = [], aspectRatios: [AspectRatio] = []
    ) {
        self.visualMediums = visualMediums
        self.moods = moods
        self.tempoBands = tempoBands
        self.conceptTypes = conceptTypes
        self.figures = figures
        self.aspectRatios = aspectRatios
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visualMediums = try container.decodeIfPresent([VisualMedium].self, forKey: .visualMediums) ?? []
        moods = try container.decodeIfPresent([MoodBand].self, forKey: .moods) ?? []
        tempoBands = try container.decodeIfPresent([PatternTempoBand].self, forKey: .tempoBands) ?? []
        conceptTypes = try container.decodeIfPresent([ConceptType].self, forKey: .conceptTypes) ?? []
        figures = try container.decodeIfPresent([FigurePresence].self, forKey: .figures) ?? []
        aspectRatios = try container.decodeIfPresent([AspectRatio].self, forKey: .aspectRatios) ?? []
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

/// A single trigger-match in pattern scoring. Port of
/// `patterns_schema.py::PatternMatchReason`.
public struct PatternMatchReason: Sendable, Equatable {
    /// "visual_medium" | "mood" | "tempo" | "concept" | "figures" | "aspect".
    public let field: String
    /// True = trigger matched, false = mismatch.
    public let hit: Bool
    /// Point contribution (positive or negative).
    public let points: Int
    /// User input, for display.
    public let inputValue: String
}

/// Result of a pattern-scoring run. Port of `patterns_schema.py::PatternScore`.
public struct PatternScore: Sendable, Equatable {
    public let patternId: String
    public let patternName: String
    public let score: Int
    public let reasons: [PatternMatchReason]

    /// Plain-text justification for user display. Port of
    /// `PatternScore.hit_summary`.
    public func hitSummary() -> String {
        guard !reasons.isEmpty else { return "(no triggers checked, score \(score))" }
        let parts = reasons.map { "\($0.field) \($0.hit ? "\u{2713}" : "\u{2717}")" }
        return "\(parts.joined(separator: " \u{b7} ")) (Score \(score))"
    }
}

/// Director pattern: a positive compose backbone for the shotlist. Port of
/// `patterns_schema.py::Pattern`.
public struct Pattern: Codable, Sendable, Equatable {
    /// Slug id, e.g. "narrative-folk-static-long-takes".
    public var id: String
    /// User-facing readable name, e.g. "Narrative Folk — static long takes".
    public var name: String
    /// 1-3 sentences describing what distinguishes this pattern (for user display).
    public var description: String
    public var triggers: PatternTriggers
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
        case triggers
        case references
        case sectionArc = "section_arc"
        case framingMix = "framing_mix"
        case aslRange = "asl_range"
        case cameraVocabulary = "camera_vocabulary"
        case lightingSignature = "lighting_signature"
        case approximationBasis = "approximation_basis"
    }

    public init(
        id: String, name: String, description: String, triggers: PatternTriggers, references: [PatternReference],
        sectionArc: [SectionArcStep], framingMix: FramingMix, aslRange: AslRange, cameraVocabulary: [String],
        lightingSignature: String, approximationBasis: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.triggers = triggers
        self.references = references
        self.sectionArc = sectionArc
        self.framingMix = framingMix
        self.aslRange = aslRange
        self.cameraVocabulary = cameraVocabulary
        self.lightingSignature = lightingSignature
        self.approximationBasis = approximationBasis
    }

    /// True when every set trigger list allows the input (empty list = wildcard).
    ///
    /// Backward-compat entry point for v0.12.x callers. New callers use
    /// `scoreAgainst` and sort by score. Port of `Pattern.matches`.
    public func matches(
        visualMedium: VisualMedium?, mood: MoodBand?, tempo: PatternTempoBand?, concept: ConceptType?,
        figures: FigurePresence?, aspect: AspectRatio?
    ) -> Bool {
        let t = triggers
        if !t.visualMediums.isEmpty, let visualMedium, !t.visualMediums.contains(visualMedium) { return false }
        if !t.moods.isEmpty, let mood, !t.moods.contains(mood) { return false }
        if !t.tempoBands.isEmpty, let tempo, !t.tempoBands.contains(tempo) { return false }
        if !t.conceptTypes.isEmpty, let concept, !t.conceptTypes.contains(concept) { return false }
        if !t.figures.isEmpty, let figures, !t.figures.contains(figures) { return false }
        if !t.aspectRatios.isEmpty, let aspect, !t.aspectRatios.contains(aspect) { return false }
        return true
    }

    /// Weighted match score against user brief inputs (v0.13.0).
    ///
    /// Point system:
    /// - visualMedium: +3 on match. Mismatch: -10 (hard veto) OR -2 if
    ///   `allowGenreCross=true` (`brief.allow_genre_cross_patterns`). The hard
    ///   veto by default stops e.g. an anime pattern from being suggested on
    ///   a live-action brief — a deliberate genre-cross lifts that.
    /// - mood: +2 on match, -2 on mismatch.
    /// - tempo: +2 on match, -1 on mismatch.
    /// - concept: +2 on match, -1 on mismatch.
    /// - figures: +1 on match, -1 on mismatch.
    /// - aspect: +1 on match, 0 on mismatch (very rarely filtered).
    /// - Wildcard (empty trigger list): 0 points (neutral).
    /// - Input nil: 0 points (the user brief has not set the field).
    ///
    /// Port of `Pattern.score_against`.
    public func scoreAgainst(
        visualMedium: VisualMedium?, mood: MoodBand?, tempo: PatternTempoBand?, concept: ConceptType?,
        figures: FigurePresence?, aspect: AspectRatio?, allowGenreCross: Bool = false
    ) -> PatternScore {
        let vmMismatch = allowGenreCross ? -2 : -10
        let t = triggers
        var score = 0
        var reasons: [PatternMatchReason] = []

        func check<T: Equatable>(field: String, input: T?, allowed: [T], matchPt: Int, mismatchPt: Int, label: (T) -> String) {
            guard let input else { return }
            guard !allowed.isEmpty else { return }  // Wildcard — pattern has no requirement on this field.
            if allowed.contains(input) {
                score += matchPt
                reasons.append(PatternMatchReason(field: field, hit: true, points: matchPt, inputValue: label(input)))
            } else {
                score += mismatchPt
                reasons.append(PatternMatchReason(field: field, hit: false, points: mismatchPt, inputValue: label(input)))
            }
        }

        check(field: "visual_medium", input: visualMedium, allowed: t.visualMediums, matchPt: 3, mismatchPt: vmMismatch) { $0.rawValue }
        check(field: "mood", input: mood, allowed: t.moods, matchPt: 2, mismatchPt: -2) { $0.rawValue }
        check(field: "tempo", input: tempo, allowed: t.tempoBands, matchPt: 2, mismatchPt: -1) { $0.rawValue }
        check(field: "concept", input: concept, allowed: t.conceptTypes, matchPt: 2, mismatchPt: -1) { $0.rawValue }
        check(field: "figures", input: figures, allowed: t.figures, matchPt: 1, mismatchPt: -1) { $0.rawValue }
        check(field: "aspect", input: aspect, allowed: t.aspectRatios, matchPt: 1, mismatchPt: 0) { $0.rawValue }

        return PatternScore(patternId: id, patternName: name, score: score, reasons: reasons)
    }
}

// MARK: - Loader

public enum PatternLibraryError: Swift.Error, Sendable {
    case decodingFailed(file: String, underlying: String)
}

/// Loads and scores the pattern library. Port of the loader/scorer half of
/// `patterns_schema.py` (`load_pattern`, `load_all_patterns`,
/// `score_patterns`, `suggest_patterns`).
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

    /// Returns the pattern library sorted by match score (v0.13.0). Port of
    /// `score_patterns`.
    ///
    /// - Parameters:
    ///   - maxResults: top-N by score.
    ///   - minScore: patterns below this threshold are filtered out. `nil` =
    ///     no threshold (negative scores allowed too).
    ///   - allowGenreCross: `true` lifts the visual_medium veto (-10 -> -2).
    ///     Pass through from `brief.allow_genre_cross_patterns` when the
    ///     caller has the flag set in the brief.
    public static func scorePatterns(
        visualMedium: VisualMedium? = nil, mood: MoodBand? = nil, perceivedBPM: Double? = nil,
        concept: ConceptType? = nil, figures: FigurePresence? = nil, aspect: AspectRatio? = nil, maxResults: Int = 5,
        minScore: Int? = 0, allowGenreCross: Bool = false
    ) throws -> [(pattern: Pattern, score: PatternScore)] {
        let tempoBand = perceivedBPM.map(patternTempoBand)
        var scored: [(Pattern, PatternScore)] = []
        for p in try loadAllPatterns() {
            let s = p.scoreAgainst(
                visualMedium: visualMedium, mood: mood, tempo: tempoBand, concept: concept, figures: figures,
                aspect: aspect, allowGenreCross: allowGenreCross
            )
            if let minScore, s.score < minScore { continue }
            scored.append((p, s))
        }
        scored.sort { $0.1.score > $1.1.score }
        return Array(scored.prefix(maxResults))
    }

    /// Filter over all known patterns (v0.12.x backward-compat). Hard filter
    /// via `Pattern.matches`. New callers should use `scorePatterns` — it
    /// returns a sorted list with `PatternScore` justification. Port of
    /// `suggest_patterns`.
    public static func suggestPatterns(
        visualMedium: VisualMedium? = nil, mood: MoodBand? = nil, perceivedBPM: Double? = nil,
        concept: ConceptType? = nil, figures: FigurePresence? = nil, aspect: AspectRatio? = nil, maxResults: Int = 3
    ) throws -> [Pattern] {
        let tempoBand = perceivedBPM.map(patternTempoBand)
        let matches = try loadAllPatterns().filter {
            $0.matches(
                visualMedium: visualMedium, mood: mood, tempo: tempoBand, concept: concept, figures: figures,
                aspect: aspect
            )
        }
        return Array(matches.prefix(maxResults))
    }
}
