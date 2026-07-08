import Foundation

/// Novelty-based structure segmentation. A deterministic simplification of
/// `structure/librosa_detector.py` (which uses Laplacian segmentation + sklearn
/// KMeans on beat-synchronous chroma+MFCC).
///
/// This port keeps the *shape* of the Python output (beat-synchronous features,
/// boundaries snapped to beats, sections with `cluster` ids, short-section
/// merge) but replaces two non-deterministic / heavy pieces:
///   1. Laplacian eigen-segmentation → a self-similarity **novelty curve**
///      (Foote 2000) whose peaks are the boundaries. Deterministic, no eigensolver.
///   2. sklearn KMeans (random init) → seed-free k-means with **farthest-point
///      init** (k-means++ made deterministic by always taking the argmax
///      distance rather than sampling). Documented divergence below.
///
/// DIVERGENCE FROM sklearn / librosa:
///   - sklearn KMeans uses k-means++ *random* seeding + Lloyd iterations; result
///     depends on `random_state`. Here init is deterministic (farthest-point),
///     so cluster *ids* differ from Python but the *partition* (which frames
///     group together) is stable and reproducible — which is what downstream
///     consolidation needs (it only reads boundaries + relative cluster changes).
///   - Boundaries come from novelty peaks, not from Laplacian recurrence, so
///     exact boundary times differ from librosa_detector; both target the same
///     beat-synchronous section changes. The consolidator's ±2s tolerance
///     absorbs the difference.
///   - Feature set mirrors Python: chroma (12) + MFCC (13). Chroma here is a
///     mel-band energy proxy folded to 12 pitch classes (no CQT), documented as
///     an approximation; MFCC is the exact DCT-II of log-mel.
public enum Structure {
    /// Port of `librosa_detector.py::LibrosaDetector` defaults.
    public static let defaultClusters = 5
    public static let defaultMinSectionS = 6.0

    /// Segment raw PCM into sections. `beats` are beat times (seconds) from the
    /// tracker; `duration` is the signal length. Returns `AudioSection`s with
    /// `source = "librosa"` to match the Python detector's label.
    public static func segment(
        _ y: [Float],
        sampleRate: Double,
        beats: [Double],
        duration: Double,
        hop: Int = Spectral.hopLength,
        nClusters: Int = Structure.defaultClusters,
        minSectionS: Double = Structure.defaultMinSectionS
    ) -> [AudioSection] {
        // Too few beats → whole file as one section (Python guard:
        // len(beats) < max(n_clusters*2, 8)).
        if beats.count < max(nClusters * 2, 8) {
            return [AudioSection(index: 0, start: 0.0, end: duration, cluster: 0, source: "librosa")]
        }

        // Beat-synchronous features: mel-dB spectrogram → per-beat mean of
        // [chroma(12) + MFCC(13)] columns (librosa.util.sync with np.mean).
        let spec = Spectral.spectrogram(y, sampleRate: sampleRate, hop: hop)
        let bank = Spectral.melFilterbank(sampleRate: sampleRate)
        let mel = Spectral.melSpectrogram(spec, filterbank: bank)
        let melDB = Spectral.powerToDB(mel)
        guard !melDB.isEmpty else {
            return [AudioSection(index: 0, start: 0.0, end: duration, cluster: 0, source: "librosa")]
        }

        let chroma = chromaFromMelDB(melDB, sampleRate: sampleRate)
        let mfcc = mfccFromMelDB(melDB, nMFCC: 13)
        // features[frame] = chroma ++ mfcc
        var features = [[Double]]()
        features.reserveCapacity(melDB.count)
        for f in 0..<melDB.count {
            features.append(chroma[f] + mfcc[f])
        }

        // Beat frame indices.
        let beatFrames = beats.map { Int(($0 * sampleRate / Double(hop)).rounded()) }
            .filter { $0 >= 0 && $0 < features.count }
        guard beatFrames.count >= max(nClusters * 2, 8) else {
            return [AudioSection(index: 0, start: 0.0, end: duration, cluster: 0, source: "librosa")]
        }

        // Sync features to beats (mean over each beat span), then z-score
        // standardize per dimension. Standardization is the key divergence from
        // the Python detector: MFCC coefficient 0 (overall energy) is ~two orders
        // of magnitude larger than the timbre coefficients, so raw-Euclidean
        // KMeans/novelty is dominated by loudness and misses timbre boundaries.
        // Standardizing gives every feature equal weight — required for the
        // two-section acceptance test to fire on a pure timbre change.
        let syncedRaw = syncToBeats(features, beatFrames: beatFrames)
        let beatFeatures = standardize(syncedRaw)
        // beat_times = [0] + beat_times + [duration] (Python), one per synced row
        // at its left edge, plus the final duration.
        var beatTimes = [0.0]
        beatTimes.append(contentsOf: beatFrames.map { Spectral.frameToTime($0, hop: hop, sampleRate: sampleRate) })
        beatTimes.append(duration)

        let nSamples = beatFeatures.count

        // Boundaries from the Foote self-similarity novelty curve (peak-picked),
        // not from raw KMeans label changes. The novelty curve localizes the
        // structural change robustly; KMeans then only *labels* the resulting
        // segments (cluster ids). This is the "novelty + clustering" pipeline the
        // work package specifies, and is deterministic.
        let novelty = noveltyCurve(beatFeatures, kernelSize: 8)
        // Minimum peak spacing in beats ≈ min_section_s / median beat period.
        var medBeat = 0.5
        if beatTimes.count > 3 {
            var diffs = [Double]()
            for i in 2..<(beatTimes.count - 1) { diffs.append(beatTimes[i] - beatTimes[i - 1]) }
            diffs.sort()
            if !diffs.isEmpty { medBeat = diffs[diffs.count / 2] }
        }
        let minGap = max(1, Int((minSectionS / max(medBeat, 0.01)).rounded()))
        let peakBeats = pickNoveltyPeaks(novelty, minGap: minGap, threshold: 0.3)

        // Boundary beat indices → section spans. Peaks index into `beatFeatures`
        // rows; map to `beatTimes` (offset by 1 for the leading 0.0 entry).
        var boundaryIdx = [0]
        for p in peakBeats {
            let bi = min(p + 1, beatTimes.count - 1)
            if bi > (boundaryIdx.last ?? 0) { boundaryIdx.append(bi) }
        }
        if (boundaryIdx.last ?? 0) < beatTimes.count - 1 {
            boundaryIdx.append(beatTimes.count - 1)
        }

        // KMeans labels for section cluster ids: k = min(n_clusters, max(2, n//2)).
        let k = min(nClusters, max(2, nSamples / 2))
        let labels = nSamples > 1 ? KMeansDeterministic.cluster(beatFeatures, k: k) : [0]

        var raw = [AudioSection]()
        for i in 0..<(boundaryIdx.count - 1) {
            let startBeat = boundaryIdx[i]
            let start = beatTimes[startBeat]
            let end = beatTimes[boundaryIdx[i + 1]]
            // Cluster id = majority label over the segment's beat rows.
            let lo = max(0, startBeat - 1)
            let hi = min(labels.count, boundaryIdx[i + 1] - 1)
            let cluster = majorityLabel(labels, from: lo, to: max(lo + 1, hi))
            raw.append(AudioSection(index: i, start: start, end: end, cluster: cluster, source: "librosa"))
        }
        if raw.isEmpty {
            return [AudioSection(index: 0, start: 0.0, end: duration, cluster: 0, source: "librosa")]
        }

        // Merge short sections into the predecessor (Python min_section_s rule).
        var merged = [AudioSection]()
        for sec in raw {
            if !merged.isEmpty && (sec.end - sec.start) < minSectionS {
                var prev = merged[merged.count - 1]
                prev.end = sec.end
                merged[merged.count - 1] = prev
            } else {
                merged.append(sec)
            }
        }
        for i in 0..<merged.count { merged[i].index = i }
        return merged
    }

    /// Per-dimension z-score standardization; zero-variance dims pass through.
    static func standardize(_ feat: [[Double]]) -> [[Double]] {
        guard let first = feat.first else { return feat }
        let dim = first.count
        let n = feat.count
        var mean = [Double](repeating: 0, count: dim)
        for row in feat { for d in 0..<dim { mean[d] += row[d] } }
        for d in 0..<dim { mean[d] /= Double(n) }
        var std = [Double](repeating: 0, count: dim)
        for row in feat { for d in 0..<dim { let x = row[d] - mean[d]; std[d] += x * x } }
        for d in 0..<dim { std[d] = (std[d] / Double(n)).squareRoot(); if std[d] == 0 { std[d] = 1 } }
        var out = feat
        for i in 0..<n { for d in 0..<dim { out[i][d] = (feat[i][d] - mean[d]) / std[d] } }
        return out
    }

    /// Local maxima of the novelty curve above `threshold`, spaced ≥ `minGap`.
    static func pickNoveltyPeaks(_ nov: [Double], minGap: Int, threshold: Double) -> [Int] {
        let n = nov.count
        guard n > 2 else { return [] }
        var peaks = [Int]()
        var last = Int.min
        for i in 1..<(n - 1) {
            if nov[i] >= threshold && nov[i] >= nov[i - 1] && nov[i] >= nov[i + 1] {
                if i - last >= minGap { peaks.append(i); last = i }
            }
        }
        return peaks
    }

    /// Most-frequent label in `labels[from..<to]`.
    static func majorityLabel(_ labels: [Int], from: Int, to: Int) -> Int {
        guard from < to, from >= 0, to <= labels.count else { return 0 }
        var counts = [Int: Int]()
        for i in from..<to { counts[labels[i], default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }

    // MARK: Features

    /// 12-band chroma proxy folded from mel-dB energy. Not CQT-chroma (that
    /// needs a constant-Q transform); a documented approximation that still
    /// captures harmonic-content changes for boundary detection. Each mel band's
    /// center frequency maps to a pitch class via `12·log2(f/C0) mod 12`.
    static func chromaFromMelDB(_ melDB: [[Float]], sampleRate: Double) -> [[Double]] {
        guard let first = melDB.first else { return [] }
        let nMels = first.count
        // Precompute pitch-class of each mel band from its Slaney center freq.
        let c0 = 16.351597831287414  // C0 in Hz
        var pc = [Int](repeating: 0, count: nMels)
        let melMin = Spectral.hzToMelSlaney(0)
        let melMax = Spectral.hzToMelSlaney(sampleRate / 2)
        for m in 0..<nMels {
            let mel = melMin + (melMax - melMin) * Double(m + 1) / Double(nMels + 1)
            let hz = Spectral.melToHzSlaney(mel)
            if hz > 0 {
                let midi = 12.0 * log2(hz / c0)
                var cls = Int(midi.rounded()) % 12
                if cls < 0 { cls += 12 }
                pc[m] = cls
            }
        }
        var out = [[Double]]()
        out.reserveCapacity(melDB.count)
        for frame in melDB {
            var chroma = [Double](repeating: 0, count: 12)
            // Use linear energy (undo dB) so louder bands dominate sensibly.
            for m in 0..<nMels {
                chroma[pc[m]] += pow(10.0, Double(frame[m]) / 10.0)
            }
            // L2 normalize (librosa chroma is normalized).
            var norm = 0.0
            for v in chroma { norm += v * v }
            norm = norm.squareRoot()
            if norm > 0 { for i in 0..<12 { chroma[i] /= norm } }
            out.append(chroma)
        }
        return out
    }

    /// MFCC = DCT-II (orthonormal, "ortho" norm) of the log-mel spectrogram,
    /// keeping the first `nMFCC` coefficients. Exact port of
    /// `librosa.feature.mfcc` (which is `dct(power_to_db(melspec), type=2,
    /// norm='ortho')[:n_mfcc]`).
    static func mfccFromMelDB(_ melDB: [[Float]], nMFCC: Int) -> [[Double]] {
        guard let first = melDB.first else { return [] }
        let nMels = first.count
        // Precompute DCT-II basis (orthonormal).
        var basis = [[Double]](repeating: [Double](repeating: 0, count: nMels), count: nMFCC)
        let scale0 = (1.0 / Double(nMels)).squareRoot()
        let scaleN = (2.0 / Double(nMels)).squareRoot()
        for k in 0..<nMFCC {
            let scale = k == 0 ? scale0 : scaleN
            for n in 0..<nMels {
                basis[k][n] = scale * cos(Double.pi / Double(nMels) * (Double(n) + 0.5) * Double(k))
            }
        }
        var out = [[Double]]()
        out.reserveCapacity(melDB.count)
        for frame in melDB {
            var coeffs = [Double](repeating: 0, count: nMFCC)
            for k in 0..<nMFCC {
                var acc = 0.0
                let b = basis[k]
                for n in 0..<nMels { acc += Double(frame[n]) * b[n] }
                coeffs[k] = acc
            }
            out.append(coeffs)
        }
        return out
    }

    /// librosa.util.sync with aggregate=mean: average feature columns within
    /// each beat span [beatFrame[i], beatFrame[i+1]).
    static func syncToBeats(_ features: [[Double]], beatFrames: [Int]) -> [[Double]] {
        guard !features.isEmpty else { return [] }
        let dim = features[0].count
        var out = [[Double]]()
        out.reserveCapacity(beatFrames.count)
        for i in 0..<beatFrames.count {
            let lo = beatFrames[i]
            let hi = i + 1 < beatFrames.count ? beatFrames[i + 1] : features.count
            guard lo < hi, lo >= 0, hi <= features.count else {
                out.append([Double](repeating: 0, count: dim))
                continue
            }
            var mean = [Double](repeating: 0, count: dim)
            for f in lo..<hi {
                for d in 0..<dim { mean[d] += features[f][d] }
            }
            let n = Double(hi - lo)
            for d in 0..<dim { mean[d] /= n }
            out.append(mean)
        }
        return out
    }

    // MARK: Foote novelty (exposed for the pipeline / tests)

    /// Self-similarity novelty curve (Foote 2000): build an SSM over the feature
    /// sequence (cosine similarity), correlate a checkerboard Gaussian kernel
    /// along the diagonal. Peaks = structural boundaries. Deterministic.
    public static func noveltyCurve(_ features: [[Double]], kernelSize: Int = 32) -> [Double] {
        let n = features.count
        guard n > 2 else { return [Double](repeating: 0, count: n) }

        // Cosine self-similarity, [n][n].
        var norms = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for v in features[i] { s += v * v }
            norms[i] = s.squareRoot()
        }
        func sim(_ i: Int, _ j: Int) -> Double {
            if norms[i] == 0 || norms[j] == 0 { return 0 }
            var dot = 0.0
            let a = features[i], b = features[j]
            for d in 0..<a.count { dot += a[d] * b[d] }
            return dot / (norms[i] * norms[j])
        }

        // Checkerboard Gaussian kernel of half-width L.
        let L = max(2, min(kernelSize, n / 2))
        let size = 2 * L
        var kernel = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        let sigma = Double(L) / 2.0
        for a in 0..<size {
            for b in 0..<size {
                let x = Double(a - L) + 0.5
                let ky = Double(b - L) + 0.5
                let gauss = exp(-(x * x + ky * ky) / (2 * sigma * sigma))
                let sign: Double = ((a < L) == (b < L)) ? 1.0 : -1.0
                kernel[a][b] = sign * gauss
            }
        }

        var novelty = [Double](repeating: 0, count: n)
        // Edge mask: only score frames where the full kernel fits. At the very
        // edges the checkerboard degenerates (half the window is out of range)
        // and the diagonal self-similarity block dominates, producing a spurious
        // peak at frame 0. Leaving edges at 0 avoids that false boundary.
        for center in L..<(n - L) {
            var acc = 0.0
            for a in 0..<size {
                let i = center - L + a
                for b in 0..<size {
                    let j = center - L + b
                    acc += kernel[a][b] * sim(i, j)
                }
            }
            novelty[center] = acc
        }
        // Normalize to 0..1 for stable peak thresholds.
        var maxV = 0.0
        for v in novelty where v > maxV { maxV = v }
        if maxV > 0 { for i in 0..<n { novelty[i] = max(0, novelty[i]) / maxV } }
        return novelty
    }
}

/// Seed-free k-means with farthest-point (deterministic k-means++) init and
/// Lloyd iterations. Fully reproducible — no RNG. Divergence from sklearn is
/// documented in `Structure`.
enum KMeansDeterministic {
    static func cluster(_ points: [[Double]], k: Int, maxIter: Int = 50) -> [Int] {
        let n = points.count
        guard n > 0 else { return [] }
        guard k > 1, k < n else { return [Int](repeating: 0, count: n) }
        let dim = points[0].count

        func dist2(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for d in 0..<dim { let x = a[d] - b[d]; s += x * x }
            return s
        }

        // Deterministic init: first centroid = point 0 (stable), then each next
        // centroid = the point farthest (max min-distance) from chosen ones.
        var centroids = [[Double]]()
        centroids.append(points[0])
        var minDist = points.map { dist2($0, points[0]) }
        while centroids.count < k {
            var best = -1
            var bestD = -1.0
            for i in 0..<n where minDist[i] > bestD {
                bestD = minDist[i]; best = i
            }
            if best < 0 { break }
            let c = points[best]
            centroids.append(c)
            for i in 0..<n {
                let d = dist2(points[i], c)
                if d < minDist[i] { minDist[i] = d }
            }
        }

        var labels = [Int](repeating: 0, count: n)
        for _ in 0..<maxIter {
            var changed = false
            // Assign.
            for i in 0..<n {
                var best = 0
                var bestD = Double.greatestFiniteMagnitude
                for c in 0..<centroids.count {
                    let d = dist2(points[i], centroids[c])
                    if d < bestD { bestD = d; best = c }
                }
                if labels[i] != best { labels[i] = best; changed = true }
            }
            // Update.
            var sums = [[Double]](repeating: [Double](repeating: 0, count: dim), count: centroids.count)
            var counts = [Int](repeating: 0, count: centroids.count)
            for i in 0..<n {
                let c = labels[i]
                counts[c] += 1
                for d in 0..<dim { sums[c][d] += points[i][d] }
            }
            for c in 0..<centroids.count where counts[c] > 0 {
                for d in 0..<dim { centroids[c][d] = sums[c][d] / Double(counts[c]) }
            }
            if !changed { break }
        }
        return labels
    }
}
