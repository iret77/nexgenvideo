import AVFoundation
import Testing
@testable import NexGenVideo

@Suite("Native speech capture preserves actual callback PCM")
struct PerformanceSpeechCaptureTests {
    @Test func finishCannotDiscardTrailingPCMAheadOfTheEndBuffer() throws {
        for (kind, interleaved) in [(AVAudioCommonFormat.pcmFormatInt16, true), (.pcmFormatFloat32, false)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try #require(AVAudioFormat(commonFormat: kind, sampleRate: 22_050, channels: 1, interleaved: interleaved))
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
            pcm.frameLength = 16
            if let samples = pcm.int16ChannelData?[0] { for i in 0..<16 { samples[i] = 1_000 } }
            if let samples = pcm.floatChannelData?[0] { for i in 0..<16 { samples[i] = 0.1 } }
            let capture = PerformanceSpeechCapture(url: url)
            capture.append(pcm)
            capture.receivedUtteranceFinish()
            #expect(!capture.status().0)
            capture.append(pcm)
            let end = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
            end.frameLength = 0
            capture.append(end)
            #expect(capture.status().0 && capture.status().1 == nil)
            #expect(try AVAudioFile(forReading: url).length == 32)
        }
    }

    @Test func endBufferAloneDoesNotClaimACompletedUtterance() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let end = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        end.frameLength = 0
        let capture = PerformanceSpeechCapture(url: url)
        capture.append(end)
        #expect(!capture.status().0)
        capture.finish("Speech synthesis was cancelled.")
        capture.receivedUtteranceFinish()
        #expect(capture.status().0 && capture.status().1 == "Speech synthesis was cancelled.")
    }
}
