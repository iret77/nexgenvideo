import Foundation
import NexGenEngine

/// Orchestrates the native audio analysis from raw PCM to the Analysis output
/// shape, mirroring `pipeline.py`'s stage order (load → rhythm → structure →
/// features → persist) for the v1-scope stages. Features include musical key
/// (Krumhansl-Schmuckler). Stems / alignment / chords are wired elsewhere
/// (`MusicvideoAnalysisRunner`) or stay optional.
public enum AudioAnalysisPipeline {
    /// Run the full DSP pipeline on a mono PCM buffer.
    ///
    /// Stage order (subset of pipeline.py):
    ///   1. rhythm     — onset envelope → beat tracking → global BPM
    ///   2. downbeats  — 4/4 heuristic with onset-energy phase voting
    ///   3. structure  — beat-synchronous novelty + deterministic clustering
    ///   4. features   — RMS energy curve + tempo curve
    /// BPM follows pipeline.py: prefer `global_bpm_from_downbeats`, fall back to
    /// the beat-interval median from the tracker.
    public static func run(_ pcm: PCMBuffer, hop: Int = Spectral.hopLength) -> AudioAnalysis {
        let y = pcm.samples
        let sr = pcm.sampleRate
        let duration = pcm.durationSeconds

        // Empty / silent input → no rhythm, no crash.
        guard !y.isEmpty, sr > 0 else {
            return AudioAnalysis(
                sampleRate: Int(sr.rounded()), durationS: duration, bpm: 0,
                beats: [], downbeats: [], downbeatSource: Downbeats.source,
                sections: [], energyCurve: [], tempoCurve: []
            )
        }

        // 1. Rhythm — shared onset envelope drives tracking + phase voting.
        let onsetEnv = Onset.envelope(y, sampleRate: sr, hop: hop)
        let beatResult = BeatTracker.track(onset: onsetEnv.values, sampleRate: sr, hop: hop)
        let beats = beatResult.beatTimes

        // 2. Downbeats — heuristic (madmom deferred).
        let downbeats = Downbeats.detect(beats: beats, beatsPerBar: 4, onset: onsetEnv)

        // 3. BPM: robust from downbeats, else beat-interval median.
        var bpm = Energy.globalBPMFromDownbeats(downbeats)
        if bpm <= 0 { bpm = beatResult.bpm }

        // 4. Structure — two independent detectors so the consolidator has a real
        // second opinion (Foote-novelty ‖ BIC-on-MFCC), not a single starved vote.
        let sections = duration > 0
            ? Structure.segment(y, sampleRate: sr, beats: beats, duration: duration)
            : []
        let sectionsEssentia = duration > 0
            ? BICStructure.segment(mfcc: Structure.mfccFrames(y, sampleRate: sr, hop: hop),
                                   hop: hop, sampleRate: sr, duration: duration)
            : []

        // 5. Features.
        let energy = Energy.rmsCurve(y, sampleRate: sr)
        let tempo = Energy.tempoCurve(y, sampleRate: sr, hop: hop)
        let key = MusicalKey.detect(chroma: Structure.globalChroma(y, sampleRate: sr, hop: hop))

        return AudioAnalysis(
            sampleRate: Int(sr.rounded()),
            durationS: Energy.round3(duration),
            bpm: Energy.round3(bpm),
            beats: beats.map { Energy.round3($0) },
            downbeats: downbeats.map { Energy.round3($0) },
            downbeatSource: Downbeats.source,
            sections: sections,
            energyCurve: energy,
            tempoCurve: tempo,
            sectionsEssentia: sectionsEssentia,
            key: key
        )
    }

    /// Persist to JSON matching the engine's idiom (`JSONArtifactStore`:
    /// pretty-printed, sorted keys, atomic write). Mirrors `pipeline.py`'s
    /// `analysis/<song>.json` persistence shape (snake_case field names).
    public static func encode(_ analysis: AudioAnalysis) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(analysis)
    }

    /// Decode a persisted analysis JSON.
    public static func decode(_ data: Data) throws -> AudioAnalysis {
        try JSONDecoder().decode(AudioAnalysis.self, from: data)
    }
}
