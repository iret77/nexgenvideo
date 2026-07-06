import Foundation

/// Dynamic-programming beat tracking — Ellis (2007), the algorithm
/// `librosa.beat.beat_track` implements. Given an onset-strength envelope and a
/// global tempo, find the beat sequence maximizing
///   sum(onset[beat]) + tightness · sum(log-spacing penalty between beats)
/// via the classic DP with backtracking.
///
/// librosa parity:
///   tightness  100    (spacing-penalty weight)
///   start_bpm  120    (feeds Tempo.estimate for the period)
///   trim       true   (drop weak beats at the very start/end)
///   The onset envelope is normalized (std) and its local mean subtracted
///   before scoring, matching librosa's `__beat_local_score`.
public enum BeatTracker {
    public static let tightness: Double = 100.0

    public struct Result: Sendable, Equatable {
        public var bpm: Double
        public var beatFrames: [Int]
        public var beatTimes: [Double]
    }

    /// Track beats from raw PCM. Mirrors `beat_track(y, sr)` returning
    /// (bpm, beat_times). BPM is taken from `Tempo.estimate`; final reported BPM
    /// follows `audio.py::estimate_tempo_and_beats`: median of beat intervals
    /// (more robust than the aggregate tempo), falling back to the estimate.
    public static func track(
        _ y: [Float],
        sampleRate: Double,
        hop: Int = Spectral.hopLength,
        startBPM: Double = Tempo.startBPM
    ) -> Result {
        let env = Onset.envelope(y, sampleRate: sampleRate, hop: hop)
        return track(onset: env.values, sampleRate: sampleRate, hop: hop, startBPM: startBPM)
    }

    /// Track beats from a precomputed onset envelope.
    public static func track(
        onset: [Float],
        sampleRate: Double,
        hop: Int = Spectral.hopLength,
        startBPM: Double = Tempo.startBPM
    ) -> Result {
        let n = onset.count
        guard n > 1 else { return Result(bpm: 0, beatFrames: [], beatTimes: []) }

        // Envelope must carry energy — silence yields no beats.
        var energy: Float = 0
        for v in onset { energy += v * v }
        if energy <= 0 { return Result(bpm: 0, beatFrames: [], beatTimes: []) }

        let bpm = Tempo.estimate(onset: onset, sampleRate: sampleRate, hop: hop, startBPM: startBPM)
        guard bpm > 0 else { return Result(bpm: 0, beatFrames: [], beatTimes: []) }

        // Beat period in frames.
        let fps = sampleRate / Double(hop)
        let period = 60.0 * fps / bpm
        guard period >= 1 else { return Result(bpm: 0, beatFrames: [], beatTimes: []) }

        // Local score: normalize by std, then subtract a Hann-smoothed local
        // mean (librosa `__beat_local_score`). We approximate the smoothing
        // window as one beat period wide.
        let localScore = beatLocalScore(onset, period: period)

        // DP over frames (librosa `__beat_track_dp`).
        let (backlink, cumScore) = beatTrackDP(localScore, period: period, tightness: tightness)

        // Backtrace from the best late-frame start (librosa `__last_beat` picks
        // the max cumulative score in the tail, thresholded by its median).
        var tail = beatTrackBacktrace(backlink, cumScore)

        // Trim weak boundary beats (trim=True): drop leading/trailing beats
        // whose local score is below 0.5·mean(localScore at beats).
        if !tail.isEmpty {
            tail = trimBeats(tail, localScore: localScore)
        }

        let times = tail.map { Spectral.frameToTime($0, hop: hop, sampleRate: sampleRate) }

        // Reported BPM: median of intervals (audio.py), fallback to estimate.
        var reported = bpm
        if times.count >= 2 {
            var diffs = [Double]()
            for i in 1..<times.count { diffs.append(times[i] - times[i - 1]) }
            diffs.sort()
            let mid = diffs.count / 2
            let median = diffs.count % 2 == 0 ? (diffs[mid - 1] + diffs[mid]) / 2 : diffs[mid]
            if median > 0 { reported = 60.0 / median }
        }

        return Result(bpm: reported, beatFrames: tail, beatTimes: times)
    }

    // MARK: DP internals

    /// librosa `__beat_local_score`: normalize onset by its std, convolve with a
    /// Gaussian-ish window of one beat period, subtract to emphasize local peaks.
    static func beatLocalScore(_ onset: [Float], period: Double) -> [Double] {
        let n = onset.count
        var std: Double = 0
        var mean: Double = 0
        for v in onset { mean += Double(v) }
        mean /= Double(n)
        for v in onset { let d = Double(v) - mean; std += d * d }
        std = (std / Double(n)).squareRoot()
        let scale = std > 0 ? std : 1.0

        // Smoothing window: Hann of width ~period (odd length).
        let w = max(3, Int(period.rounded()) | 1)
        var window = [Double](repeating: 0, count: w)
        var wsum: Double = 0
        for i in 0..<w {
            let h = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(w - 1))
            window[i] = h
            wsum += h
        }
        if wsum > 0 { for i in 0..<w { window[i] /= wsum } }

        // Normalized onset.
        var norm = [Double](repeating: 0, count: n)
        for i in 0..<n { norm[i] = Double(onset[i]) / scale }

        // Local-mean via same-length convolution, then subtract.
        var smoothed = [Double](repeating: 0, count: n)
        let half = w / 2
        for i in 0..<n {
            var acc: Double = 0
            for k in 0..<w {
                let j = i + k - half
                if j >= 0 && j < n { acc += norm[j] * window[k] }
            }
            smoothed[i] = acc
        }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n { out[i] = norm[i] - smoothed[i] }
        return out
    }

    /// librosa `__beat_track_dp`: cumulative score with a log-Gaussian spacing
    /// penalty. For frame i, best predecessor j in [i-2·period, i-period/2]:
    ///   score = -tightness · (log(period_ratio))^2
    /// where period_ratio = (i-j)/period. cum[i] = local[i] + max_j(cum[j]+score).
    static func beatTrackDP(
        _ localScore: [Double],
        period: Double,
        tightness: Double
    ) -> (backlink: [Int], cumScore: [Double]) {
        let n = localScore.count
        var backlink = [Int](repeating: -1, count: n)
        var cumScore = [Double](repeating: 0, count: n)

        // Window of candidate predecessors, centered on one period back.
        let loOffset = max(1, Int((period * 0.5).rounded()))
        let hiOffset = max(loOffset + 1, Int((period * 2.0).rounded()))

        // Precompute the spacing penalty for each offset in [loOffset, hiOffset].
        var penalty = [Int: Double]()
        for off in loOffset...hiOffset {
            let ratio = Double(off) / period
            let logR = log(ratio)
            penalty[off] = -tightness * logR * logR
        }

        // Seed: first plausible beat. librosa sets cum[i]=local[i] until a full
        // period has elapsed (no predecessor available yet).
        for i in 0..<n {
            if i < loOffset {
                cumScore[i] = localScore[i]
                backlink[i] = -1
                continue
            }
            var best = -Double.greatestFiniteMagnitude
            var bestJ = -1
            let jLo = max(0, i - hiOffset)
            let jHi = i - loOffset
            if jHi >= jLo {
                for j in jLo...jHi {
                    let off = i - j
                    let pen = penalty[off] ?? (-tightness)
                    let sc = cumScore[j] + pen
                    if sc > best { best = sc; bestJ = j }
                }
            }
            if bestJ >= 0 {
                cumScore[i] = localScore[i] + best
                backlink[i] = bestJ
            } else {
                cumScore[i] = localScore[i]
                backlink[i] = -1
            }
        }
        return (backlink, cumScore)
    }

    /// librosa `__last_beat` + backtrace: start from the highest cumulative
    /// score in the tail (above 0.5·median of local maxima), follow backlinks.
    static func beatTrackBacktrace(_ backlink: [Int], _ cumScore: [Double]) -> [Int] {
        let n = cumScore.count
        guard n > 0 else { return [] }

        // Median-threshold the tail candidates (librosa uses local maxima of
        // cumScore; here we take the global argmax which lands on the same
        // final beat for well-formed envelopes).
        var tail = -1
        var best = -Double.greatestFiniteMagnitude
        for i in 0..<n where cumScore[i] > best {
            best = cumScore[i]; tail = i
        }
        guard tail >= 0 else { return [] }

        var beats = [Int]()
        var cur = tail
        while cur >= 0 {
            beats.append(cur)
            cur = backlink[cur]
        }
        beats.reverse()
        return beats
    }

    /// trim=True: drop leading/trailing beats whose local score is below
    /// 0.5·mean(localScore over the beat set) — librosa `__trim_beats`.
    static func trimBeats(_ beats: [Int], localScore: [Double]) -> [Int] {
        guard !beats.isEmpty else { return beats }
        var sum: Double = 0
        for b in beats { sum += max(0, localScore[b]) }
        let threshold = 0.5 * sum / Double(beats.count)

        var lo = 0
        while lo < beats.count && max(0, localScore[beats[lo]]) < threshold { lo += 1 }
        var hi = beats.count - 1
        while hi > lo && max(0, localScore[beats[hi]]) < threshold { hi -= 1 }
        guard lo <= hi else { return [] }
        return Array(beats[lo...hi])
    }
}
