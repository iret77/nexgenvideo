import Foundation

/// Native audio-analysis output structs, mirroring the field names of the Python
/// Analysis v2 schema. These are MUSIC-domain analysis types and live in the pack
/// — the generic engine core owns only `PCMBuffer`/`AudioPCMDecoding`.
///
/// `EnergyPoint`/`TempoPoint` are the DSP time-series primitives `Energy.swift`
/// produces and `AudioAnalysis` carries; the pack's canonical `Analysis` schema
/// reuses them directly. `AudioAnalysisPipeline` is the DSP producer and is
/// schema-agnostic; `MusicvideoAnalysisRunner` maps this DSP-producible subset
/// onto the full canonical schema.

/// Port of `analysis_schema.py::Section`. `cluster` is the section-type id;
/// `label` (narrative) and the schema's v2-only fields are left to downstream.
public struct AudioSection: Codable, Sendable, Equatable {
    public var index: Int
    public var start: Double
    public var end: Double
    public var cluster: Int
    public var label: String?
    public var source: String?
    public var confidence: Double?

    public init(
        index: Int,
        start: Double,
        end: Double,
        cluster: Int,
        label: String? = nil,
        source: String? = nil,
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

/// A single point on the loudness (RMS energy) curve. Seconds → normalized 0..1.
public struct EnergyPoint: Codable, Sendable, Equatable {
    /// Seconds.
    public var t: Double
    /// Normalized 0..1.
    public var rms: Double

    public init(t: Double, rms: Double) {
        self.t = t
        self.rms = rms
    }
}

/// A single point on the instantaneous-tempo curve. Seconds → BPM.
public struct TempoPoint: Codable, Sendable, Equatable {
    public var t: Double
    public var bpm: Double

    public init(t: Double, bpm: Double) {
        self.t = t
        self.bpm = bpm
    }
}

/// The DSP-producible subset of the canonical `Analysis` schema — the fields the
/// native pipeline computes in v1 scope. Stems/alignment/chords/interpretation
/// stay out (those schema fields remain optional on the canonical type). `key`
/// (Krumhansl-Schmuckler) is produced here.
public struct AudioAnalysis: Codable, Sendable, Equatable {
    public var sampleRate: Int
    public var durationS: Double
    public var bpm: Double
    public var beats: [Double]
    public var downbeats: [Double]
    public var downbeatSource: String
    /// Librosa (Foote-novelty) detector sections — the primary structure candidate.
    public var sections: [AudioSection]
    /// BIC-on-MFCC (`source = "essentia"`) detector sections — the second,
    /// independent candidate the consolidator converges against. Empty if unrun.
    public var sectionsEssentia: [AudioSection]
    public var energyCurve: [EnergyPoint]
    public var tempoCurve: [TempoPoint]
    /// Detected musical key, e.g. `"C major"` / `"A minor"`; nil when undetermined.
    public var key: String?

    public init(
        sampleRate: Int,
        durationS: Double,
        bpm: Double,
        beats: [Double],
        downbeats: [Double],
        downbeatSource: String,
        sections: [AudioSection],
        energyCurve: [EnergyPoint],
        tempoCurve: [TempoPoint],
        sectionsEssentia: [AudioSection] = [],
        key: String? = nil
    ) {
        self.sampleRate = sampleRate
        self.durationS = durationS
        self.bpm = bpm
        self.beats = beats
        self.downbeats = downbeats
        self.downbeatSource = downbeatSource
        self.sections = sections
        self.sectionsEssentia = sectionsEssentia
        self.energyCurve = energyCurve
        self.tempoCurve = tempoCurve
        self.key = key
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case durationS = "duration_s"
        case bpm
        case beats
        case downbeats
        case downbeatSource = "downbeat_source"
        case sections
        case sectionsEssentia = "sections_essentia"
        case energyCurve = "energy_curve"
        case tempoCurve = "tempo_curve"
        case key
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sampleRate = try c.decode(Int.self, forKey: .sampleRate)
        durationS = try c.decode(Double.self, forKey: .durationS)
        bpm = try c.decode(Double.self, forKey: .bpm)
        beats = try c.decode([Double].self, forKey: .beats)
        downbeats = try c.decode([Double].self, forKey: .downbeats)
        downbeatSource = try c.decode(String.self, forKey: .downbeatSource)
        sections = try c.decode([AudioSection].self, forKey: .sections)
        sectionsEssentia = try c.decodeIfPresent([AudioSection].self, forKey: .sectionsEssentia) ?? []
        energyCurve = try c.decode([EnergyPoint].self, forKey: .energyCurve)
        tempoCurve = try c.decode([TempoPoint].self, forKey: .tempoCurve)
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }
}
