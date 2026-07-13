import Foundation

/// Pure, deterministic decode of frame-wise chord logits into chord segments — the CPU-side tail of
/// a chord recognizer (`AudioChordRecognizing`), factored out so it is fully CI-testable without the
/// ONNX model (the same split Demucs / Beat This! use: CI covers the pure parts, real inference is
/// validated on-device). No RNG, no framework — a Viterbi smoothing pass against label flicker, then
/// a run-length merge into `[RecognizedChord]` mirroring the reference's output shaping (drop the
/// no-chord "N" label, round times to 3 decimals). Port of the decode/shape half of
/// `analysis/features.py::chord_progression`.
public enum ChordDecode {
    /// Viterbi over per-frame log-likelihoods with a flat transition penalty for switching labels.
    /// `logits[t][k]` is the (higher-is-better) score for class `k` at frame `t`; every row must have
    /// the same width. `transitionPenalty >= 0` is subtracted whenever the path changes label between
    /// adjacent frames — larger values smooth more aggressively. Returns the best class index per
    /// frame; ties break to the lowest index so the result is stable. Empty input → empty path.
    public static func viterbi(logits: [[Double]], transitionPenalty: Double) -> [Int] {
        guard let first = logits.first, !first.isEmpty else { return [] }
        let k = first.count
        let penalty = max(0, transitionPenalty)

        var score = first
        var back = [[Int]]()
        back.reserveCapacity(logits.count)

        for t in 1..<logits.count {
            let row = logits[t]
            precondition(row.count == k, "ChordDecode.viterbi: ragged logits at frame \(t)")
            var next = [Double](repeating: 0, count: k)
            var ptr = [Int](repeating: 0, count: k)
            for j in 0..<k {
                // Best predecessor i for staying/switching into j — lowest index wins ties.
                var bestI = 0
                var bestVal = score[0] - (0 == j ? 0 : penalty)
                for i in 1..<k {
                    let v = score[i] - (i == j ? 0 : penalty)
                    if v > bestVal { bestVal = v; bestI = i }
                }
                next[j] = bestVal + row[j]
                ptr[j] = bestI
            }
            score = next
            back.append(ptr)
        }

        // Backtrack from the best final state (lowest index on ties).
        var best = 0
        for i in 1..<k where score[i] > score[best] { best = i }
        var path = [Int](repeating: 0, count: logits.count)
        path[logits.count - 1] = best
        var t = logits.count - 1
        while t > 0 {
            best = back[t - 1][best]
            path[t - 1] = best
            t -= 1
        }
        return path
    }

    /// Merge a per-frame class-index path into chord segments: consecutive equal labels collapse into
    /// one span `[startFrame*hop, (endFrame+1)*hop)`, the no-chord label is dropped, and times are
    /// rounded to 3 decimals. `vocabulary` maps a class index to its label ("Am", "G7", "N", …); an
    /// out-of-range index is treated as no-chord and dropped.
    public static func segments(
        labels: [Int], vocabulary: [String], hopSeconds: Double, noChordLabel: String = "N"
    ) -> [RecognizedChord] {
        guard !labels.isEmpty, hopSeconds > 0 else { return [] }
        func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        func label(_ idx: Int) -> String? {
            guard idx >= 0, idx < vocabulary.count else { return nil }
            let l = vocabulary[idx]
            return l == noChordLabel ? nil : l
        }

        var out: [RecognizedChord] = []
        var runStart = 0
        var runLabel = labels[0]
        for i in 1...labels.count {
            let ended = i == labels.count || labels[i] != runLabel
            if ended {
                if let l = label(runLabel) {
                    out.append(RecognizedChord(
                        start: round3(Double(runStart) * hopSeconds),
                        end: round3(Double(i) * hopSeconds),
                        label: l))
                }
                if i < labels.count { runStart = i; runLabel = labels[i] }
            }
        }
        return out
    }

    /// End-to-end: Viterbi-smooth `logits`, then merge into chord segments. Convenience for a
    /// recognizer that has produced frame logits + a class vocabulary + the frame hop.
    public static func decode(
        logits: [[Double]], vocabulary: [String], hopSeconds: Double,
        transitionPenalty: Double, noChordLabel: String = "N"
    ) -> [RecognizedChord] {
        let path = viterbi(logits: logits, transitionPenalty: transitionPenalty)
        return segments(labels: path, vocabulary: vocabulary, hopSeconds: hopSeconds, noChordLabel: noChordLabel)
    }
}
