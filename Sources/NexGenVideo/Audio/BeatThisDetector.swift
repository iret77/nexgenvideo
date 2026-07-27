import Accelerate
import AVFoundation
import Foundation
import NexGenEngine
import OnnxRuntimeBindings

/// On-device neural beat/downbeat tracking via "Beat This!" (CPJKU, ISMIR 2024) exported to ONNX.
/// Implements the engine's generic `AudioBeatDetecting` seam; the musicvideo pack prefers this grid over
/// the DSP heuristic when it looks valid. Faithful port of the model's C++ reference pipeline: 22.05 kHz
/// mono → 128-band Slaney log-mel (n_fft 1024, hop 441) → transformer over 1500-frame chunks (6-frame
/// border) → minimal post-processing (max-pool peak pick + dedup + downbeat-to-beat snap).
///
/// The mel front-end is NOT baked into the ONNX, so the spectrogram is computed here with Accelerate.
/// The exact scaling must match what the network trained on — hence this validates on-device (a plausible
/// but subtly wrong grid would degrade beat sync), and `detectBeats` returns nil on an implausible result
/// so the pack falls back to its DSP grid rather than regressing.
struct BeatThisDetector: AudioBeatDetecting {
    private static let sr: Double = 22_050
    private static let nFFT = 1024
    private static let hop = 441
    private static let nMels = 128
    private static let fMin: Double = 30
    private static let fMax: Double = 11_000
    private static let logMultiplier: Double = 1000
    private static let amin: Double = 1e-10
    private static let chunkSize = 1500
    private static let border = 6
    private static let fps: Double = 50            // sr / hop
    private static let modelURL = "https://raw.githubusercontent.com/mosynthkey/beat_this_cpp/07ab790a9ec2eda8093d52d249e3ec4f0510ee72/onnx/beat_this.onnx"
    private static let modelSHA256 = "c5c1466e08abdb03fdeb50668a06f244b787d564c212490482231a9cfbe9ccbd"

    func detectBeats(_ audio: URL, stems: SeparatedStems?) throws -> DetectedBeatGrid? {
        let mono = try Self.loadMono22k(audio)
        guard mono.count > Self.nFFT else { return nil }
        let mel = Self.melSpectrogram(mono)
        guard mel.count > 2 * Self.border else { return nil }
        let modelPath = try HFModelStore.ensure(
            urlString: Self.modelURL,
            file: "beat_this.onnx",
            subdir: "beatthis",
            expectedSHA256: Self.modelSHA256
        )
        let (beatLogits, downLogits) = try Self.runChunked(mel, modelPath: modelPath.path)
        let (beats, downbeats) = Self.postprocess(beat: beatLogits, downbeat: downLogits)
        // Plausibility guard: a real grid is several strictly-increasing beats. Anything else → let the
        // caller keep its DSP grid instead of overriding with a degenerate neural result.
        guard beats.count >= 4, zip(beats, beats.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        // Derive BPM from the neural beats so the persisted tempo agrees with the persisted grid (the
        // detector returns nil BPM otherwise, leaving the mismatched DSP value in place).
        return DetectedBeatGrid(beats: beats, downbeats: downbeats, bpm: Self.estimateBPM(beats))
    }

    /// Median-interval BPM from a beat sequence (robust to the odd missed/extra beat). Nil if too few.
    private static func estimateBPM(_ beats: [Double]) -> Double? {
        let intervals = zip(beats, beats.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        guard !intervals.isEmpty else { return nil }
        let median = intervals[intervals.count / 2]
        return median > 0 ? 60.0 / median : nil
    }

    // MARK: - Mel spectrogram (port of MelSpectrogram.cpp)

    private static let hannWindow: [Float] = (0..<nFFT).map {
        Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(nFFT))))
    }

    /// Triangular Slaney-scale mel filterbank, shape [nFFT/2+1][nMels].
    private static let filterbank: [[Double]] = {
        func hzToMel(_ hz: Double) -> Double {
            let fSp = 200.0 / 3.0
            var mel = hz / fSp
            let minLogHz = 1000.0, minLogMel = minLogHz / fSp, logstep = log(6.4) / 27.0
            if hz >= minLogHz { mel = minLogMel + log(hz / minLogHz) / logstep }
            return mel
        }
        func melToHz(_ mel: Double) -> Double {
            let fSp = 200.0 / 3.0
            var hz = fSp * mel
            let minLogHz = 1000.0, minLogMel = minLogHz / fSp, logstep = log(6.4) / 27.0
            if mel >= minLogMel { hz = minLogHz * exp(logstep * (mel - minLogMel)) }
            return hz
        }
        let bins = nFFT / 2 + 1
        let melMin = hzToMel(fMin), melMax = hzToMel(fMax)
        let hzPoints = (0..<(nMels + 2)).map { melToHz(melMin + (melMax - melMin) * Double($0) / Double(nMels + 1)) }
        let freqs = (0..<bins).map { Double($0) * sr / Double(nFFT) }
        var fb = [[Double]](repeating: [Double](repeating: 0, count: nMels), count: bins)
        for i in 0..<bins {
            let hzI = freqs[i]
            for j in 0..<nMels {
                let left = hzPoints[j], center = hzPoints[j + 1], right = hzPoints[j + 2]
                let leftSlope = center - left != 0 ? (hzI - left) / (center - left) : 0
                let rightSlope = right - center != 0 ? (right - hzI) / (right - center) : 0
                fb[i][j] = max(0, min(leftSlope, rightSlope))
            }
        }
        return fb
    }()

    /// Compute the 128-band log-mel spectrogram, [frames][nMels]. Reflect-padded STFT (center=True),
    /// magnitude scaled `|X|/√win`, then `log1p(1000·max(melEnergy, 1e-10))`.
    static func melSpectrogram(_ audio: [Float]) -> [[Float]] {
        let pad = nFFT / 2
        let padded = reflectPad(audio, pad: pad)
        guard padded.count >= nFFT else { return [] }
        let numFrames = (padded.count - nFFT) / hop + 1
        guard numFrames > 0 else { return [] }
        let bins = nFFT / 2 + 1
        let norm = Float(sqrt(Double(nFFT)))

        let log2n = vDSP_Length(log2(Double(nFFT)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var out = [[Float]](repeating: [Float](repeating: 0, count: nMels), count: numFrames)
        var windowed = [Float](repeating: 0, count: nFFT)
        var realp = [Float](repeating: 0, count: nFFT / 2)
        var imagp = [Float](repeating: 0, count: nFFT / 2)
        var amp = [Float](repeating: 0, count: bins)

        for f in 0..<numFrames {
            let start = f * hop
            for j in 0..<nFFT { windowed[j] = padded[start + j] * hannWindow[j] }
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(nFFT / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // zrip packs DC in realp[0], Nyquist in imagp[0]; bins carry 2×the DFT value.
                    amp[0] = abs(rp[0]) * 0.5 / norm
                    amp[nFFT / 2] = abs(ip[0]) * 0.5 / norm
                    for k in 1..<(nFFT / 2) {
                        amp[k] = (rp[k] * rp[k] + ip[k] * ip[k]).squareRoot() * 0.5 / norm
                    }
                }
            }
            for m in 0..<nMels {
                var energy = 0.0
                for k in 0..<bins { energy += Double(amp[k]) * filterbank[k][m] }
                out[f][m] = Float(log(1 + logMultiplier * max(energy, amin)))
            }
        }
        return out
    }

    /// numpy/torch "reflect" padding (excludes the edge sample), clamped for very short input.
    private static func reflectPad(_ x: [Float], pad: Int) -> [Float] {
        let n = x.count
        guard n > 1 else { return x }
        var out = [Float]()
        out.reserveCapacity(n + 2 * pad)
        for k in 0..<pad { out.append(x[min(pad - k, n - 1)]) }   // reflect front: x[pad], x[pad-1], … x[1]
        out.append(contentsOf: x)
        for k in 0..<pad { out.append(x[max(n - 2 - k, 0)]) }      // reflect back: x[n-2], x[n-3], …
        return out
    }

    // MARK: - Chunked inference (port of InferenceProcessor.cpp)

    private static func runChunked(_ mel: [[Float]], modelPath: String) throws -> (beat: [Float], downbeat: [Float]) {
        let numFrames = mel.count
        let session = try OrtRuntime.session(modelPath: modelPath)
        var beat = [Float](repeating: -1000, count: numFrames)
        var down = [Float](repeating: -1000, count: numFrames)

        // Chunk starts: step by (chunkSize - 2·border), first chunk begins at -border; the last is
        // pulled back so it ends at the piece end.
        var starts: [Int] = []
        var s = -border
        while s < numFrames - border { starts.append(s); s += chunkSize - 2 * border }
        if numFrames > chunkSize - 2 * border, !starts.isEmpty {
            starts[starts.count - 1] = numFrames - (chunkSize - border)
        }

        for start in starts {
            // Build [1, chunkSize, nMels] input, zero-padding frames outside [0, numFrames).
            var input = [Float](repeating: 0, count: chunkSize * nMels)
            for j in 0..<chunkSize {
                let gf = start + j
                if gf >= 0 && gf < numFrames {
                    let row = mel[gf]
                    let base = j * nMels
                    for m in 0..<nMels { input[base + m] = row[m] }
                }
            }
            let inData = input.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            let inValue = try ORTValue(
                tensorData: inData, elementType: .float,
                shape: [NSNumber(value: 1), NSNumber(value: chunkSize), NSNumber(value: nMels)])
            let outputs = try session.run(
                withInputs: ["input_spectrogram": inValue], outputNames: ["beat", "downbeat"], runOptions: nil)
            guard let bVal = outputs["beat"], let dVal = outputs["downbeat"] else {
                throw NSError(domain: "BeatThis", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "model produced no beat/downbeat output"])
            }
            let bChunk = try floats(bVal), dChunk = try floats(dVal)
            // Discard the border frames from each edge; place the interior into the full-length arrays.
            for j in border..<(chunkSize - border) where j < bChunk.count {
                let gf = start + j
                if gf >= 0 && gf < numFrames { beat[gf] = bChunk[j]; down[gf] = dChunk[j] }
            }
        }
        return (beat, down)
    }

    private static func floats(_ value: ORTValue) throws -> [Float] {
        // `tensorData()` wraps the ORTValue's buffer without copying — keep `value` alive across the read.
        try withExtendedLifetime(value) {
            let data = try value.tensorData()
            let count = data.length / MemoryLayout<Float>.stride
            let p = data.bytes.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: p, count: count))
        }
    }

    // MARK: - Post-processing (port of Postprocessor.cpp, "minimal")

    private static func postprocess(beat: [Float], downbeat: [Float]) -> (beats: [Double], downbeats: [Double]) {
        // Peak = local max under a width-7 max-pool AND positive. Pool the two series SEPARATELY: the
        // model's postprocess runs max_pool1d per channel — concatenating them would let a strong peak
        // in one series suppress peaks near the concat boundary of the other.
        let pooledBeat = maxPool1d(beat, kernel: 7, padding: 3)
        let pooledDown = maxPool1d(downbeat, kernel: 7, padding: 3)
        var beatFrames: [Int] = []
        var downFrames: [Int] = []
        for i in beat.indices {
            if beat[i] == pooledBeat[i] && beat[i] > 0 { beatFrames.append(i) }
            if downbeat[i] == pooledDown[i] && downbeat[i] > 0 { downFrames.append(i) }
        }
        beatFrames = deduplicate(beatFrames, width: 1)
        downFrames = deduplicate(downFrames, width: 1)

        var beatTimes = beatFrames.map { Double($0) / fps }
        var downTimes = downFrames.map { Double($0) / fps }
        // Snap each downbeat to the nearest beat, then drop duplicates.
        if !beatTimes.isEmpty {
            downTimes = downTimes.map { d in beatTimes.min(by: { abs($0 - d) < abs($1 - d) }) ?? d }
        }
        downTimes = Array(Set(downTimes)).sorted()
        beatTimes.sort()
        return (beatTimes, downTimes)
    }

    private static func maxPool1d(_ input: [Float], kernel: Int, padding: Int) -> [Float] {
        var out = [Float](repeating: 0, count: input.count)
        for i in input.indices {
            var m = -Float.greatestFiniteMagnitude
            for k in 0..<kernel {
                let idx = i - padding + k
                if idx >= 0 && idx < input.count { m = max(m, input[idx]) }
            }
            out[i] = m
        }
        return out
    }

    /// Merge peaks within `width` frames into their running mean (port of `deduplicate_peaks`).
    private static func deduplicate(_ peaks: [Int], width: Int) -> [Int] {
        guard !peaks.isEmpty else { return [] }
        var result: [Int] = []
        var p = Double(peaks[0])
        var c = 1
        for i in 1..<peaks.count {
            let p2 = peaks[i]
            if Double(p2) - p <= Double(width) {
                c += 1
                p += (Double(p2) - p) / Double(c)
            } else {
                result.append(Int(p.rounded()))
                p = Double(p2)
                c = 1
            }
        }
        result.append(Int(p.rounded()))
        return result
    }

    // MARK: - Audio load

    /// Decode an audio file to 22.05 kHz mono Float32 (channel-averaged downmix + resample).
    static func loadMono22k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let frames = file.length
        guard frames > 0 else { return [] }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target),
            let readBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames))
        else { return [] }
        converter.downmix = true
        try file.read(into: readBuffer)
        let ratio = sr / source.sampleRate
        let outCap = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return [] }
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true; outStatus.pointee = .haveData; return readBuffer
        }
        guard convError == nil, status != .error, let ch = outBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))
    }
}
