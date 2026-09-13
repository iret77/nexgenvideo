import AVFoundation
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Decoded waveform")
struct WaveformExtractorTests {
    private struct PCMSource: WaveformSampleSource {
        let buffers: [CMSampleBuffer]

        func read(_ consume: (CMSampleBuffer) throws -> Void) async throws {
            for buffer in buffers { try consume(buffer) }
        }
    }

    private func pcm(_ values: [Float], pts: Double, rate: Double = 1000) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
        ))
        var block: CMBlockBuffer?
        let bytes = values.count * MemoryLayout<Float>.size
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
        ) == noErr)
        let data = try #require(block)
        let status = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: bytes)
        }
        #expect(status == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: 1 / rate, preferredTimescale: 1_000_000_000),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var size = MemoryLayout<Float>.size
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: format.formatDescription,
            sampleCount: values.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr)
        return try #require(sample)
    }

    @Test("partial windows cross buffers and keep a final partial bin")
    func partialBuffers() async throws {
        let source = PCMSource(buffers: [
            try pcm([0, 0, 0], pts: 0),
            try pcm([0, 1, 0, 0, 0, 0, 0, 0.1, 0.1], pts: 0.003),
        ])
        let result = try await WaveformExtractor.extract(from: source)
        #expect(result.samples.count == 3)
        #expect(result.samples[0] == 0)
        #expect(result.samples[1] == 1)
        #expect(abs(result.samples[2] - 0.4) < 0.00001)
        #expect(result.sourceStartTime == 0)
        #expect(abs(result.decodedDuration - 0.012) < 0.0000001)
        #expect(result.samplePeriod == 0.005)
    }

    @Test("nonzero PTS preserves gaps and discards already decoded overlap")
    func timestamps() async throws {
        let source = PCMSource(buffers: [
            try pcm([0, 0, 0, 0, 0], pts: 2),
            try pcm([1, 1, 0.1, 0.1, 0.1, 0.1, 0.1], pts: 2.003),
            try pcm([1, 1, 1, 1, 1], pts: 2.015),
        ])
        let result = try await WaveformExtractor.extract(from: source)
        #expect(result.samples.count == 4)
        #expect(result.samples[0] == 1)
        #expect(abs(result.samples[1] - 0.4) < 0.00001)
        #expect(result.samples[2] == 1)
        #expect(result.samples[3] == 0)
        #expect(result.sourceStartTime == 2)
        #expect(abs(result.decodedDuration - 0.020) < 0.0000001)
        #expect(result.loudestSample(from: 0, to: 1) == 1)
        #expect(result.loudestSample(from: 2.010, to: 2.015) == 1)
        #expect(result.loudestSample(from: 2.015, to: 2.020) == 0)
        #expect(result.loudestSample(from: 2.020, to: 4) == 1)
    }

    @Test("silence floor, loud tone and invalid PCM remain finite")
    func normalization() async throws {
        let result = try await WaveformExtractor.extract(from: PCMSource(buffers: [
            try pcm([0, 0.001, .nan, .infinity, -.infinity], pts: 0),
            try pcm([0, 1, 0, -1, 0], pts: 0.005),
            try pcm([0, 0.01, 0, -0.01, 0], pts: 0.010),
        ]))
        #expect(result.samples.count == 3)
        #expect(result.samples[0] == 1)
        #expect(result.samples[1] == 0)
        #expect(abs(result.samples[2] - 0.8) < 0.00001)
    }

    @Test("empty decoded media is a valid empty envelope")
    func empty() async throws {
        let result = try await WaveformExtractor.extract(from: PCMSource(buffers: []))
        #expect(result.samples.isEmpty)
        #expect(result.decodedDuration == 0)
        #expect(result.sourceStartTime == 0)
    }

    @Test("adaptive compaction retains peaks and source alignment")
    func compaction() async throws {
        let result = try await WaveformExtractor.extract(from: PCMSource(buffers: [
            try pcm([1, 0, 0, 0, 0], pts: 0),
            try pcm([0.1, 0.1, 0.1, 0.1, 0.1], pts: 0.035),
        ]), maxSamples: 3)
        #expect(result.samples.count == 2)
        #expect(result.samplePeriod == 0.020)
        #expect(result.samples[0] == 0)
        #expect(abs(result.samples[1] - 0.4) < 0.00001)
        #expect(abs(result.decodedDuration - 0.040) < 0.0000001)
    }

    @Test("long sparse audio stays capped without duration-based allocation")
    func longDuration() async throws {
        let result = try await WaveformExtractor.extract(from: PCMSource(buffers: [
            try pcm([1], pts: 0), try pcm([0.1], pts: 3600),
        ]), maxSamples: Int.max)
        #expect(result.samples.count == 180_001)
        #expect(result.samplePeriod == 0.020)
        #expect(result.samples.first == 0)
        #expect(abs(try #require(result.samples.last) - 0.4) < 0.00001)
        #expect(abs(result.decodedDuration - 3600.001) < 0.0000001)
    }

    @Test("continuous decoded frames compact past twenty minutes without losing the tail")
    func continuousCap() async throws {
        var values = [Float](repeating: 0, count: 1_200_005)
        values[0] = 1
        values[1_200_004] = 0.1
        let result = try await WaveformExtractor.extract(from: PCMSource(buffers: [try pcm(values, pts: 0)]))
        #expect(result.samples.count == 120_001)
        #expect(result.samplePeriod == 0.010)
        #expect(result.samples.first == 0)
        #expect(abs(try #require(result.samples.last) - 0.4) < 0.00001)
        #expect(abs(result.decodedDuration - 1200.005) < 0.0000001)
    }

    @Test("buffer partitioning produces identical envelope cache bytes")
    func partitioning() async throws {
        let values: [Float] = [0, 0, 1, 0, 0, 0.1, 0, 0, 0, 0, 0.01]
        let whole = try await WaveformExtractor.extract(from: PCMSource(buffers: [try pcm(values, pts: 2)]), maxSamples: 2)
        let split = try await WaveformExtractor.extract(from: PCMSource(buffers: [
            try pcm(Array(values.prefix(3)), pts: 2),
            try pcm(Array(values.dropFirst(3)), pts: 2.003),
        ]), maxSamples: 2)
        #expect(try whole.cacheData() == split.cacheData())
    }

    @Test("a cancelled decode cannot publish a partial envelope")
    func cancellation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WaveformExtractor.extract(from: PCMSource(buffers: []))
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled extraction returned an envelope")
        } catch is CancellationError {
        }
    }

    @Test("cache bytes are deterministic and reject damaged or old envelopes")
    func cacheRoundtrip() async throws {
        let result = try await WaveformExtractor.extract(from: PCMSource(buffers: [try pcm([1], pts: 3)]))
        let first = try result.cacheData()
        #expect(first == (try result.cacheData()))
        #expect(try WaveformEnvelopeV2(cacheData: first) == result)
        #expect(throws: (any Error).self) { try WaveformEnvelopeV2(cacheData: Data(first.dropLast())) }
        #expect(throws: (any Error).self) { try WaveformEnvelopeV2(cacheData: Data([0, 0, 0, 0])) }
        let invalid = Data(#"{"version":1,"samples":[0],"sourceStartTime":0,"decodedDuration":1,"samplePeriod":0.005}"#.utf8)
        #expect(throws: (any Error).self) { try WaveformEnvelopeV2(cacheData: invalid) }
        let mismatched = Data(#"{"version":2,"samples":[0],"sourceStartTime":0,"decodedDuration":1,"samplePeriod":0.005}"#.utf8)
        #expect(throws: (any Error).self) { try WaveformEnvelopeV2(cacheData: mismatched) }
    }

    @Test("disk cache replaces a partial entry and keeps the last valid entry on invalid writes")
    func diskCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-\(UUID().uuidString).waveform2")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0, 1, 2]).write(to: url)
        #expect(MediaVisualCache.loadWaveform(at: url) == nil)
        let envelope = try await WaveformExtractor.extract(from: PCMSource(buffers: [try pcm([1], pts: 1)]))
        MediaVisualCache.saveWaveform(envelope, at: url)
        #expect(MediaVisualCache.loadWaveform(at: url) == envelope)
        let first = try Data(contentsOf: url)
        MediaVisualCache.saveWaveform(envelope, at: url)
        #expect(try Data(contentsOf: url) == first)
        let invalid = WaveformEnvelopeV2(samples: [.nan], sourceStartTime: 0, decodedDuration: 1, samplePeriod: 0.005)
        MediaVisualCache.saveWaveform(invalid, at: url)
        #expect(try Data(contentsOf: url) == first)
    }

    @Test("real WAV decoding derives duration from all decoded frames")
    func wavIntegration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        ))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 487))
            buffer.frameLength = 487
            let channel = try #require(buffer.floatChannelData?[0])
            for index in 0..<487 { channel[index] = index < 240 ? 0 : 1 }
            try file.write(from: buffer)
        }
        let result = try await WaveformExtractor.extract(from: url)
        #expect(result.samples == [1, 0, 0])
        #expect(abs(result.decodedDuration - 0.0101458333333333) < 0.0000001)
        #expect(result.sourceStartTime == 0)
    }
}
