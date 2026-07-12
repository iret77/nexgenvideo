import Foundation

/// Raw PCM input and the decode seam — the ONLY audio primitives the generic
/// engine core owns. Everything that *analyzes* audio (beat/downbeat/onset/tempo/
/// spectral/structure/energy, the pipeline, and the `AudioAnalysis` output type)
/// is music-domain work and lives in the format pack, not here. The core keeps
/// just the host↔pack contract: bytes → mono samples.

/// Raw PCM input a pack analyzes. File decoding lives behind `AudioPCMDecoding`
/// so the core stays pure (no AVFoundation/AudioToolbox) and fully testable with
/// synthesized signals; the app implements the decoder and injects it.
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
/// `librosa.load` defaults (mono downmix by channel average, 22050 Hz). The core
/// stays pure (no AVFoundation/AudioToolbox); the app provides the concrete
/// decoder and injects it into the `EngineRegistry` so a pack's analysis phase
/// runner can reach it. Dependency inversion: the pure core declares the seam,
/// the host fills it.
public protocol AudioPCMDecoding: Sendable {
    /// Decode `url` into mono float PCM at `analysisSampleRate`. Throws on an
    /// unreadable file or a file with zero audio frames.
    func decode(_ url: URL) throws -> PCMBuffer
}

/// The sample rate audio analysis runs at — `librosa.load`'s default (22050 Hz).
/// Decoders resample to this; a pack's analysis pipeline assumes it.
public let analysisSampleRate: Double = 22050
