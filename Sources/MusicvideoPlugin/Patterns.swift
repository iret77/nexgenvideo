import Foundation
import NexGenEngine

/// Director-pattern schema. Every operative value states whether it is measured,
/// documented, or inferred and cites the material behind that classification.
/// A pattern describes a language, not a straitjacket — escape via
/// `pattern_override:` in the brief or a shot's notes.

struct PatternCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func rejectUnknownPatternKeys(
    _ decoder: Decoder,
    allowed: Set<String>,
    context: String
) throws {
    let container = try decoder.container(keyedBy: PatternCodingKey.self)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "\(context) has unknown fields: \(unknown.joined(separator: ", "))"
            )
        )
    }
}

public enum PatternEvidenceBasis: String, Codable, Sendable, CaseIterable {
    case measured
    case documented
    case inferred
}

public struct PatternReferenceVideo: Codable, Sendable, Equatable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public protocol PatternProvenancedValue {
    var basis: PatternEvidenceBasis { get }
    var sources: [String] { get }
    var referenceVideo: PatternReferenceVideo? { get }
}

public enum PatternPipelineLever: String, Codable, Sendable, CaseIterable {
    case visualPrompt = "visual_prompt"
    case bibleLook = "bible_look"
    case bibleLighting = "bible_lighting"
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
    public var basis: PatternEvidenceBasis
    public var sources: [String]
    public var referenceVideo: PatternReferenceVideo?

    private enum CodingKeys: String, CodingKey, CaseIterable {
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
        case basis
        case sources
        case referenceVideo = "reference_video"
    }

    public init(
        widePct: Int = 0, fullPct: Int = 0, msPct: Int = 0, mcuPct: Int = 0, cuPct: Int = 0, ecuPct: Int = 0,
        otsPct: Int = 0, povPct: Int = 0, insertPct: Int = 0, aerialPct: Int = 0,
        basis: PatternEvidenceBasis, sources: [String], referenceVideo: PatternReferenceVideo? = nil
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
        self.basis = basis
        self.sources = sources
        self.referenceVideo = referenceVideo
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownPatternKeys(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            context: "framing_mix"
        )
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
        basis = try container.decode(PatternEvidenceBasis.self, forKey: .basis)
        sources = try container.decode([String].self, forKey: .sources)
        referenceVideo = try container.decodeIfPresent(PatternReferenceVideo.self, forKey: .referenceVideo)
    }

    /// Port of `FramingMix.by_framing`.
    public func byFraming() -> [Framing: Int] {
        [
            .wide: widePct, .full: fullPct, .ms: msPct, .mcu: mcuPct, .cu: cuPct, .ecu: ecuPct, .ots: otsPct,
            .pov: povPct, .insert: insertPct, .aerial: aerialPct,
        ]
    }
}

extension FramingMix: PatternProvenancedValue {}

/// Average Shot Length: range in seconds. Port of `patterns_schema.py::AslRange`.
public struct AslRange: Codable, Sendable, Equatable {
    public var minS: Double
    public var maxS: Double
    public var typicalS: Double
    public var basis: PatternEvidenceBasis
    public var sources: [String]
    public var referenceVideo: PatternReferenceVideo?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case minS = "min_s"
        case maxS = "max_s"
        case typicalS = "typical_s"
        case basis
        case sources
        case referenceVideo = "reference_video"
    }

    public init(
        minS: Double, maxS: Double, typicalS: Double,
        basis: PatternEvidenceBasis, sources: [String], referenceVideo: PatternReferenceVideo? = nil
    ) {
        self.minS = minS
        self.maxS = maxS
        self.typicalS = typicalS
        self.basis = basis
        self.sources = sources
        self.referenceVideo = referenceVideo
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownPatternKeys(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            context: "asl_range"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minS = try container.decode(Double.self, forKey: .minS)
        maxS = try container.decode(Double.self, forKey: .maxS)
        typicalS = try container.decode(Double.self, forKey: .typicalS)
        basis = try container.decode(PatternEvidenceBasis.self, forKey: .basis)
        sources = try container.decode([String].self, forKey: .sources)
        referenceVideo = try container.decodeIfPresent(PatternReferenceVideo.self, forKey: .referenceVideo)
    }
}

extension AslRange: PatternProvenancedValue {}

public struct PatternCamera: Codable, Sendable, Equatable, PatternProvenancedValue {
    public var vocabulary: [String]
    public var basis: PatternEvidenceBasis
    public var sources: [String]
    public var referenceVideo: PatternReferenceVideo?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case vocabulary
        case basis
        case sources
        case referenceVideo = "reference_video"
    }

    public init(
        vocabulary: [String], basis: PatternEvidenceBasis, sources: [String],
        referenceVideo: PatternReferenceVideo? = nil
    ) {
        self.vocabulary = vocabulary
        self.basis = basis
        self.sources = sources
        self.referenceVideo = referenceVideo
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownPatternKeys(
            decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)), context: "camera"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vocabulary = try container.decode([String].self, forKey: .vocabulary)
        basis = try container.decode(PatternEvidenceBasis.self, forKey: .basis)
        sources = try container.decode([String].self, forKey: .sources)
        referenceVideo = try container.decodeIfPresent(PatternReferenceVideo.self, forKey: .referenceVideo)
    }
}

public struct PatternLighting: Codable, Sendable, Equatable, PatternProvenancedValue {
    public var description: String
    public var basis: PatternEvidenceBasis
    public var sources: [String]
    public var referenceVideo: PatternReferenceVideo?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case description
        case basis
        case sources
        case referenceVideo = "reference_video"
    }

    public init(
        description: String, basis: PatternEvidenceBasis, sources: [String],
        referenceVideo: PatternReferenceVideo? = nil
    ) {
        self.description = description
        self.basis = basis
        self.sources = sources
        self.referenceVideo = referenceVideo
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownPatternKeys(
            decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)), context: "lighting"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decode(String.self, forKey: .description)
        basis = try container.decode(PatternEvidenceBasis.self, forKey: .basis)
        sources = try container.decode([String].self, forKey: .sources)
        referenceVideo = try container.decodeIfPresent(PatternReferenceVideo.self, forKey: .referenceVideo)
    }
}

public struct PatternColor: Codable, Sendable, Equatable, PatternProvenancedValue {
    public var description: String
    public var basis: PatternEvidenceBasis
    public var sources: [String]
    public var referenceVideo: PatternReferenceVideo?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case description
        case basis
        case sources
        case referenceVideo = "reference_video"
    }

    public init(
        description: String, basis: PatternEvidenceBasis, sources: [String],
        referenceVideo: PatternReferenceVideo? = nil
    ) {
        self.description = description
        self.basis = basis
        self.sources = sources
        self.referenceVideo = referenceVideo
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownPatternKeys(
            decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)), context: "color"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decode(String.self, forKey: .description)
        basis = try container.decode(PatternEvidenceBasis.self, forKey: .basis)
        sources = try container.decode([String].self, forKey: .sources)
        referenceVideo = try container.decodeIfPresent(PatternReferenceVideo.self, forKey: .referenceVideo)
    }
}

public struct PatternCraftTechnique: Codable, Sendable, Equatable, PatternProvenancedValue {
    public var technique: String
    public var directive: String
    public var pipelineLevers: [PatternPipelineLever]
    public var basis: PatternEvidenceBasis
    public var sources: [String]
    public var referenceVideo: PatternReferenceVideo?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case technique
        case directive
        case pipelineLevers = "pipeline_levers"
        case basis
        case sources
        case referenceVideo = "reference_video"
    }

    public init(
        technique: String, directive: String, pipelineLevers: [PatternPipelineLever],
        basis: PatternEvidenceBasis, sources: [String], referenceVideo: PatternReferenceVideo? = nil
    ) {
        self.technique = technique
        self.directive = directive
        self.pipelineLevers = pipelineLevers
        self.basis = basis
        self.sources = sources
        self.referenceVideo = referenceVideo
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownPatternKeys(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            context: "craft_signature entry"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        technique = try container.decode(String.self, forKey: .technique)
        directive = try container.decode(String.self, forKey: .directive)
        pipelineLevers = try container.decode([PatternPipelineLever].self, forKey: .pipelineLevers)
        basis = try container.decode(PatternEvidenceBasis.self, forKey: .basis)
        sources = try container.decode([String].self, forKey: .sources)
        referenceVideo = try container.decodeIfPresent(PatternReferenceVideo.self, forKey: .referenceVideo)
    }
}

/// Director-pattern backbone for shot composition and deterministic fit recommendations.
public struct Pattern: Codable, Sendable, Equatable {
    /// Slug id, e.g. "narrative-folk-static-long-takes".
    public var id: String
    /// User-facing readable name, e.g. "Narrative Folk — static long takes".
    public var name: String
    /// 1-3 sentences describing what distinguishes this pattern (for user display).
    public var description: String
    /// Optional while unauthored; only present, valid profiles are recommendable.
    public var fitProfile: PatternFitProfile?
    /// Verifiable references with sources — at least one.
    public var references: [PatternReference]
    /// Recommended internal structure of a section.
    public var sectionArc: [SectionArcStep]
    /// Target distribution of framings across the whole shotlist.
    public var framingMix: FramingMix
    public var aslRange: AslRange
    public var camera: PatternCamera
    public var lighting: PatternLighting
    public var color: PatternColor
    public var craftSignature: [PatternCraftTechnique]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case description
        case fitProfile = "fit_profile"
        case references
        case sectionArc = "section_arc"
        case framingMix = "framing_mix"
        case aslRange = "asl_range"
        case camera
        case lighting
        case color
        case craftSignature = "craft_signature"
    }

    public init(
        id: String, name: String, description: String, references: [PatternReference],
        sectionArc: [SectionArcStep], framingMix: FramingMix, aslRange: AslRange, camera: PatternCamera,
        lighting: PatternLighting, color: PatternColor, craftSignature: [PatternCraftTechnique],
        fitProfile: PatternFitProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.fitProfile = fitProfile
        self.references = references
        self.sectionArc = sectionArc
        self.framingMix = framingMix
        self.aslRange = aslRange
        self.camera = camera
        self.lighting = lighting
        self.color = color
        self.craftSignature = craftSignature
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownPatternKeys(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            context: "pattern"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        fitProfile = try container.decodeIfPresent(PatternFitProfile.self, forKey: .fitProfile)
        references = try container.decode([PatternReference].self, forKey: .references)
        sectionArc = try container.decode([SectionArcStep].self, forKey: .sectionArc)
        framingMix = try container.decode(FramingMix.self, forKey: .framingMix)
        aslRange = try container.decode(AslRange.self, forKey: .aslRange)
        camera = try container.decode(PatternCamera.self, forKey: .camera)
        lighting = try container.decode(PatternLighting.self, forKey: .lighting)
        color = try container.decode(PatternColor.self, forKey: .color)
        craftSignature = try container.decode([PatternCraftTechnique].self, forKey: .craftSignature)
    }
}

public enum PatternSchemaValidator {
    public static func validate(_ pattern: Pattern) -> [String] {
        var issues: [String] = []
        if pattern.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("id is empty") }
        if pattern.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("name is empty") }
        if pattern.references.isEmpty { issues.append("references is empty") }
        for reference in pattern.references {
            if reference.sources.isEmpty { issues.append("reference '\(reference.name)' has no sources") }
            for source in reference.sources {
                if source.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("reference '\(reference.name)' has an unlabeled source")
                }
                if !isWebURL(source.url) {
                    issues.append("reference '\(reference.name)' has a non-web source URL")
                }
            }
        }
        if pattern.sectionArc.isEmpty { issues.append("section_arc is empty") }

        let framingTotal = pattern.framingMix.byFraming().values.reduce(0, +)
        if framingTotal != 100 { issues.append("framing_mix totals \(framingTotal), expected 100") }
        if pattern.framingMix.byFraming().values.contains(where: { $0 < 0 || $0 > 100 }) {
            issues.append("framing_mix percentages must be between 0 and 100")
        }
        if pattern.aslRange.minS <= 0 { issues.append("asl_range.min_s must be positive") }
        if pattern.aslRange.maxS < pattern.aslRange.minS { issues.append("asl_range.max_s is below min_s") }
        if pattern.aslRange.typicalS < pattern.aslRange.minS || pattern.aslRange.typicalS > pattern.aslRange.maxS {
            issues.append("asl_range.typical_s is outside min_s...max_s")
        }
        if pattern.camera.vocabulary.isEmpty { issues.append("camera.vocabulary is empty") }
        if pattern.lighting.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("lighting.description is empty")
        }
        if pattern.color.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("color.description is empty")
        }

        let values: [(String, any PatternProvenancedValue)] = [
            ("framing_mix", pattern.framingMix),
            ("asl_range", pattern.aslRange),
            ("camera", pattern.camera),
            ("lighting", pattern.lighting),
            ("color", pattern.color),
        ]
        for (path, value) in values {
            issues.append(contentsOf: provenanceIssues(value, path: path))
        }

        if pattern.craftSignature.isEmpty { issues.append("craft_signature is empty") }
        for (index, technique) in pattern.craftSignature.enumerated() {
            let path = "craft_signature[\(index)]"
            if technique.technique.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(path).technique is empty")
            }
            if technique.directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(path).directive is empty")
            }
            if technique.pipelineLevers.isEmpty { issues.append("\(path).pipeline_levers is empty") }
            if Set(technique.pipelineLevers).count != technique.pipelineLevers.count {
                issues.append("\(path).pipeline_levers contains duplicates")
            }
            issues.append(contentsOf: provenanceIssues(technique, path: path))
        }
        return issues
    }

    private static func provenanceIssues(_ value: any PatternProvenancedValue, path: String) -> [String] {
        var issues: [String] = []
        if value.sources.isEmpty { issues.append("\(path).sources is empty") }
        for source in value.sources where !isWebURL(source) {
            issues.append("\(path).sources contains a non-web URL")
        }
        if value.basis == .measured {
            guard let video = value.referenceVideo else {
                issues.append("\(path).reference_video is required for measured evidence")
                return issues
            }
            if video.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(path).reference_video.title is empty")
            }
            if !isWebURL(video.url) { issues.append("\(path).reference_video.url is not a web URL") }
        } else if value.referenceVideo != nil {
            issues.append("\(path).reference_video is only valid for measured evidence")
        }
        return issues
    }

    private static func isWebURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "https" || components.scheme == "http",
              components.host?.isEmpty == false else { return false }
        return true
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
            let pattern = try YAMLCoding.decode(Pattern.self, from: yaml)
            let issues = PatternSchemaValidator.validate(pattern)
            guard issues.isEmpty else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: issues.joined(separator: "; "))
                )
            }
            return pattern
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
