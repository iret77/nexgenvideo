import AVFoundation
import Foundation
import NexGenEngine
import OnnxRuntimeBindings

/// On-device vocal isolation via HT-Demucs FT (vocals specialist), exported to ONNX with the STFT/iSTFT
/// baked into the graph — so this is a faithful port of the model's `infer.py` reference: load the mix
/// as 44.1 kHz stereo, run fixed 7.8 s segments through ONNX Runtime with 25% overlap-add, and write the
/// isolated vocal stem. Implements the engine's generic `AudioStemSeparating` seam; the musicvideo pack
/// feeds the clean vocal to whisper so transcription reads the voice, not the full mix.
struct DemucsStemSeparator: AudioStemSeparating {
    private static let sampleRate: Double = 44_100
    private static let segment = 343_980            // 7.8 s @ 44.1 kHz, the model's fixed input length
    private static let sourceCount = 4              // drums, bass, other, vocals
    private static let vocalsIndex = 3
    private static let modelRepo = "StemSplitio/htdemucs-ft-vocals-onnx"
    private static let modelRevision = "2ef0d757d3e226d0da85fb8c71514f464fcabdd0"
    private static let modelFile = "htdemucs_ft_vocals.onnx"
    private static let modelSHA256 = "8c5d5e2da1f27050240bb80236673307ee3b40d4b064066d9350f4d64bfd544d"

    enum SeparateError: LocalizedError {
        case audioLoadFailed(String)
        case inferenceFailed(String)
        var errorDescription: String? {
            switch self {
            case .audioLoadFailed(let m): return "Couldn't read audio for separation: \(m)"
            case .inferenceFailed(let m): return "Vocal separation failed: \(m)"
            }
        }
    }

    func separateStems(_ audio: URL, into dir: URL) throws -> SeparatedStems {
        let mix = try Self.loadStereo44k(audio)
        guard mix.left.count > 0 else { return SeparatedStems() }
        let modelPath = try HFModelStore.ensure(
            repo: Self.modelRepo,
            revision: Self.modelRevision,
            file: Self.modelFile,
            subdir: "demucs",
            expectedSHA256: Self.modelSHA256
        )
        let vocals = try Self.separateVocals(left: mix.left, right: mix.right, modelPath: modelPath.path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vocalsURL = dir.appendingPathComponent("vocals.wav")
        try Self.writeStereoWAV(left: vocals.left, right: vocals.right, to: vocalsURL)
        return SeparatedStems(vocals: vocalsURL)
    }

    /// Chunked overlap-add separation (port of `infer.py::separate`): stride = segment − segment/4, a
    /// linear fade-in/out transition window, weighted accumulate, normalize by the summed weight.
    private static func separateVocals(
        left: [Float], right: [Float], modelPath: String
    ) throws -> (left: [Float], right: [Float]) {
        let total = left.count
        let overlap = segment / 4
        let stride = segment - overlap
        let nChunks = max(1, (total + stride - 1) / stride)
        let window = transitionWindow(segment: segment, overlapFrac: 0.25)

        let session = try OrtRuntime.session(modelPath: modelPath)
        var outL = [Float](repeating: 0, count: total)
        var outR = [Float](repeating: 0, count: total)
        var weight = [Float](repeating: 0, count: total)

        for i in 0..<nChunks {
            let start = i * stride
            guard start < total else { break }
            let end = min(start + segment, total)
            let chunkLen = end - start

            // Pack [1, 2, segment] channel-major (L block then R block), zero-padded past chunkLen.
            var input = [Float](repeating: 0, count: 2 * segment)
            for j in 0..<chunkLen {
                input[j] = left[start + j]
                input[segment + j] = right[start + j]
            }
            let inData = input.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            let inValue = try ORTValue(
                tensorData: inData, elementType: .float,
                shape: [NSNumber(value: 1), NSNumber(value: 2), NSNumber(value: segment)])
            let outputs = try session.run(
                withInputs: ["mix": inValue], outputNames: ["stems"], runOptions: nil)
            guard let stemsVal = outputs["stems"] else {
                throw SeparateError.inferenceFailed("model produced no 'stems' output")
            }
            // stems: [1, sourceCount, 2, segment] source-major → vocals L/R blocks. `tensorData()` wraps
            // the ORTValue's buffer WITHOUT copying, so copy the vocal slices out while `stemsVal` is
            // guaranteed alive — otherwise ARC could free the tensor before this read (use-after-free).
            let vocalOffset = vocalsIndex * 2 * segment
            let (vocalsL, vocalsR): ([Float], [Float]) = try withExtendedLifetime(stemsVal) {
                let outData = try stemsVal.tensorData()
                let floatCount = outData.length / MemoryLayout<Float>.stride
                let p = outData.bytes.bindMemory(to: Float.self, capacity: floatCount)
                return (Array(UnsafeBufferPointer(start: p + vocalOffset, count: chunkLen)),
                        Array(UnsafeBufferPointer(start: p + vocalOffset + segment, count: chunkLen)))
            }
            for j in 0..<chunkLen {
                let w = window[j]
                outL[start + j] += vocalsL[j] * w
                outR[start + j] += vocalsR[j] * w
                weight[start + j] += w
            }
        }
        for j in 0..<total {
            let w = max(weight[j], 1e-8)
            outL[j] /= w
            outR[j] /= w
        }
        return (outL, outR)
    }

    /// Linear fade over the first/last `segment*overlapFrac` samples, 1.0 in between (port of
    /// `_make_transition_window`).
    private static func transitionWindow(segment: Int, overlapFrac: Float) -> [Float] {
        let transition = Int(Float(segment) * overlapFrac)
        var window = [Float](repeating: 1, count: segment)
        guard transition > 1 else { return window }
        for i in 0..<transition {
            let v = Float(i) / Float(transition - 1)
            window[i] = v
            window[segment - 1 - i] = v
        }
        return window
    }

    /// Load an audio file as 44.1 kHz stereo Float32 (per-channel arrays). Mono is duplicated to both
    /// channels; >2 channels are downmixed by the converter.
    static func loadStereo44k(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw SeparateError.audioLoadFailed("\(url.lastPathComponent) (\(error.localizedDescription))")
        }
        let source = file.processingFormat
        let frames = file.length
        guard frames > 0 else { return ([], []) }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target),
            let readBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames))
        else {
            throw SeparateError.audioLoadFailed("could not build 44.1 kHz stereo converter")
        }
        do { try file.read(into: readBuffer) } catch {
            throw SeparateError.audioLoadFailed("\(url.lastPathComponent) (\(error.localizedDescription))")
        }
        let ratio = sampleRate / source.sampleRate
        let outCap = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else {
            throw SeparateError.audioLoadFailed("could not allocate output buffer")
        }
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true; outStatus.pointee = .haveData; return readBuffer
        }
        if let convError { throw SeparateError.audioLoadFailed(convError.localizedDescription) }
        guard status != .error, let channels = outBuffer.floatChannelData else {
            throw SeparateError.audioLoadFailed("converter returned an error")
        }
        let n = Int(outBuffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: channels[0], count: n))
        // channels[1] exists because the target format is stereo (the converter upmixes mono).
        let right = Array(UnsafeBufferPointer(start: channels[1], count: n))
        return (left, right)
    }

    /// Write a 44.1 kHz stereo Float32 WAV (readable by the transcriber's loader).
    static func writeStereoWAV(left: [Float], right: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) else {
            throw SeparateError.inferenceFailed("could not build output WAV format")
        }
        let n = min(left.count, right.count)
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        // Write in blocks to bound peak buffer memory.
        let block = 1 << 20
        var offset = 0
        while offset < n {
            let count = min(block, n - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw SeparateError.inferenceFailed("could not allocate write buffer")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let ch = buffer.floatChannelData {
                left.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress! + offset, count: count) }
                right.withUnsafeBufferPointer { ch[1].update(from: $0.baseAddress! + offset, count: count) }
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}
