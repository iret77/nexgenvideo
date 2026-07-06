import Foundation

/// Global tempo estimation via autocorrelation of the onset envelope, weighted
/// by librosa's log-normal tempo prior. Port of `librosa.feature.rhythm.tempo`
/// / the tempogram path used inside `beat_track`.
///
/// librosa parity:
///   start_bpm  120.0   (prior center)
///   std_bpm    1.0     (prior width, in log2 space)
///   ac_size    8.0 s   (autocorrelation window length)
///   max_tempo  320.0   (upper BPM clamp; lags below this ignored)
///   aggregate  mean    (tempogram → global via mean over frames)
///   hop_length 512
public enum Tempo {
    public static let startBPM: Double = 120.0
    public static let stdBPM: Double = 1.0
    public static let acSize: Double = 8.0
    public static let maxTempo: Double = 320.0

    /// Windowed autocorrelation of the onset envelope, then a log-normal prior
    /// over BPM, argmax → global tempo. Returns 0 when the envelope is empty or
    /// flat (silence).
    public static func estimate(
        onset: [Float],
        sampleRate: Double,
        hop: Int = Spectral.hopLength,
        startBPM: Double = Tempo.startBPM,
        stdBPM: Double = Tempo.stdBPM
    ) -> Double {
        let n = onset.count
        guard n > 1 else { return 0 }

        // Envelope energy check — pure silence has no rhythm.
        var energy: Float = 0
        for v in onset { energy += v * v }
        if energy <= 0 { return 0 }

        // Global (mean) autocorrelation over the ac_size window.
        // librosa builds a tempogram (windowed AC per frame) then means it;
        // the mean tempogram equals the biased autocorrelation of the whole
        // (mean-centered) envelope, which we compute directly for determinism.
        let maxLag = min(n - 1, Int((acSize * sampleRate / Double(hop)).rounded()))
        guard maxLag > 1 else { return 0 }

        // Mean-center (librosa's tempogram detrends per-window; centering the
        // whole envelope is the equivalent global operation).
        var mean: Float = 0
        for v in onset { mean += v }
        mean /= Float(n)
        var centered = [Float](repeating: 0, count: n)
        for i in 0..<n { centered[i] = onset[i] - mean }

        var ac = [Double](repeating: 0, count: maxLag + 1)
        for lag in 0...maxLag {
            var acc: Double = 0
            for i in 0..<(n - lag) {
                acc += Double(centered[i]) * Double(centered[i + lag])
            }
            ac[lag] = acc
        }
        // Normalize by lag-0 (like librosa's normalized autocorrelation).
        let ac0 = ac[0]
        if ac0 > 0 {
            for i in 0...maxLag { ac[i] /= ac0 }
        }

        // BPM for each lag: bpm = 60 * sr / (hop * lag).
        // Weight by a log-normal prior centered on start_bpm.
        let fps = sampleRate / Double(hop)
        var bestBPM: Double = 0
        var bestScore = -Double.greatestFiniteMagnitude
        let logStart = log2(startBPM)
        let twoStd2 = 2.0 * stdBPM * stdBPM

        for lag in 1...maxLag {
            let bpm = 60.0 * fps / Double(lag)
            if bpm > maxTempo { continue }
            if bpm <= 0 { continue }
            // log-normal prior in log2 BPM space.
            let logDiff = log2(bpm) - logStart
            let prior = exp(-0.5 * (logDiff * logDiff) / (twoStd2 / 2.0))
            let score = ac[lag] * prior
            if score > bestScore {
                bestScore = score
                bestBPM = bpm
            }
        }
        return bestBPM
    }

    /// Local tempo curve: `estimate` over sliding windows of the onset envelope,
    /// one value per frame (aggregate=None in features.py's `tempo_curve`).
    /// Uses the same prior; window length = ac_size seconds.
    public static func perFrame(
        onset: [Float],
        sampleRate: Double,
        hop: Int = Spectral.hopLength
    ) -> [Double] {
        let n = onset.count
        guard n > 0 else { return [] }
        let win = max(2, Int((acSize * sampleRate / Double(hop)).rounded()))
        var out = [Double](repeating: 0, count: n)
        for f in 0..<n {
            let lo = max(0, f - win / 2)
            let hi = min(n, lo + win)
            let slice = Array(onset[lo..<hi])
            out[f] = estimate(onset: slice, sampleRate: sampleRate, hop: hop)
        }
        return out
    }
}
