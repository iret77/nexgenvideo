import AVFoundation
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Caption extraction at the real media end")
struct CaptionAudioRangeTests {
    @Test(arguments: [0.0, 1.0])
    func paddedRangeReadsExistingSamplesWithoutPaddingOrFailure(start: Double) async throws {
        let source = AVFoundationAudioDecoderTests.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: source) }
        try AVFoundationAudioDecoderTests.writeTone(to: source, seconds: 2, sr: 16_000, channels: 1)
        var frames = 0
        try await AudioTrackReader.read(from: source, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ], range: start...3) { pcm in
            #expect(pcm.format.sampleRate == 16_000)
            frames += Int(pcm.frameLength)
        }
        #expect(frames == Int((2 - start) * 16_000))
    }
}
