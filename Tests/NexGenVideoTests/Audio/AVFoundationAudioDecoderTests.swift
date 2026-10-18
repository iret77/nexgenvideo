import AVFoundation
import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo

/// M8c app-side decoder: AVFoundation → mono Float32 @ 22050 Hz (librosa.load
/// defaults). Writes real audio files to a temp dir and decodes them.
@Suite("AVFoundation Audio Decoder", .serialized)
struct AVFoundationAudioDecoderTests {
    /// Write a `seconds`-long tone to `url` at `sr`/`channels`. Each channel is
    /// a distinct sine so a mono downmix (average) is visibly non-trivial.
    static func writeTone(
        to url: URL, seconds: Double, sr: Double, channels: AVAudioChannelCount, freq: Double = 440
    ) throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: channels, interleaved: false)
        )
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        let frames = AVAudioFrameCount(seconds * sr)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = Float(0.5 * sin(2 * Double.pi * (freq + Double(ch) * 110) * Double(i) / sr))
            }
        }
        try file.write(from: buffer)
    }

    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m8c-dec-\(UUID().uuidString).\(ext)")
    }

    @Test("stereo 48kHz WAV decodes to mono Float32 at 22050 Hz")
    func stereoResample() throws {
        let url = Self.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTone(to: url, seconds: 2.0, sr: 48000, channels: 2)

        let pcm = try AVFoundationAudioDecoder().decode(url)
        #expect(pcm.sampleRate == analysisSampleRate)
        #expect(pcm.samples.count == 44_100, "duration=\(pcm.durationSeconds)")
        // Real audio, not silence.
        #expect(pcm.samples.contains { abs($0) > 0.01 })
    }

    @Test("decoding preserves all 4.3 seconds and the real final audio", arguments: [22_050.0, 44_100.0, 48_000.0])
    func preservesFinalSamples(sourceRate: Double) throws {
        let url = Self.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(4.3 * sourceRate)))
        buffer.frameLength = buffer.frameCapacity
        let source = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / sourceRate
            source[index] = time >= 4.292 ? Float(0.5 * sin(2 * .pi * 1000 * (time - 4.292))) : 0
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let pcm = try AVFoundationAudioDecoder().decode(url)
        #expect(pcm.sampleRate == 22_050)
        try #require(pcm.samples.count == 94_815, "duration=\(pcm.durationSeconds)")
        let marker = Int(4.295 * 22_050)..<Int(4.299 * 22_050)
        let error = marker.reduce(0.0) { sum, index in
            let expected = 0.5 * sin(2 * Double.pi * 1000 * (Double(index) / 22_050 - 4.292))
            let difference = Double(pcm.samples[index]) - expected
            return sum + difference * difference
        }
        #expect(sqrt(error / Double(marker.count)) < 0.08, "The final marker was lost, padded, or shifted.")
    }

    @Test("already mono at 22050 Hz decodes through the fast path")
    func monoFastPath() throws {
        let url = Self.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTone(to: url, seconds: 1.0, sr: analysisSampleRate, channels: 1)

        let pcm = try AVFoundationAudioDecoder().decode(url)
        #expect(pcm.sampleRate == analysisSampleRate)
        #expect(pcm.samples.count == 22_050, "duration=\(pcm.durationSeconds)")
        #expect(pcm.samples.contains { abs($0) > 0.01 })
    }

    @Test("unreadable file throws, does not crash")
    func unreadable() throws {
        let url = Self.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)  // not valid audio
        #expect(throws: (any Error).self) { try AVFoundationAudioDecoder().decode(url) }
    }
}
