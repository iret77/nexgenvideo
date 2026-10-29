import AVFoundation
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Actual exported performance phrase used as known audio")
struct ProductionKnownPerformanceAudioTests {
    @Test func fullNativeSamplePhraseReachesConditioningWithoutShotReslicing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Known performance \(UUID().uuidString)")
        let sourcePath = "audio/song.wav"
        let outputPath = "execution/planning/v1/performance-audio/phrase/segment.wav"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(outputPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = root.appendingPathComponent(sourcePath)
        try writeSong(to: song)
        let track = try PlanningWriterIO.reference(sourcePath, id: "original-song", role: "musicvideo.original-song", dataRoot: root)
        let draft = MusicPerformanceSegmentDraftV1(id: "four-second-phrase", shotIDs: ["two-second-shot"],
            sourceStartSample: 48_000, sourceEndSample: 240_000, sampleRate: 48_000, timelineStartSeconds: 0,
            purpose: .timingOnly, performerIDs: [], audibleVoiceIDs: [], mouthOwnership: [],
            routeInputRoleID: CoreReferenceSemanticJobIDV1.audioTiming, phraseBoundaryEvidence: "Actual sample interval 1…5 seconds.")
        let exported = try PipelineMusicvideoProductionWriterV2.export(audioURL: song, draft: draft)
        try exported.bytes.write(to: root.appendingPathComponent(outputPath))
        #expect(exported.samples == 192_000)
        #expect(exported.sourceFrames == 288_000)
        let actual = try AVAudioFile(forReading: root.appendingPathComponent(outputPath), commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(actual.length == 192_000)
        let first = try #require(AVAudioPCMBuffer(pcmFormat: actual.processingFormat, frameCapacity: 1))
        try actual.read(into: first, frameCount: 1)
        #expect(first.int16ChannelData?[0][0] == Int16(48_000 % 32_000))
        let output = try PlanningWriterIO.reference(outputPath, id: "performance-phrase", role: "musicvideo.performance-audio", dataRoot: root)
        let segment = MaterializedMusicPerformanceSegmentV1(draft: draft, sourceTrackPath: track.path, sourceTrackSHA256: track.sha256,
            segmentPath: output.path, segmentSHA256: output.sha256, segmentByteCount: Int64(exported.bytes.count), exportedSampleCount: exported.samples)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        func receipt(_ recorded: String) -> MusicPerformanceAudioReceiptV2 {
            .init(projectID: "performance", revision: 1, segmentID: draft.id, source: track, output: output,
                startSample: draft.sourceStartSample, endSample: draft.sourceEndSample, sourceFrameCount: exported.sourceFrames,
                exportedSampleCount: exported.samples, sampleRate: draft.sampleRate, channels: exported.channels,
                byteCount: Int64(exported.bytes.count), recordedAt: recorded)
        }
        func input(_ recorded: String) throws -> PipelineProductionKnownAudio.Input {
            try PipelineProductionKnownAudio.performanceInput(segment: segment, receipt: receipt(recorded), track: track,
                shotID: "two-second-shot", modeID: "actual-provider-audio-mode", references: [track, output], dataRoot: root)
        }
        let known = try input(timestamp)
        #expect(known.asset.durationSeconds == 4)
        #expect(known.demand.durationSeconds == 4)
        #expect(known.asset.path == output.path)
        #expect(known.asset.sha256 == output.sha256)
        #expect(known.asset.provenance.sourceAssetID == track.id)
        #expect(known.asset.provenance.recordedAt == timestamp)
        #expect(known.preparedMedia == nil)
        #expect(known.references == [track, output])
        #expect(throws: (any Error).self) { try input("") }
        try (exported.bytes + Data("changed output".utf8)).write(to: root.appendingPathComponent(outputPath))
        #expect(throws: (any Error).self) { try input(timestamp) }
    }

    private func writeSong(to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 288_000))
        buffer.frameLength = 288_000
        let samples = try #require(buffer.int16ChannelData?[0])
        for index in 0..<288_000 { samples[index] = Int16(index % 32_000) }
        try file.write(from: buffer)
    }
}
