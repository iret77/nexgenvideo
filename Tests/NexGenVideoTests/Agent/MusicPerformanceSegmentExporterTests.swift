import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@Suite("Music performance segment export")
struct MusicPerformanceSegmentExporterTests {
    @Test("different source sample ranges produce distinct exact segment artifacts")
    func exactSourceRanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-segments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.wav")
        try fixtureWave().write(to: source)

        let first = try MusicPerformanceSegmentExporter.export(
            sourceURL: source,
            draft: segment(id: "first", start: 0, end: 24_000),
            dataRoot: root
        )
        let second = try MusicPerformanceSegmentExporter.export(
            sourceURL: source,
            draft: segment(id: "second", start: 24_000, end: 48_000),
            dataRoot: root
        )

        #expect(first.sampleCount == 24_000)
        #expect(second.sampleCount == 24_000)
        #expect(first.sha256 != second.sha256)
        #expect(first.path != second.path)
        #expect(try FileDigest.sha256(of: root.appendingPathComponent(first.path)) == first.sha256)
        #expect(try FileDigest.sha256(of: root.appendingPathComponent(second.path)) == second.sha256)
    }

    private func segment(id: String, start: Int64, end: Int64) -> MusicPerformanceSegmentDraftV1 {
        MusicPerformanceSegmentDraftV1(
            id: id,
            shotIDs: ["s001"],
            sourceStartSample: start,
            sourceEndSample: end,
            sampleRate: 48_000,
            timelineStartSeconds: Double(start) / 48_000,
            purpose: .timingOnly,
            performerIDs: [],
            audibleVoiceIDs: [],
            mouthOwnership: [],
            routeInputRoleID: CoreReferenceInputSlotIDV1.audioTiming,
            phraseBoundaryEvidence: "Fixture half-second boundary."
        )
    }

    private func fixtureWave() -> Data {
        let sampleRate = 48_000
        let channels = 2
        let bytesPerSample = 2
        var pcm = Data()
        for frame in 0..<sampleRate {
            let sample: Int16 = frame < sampleRate / 2 ? 4_000 : -4_000
            for _ in 0..<channels { append(sample, to: &pcm) }
        }
        var data = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(channels), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * channels * bytesPerSample), to: &data)
        append(UInt16(channels * bytesPerSample), to: &data)
        append(UInt16(bytesPerSample * 8), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
