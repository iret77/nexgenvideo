import Foundation

/// Second, independent structure detector: BIC (Bayesian Information Criterion)
/// segmentation on MFCC features. Port of `structure/essentia_detector.py`, which
/// used Essentia's `SBic` — optional and absent on most installs, so the
/// consolidator's cross-detector convergence (`single_source_boundary` /
/// `boundary_divergence`) ran starved with only the librosa detector: every
/// boundary was single-source. This restores the second opinion.
///
/// DIVERGENCE FROM Essentia SBic: SBic is a two-resolution sweep with its own
/// parameters (cpw/inc1/inc2/size1/size2). This is a single-pass local-BIC
/// "novelty" (the classic DISTBIC first pass): at each frame, score a boundary by
/// the ΔBIC of "two adjacent-window Gaussians vs one merged Gaussian" over MFCC;
/// positive local maxima are boundaries. It's a genuinely different mechanism from
/// the Foote cosine-SSM novelty the librosa detector uses (Gaussian-likelihood vs
/// self-similarity), which is what the consolidator needs — two independent votes.
/// Exact boundary times differ from Essentia; the consolidator's ±2s tolerance
/// absorbs it, same as the librosa detector's documented divergence.
public enum BICStructure {
    public static let defaultMinSectionS = 6.0
    /// Half-window (seconds) compared on each side of a candidate boundary.
    public static let defaultWindowS = 2.0
    /// BIC complexity-penalty weight (Essentia SBic's `cpw` default is 1.5).
    public static let defaultPenaltyWeight = 1.5

    /// Segment a track from its per-frame MFCC matrix (`frames[t] = [d coeffs]`).
    /// `hop`/`sampleRate` map frame index → seconds. Returns `AudioSection`s with
    /// `source = "essentia"` (kept from the Python so the consolidator labels the
    /// second opinion consistently).
    public static func segment(
        mfcc frames: [[Double]],
        hop: Int,
        sampleRate: Double,
        duration: Double,
        minSectionS: Double = BICStructure.defaultMinSectionS,
        windowS: Double = BICStructure.defaultWindowS,
        penaltyWeight: Double = BICStructure.defaultPenaltyWeight
    ) -> [AudioSection] {
        let single = [AudioSection(index: 0, start: 0.0, end: duration, cluster: 0, source: "essentia")]
        guard let d = frames.first?.count, d > 0, sampleRate > 0, hop > 0 else { return single }
        let n = frames.count
        let frameDur = Double(hop) / sampleRate
        let w = max(d + 1, Int((windowS / max(frameDur, 1e-9)).rounded()))
        // Need at least one full [t-w, t+w) window to score any boundary.
        guard n >= 2 * w + 1 else { return single }

        let prefix = Prefix(frames: frames, d: d)

        // ΔBIC curve over scorable centers; boundaries = positive local maxima,
        // spaced ≥ minSectionS.
        var curve = [Double](repeating: -Double.greatestFiniteMagnitude, count: n)
        for t in w...(n - w) where t < n {
            curve[t] = deltaBIC(prefix: prefix, d: d, left: t - w, mid: t, right: t + w, penaltyWeight: penaltyWeight)
        }
        let minGap = max(1, Int((minSectionS / max(frameDur, 1e-9)).rounded()))
        var boundaryFrames: [Int] = []
        var last = Int.min
        for t in (w)...(n - w) where t < n {
            let v = curve[t]
            guard v > 0 else { continue }
            if v >= curve[t - 1] && v >= curve[min(t + 1, n - 1)] && t - last >= minGap {
                boundaryFrames.append(t); last = t
            }
        }

        // Frame boundaries → times → sections.
        var times = [0.0]
        for f in boundaryFrames {
            let s = Double(f) * frameDur
            if s > (times.last ?? 0) + 0.01 && s < duration { times.append(s) }
        }
        times.append(duration)

        var raw: [AudioSection] = []
        for i in 0..<(times.count - 1) {
            raw.append(AudioSection(index: i, start: round3(times[i]), end: round3(times[i + 1]),
                                    cluster: i, source: "essentia"))
        }
        // Merge short sections into the predecessor (Python min_section_s rule).
        var merged: [AudioSection] = []
        for sec in raw {
            if !merged.isEmpty && (sec.end - sec.start) < minSectionS {
                merged[merged.count - 1].end = sec.end
            } else {
                merged.append(sec)
            }
        }
        for i in merged.indices { merged[i].index = i; merged[i].cluster = i }
        return merged.isEmpty ? single : merged
    }

    /// ΔBIC of splitting `[left, right)` at `mid` (two Gaussians vs one). Positive
    /// ⇒ the two sides are distinct enough to justify a boundary. Pure — the
    /// testable core.
    static func deltaBIC(prefix: Prefix, d: Int, left: Int, mid: Int, right: Int, penaltyWeight: Double) -> Double {
        let nL = mid - left, nR = right - mid, nF = right - left
        guard nL > d, nR > d, nF > d else { return -Double.greatestFiniteMagnitude }
        let lF = prefix.logDetCov(from: left, to: right, d: d)
        let lL = prefix.logDetCov(from: left, to: mid, d: d)
        let lR = prefix.logDetCov(from: mid, to: right, d: d)
        let r = 0.5 * Double(nF) * lF - 0.5 * Double(nL) * lL - 0.5 * Double(nR) * lR
        let penalty = 0.5 * (Double(d) + 0.5 * Double(d) * Double(d + 1)) * log(Double(nF))
        return r - penaltyWeight * penalty
    }

    /// Prefix sums of x and xxᵀ so any segment's covariance is O(d²) to assemble.
    struct Prefix {
        let p1: [[Double]]        // (n+1) × d
        let p2: [[Double]]        // (n+1) × d*d (row-major)

        init(frames: [[Double]], d: Int) {
            let n = frames.count
            var p1 = [[Double]](repeating: [Double](repeating: 0, count: d), count: n + 1)
            var p2 = [[Double]](repeating: [Double](repeating: 0, count: d * d), count: n + 1)
            for k in 0..<n {
                let x = frames[k]
                for i in 0..<d {
                    p1[k + 1][i] = p1[k][i] + x[i]
                }
                for i in 0..<d {
                    let xi = x[i]
                    let base = i * d
                    for j in 0..<d { p2[k + 1][base + j] = p2[k][base + j] + xi * x[j] }
                }
            }
            self.p1 = p1
            self.p2 = p2
        }

        /// log|Σ| of frames `[a, b)`, regularized so a near-singular covariance
        /// (short / low-rank segment) stays positive-definite. `-inf`-safe.
        func logDetCov(from a: Int, to b: Int, d: Int) -> Double {
            let n = Double(b - a)
            guard n > 0 else { return 0 }
            var mean = [Double](repeating: 0, count: d)
            for i in 0..<d { mean[i] = (p1[b][i] - p1[a][i]) / n }
            var cov = [Double](repeating: 0, count: d * d)
            for i in 0..<d {
                let base = i * d
                for j in 0..<d {
                    cov[base + j] = (p2[b][base + j] - p2[a][base + j]) / n - mean[i] * mean[j]
                }
            }
            // Tikhonov regularization proportional to the average variance.
            var tr = 0.0
            for i in 0..<d { tr += cov[i * d + i] }
            let eps = max(1e-6, 1e-3 * tr / Double(d))
            for i in 0..<d { cov[i * d + i] += eps }
            return choleskyLogDet(cov, d: d) ?? logDetDiagonal(cov, d: d)
        }
    }

    /// log-determinant via Cholesky (Σ = L·Lᵀ ⇒ log|Σ| = 2·Σ log Lᵢᵢ). Returns nil
    /// if not positive-definite (caller falls back to the diagonal approximation).
    static func choleskyLogDet(_ a: [Double], d: Int) -> Double? {
        var l = [Double](repeating: 0, count: d * d)
        for i in 0..<d {
            for j in 0...i {
                var sum = a[i * d + j]
                for k in 0..<j { sum -= l[i * d + k] * l[j * d + k] }
                if i == j {
                    guard sum > 0 else { return nil }
                    l[i * d + j] = sum.squareRoot()
                } else {
                    l[i * d + j] = sum / l[j * d + j]
                }
            }
        }
        var logDet = 0.0
        for i in 0..<d { logDet += 2.0 * log(l[i * d + i]) }
        return logDet
    }

    /// Fallback: log-det from the diagonal only (assumes independence). Used when
    /// Cholesky fails despite regularization — keeps the score finite.
    static func logDetDiagonal(_ a: [Double], d: Int) -> Double {
        var s = 0.0
        for i in 0..<d { s += log(max(a[i * d + i], 1e-12)) }
        return s
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
