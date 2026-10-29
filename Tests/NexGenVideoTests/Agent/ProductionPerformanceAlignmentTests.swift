import AppKit
import AVFoundation
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Actual performance range and original phrase alignment")
struct ProductionPerformanceAlignmentTests {
    private typealias Alignment = PipelineProductionPerformanceAlignment

    @Test func twoShotsKeepDistinctRangesWithinOneActualPhrase() throws {
        let phrase = segment()
        let first = binding(segment: phrase, videoStart: 1, songStart: 0, duration: 2)
        let second = binding(segment: phrase, shotID: "second", videoStart: 3, songStart: 2, duration: 2)
        try Alignment.validateWindows(first)
        try Alignment.validateWindows(second)
        #expect(first.segment == second.segment)
        #expect(first.videoStart != second.videoStart)
        #expect(first.songStart != second.songStart)
        #expect(throws: (any Error).self) {
            try Alignment.validateWindows(binding(segment: phrase, songStart: 3, duration: 2))
        }
    }

    @Test func immutableNativeObservationCannotAuthorizeAnotherRangePhraseOrTake() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Performance binding \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("actual selected video".utf8).write(to: root.appendingPathComponent("video.mov"))
        try Data("actual original track".utf8).write(to: root.appendingPathComponent("song.wav"))
        try Data("actual viewed preview".utf8).write(to: root.appendingPathComponent("preview.mov"))
        let video = try PlanningWriterIO.reference("video.mov", id: "take", role: "host.production-video", dataRoot: root)
        let song = try PlanningWriterIO.reference("song.wav", id: "song", role: "musicvideo.original-song", dataRoot: root)
        let preview = try PlanningWriterIO.reference("preview.mov", id: "preview", role: "host.performance-alignment-preview", dataRoot: root)
        let original = binding(video: video, song: song, videoStart: 1, songStart: 2, duration: 2, refs: [video, song])
        func receipt(watched: Bool = true, observation: String = "The visible movement matches the original phrase.") -> Alignment.Receipt {
            .init(schema: "native-performance-alignment/v1", binding: original, preview: preview, reviewer: "native-user",
                watchedAndListened: watched, observation: observation, recordedAt: "2026-10-18T12:00:00Z")
        }
        try Alignment.require(receipt(), expected: original, dataRoot: root)
        for changed in [binding(video: video, song: song, videoStart: 0, songStart: 2, duration: 2, refs: [video, song]),
                        binding(video: video, song: song, videoStart: 1, songStart: 1, duration: 2, refs: [video, song]),
                        binding(video: video, song: song, videoStart: 1, songStart: 2, duration: 1, refs: [video, song]),
                        binding(video: video, song: song, segment: segment(id: "new-phrase"), videoStart: 1, songStart: 2,
                            duration: 2, refs: [video, song]),
                        binding(video: .init(id: "other-take", role: video.role, path: video.path, sha256: video.sha256),
                            song: song, videoStart: 1, songStart: 2, duration: 2, refs: [video, song])] {
            #expect(throws: (any Error).self) { try Alignment.require(receipt(), expected: changed, dataRoot: root) }
        }
        #expect(throws: (any Error).self) { try Alignment.require(receipt(watched: false), expected: original, dataRoot: root) }
        #expect(throws: (any Error).self) { try Alignment.require(receipt(observation: "  "), expected: original, dataRoot: root) }
        try Data("changed original song".utf8).write(to: root.appendingPathComponent("song.wav"))
        #expect(throws: (any Error).self) { try Alignment.require(receipt(), expected: original, dataRoot: root) }
    }

    @Test func previewContainsSelectedPictureAndExactOriginalSongInterval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Performance preview \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await FixtureVideo.write(scenes: [.init(rgb: (220, 20, 20), seconds: 2),
            .init(rgb: (20, 220, 20), seconds: 2)], fps: 30, size: 64)
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("video.mov"))
        try writeSong(root.appendingPathComponent("song.wav"))
        let video = try PlanningWriterIO.reference("video.mov", id: "take", role: "host.production-video", dataRoot: root)
        let song = try PlanningWriterIO.reference("song.wav", id: "song", role: "musicvideo.original-song", dataRoot: root)
        let value = binding(video: video, song: song, videoStart: 2, songStart: 2, duration: 1, refs: [video, song])
        let destination = root.appendingPathComponent("preview.mov")
        try await Alignment.makePreview(binding: value, dataRoot: root, destination: destination)
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        #expect(CMTimeCompare(duration, CMTime(value: 1, timescale: 1)) == 0)
        let (image, _) = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(value: 1, timescale: 2))
        let pixel = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        #expect(pixel.greenComponent > pixel.redComponent * 3)
        let decoded = try await decodedAudio(destination)
        try #require(decoded.count >= 28_800)
        let section = Array(decoded[4_800..<28_800])
        let crossings = zip(section, section.dropFirst()).filter { pair in pair.0 < 0 && pair.1 >= 0 }.count
        #expect((325...335).contains(crossings))
        let invalid = binding(video: video, song: song, videoStart: 4, songStart: 2, duration: 1, refs: [video, song])
        await #expect(throws: (any Error).self) {
            try await Alignment.makePreview(binding: invalid, dataRoot: root, destination: root.appendingPathComponent("outside.mov"))
        }
    }

    @Test @MainActor func agentFileToolsCannotForgeAnAlignmentObservation() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Performance authority \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "Performance authority", mode: .generic)
        _ = try ProjectLocalFile.ensureDirectory("import", dataRoot: root)
        let source = root.appendingPathComponent("import/candidate.json")
        try Data("forged native observation".utf8).write(to: source)
        let harness = ToolHarness()
        for path in ["renders/performance-alignment/shot/current.v1.json", "pipeline/renders/performance-alignment/shot/current.v1.json"] {
            let copied = await harness.runRaw("copy_project_file", args: ["project_dir": root.path,
                "from": "import/candidate.json", "to": path])
            #expect(copied.isError)
            let imported = await harness.runRaw("import_media", args: ["source": ["path": source.path], "destination": path])
            #expect(imported.isError)
            let written = await harness.runRaw("write_file", args: ["path": root.appendingPathComponent(path).path, "content": "forged"])
            #expect(written.isError)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
    }

    private func segment(id: String = "full-phrase") -> MaterializedMusicPerformanceSegmentV1 {
        .init(draft: .init(id: id, shotIDs: ["first", "second"], sourceStartSample: 0, sourceEndSample: 192_000,
            sampleRate: 48_000, timelineStartSeconds: 0, purpose: .timingOnly, performerIDs: [], audibleVoiceIDs: [],
            mouthOwnership: [], routeInputRoleID: CoreReferenceSemanticJobIDV1.audioTiming,
            phraseBoundaryEvidence: "Actual four-second phrase."), sourceTrackPath: "song.wav", sourceTrackSHA256: String(repeating: "a", count: 64),
            segmentPath: "phrase.wav", segmentSHA256: String(repeating: "b", count: 64), segmentByteCount: 384_044, exportedSampleCount: 192_000)
    }

    private func binding(video: CanonicalArtifactReferenceV1? = nil, song: CanonicalArtifactReferenceV1? = nil,
        segment: MaterializedMusicPerformanceSegmentV1? = nil, shotID: String = "first", videoStart: Int64 = 0,
        songStart: Int64 = 0, duration: Int64 = 2, refs: [CanonicalArtifactReferenceV1] = []) -> Alignment.Binding {
        .init(projectKey: "actual-project", shotID: shotID, segment: segment ?? self.segment(),
            video: video ?? .init(id: "take", role: "host.production-video", path: "video.mov", sha256: String(repeating: "a", count: 64)),
            videoStart: .init(value: videoStart, timescale: 1),
            originalSong: song ?? .init(id: "song", role: "musicvideo.original-song", path: "song.wav", sha256: String(repeating: "b", count: 64)),
            songStart: .init(value: songStart, timescale: 1), duration: .init(value: duration, timescale: 1),
            frameDuration: .init(value: 1, timescale: 30), references: refs)
    }

    private func writeSong(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            let frequency = index < 96_000 ? 220.0 : 660.0
            samples[index] = Float(sin(Double(index) * frequency * 2 * .pi / 48_000) * 0.25)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func decodedAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw CocoaError(.fileReadCorruptFile) }
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { storage in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: storage.count, destination: storage.baseAddress!)
            }
            guard status == noErr else { throw CocoaError(.fileReadCorruptFile) }
            bytes.withUnsafeBytes { storage in
                for offset in stride(from: 0, to: storage.count, by: MemoryLayout<Float>.size) {
                    result.append(storage.loadUnaligned(fromByteOffset: offset, as: Float.self))
                }
            }
        }
        #expect(reader.status == .completed)
        #expect(result.count >= 28_800)
        return result
    }
}
