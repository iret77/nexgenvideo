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
        }
    }

    @Test func changedAnalysisBytesCannotRebindApprovedMusicalSections() throws {
        try withAnalysis { root, reference, timing in
            try Data("{}".utf8).write(to: root.appendingPathComponent(reference.path))
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
