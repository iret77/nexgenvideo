import Foundation
import Testing
@testable import NexGenEngine

struct MusicvideoProductionExtensionV2Tests {
    @Test func nativeSectionsBindAllOverlappingShotsWithoutInventingAnotherShotOrder() throws {
        try withAnalysis { root, reference, timing in
            let sections = try MusicvideoProductionExtensionStoreV2.sections(analysis: reference, timing: timing, dataRoot: root)
            #expect(sections.map(\.id) == ["section-3", "section-7"])
            #expect(sections[0].shotIDs == ["shot-a", "shot-b"])
            #expect(sections[1].shotIDs == ["shot-b", "shot-c"])
            let boundary = StoryboardTimingV1(header: timing.header, timebase: timing.timebase, mode: timing.mode,
                rangeDurationTicks: timing.rangeDurationTicks, audio: timing.audio, shots: [
                    .init(id: "shot-c", primaryStepID: "c", startTicks: 48, durationTicks: 48, framing: timing.shots[0].framing, moments: []),
                    .init(id: "shot-b", primaryStepID: "b", startTicks: 24, durationTicks: 24, framing: timing.shots[0].framing, moments: []),
                    timing.shots[0],
                ])
            let reordered = try MusicvideoProductionExtensionStoreV2.sections(analysis: reference, timing: boundary, dataRoot: root)
            #expect(reordered[0].shotIDs == ["shot-b", "shot-a"])
            #expect(reordered[1].shotIDs == ["shot-c"])
        }
    }

    @Test func changedAnalysisBytesCannotRebindApprovedMusicalSections() throws {
        try withAnalysis { root, reference, timing in
            let before = try MusicvideoProductionExtensionStoreV2.sections(analysis: reference, timing: timing, dataRoot: root)
            let bytes = try Data(contentsOf: root.appendingPathComponent(reference.path))
            let changed = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"index\":3", with: "\"index\":5").utf8)
            try #require(changed != bytes)
            try changed.write(to: root.appendingPathComponent(reference.path))
            let current = CanonicalArtifactReferenceV1(id: reference.id, role: reference.role,
                path: reference.path, sha256: FileDigest.sha256(of: changed))
            let after = try MusicvideoProductionExtensionStoreV2.sections(analysis: current, timing: timing, dataRoot: root)
            #expect(before.map(\.id) == ["section-3", "section-7"])
            #expect(after.map(\.id) == ["section-5", "section-7"])
            #expect(throws: (any Error).self) {
                try MusicvideoProductionExtensionStoreV2.sections(analysis: reference, timing: timing, dataRoot: root)
            }
        }
    }

    private func withAnalysis(_ body: (URL, CanonicalArtifactReferenceV1, StoryboardTimingV1) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let bytes = Data(#"{"schema":"analysis/v3","project":"song","song_path":"audio/song.wav","sample_rate":48000,"duration_s":4,"sections":[{"index":3,"start":0,"end":2},{"index":7,"start":2,"end":4}]}"#.utf8)
        let reference = CanonicalArtifactReferenceV1(id: "analysis", role: "musicvideo.analysis", path: "analysis.json", sha256: FileDigest.sha256(of: bytes))
        try bytes.write(to: root.appendingPathComponent(reference.path))
        let framing = StoryboardTimingV1.FramingIntent(scale: "wide", composition: "centred", cameraView: "eye level")
        let timing = StoryboardTimingV1(header: .init(projectID: "song", revision: 1, origin: .userRevision, inputs: []),
            timebase: .init(ticksPerSecond: 24, fpsNumerator: 24), mode: .generic, rangeDurationTicks: 96,
            audio: .init(source: .init(id: "track", role: "audio", path: "audio/song.wav", sha256: String(repeating: "0", count: 64)), durationTicks: 96),
            shots: [.init(id: "shot-a", primaryStepID: "a", startTicks: 0, durationTicks: 24, framing: framing, moments: []),
                    .init(id: "shot-b", primaryStepID: "b", startTicks: 24, durationTicks: 48, framing: framing, moments: []),
                    .init(id: "shot-c", primaryStepID: "c", startTicks: 72, durationTicks: 24, framing: framing, moments: [])])
        try body(root, reference, timing)
    }
}
