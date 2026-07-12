import Foundation
import NexGenEngine

/// Analysis schema v2 (backward-compatible with v1). Port of
/// `nexgen_pack_musicvideo/analysis_schema.py`.
///
/// v2 introduces the following fields, all optional (absent from v1
/// analyses): `stemsPath`, `alignment` (word/line-level forced alignment
/// against supplied lyrics), `structureSources` (multiple section
/// candidates from different detectors), `energyCurve`, `tempoCurve`, `key`,
/// `chordProgression`.
///
/// The primary `sections` list is merged by the consolidator (see
/// `Consolidator.swift`). This schema is kept self-contained here — the DSP
/// analysis pipeline that populates it lands separately (M8c).
public let analysisSchemaVersion = "analysis/v2"

/// Port of `analysis_schema.py::AnalysisSection`.
public struct AnalysisSection: Codable, Sendable, Equatable {
    public var index: Int
    public var start: Double
    public var end: Double
    public var cluster: Int
    /// Narrative, set by the analysis agent.
    public var label: String?
    /// "alignment" | "essentia" | "librosa" | "consolidated".
    public var source: String?
    public var confidence: Double?

    public init(
        index: Int, start: Double, end: Double, cluster: Int, label: String? = nil, source: String? = nil,
        confidence: Double? = nil
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.cluster = cluster
        self.label = label
        self.source = source
        self.confidence = confidence
    }
}

/// One forced-alignment word, kept as a loose string map since Python models
/// it as `dict` (no fixed schema on the word entries). Port of
/// `analysis_schema.py::AlignmentLine.words` element shape.
public struct AlignmentWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var score: Double?

    public init(text: String, start: Double, end: Double, score: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.score = score
    }
}

/// Port of `analysis_schema.py::AlignmentLine`.
public struct AlignmentLine: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    /// E.g. "verse1", "chorus1" — from `[AnalysisSection]` markers.
    public var sectionMarker: String?
    public var words: [AlignmentWord]

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case text
        case sectionMarker = "section_marker"
        case words
    }

    public init(start: Double, end: Double, text: String, sectionMarker: String? = nil, words: [AlignmentWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.sectionMarker = sectionMarker
        self.words = words
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        sectionMarker = try container.decodeIfPresent(String.self, forKey: .sectionMarker)
        words = try container.decodeIfPresent([AlignmentWord].self, forKey: .words) ?? []
    }
}

/// A section-candidate set from a particular detector. Port of
/// `analysis_schema.py::StructureCandidate`.
public struct StructureCandidate: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case alignment
        case essentia
        case librosa
    }

    public var source: Source
    public var sections: [AnalysisSection]
    public var notes: String?

    public init(source: Source, sections: [AnalysisSection] = [], notes: String? = nil) {
        self.source = source
        self.sections = sections
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(Source.self, forKey: .source)
        sections = try container.decodeIfPresent([AnalysisSection].self, forKey: .sections) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case sections
        case notes
    }
}

/// `EnergyPoint`/`TempoPoint` live alongside the pack's DSP in `Audio/AudioAnalysis.swift`
/// — music-domain time-series primitives the analysis pipeline produces.

/// Port of `analysis_schema.py::Stems`.
public struct Stems: Codable, Sendable, Equatable {
    /// Relative to the project directory.
    public var vocals: String?
    public var drums: String?
    public var bass: String?
    public var other: String?

    public init(vocals: String? = nil, drums: String? = nil, bass: String? = nil, other: String? = nil) {
        self.vocals = vocals
        self.drums = drums
        self.bass = bass
        self.other = other
    }
}

/// Port of `analysis_schema.py::Chord`.
public struct Chord: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// E.g. "Am", "G7", "C:maj".
    public var label: String

    public init(start: Double, end: Double, label: String) {
        self.start = start
        self.end = end
        self.label = label
    }
}

/// Loose-schema interpretation block — Python declares `extra="allow"`, so
/// unknown keys survive a round-trip. `Codable` has no direct analogue; the
/// engine keeps the three named fields (all the pack ever reads/writes) and
/// accepts that a foreign extra key would be dropped on re-encode. No caller
/// in this pack relies on preserving unknown interpretation keys.
public struct Interpretation: Codable, Sendable, Equatable {
    public var sectionLabels: [[String: String]]
    public var anomalies: [[String: String]]
    public var overallCharacter: String

    private enum CodingKeys: String, CodingKey {
        case sectionLabels = "section_labels"
        case anomalies
        case overallCharacter = "overall_character"
    }

    public init(sectionLabels: [[String: String]] = [], anomalies: [[String: String]] = [], overallCharacter: String = "") {
        self.sectionLabels = sectionLabels
        self.anomalies = anomalies
        self.overallCharacter = overallCharacter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sectionLabels = try container.decodeIfPresent([[String: String]].self, forKey: .sectionLabels) ?? []
        anomalies = try container.decodeIfPresent([[String: String]].self, forKey: .anomalies) ?? []
        overallCharacter = try container.decodeIfPresent(String.self, forKey: .overallCharacter) ?? ""
    }
}

/// The full audio analysis artifact (beat/downbeat/stems/chords/structure).
/// Port of `analysis_schema.py::Analysis`.
public struct Analysis: Codable, Sendable, Equatable {
    public var schema: String
    public var project: String
    public var songPath: String
    public var sampleRate: Int
    public var durationS: Double

    /// Technical BPM measurement (essentia / madmom / librosa).
    public var bpm: Double

    /// User-/A2-confirmed multiplier for the **perceived** tempo. Typical
    /// values: 0.5 (track feels half as fast as measured) / 1.0 (matches) /
    /// 2.0 (track feels twice as fast). Set interactively in the A2 phase,
    /// because the technical value is often half/double the subjective
    /// tempo, and this structurally affects storyboard/shotlist pacing.
    ///
    /// Consumers (sanity tempo cap, storyboard/shotlist agent) should use
    /// `perceivedBpm`, not the raw `bpm` value.
    public var tempoMultiplier: Double

    public var beats: [Double]
    public var downbeats: [Double]
    public var downbeatSource: DownbeatSource

    public enum DownbeatSource: String, Codable, Sendable, CaseIterable {
        case madmom
        case librosaHeuristic = "librosa-heuristic"
        case beatTransformer = "beat-transformer"
    }

    /// Subjectively perceived tempo = bpm x tempoMultiplier. Default
    /// multiplier 1.0 -> perceivedBpm == bpm. Port of `Analysis.perceived_bpm`.
    public var perceivedBpm: Double { bpm * tempoMultiplier }

    /// Structure (consolidated).
    public var sections: [AnalysisSection]

    // v2 extensions (all optional, may be absent).
    public var stems: Stems?
    public var alignment: [AlignmentLine]
    public var structureCandidates: [StructureCandidate]
    public var energyCurve: [EnergyPoint]
    public var tempoCurve: [TempoPoint]
    /// "C major" / "A minor".
    public var key: String?
    public var chordProgression: [Chord]

    /// Set by the analysis agent.
    public var interpretation: Interpretation?

    /// Which optional pipeline stages ran.
    public var pipelineStages: [String]

    private enum CodingKeys: String, CodingKey {
        case schema
        case project
        case songPath = "song_path"
        case sampleRate = "sample_rate"
        case durationS = "duration_s"
        case bpm
        case tempoMultiplier = "tempo_multiplier"
        case beats
        case downbeats
        case downbeatSource = "downbeat_source"
        case sections
        case stems
        case alignment
        case structureCandidates = "structure_candidates"
        case energyCurve = "energy_curve"
        case tempoCurve = "tempo_curve"
        case key
        case chordProgression = "chord_progression"
        case interpretation
        case pipelineStages = "pipeline_stages"
    }

    public init(
        schema: String = analysisSchemaVersion, project: String, songPath: String, sampleRate: Int, durationS: Double,
        bpm: Double, tempoMultiplier: Double = 1.0, beats: [Double], downbeats: [Double],
        downbeatSource: DownbeatSource, sections: [AnalysisSection], stems: Stems? = nil, alignment: [AlignmentLine] = [],
        structureCandidates: [StructureCandidate] = [], energyCurve: [EnergyPoint] = [],
        tempoCurve: [TempoPoint] = [], key: String? = nil, chordProgression: [Chord] = [],
        interpretation: Interpretation? = nil, pipelineStages: [String] = []
    ) throws {
        self.schema = schema
        self.project = project
        self.songPath = songPath
        self.sampleRate = sampleRate
        self.durationS = durationS
        self.bpm = bpm
        self.tempoMultiplier = tempoMultiplier
        self.beats = beats
        self.downbeats = downbeats
        self.downbeatSource = downbeatSource
        self.sections = sections
        self.stems = stems
        self.alignment = alignment
        self.structureCandidates = structureCandidates
        self.energyCurve = energyCurve
        self.tempoCurve = tempoCurve
        self.key = key
        self.chordProgression = chordProgression
        self.interpretation = interpretation
        self.pipelineStages = pipelineStages
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? analysisSchemaVersion
        project = try container.decode(String.self, forKey: .project)
        songPath = try container.decode(String.self, forKey: .songPath)
        sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        durationS = try container.decode(Double.self, forKey: .durationS)
        bpm = try container.decode(Double.self, forKey: .bpm)
        tempoMultiplier = try container.decodeIfPresent(Double.self, forKey: .tempoMultiplier) ?? 1.0
        beats = try container.decode([Double].self, forKey: .beats)
        downbeats = try container.decode([Double].self, forKey: .downbeats)
        downbeatSource = try container.decode(DownbeatSource.self, forKey: .downbeatSource)
        sections = try container.decode([AnalysisSection].self, forKey: .sections)
        stems = try container.decodeIfPresent(Stems.self, forKey: .stems)
        alignment = try container.decodeIfPresent([AlignmentLine].self, forKey: .alignment) ?? []
        structureCandidates =
            try container.decodeIfPresent([StructureCandidate].self, forKey: .structureCandidates) ?? []
        energyCurve = try container.decodeIfPresent([EnergyPoint].self, forKey: .energyCurve) ?? []
        tempoCurve = try container.decodeIfPresent([TempoPoint].self, forKey: .tempoCurve) ?? []
        key = try container.decodeIfPresent(String.self, forKey: .key)
        chordProgression = try container.decodeIfPresent([Chord].self, forKey: .chordProgression) ?? []
        interpretation = try container.decodeIfPresent(Interpretation.self, forKey: .interpretation)
        pipelineStages = try container.decodeIfPresent([String].self, forKey: .pipelineStages) ?? []
        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case durationNotPositive(Double)
        case bpmNotPositive(Double)
    }

    /// Mirrors pydantic's `Field(gt=0)` on `duration_s` / `bpm`.
    public func validate() throws {
        guard durationS > 0 else { throw ValidationError.durationNotPositive(durationS) }
        guard bpm > 0 else { throw ValidationError.bpmNotPositive(bpm) }
    }
}
