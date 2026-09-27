import AVFoundation
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Analysis waveform source identity")
struct AnalysisWaveformSourceTests {
    @Test func replacingSameSizedSourceWithPreservedTimestampCannotReuseItsWaveform() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.caf")
        try writeAudio(url, firstHalfAudible: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let firstBytes = try Data(contentsOf: url)
        let firstHash = try FileDigest.sha256(of: url)
        let firstResult = await MediaVisualCache.loadOrGenerateWaveform(url: url, expectedSourceSHA256: firstHash)
        let first = try #require(firstResult)
        try writeAudio(url, firstHalfAudible: false)
        try FileManager.default.setAttributes([.modificationDate: try #require(attributes[.modificationDate])],
            ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url).count == firstBytes.count)
        let secondHash = try FileDigest.sha256(of: url)
        #expect(firstHash != secondHash)
        let stale = await MediaVisualCache.loadOrGenerateWaveform(url: url, expectedSourceSHA256: firstHash)
        #expect(stale == nil)
        let secondResult = await MediaVisualCache.loadOrGenerateWaveform(url: url, expectedSourceSHA256: secondHash)
        let second = try #require(secondResult)
        #expect(!first.isEmpty && first.count == second.count)
        #expect(first != second)
        let cached = await MediaVisualCache.loadOrGenerateWaveform(url: url, expectedSourceSHA256: secondHash)
        #expect(cached == second)
    }

    private func writeAudio(_ url: URL, firstHalfAudible: Bool) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<8_000 {
            samples[index] = ((index < 4_000) == firstHalfAudible) ? 0.6 : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
