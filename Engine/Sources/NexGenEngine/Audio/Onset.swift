import Foundation

/// Spectral-flux onset envelope + librosa-style peak picking.
///
/// `onset_strength` (librosa.onset.onset_strength):
///   S = power_to_db(melspectrogram(y))   [dB mel]
///   onset[t] = mean over mel bands of max(0, S[:,t] - S[:,t-lag])
///   lag = 1, then the envelope is left-padded so onset[0] aligns with frame 0.
/// librosa also subtracts a per-frame reference by shifting; with default
/// `ref = S` and `lag=1` this is the plain first-order positive difference.
public enum Onset {
    /// The onset strength envelope, one value per STFT frame.
    public struct Envelope: Sendable, Equatable {
        public var values: [Float]
        public var hopLength: Int
        public var sampleRate: Double

        public func time(of frame: Int) -> Double {
            Spectral.frameToTime(frame, hop: hopLength, sampleRate: sampleRate)
        }
    }

    /// Compute the onset-strength envelope from a mel spectrogram in dB.
    /// `melDB` is `[frame][band]`. lag=1, mean aggregation, ReLU on the diff.
    public static func strength(melDB: [[Float]], hop: Int, sampleRate: Double) -> Envelope {
        let nFrames = melDB.count
        guard nFrames > 0 else { return Envelope(values: [], hopLength: hop, sampleRate: sampleRate) }
        let nBands = melDB[0].count
        var env = [Float](repeating: 0, count: nFrames)
        // frame 0 has no predecessor → 0 (librosa pads the leading diff with 0).
        for f in 1..<nFrames {
            var acc: Float = 0
            let cur = melDB[f]
            let prev = melDB[f - 1]
            for b in 0..<nBands {
                let d = cur[b] - prev[b]
                if d > 0 { acc += d }
            }
            env[f] = acc / Float(nBands)
        }
        return Envelope(values: env, hopLength: hop, sampleRate: sampleRate)
    }

    /// Full path: raw PCM → onset envelope, wiring Spectral primitives.
    public static func envelope(
        _ y: [Float],
        sampleRate: Double,
        nFFT: Int = Spectral.nFFT,
        hop: Int = Spectral.hopLength,
        nMels: Int = Spectral.nMels
    ) -> Envelope {
        let spec = Spectral.spectrogram(y, sampleRate: sampleRate, nFFT: nFFT, hop: hop)
        let bank = Spectral.melFilterbank(sampleRate: sampleRate, nFFT: nFFT, nMels: nMels)
        let mel = Spectral.melSpectrogram(spec, filterbank: bank)
        let melDB = Spectral.powerToDB(mel)
        return strength(melDB: melDB, hop: hop, sampleRate: sampleRate)
    }

    /// librosa's default onset peak-picking parameters, in *frames* @ sr/hop.
    /// The Python defaults (librosa.onset.onset_detect) are expressed as time
    /// fractions of `sr/hop_length` frames-per-second, converted here:
    ///   pre_max   = 0.03 * sr / hop   (~1 frame @ default)
    ///   post_max  = 0.00 * sr / hop + 1
    ///   pre_avg   = 0.10 * sr / hop
    ///   post_avg  = 0.10 * sr / hop + 1
    ///   wait      = 0.03 * sr / hop
    ///   delta     = 0.07
    public struct PeakParams: Sendable, Equatable {
        public var preMax: Int
        public var postMax: Int
        public var preAvg: Int
        public var postAvg: Int
        public var wait: Int
        public var delta: Float

        public static func librosaDefault(sampleRate: Double, hop: Int) -> PeakParams {
            let fps = sampleRate / Double(hop)
            func frames(_ seconds: Double) -> Int { Int((seconds * fps).rounded()) }
            return PeakParams(
                preMax: max(1, frames(0.03)),
                postMax: max(1, frames(0.00) + 1),
                preAvg: max(1, frames(0.10)),
                postAvg: max(1, frames(0.10) + 1),
                wait: max(1, frames(0.03)),
                delta: 0.07
            )
        }
    }

    /// Port of `librosa.util.peak_pick`. A sample `n` is a peak iff:
    ///   x[n] == max(x[n-pre_max : n+post_max])       (local max)
    ///   x[n] >= mean(x[n-pre_avg : n+post_avg]) + delta
    ///   n - last_peak > wait
    /// librosa's windows are half-open: `[n-pre : n+post]` with post exclusive
    /// of the right edge index+post. We replicate the exact index arithmetic.
    public static func peakPick(_ x: [Float], _ p: PeakParams) -> [Int] {
        let n = x.count
        guard n > 0 else { return [] }
        var peaks: [Int] = []
        var lastPeak = -1  // -inf sentinel: first candidate always passes wait

        for i in 0..<n {
            // Local-max window [i-pre_max, i+post_max)
            let maxLo = max(0, i - p.preMax)
            let maxHi = min(n, i + p.postMax)
            var isMax = true
            for j in maxLo..<maxHi where x[j] > x[i] { isMax = false; break }
            if !isMax { continue }

            // Moving-average window [i-pre_avg, i+post_avg)
            let avgLo = max(0, i - p.preAvg)
            let avgHi = min(n, i + p.postAvg)
            var sum: Float = 0
            for j in avgLo..<avgHi { sum += x[j] }
            let avg = sum / Float(avgHi - avgLo)
            if x[i] < avg + p.delta { continue }

            if lastPeak >= 0 && (i - lastPeak) <= p.wait { continue }
            peaks.append(i)
            lastPeak = i
        }
        return peaks
    }

    /// Onset detection end-to-end: envelope → peak frames → times.
    public static func detect(
        _ y: [Float],
        sampleRate: Double,
        hop: Int = Spectral.hopLength
    ) -> [Double] {
        let env = envelope(y, sampleRate: sampleRate, hop: hop)
        let params = PeakParams.librosaDefault(sampleRate: sampleRate, hop: hop)
        let frames = peakPick(env.values, params)
        return frames.map { Spectral.frameToTime($0, hop: hop, sampleRate: sampleRate) }
    }
}
