import AVFoundation
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Waveform extraction", .serialized)
struct WaveformExtractorTests {
    @Test("buckets use decoded frame rate")
    func bucketsUseDecodedFrameRate() {
        var fortyEight = accumulator()
        fortyEight.append(peak: 0.5, frameCount: 60_000, sampleRate: 48_000)

        var fortyFourOne = accumulator()
        fortyFourOne.append(peak: 0.5, frameCount: 55_125, sampleRate: 44_100)

        #expect(fortyEight.finish().count == 250)
        #expect(fortyFourOne.finish().count == 250)
    }

    @Test("trimmed extraction follows the audio track timebase")
    func trimmedExtractionFollowsTrackTimebase() async throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilenceThenTone(to: url, sampleRate: 44_100)

        let silence = try await WaveformExtractor.peakEnvelope(from: url, range: 0...1)
        let tone = try await WaveformExtractor.peakEnvelope(from: url, range: 1...2)

        #expect((198...202).contains(silence.count))
        #expect((198...202).contains(tone.count))
        #expect(silence.allSatisfy { $0 > 0.99 })
        #expect(tone.reduce(0, +) / Float(tone.count) < 0.1)
    }

    @Test("zero length and invalid timebases are safe")
    func zeroLengthAndInvalidTimebasesAreSafe() async throws {
        var empty = accumulator()
        empty.append(peak: 1, frameCount: 0, sampleRate: 48_000)
        empty.append(peak: 1, frameCount: 1_000, sampleRate: 0)
        empty.append(peak: 1, frameCount: 1_000, sampleRate: .infinity)
        empty.append(peak: 1, frameCount: 1_000, sampleRate: .nan)
        #expect(empty.finish().isEmpty)

        let url = tempURL("wav")
        let zeroRange = try await WaveformExtractor.peakEnvelope(from: url, range: 1...1)
        #expect(zeroRange.isEmpty)
        await #expect(throws: AudioTrackReader.ReadError.self) {
            try await WaveformExtractor.peakEnvelope(from: url, range: 0 ... .infinity)
        }
    }

    @Test("large unknown streams stay bounded and preserve peaks")
    func largeUnknownStreamsStayBounded() {
        var subject = WaveformPeakAccumulator(
            samplesPerSecond: 200,
            noiseFloorDb: -50,
            maxSamples: 128
        )
        subject.append(
            peak: 0.5,
            frameCount: 48_000 * 60 * 60 * 24,
            sampleRate: 48_000
        )
        let result = subject.finish()
        let expected = WaveformPeakAccumulator.normalized(peak: 0.5, noiseFloorDb: -50)

        #expect(!result.isEmpty)
        #expect(result.count <= 128)
        #expect(result.allSatisfy { abs($0 - expected) < 0.000_001 })
    }

    @Test("cache bytes are deterministic, atomic, and validated off main actor")
    func cacheIsDeterministicAndValidatedOffMainActor() async throws {
        let key = "waveform-test-\(UUID().uuidString)"
        let url = MediaVisualCache.diskCache.directory.appendingPathComponent(key + ".waveform2")
        defer { try? FileManager.default.removeItem(at: url) }
        let expected: [Float] = [0, 0.25, 0.5, 0.75, 1]

        let first = try await Task.detached {
            MediaVisualCache.saveWaveform(expected, key: key)
            return try Data(contentsOf: url)
        }.value
        let second = try await Task.detached {
            MediaVisualCache.saveWaveform(expected, key: key)
            return try Data(contentsOf: url)
        }.value

        #expect(first == second)
        let loaded = await Task.detached { MediaVisualCache.loadWaveform(key: key) }.value
        #expect(loaded == expected)

        try [Float.nan].withUnsafeBytes { try Data($0).write(to: url, options: .atomic) }
        let rejected = await Task.detached { MediaVisualCache.loadWaveform(key: key) }.value
        #expect(rejected == nil)

        await Task.detached { MediaVisualCache.saveWaveform([], key: key) }.value
        let empty = await Task.detached { MediaVisualCache.loadWaveform(key: key) }.value
        #expect(empty == [])
    }

    private func accumulator() -> WaveformPeakAccumulator {
        WaveformPeakAccumulator(samplesPerSecond: 200, noiseFloorDb: -50, maxSamples: 240_000)
    }

    private func tempURL(_ extension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-\(UUID().uuidString)")
            .appendingPathExtension(`extension`)
    }

    private func writeSilenceThenTone(to url: URL, sampleRate: Double) throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        let frames = AVAudioFrameCount(sampleRate * 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            guard frame >= Int(sampleRate) else {
                channel[frame] = 0
                continue
            }
            channel[frame] = Float(0.8 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }
}
