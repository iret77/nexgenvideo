import Accelerate
import Foundation

/// Windowed STFT, magnitude spectrogram, and a Slaney mel filterbank — the
/// primitives every downstream analyzer builds on. Ported to match librosa's
/// defaults exactly (see the parameter table in the module docs / PR notes).
///
/// Parameter parity with librosa @ sr 22050:
///   n_fft      2048   (frame/window length)
///   hop_length 512    (~23.2 ms @ 22050)
///   window     hann   (symmetric=False → periodic, librosa's `get_window`)
///   center     true   (reflect-pad by n_fft/2 both ends → frame count matches)
///   n_mels     128
///   fmin       0.0
///   fmax       sr/2   (11025 @ 22050)
///   htk        false  (Slaney mel scale — librosa default)
///   norm       slaney (area-normalize each filter — librosa default)
///   power      2.0    (magnitude→power for mel; melspectrogram default)
public enum Spectral {
    public static let nFFT = 2048
    public static let hopLength = 512
    public static let nMels = 128

    // MARK: STFT

    /// A framed, hann-windowed real FFT magnitude spectrogram.
    /// Returns `[frame][bin]` where `bin` in `0 ... n_fft/2` (1025 bins for
    /// n_fft 2048). Matches `np.abs(librosa.stft(y))` with default center=True.
    public struct Spectrogram: Sendable, Equatable {
        /// magnitude[frame][bin]
        public var magnitude: [[Float]]
        public var nBins: Int
        public var nFrames: Int
        public var hopLength: Int
        public var sampleRate: Double
    }

    /// Periodic Hann window of length `n`, matching librosa/scipy
    /// `get_window("hann", n, fftbins=True)`: `0.5 - 0.5*cos(2πk/n)`.
    static func hannWindow(_ n: Int) -> [Float] {
        guard n > 1 else { return [Float](repeating: 1, count: max(n, 0)) }
        var w = [Float](repeating: 0, count: n)
        let factor = 2.0 * Double.pi / Double(n)
        for k in 0..<n {
            w[k] = Float(0.5 - 0.5 * cos(factor * Double(k)))
        }
        return w
    }

    /// Reflect-pad the signal by `n_fft/2` on both ends (librosa center=True
    /// uses `np.pad(mode="reflect")`), then frame with `hop_length`. A reflect
    /// pad mirrors without repeating the edge sample: [b,c] ... for signal
    /// starting a,b,c → pad of length 2 = [c,b].
    static func centerPadReflect(_ y: [Float], pad: Int) -> [Float] {
        guard pad > 0, !y.isEmpty else { return y }
        let n = y.count
        // librosa/np reflect requires pad < n for a clean mirror; clamp defensively.
        var out = [Float]()
        out.reserveCapacity(n + 2 * pad)
        for i in 0..<pad {
            let idx = pad - i            // 1..pad  → mirror index
            out.append(y[min(idx, n - 1)])
        }
        out.append(contentsOf: y)
        for i in 0..<pad {
            let idx = n - 2 - i          // mirror from the tail
            out.append(y[max(idx, 0)])
        }
        return out
    }

    /// STFT magnitude with librosa's default framing.
    public static func spectrogram(
        _ y: [Float],
        sampleRate: Double,
        nFFT: Int = Spectral.nFFT,
        hop: Int = Spectral.hopLength,
        center: Bool = true
    ) -> Spectrogram {
        let nBins = nFFT / 2 + 1
        let window = hannWindow(nFFT)

        let signal: [Float] = center ? centerPadReflect(y, pad: nFFT / 2) : y

        // Number of frames: librosa center=True → 1 + len(y)//hop.
        let nFrames: Int
        if center {
            nFrames = 1 + y.count / hop
        } else {
            nFrames = y.count >= nFFT ? 1 + (y.count - nFFT) / hop : 0
        }
        guard nFrames > 0 else {
            return Spectrogram(magnitude: [], nBins: nBins, nFrames: 0, hopLength: hop, sampleRate: sampleRate)
        }

        // Legacy vDSP real FFT (vDSP_create_fftsetup + vDSP_fft_zrip). The modern
        // vDSP.FFT<DSPSplitComplex>.forward wrapper's WRITE bound is not
        // documented tightly enough to rule out writes past packed halfN output
        // buffers (CI showed wandering heap-corruption crashes with it while the
        // first-halfN math stayed correct). zrip's contract is explicit and
        // in-place: N = 2^log2n real points, realp/imagp each hold and receive
        // EXACTLY N/2 elements. log2n = log2(nFFT) with the even/odd ctoz split;
        // forward output is scaled ×2 vs the math DFT (hence the 0.5 below).
        // Setup is created per call and destroyed on exit — negligible next to
        // the frame loop, and no shared mutable state.
        let halfN = nFFT / 2
        let log2n = vDSP_Length(log2(Double(nFFT)).rounded())
        guard nFFT >= 4, nFFT == 1 << Int(log2n),
              let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return Spectrogram(magnitude: [], nBins: nBins, nFrames: 0, hopLength: hop, sampleRate: sampleRate)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var magnitude = [[Float]](repeating: [Float](repeating: 0, count: nBins), count: nFrames)

        var windowed = [Float](repeating: 0, count: nFFT)
        var splitReal = [Float](repeating: 0, count: halfN)
        var splitImag = [Float](repeating: 0, count: halfN)

        for frame in 0..<nFrames {
            let start = frame * hop
            for i in 0..<nFFT {
                let si = start + i
                windowed[i] = si < signal.count ? signal[si] * window[i] : 0
            }
            // ctoz pack: even samples → realp, odd samples → imagp.
            for i in 0..<halfN {
                splitReal[i] = windowed[2 * i]
                splitImag[i] = windowed[2 * i + 1]
            }

            splitReal.withUnsafeMutableBufferPointer { rp in
                splitImag.withUnsafeMutableBufferPointer { ip in
                    var packed = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &packed, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }

            // Packed output in place: splitReal[0]=DC, splitImag[0]=Nyquist,
            // bin k in splitReal[k]/splitImag[k]; ×0.5 undoes zrip's forward
            // scaling to match librosa's unscaled `stft` magnitudes.
            var mags = [Float](repeating: 0, count: nBins)
            mags[0] = abs(splitReal[0]) * 0.5
            mags[nBins - 1] = abs(splitImag[0]) * 0.5
            for bin in 1..<halfN {
                let re = splitReal[bin] * 0.5
                let im = splitImag[bin] * 0.5
                mags[bin] = (re * re + im * im).squareRoot()
            }
            magnitude[frame] = mags
        }

        return Spectrogram(
            magnitude: magnitude, nBins: nBins, nFrames: nFrames, hopLength: hop, sampleRate: sampleRate
        )
    }

    // MARK: Mel scale (Slaney)

    /// Hz → mel on the Slaney (auditory) scale — librosa `hz_to_mel(htk=False)`.
    /// Linear below 1000 Hz at 200/3 mel per Hz, log-spaced above.
    static func hzToMelSlaney(_ hz: Double) -> Double {
        let fMin = 0.0
        let fSp = 200.0 / 3.0
        var mel = (hz - fMin) / fSp
        let minLogHz = 1000.0
        let minLogMel = (minLogHz - fMin) / fSp
        let logstep = log(6.4) / 27.0
        if hz >= minLogHz {
            mel = minLogMel + log(hz / minLogHz) / logstep
        }
        return mel
    }

    /// mel → Hz, Slaney — inverse of `hzToMelSlaney`. librosa `mel_to_hz(htk=False)`.
    static func melToHzSlaney(_ mel: Double) -> Double {
        let fMin = 0.0
        let fSp = 200.0 / 3.0
        var hz = fMin + fSp * mel
        let minLogHz = 1000.0
        let minLogMel = (minLogHz - fMin) / fSp
        let logstep = log(6.4) / 27.0
        if mel >= minLogMel {
            hz = minLogHz * exp(logstep * (mel - minLogMel))
        }
        return hz
    }

    /// Slaney-normalized mel filterbank: `[n_mels][n_bins]`. Exact port of
    /// `librosa.filters.mel` with htk=False, norm='slaney'.
    ///
    /// Construction: `n_mels+2` mel points equally spaced from `hzToMel(fmin)`
    /// to `hzToMel(fmax)`, mapped back to Hz, giving triangular filters over the
    /// FFT bin frequencies. Each triangle is area-normalized by
    /// `2 / (freq[i+2] - freq[i])` (Slaney norm).
    public static func melFilterbank(
        sampleRate: Double,
        nFFT: Int = Spectral.nFFT,
        nMels: Int = Spectral.nMels,
        fMin: Double = 0.0,
        fMax: Double? = nil
    ) -> [[Float]] {
        let fmax = fMax ?? sampleRate / 2.0
        let nBins = nFFT / 2 + 1

        // FFT bin center frequencies: linspace(0, sr/2, n_bins).
        var fftFreqs = [Double](repeating: 0, count: nBins)
        for i in 0..<nBins {
            fftFreqs[i] = Double(i) * sampleRate / Double(nFFT)
        }

        // n_mels+2 mel points → Hz.
        let melMin = hzToMelSlaney(fMin)
        let melMax = hzToMelSlaney(fmax)
        var melFreqs = [Double](repeating: 0, count: nMels + 2)
        for i in 0..<(nMels + 2) {
            let mel = melMin + (melMax - melMin) * Double(i) / Double(nMels + 1)
            melFreqs[i] = melToHzSlaney(mel)
        }

        var weights = [[Float]](repeating: [Float](repeating: 0, count: nBins), count: nMels)
        // fdiff[i] = melFreqs[i+1]-melFreqs[i]
        var fdiff = [Double](repeating: 0, count: nMels + 1)
        for i in 0..<(nMels + 1) {
            fdiff[i] = melFreqs[i + 1] - melFreqs[i]
        }

        for m in 0..<nMels {
            let lower = melFreqs[m]
            let center = melFreqs[m + 1]
            let upper = melFreqs[m + 2]
            let enorm = 2.0 / (upper - lower)  // Slaney area normalization
            for k in 0..<nBins {
                let f = fftFreqs[k]
                // Rising edge from lower→center, falling center→upper.
                let lowerSlope = fdiff[m] > 0 ? (f - lower) / fdiff[m] : 0
                let upperSlope = fdiff[m + 1] > 0 ? (upper - f) / fdiff[m + 1] : 0
                let tri = max(0.0, min(lowerSlope, upperSlope))
                weights[m][k] = Float(tri * enorm)
            }
        }
        return weights
    }

    /// Mel spectrogram: `mel_filter · |STFT|^power`, `[frame][n_mels]`.
    /// Matches `librosa.feature.melspectrogram(power=2.0)`.
    public static func melSpectrogram(
        _ spec: Spectrogram,
        filterbank: [[Float]],
        power: Float = 2.0
    ) -> [[Float]] {
        let nMels = filterbank.count
        // Length agreement is a hard precondition for the vDSP reads below:
        // vDSP_vsq/vDSP_dotpr take nBins on faith and would read past shorter
        // rows (e.g. a filterbank built for a different nFFT).
        guard nMels > 0, spec.nFrames > 0,
              spec.magnitude.count == spec.nFrames,
              spec.magnitude.allSatisfy({ $0.count == spec.nBins }),
              filterbank.allSatisfy({ $0.count == spec.nBins })
        else { return [] }
        let nBins = spec.nBins
        var out = [[Float]](repeating: [Float](repeating: 0, count: nMels), count: spec.nFrames)

        // Precompute power spectrogram per frame, then matrix-apply the bank.
        for f in 0..<spec.nFrames {
            let mag = spec.magnitude[f]
            var powFrame = [Float](repeating: 0, count: nBins)
            if power == 2.0 {
                // Square out-of-place (avoids input/output aliasing).
                vDSP_vsq(mag, 1, &powFrame, 1, vDSP_Length(nBins))
            } else if power == 1.0 {
                powFrame = mag
            } else {
                for i in 0..<nBins { powFrame[i] = pow(mag[i], power) }
            }
            for m in 0..<nMels {
                var acc: Float = 0
                let bankRow = filterbank[m]
                vDSP_dotpr(bankRow, 1, powFrame, 1, &acc, vDSP_Length(nBins))
                out[f][m] = acc
            }
        }
        return out
    }

    /// `librosa.power_to_db(S, ref=max)` on a `[frame][band]` matrix:
    /// `10·log10(max(amin, S)) - 10·log10(max(amin, ref))`, floored to
    /// `top_db` (80) below the peak. `amin=1e-10`.
    public static func powerToDB(
        _ mat: [[Float]],
        topDB: Float = 80.0
    ) -> [[Float]] {
        guard !mat.isEmpty else { return mat }
        let amin: Float = 1e-10
        var peak: Float = amin
        for row in mat {
            for v in row where v > peak { peak = v }
        }
        let refDB = 10.0 * log10(max(amin, peak))
        var out = mat
        var maxDB = -Float.greatestFiniteMagnitude
        for f in 0..<out.count {
            for b in 0..<out[f].count {
                let db = 10.0 * log10(max(amin, out[f][b])) - refDB
                out[f][b] = db
                if db > maxDB { maxDB = db }
            }
        }
        // top_db floor relative to the max value in the result.
        let floor = maxDB - topDB
        for f in 0..<out.count {
            for b in 0..<out[f].count where out[f][b] < floor {
                out[f][b] = floor
            }
        }
        return out
    }

    /// Frame index → time in seconds, librosa `frames_to_time`
    /// (`frame · hop / sr`, no centering offset — librosa cancels the
    /// center pad in the default call).
    public static func frameToTime(_ frame: Int, hop: Int, sampleRate: Double) -> Double {
        Double(frame) * Double(hop) / sampleRate
    }
}
