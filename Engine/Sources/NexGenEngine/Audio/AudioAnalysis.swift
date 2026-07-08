import Foundation

/// Native audio-analysis output structs, mirroring the field names of the
/// Python Analysis v2 schema.
///
/// `EnergyPoint`/`TempoPoint` are generic time-series primitives the DSP layer
/// (`Energy.swift`) produces and `AudioAnalysis` carries, so they live in the
/// engine — the `musicvideo` pack's canonical `Analysis` schema reuses them via
/// `import NexGenEngine`. `AudioAnalysisPipeline` is the DSP producer and is
/// schema-agnostic; a pack maps this DSP-producible subset onto its full schema.

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
/// native engine computes in v1 scope. Stems/alignment/key/chords/interpretation
/// stay out (deferred; those schema fields remain optional in the canonical type).
public struct AudioAnalysis: Codable, Sendable, Equatable {
    public var sampleRate: Int
    public var durationS: Double
    public var bpm: Double
    public var beats: [Double]
    public var downbeats: [Double]
    public var downbeatSource: String
    public var sections: [AudioSection]
    public var energyCurve: [EnergyPoint]
    public var tempoCurve: [TempoPoint]

    public init(
        sampleRate: Int,
        durationS: Double,
        bpm: Double,
        beats: [Double],
        downbeats: [Double],
        downbeatSource: String,
        sections: [AudioSection],
        energyCurve: [EnergyPoint],
        tempoCurve: [TempoPoint]
    ) {
        self.sampleRate = sampleRate
        self.durationS = durationS
        self.bpm = bpm
        self.beats = beats
        self.downbeats = downbeats
        self.downbeatSource = downbeatSource
        self.sections = sections
        self.energyCurve = energyCurve
        self.tempoCurve = tempoCurve
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case durationS = "duration_s"
        case bpm
        case beats
        case downbeats
        case downbeatSource = "downbeat_source"
        case sections
        case energyCurve = "energy_curve"
        case tempoCurve = "tempo_curve"
    }
}

/// Raw PCM input the engine analyzes. File decoding lives behind
/// `AudioPCMDecoding` so the engine stays pure (no AVFoundation/AudioToolbox)
/// and fully testable with synthesized signals; the app implements the decoder.
public struct PCMBuffer: Sendable, Equatable {
    /// Mono float samples in [-1, 1]. Multi-channel input is downmixed by the
    /// caller before construction (the app's decoder averages channels, matching
    /// `librosa.load(..., mono=True)`).
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

/// Decodes an audio file at a URL into a mono `PCMBuffer`, resampled to
/// `librosa.load` defaults (mono downmix by channel average, 22050 Hz). The
/// engine stays pure (no AVFoundation/AudioToolbox); the app provides the
/// concrete decoder and injects it into the `EngineRegistry` so the pack's
/// analysis phase runner can reach it. Dependency inversion: the pure DSP
/// library declares the seam, the host fills it.
public protocol AudioPCMDecoding: Sendable {
    /// Decode `url` into mono float PCM at `analysisSampleRate`. Throws on an
    /// unreadable file or a file with zero audio frames.
    func decode(_ url: URL) throws -> PCMBuffer
}

/// The sample rate the analysis pipeline runs at — `librosa.load`'s default
/// (22050 Hz). Decoders resample to this; the pipeline assumes it.
public let analysisSampleRate: Double = 22050
