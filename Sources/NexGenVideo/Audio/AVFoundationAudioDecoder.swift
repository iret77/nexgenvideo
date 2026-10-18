import AVFoundation
import Foundation
import NexGenEngine

/// The host's audio decoder for the engine's analysis pipeline: reads an audio
/// file and returns mono Float32 PCM resampled to `analysisSampleRate`
/// (22050 Hz), matching `librosa.load`'s defaults (mono downmix by channel
/// average, resample). Injected into the `EngineRegistry` so the musicvideo
/// pack's analysis phase runner stays free of AVFoundation.
struct AVFoundationAudioDecoder: AudioPCMDecoding {
    enum DecodeError: Error, CustomStringConvertible {
        case unreadable(String)
        case emptyAudio(String)
        case conversionFailed(String)

        var description: String {
            switch self {
            case .unreadable(let name): return "Couldn't read audio file \(name)."
            case .emptyAudio(let name): return "Audio file \(name) has no decodable audio frames."
            case .conversionFailed(let reason): return "Audio decode failed: \(reason)."
            }
        }
    }

    func decode(_ url: URL) throws -> PCMBuffer {
        let name = url.lastPathComponent
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DecodeError.unreadable("\(name) (\(error.localizedDescription))")
        }

        let sourceFormat = file.processingFormat
        let frameCount = file.length
        guard frameCount > 0 else { throw DecodeError.emptyAudio(name) }

        // Target: mono Float32, non-interleaved, at the analysis sample rate.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: analysisSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw DecodeError.conversionFailed("could not build target format")
        }

        // Fast path: already mono at the target rate — read straight through.
        if sourceFormat.channelCount == 1,
           sourceFormat.sampleRate == analysisSampleRate,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            return try readDirect(file: file, frameCount: frameCount, name: name)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw DecodeError.conversionFailed("no converter from \(sourceFormat) to \(targetFormat)")
        }
        // Average channels on downmix, matching librosa's mono=True.
        converter.downmix = true

        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw DecodeError.conversionFailed("could not allocate read buffer")
        }
        do {
            try file.read(into: readBuffer)
        } catch {
            throw DecodeError.unreadable("\(name) (\(error.localizedDescription))")
        }

        // Output capacity: source frames scaled by the sample-rate ratio, plus
        // slack for the resampler's tail.
        let ratio = analysisSampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up)) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw DecodeError.conversionFailed("could not allocate output buffer")
        }

        var fed = false
        var samples: [Float] = []
        samples.reserveCapacity(Int(outCapacity))
        while true {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if fed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return readBuffer
            }
            if let conversionError {
                throw DecodeError.conversionFailed(conversionError.localizedDescription)
            }
            guard status != .error else {
                throw DecodeError.conversionFailed("converter returned an error")
            }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream { break }
            guard outBuffer.frameLength > 0 else {
                throw DecodeError.conversionFailed("converter stopped producing frames before reaching the end of the stream")
            }
        }

        guard !samples.isEmpty else { throw DecodeError.emptyAudio(name) }
        return PCMBuffer(samples: samples, sampleRate: analysisSampleRate)
    }

    /// Already mono/Float32 at the target rate: read the whole file into one
    /// buffer and lift the channel out.
    private func readDirect(file: AVAudioFile, frameCount: AVAudioFramePosition, name: String) throws -> PCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw DecodeError.conversionFailed("could not allocate read buffer")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw DecodeError.unreadable("\(name) (\(error.localizedDescription))")
        }
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            throw DecodeError.emptyAudio(name)
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return PCMBuffer(samples: samples, sampleRate: analysisSampleRate)
    }
}
