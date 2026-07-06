import Accelerate
import Foundation

/// Frame-wise energy + tempo curves and the downbeat-derived global BPM.
/// Port of `features.py`.
///
/// librosa parity:
///   RMS frame_length 2048, hop_length = sr·hop_ms/1000 (hop_ms 100 → 2205 @ 22050)
///   RMS center=True (reflect pad), normalized to its max → 0..1
///   tempo_curve: onset_strength → per-frame tempo (aggregate=None), hop 512,
///     downsampled to hop_s=2.0 s
public enum Energy {
    /// RMS energy curve. `hopMs` matches `features.py::energy_curve` (100 ms).
    /// Returns points `{t, rms}` with `rms` normalized to the curve's max.
    public static func rmsCurve(
        _ y: [Float],
        sampleRate: Double,
        frameLength: Int = 2048,
        hopMs: Double = 100.0
    ) -> [EnergyPoint] {
        guard !y.isEmpty else { return [] }
        let hop = max(1, Int(sampleRate * hopMs / 1000.0))

        // librosa.feature.rms uses center=True: reflect-pad by frame_length/2.
        let padded = Spectral.centerPadReflect(y, pad: frameLength / 2)
        let nFrames = 1 + y.count / hop

        var rms = [Float](repeating: 0, count: nFrames)
        padded.withUnsafeBufferPointer { p in
            for f in 0..<nFrames {
                let start = f * hop
                let count = min(frameLength, max(0, padded.count - start))
                if count <= 0 { rms[f] = 0; continue }
                var meanSquare: Float = 0
                vDSP_measqv(p.baseAddress! + start, 1, &meanSquare, vDSP_Length(count))
                rms[f] = meanSquare.squareRoot()
            }
        }

        var maxRMS: Float = 0
        vDSP_maxv(rms, 1, &maxRMS, vDSP_Length(nFrames))
        if maxRMS > 0 {
            var inv = 1.0 / maxRMS
            var scaled = [Float](repeating: 0, count: nFrames)
            vDSP_vsmul(rms, 1, &inv, &scaled, 1, vDSP_Length(nFrames))
            rms = scaled
        }

        var out = [EnergyPoint]()
        out.reserveCapacity(nFrames)
        for f in 0..<nFrames {
            let t = Double(f) * Double(hop) / sampleRate
            out.append(EnergyPoint(t: round3(t), rms: round4(Double(rms[f]))))
        }
        return out
    }

    /// Tempo curve. Port of `features.py::tempo_curve`: per-frame local tempo
    /// from the onset envelope (hop 512), downsampled to `hopS` seconds.
    public static func tempoCurve(
        _ y: [Float],
        sampleRate: Double,
        hop: Int = Spectral.hopLength,
        hopS: Double = 2.0
    ) -> [TempoPoint] {
        let env = Onset.envelope(y, sampleRate: sampleRate, hop: hop)
        guard !env.values.isEmpty else { return [] }
        let perFrame = Tempo.perFrame(onset: env.values, sampleRate: sampleRate, hop: hop)

        let step = max(1, Int(hopS * sampleRate / Double(hop)))
        var out = [TempoPoint]()
        var i = 0
        while i < perFrame.count {
            let t = Double(i) * Double(hop) / sampleRate
            out.append(TempoPoint(t: round3(t), bpm: round2(perFrame[i])))
            i += step
        }
        return out
    }

    /// Port of `features.py::global_bpm_from_downbeats`: median of downbeat
    /// intervals × beats_per_bar. Needs ≥3 downbeats; else 0.
    public static func globalBPMFromDownbeats(
        _ downbeats: [Double],
        beatsPerBar: Int = 4
    ) -> Double {
        guard downbeats.count >= 3 else { return 0 }
        var intervals = [Double]()
        for i in 1..<downbeats.count { intervals.append(downbeats[i] - downbeats[i - 1]) }
        intervals.sort()
        let mid = intervals.count / 2
        let median = intervals.count % 2 == 0
            ? (intervals[mid - 1] + intervals[mid]) / 2
            : intervals[mid]
        guard median > 0 else { return 0 }
        return round3(60.0 * Double(beatsPerBar) / median)
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
