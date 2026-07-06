import Foundation

/// Native audio-analysis output structs, mirroring the field names of the
/// Python Analysis v2 schema (`plugins/musicvideo/.../analysis_schema.py`).
///
/// MERGE NOTE: a sibling package is porting the full schema as
/// `AnalysisSchema.swift`. When it lands, delete `AudioSection`,
/// `EnergyPoint`, `TempoPoint`, and `AudioAnalysis` from this file and have the
/// pipeline emit the canonical `Section` / `Analysis` types instead — the field
/// names here are chosen to match 1:1 (`index/start/end/cluster/label/source/
/// confidence`; `t/rms`; `t/bpm`; `bpm/beats/downbeats/downbeat_source/
/// sections/energy_curve/tempo_curve/sample_rate/duration_s`). Only the
/// container names differ. `AudioAnalysisPipeline` is the DSP producer and is
/// schema-agnostic; the merge is a rename at the boundary.

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

/// The DSP-producible subset of `analysis_schema.py::Analysis` — the fields the
/// native engine computes in v1 scope. Stems/alignment/key/chords/interpretation
/// stay out (deferred; those schema fields remain optional in the canonical type).
// EnergyPoint/TempoPoint come from Packs/Musicvideo/AnalysisSchema.swift (canonical).
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
/// `PCMAudioSource` so the engine stays pure (no AVFoundation/AudioToolbox) and
/// fully testable with synthesized signals. The APP implements a decoder later.
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

/// The seam the app fills with a real decoder (ExtAudioFile/AVFoundation), kept
/// out of the engine target. Not used by the DSP itself — the pipeline takes a
/// `PCMBuffer` directly — but declared here so the app has one protocol to
/// implement, mirroring `audio.py::load` returning mono PCM at 22050 Hz.
public protocol PCMAudioSource: Sendable {
    func loadPCM(sampleRate: Double) throws -> PCMBuffer
}
