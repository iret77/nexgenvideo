import Foundation

/// Generic on-device audio-ML inference seams — the same dependency-inversion
/// pattern as `AudioPCMDecoding`. The core declares WHAT (transcribe, separate,
/// detect beats); the HOST app fills them with heavy frameworks (Whisper / a
/// source separator / a neural tempo model) inside its single signed binary; a
/// format pack RESOLVES them from the registry and orchestrates the music-domain
/// logic (lyric alignment, section consolidation) on top. No third-party ML
/// framework is embedded in a loadable pack bundle, and the core stays free of any
/// music concept — these are generic capabilities a video host offers, like decode.
///
/// All methods are synchronous and may block: a pack's analysis phase runner is
/// sync and already runs off the main actor (`Task.detached`), so an impl bridges
/// its async model calls to a blocking result (or serves a pre-warmed cache).

/// One transcribed word with a measured time span and the recognizer's confidence.
public struct TranscribedWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Recognizer confidence in [0,1], if the model exposes it.
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// Generic on-device speech recognition: audio file → timed word tokens. `language`
/// is hard-set by the caller (never auto-detected) so recognition can't misfire on
/// sparse or sung audio. Throws on an unreadable file or an unavailable model.
public protocol AudioTranscribing: Sendable {
    func transcribe(_ audio: URL, language: String) throws -> [TranscribedWord]
}

/// Separated source stems written to disk. Any field is nil if the separator does
/// not produce that stem. Paths are absolute.
public struct SeparatedStems: Sendable, Equatable {
    public var vocals: URL?
    public var drums: URL?
    public var bass: URL?
    public var other: URL?

    public init(vocals: URL? = nil, drums: URL? = nil, bass: URL? = nil, other: URL? = nil) {
        self.vocals = vocals
        self.drums = drums
        self.bass = bass
        self.other = other
    }
}

/// Generic on-device source separation: split a mix into stems written under `dir`.
/// Throws on an unreadable file or an unavailable model.
public protocol AudioStemSeparating: Sendable {
    func separateStems(_ audio: URL, into dir: URL) throws -> SeparatedStems
}

/// A detected beat grid: beat and downbeat times in seconds, plus an optional BPM.
public struct DetectedBeatGrid: Sendable, Equatable {
    public var beats: [Double]
    public var downbeats: [Double]
    public var bpm: Double?

    public init(beats: [Double], downbeats: [Double], bpm: Double? = nil) {
        self.beats = beats
        self.downbeats = downbeats
        self.bpm = bpm
    }
}

/// Generic on-device beat/downbeat detection (e.g. a neural tempo model). Optional
/// `stems` let a detector run on a demixed signal for a cleaner result. Returns nil
/// when no model is available, so the caller keeps its own DSP-derived beat grid.
public protocol AudioBeatDetecting: Sendable {
    func detectBeats(_ audio: URL, stems: SeparatedStems?) throws -> DetectedBeatGrid?
}

/// One recognized chord segment: a time span and its label (e.g. "Am", "G7", "C:maj").
/// The no-chord ("N") label is already dropped by the recognizer.
public struct RecognizedChord: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var label: String

    public init(start: Double, end: Double, label: String) {
        self.start = start
        self.end = end
        self.label = label
    }
}

/// Generic on-device chord recognition (e.g. a deep-chroma / transformer chord model
/// over CQT or mel features, decoded with `ChordDecode`). Optional `stems` let a model
/// run on a harmonic-leaning signal. Returns nil when no model is available, so the
/// caller keeps an empty chord progression rather than treating it as a failure.
public protocol AudioChordRecognizing: Sendable {
    func recognizeChords(_ audio: URL, stems: SeparatedStems?) throws -> [RecognizedChord]?
}
