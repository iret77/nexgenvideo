import Foundation

/// Downbeat heuristic — the librosa fallback from `downbeats.py`.
///
/// The Python `_librosa_heuristic` takes every Nth beat (N = beats_per_bar,
/// assumed 4/4) starting at phase 0. That is phase-blind. This port keeps the
/// every-Nth-beat structure but chooses the *phase* by onset-energy voting: of
/// the `beats_per_bar` possible starting offsets, pick the one whose selected
/// beats carry the most onset strength — i.e. land on accents. With a phase-0
/// accent pattern this reduces to the Python behavior; with any other accent
/// phase it recovers the correct downbeats (needed for the accented-click test).
///
/// madmom's RNN path is out of scope (deferred); `source` is always
/// "librosa-heuristic", matching the schema's `downbeat_source` literal.
public enum Downbeats {
    public static let source = "librosa-heuristic"

    /// Every `beatsPerBar`-th beat, phase chosen by onset-energy voting.
    /// When `onset` is nil or empty, falls back to phase 0 (pure Python
    /// `_librosa_heuristic`).
    public static func detect(
        beats: [Double],
        beatsPerBar: Int = 4,
        onset: Onset.Envelope? = nil
    ) -> [Double] {
        guard !beats.isEmpty else { return [] }
        let bpb = max(1, beatsPerBar)
        guard bpb > 1, beats.count >= bpb else {
            // Too few beats to distinguish phase — Python behavior (phase 0).
            return stride(from: 0, to: beats.count, by: bpb).map { beats[$0] }
        }

        let phase = bestPhase(beats: beats, beatsPerBar: bpb, onset: onset)
        return stride(from: phase, to: beats.count, by: bpb).map { beats[$0] }
    }

    /// Onset-energy voting: for each candidate phase in 0..<beatsPerBar, sum the
    /// onset strength at the beats that phase would select; return the argmax.
    /// Falls back to phase 0 when no envelope is available.
    static func bestPhase(
        beats: [Double],
        beatsPerBar: Int,
        onset: Onset.Envelope?
    ) -> Int {
        guard let onset, !onset.values.isEmpty else { return 0 }
        let env = onset.values
        let hop = onset.hopLength
        let sr = onset.sampleRate

        func frameIndex(forTime t: Double) -> Int {
            let f = Int((t * sr / Double(hop)).rounded())
            return min(max(f, 0), env.count - 1)
        }

        var bestPhase = 0
        var bestScore = -Float.greatestFiniteMagnitude
        for phase in 0..<beatsPerBar {
            var score: Float = 0
            var idx = phase
            while idx < beats.count {
                // Sample the onset peak in a small neighborhood around the beat
                // (beats and frames don't align exactly).
                let center = frameIndex(forTime: beats[idx])
                let lo = max(0, center - 1)
                let hi = min(env.count - 1, center + 1)
                var local: Float = 0
                for f in lo...hi where env[f] > local { local = env[f] }
                score += local
                idx += beatsPerBar
            }
            if score > bestScore {
                bestScore = score
                bestPhase = phase
            }
        }
        return bestPhase
    }
}
