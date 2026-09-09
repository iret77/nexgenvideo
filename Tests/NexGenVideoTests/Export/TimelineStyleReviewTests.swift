import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Timeline style review currency")
@MainActor
struct TimelineStyleReviewTests {
    @Test("a complete human review expires when the cut or source bytes change")
    func exactCut() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "review")
        try Data("brief".utf8).write(to: root.appendingPathComponent(PipelineLayout.briefFile))
        let design = try ProductionDesign(project: "review", generated: "fixture", generator: "test",
            visualMedium: .liveActionRealistic, colorScript: ["opening": "amber"])
        try ProductionStyleStoreV1.write(design: design, selection: .init(directorID: "director-wes-anderson-symmetry-deadpan"), clearStyle: false, dataRoot: root)
        let store = YAMLArtifactStore(dataRoot: root)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        gates.set("production_design", Gate(approved: true))
        try store.save(gates, to: PipelineLayout.gatesFile)
        let image = home.appendingPathComponent("clip.mov")
        try Data("fixture video".utf8).write(to: image)
        let audio = home.appendingPathComponent("song.wav")
        try Data("fixture audio".utf8).write(to: audio)
        var manifest = MediaManifest()
        manifest.entries = [
            .init(id: "clip", name: "Clip", type: .video,
                  source: .project(relativePath: "clip.mov"), duration: 1),
            .init(id: "song", name: "Song", type: .audio,
                  source: .project(relativePath: "song.wav"), duration: 1),
        ]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { home })
        var timeline = Timeline(tracks: [
            Track(type: .video, clips: [
                Clip(mediaRef: "clip", mediaType: .video,
                     sourceClipType: .video, startFrame: 0, durationFrames: 30),
            ]),
            Track(type: .audio, clips: [
                Clip(mediaRef: "song", mediaType: .audio,
                     sourceClipType: .audio, startFrame: 0, durationFrames: 30),
            ]),
        ])
        let snapshot = try #require(try await TimelineStyleReview.capture(timeline: timeline, resolver: resolver))
        #expect(throws: (any Error).self) { try TimelineStyleReview.requireCurrent(snapshot) }
        let findings = snapshot.style.criteria.map {
            TimelineStyleReview.makeFinding(
                criterion: $0,
                result: .fail,
                acceptedDeviation: true,
                observation: "Reviewed the full one-second cut; accepted its limited motion and silence.",
                snapshot: snapshot
            )
        }
        #expect(throws: (any Error).self) {
            try TimelineStyleReview.validate(Array(findings.dropLast()), snapshot: snapshot)
        }
        let review = TimelineStyleReview(schema: "timeline-style-review/v2", fingerprint: snapshot.fingerprint, findings: findings, reviewedAt: "fixture")
        let receipt = root.appendingPathComponent(TimelineStyleReview.relativePath)
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(review).write(to: receipt)
        try TimelineStyleReview.requireCurrent(snapshot)
        try await TimelineStyleReview.revalidate(snapshot, timeline: timeline, resolver: resolver)
        timeline.tracks[0].clips[0].durationFrames = 60
        await #expect(throws: (any Error).self) { try await TimelineStyleReview.revalidate(snapshot, timeline: timeline, resolver: resolver) }
        timeline.tracks[0].clips[0].durationFrames = 30
        try Data("changed source video".utf8).write(to: image)
        await #expect(throws: (any Error).self) { try await TimelineStyleReview.revalidate(snapshot, timeline: timeline, resolver: resolver) }
    }

    @Test("a still cannot pass a motion or timing criterion")
    func stillLeavesMotionUnobserved() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "still-review")
        try Data("brief".utf8).write(to: root.appendingPathComponent(PipelineLayout.briefFile))
        let design = try ProductionDesign(project: "still-review", generated: "fixture", generator: "test",
            visualMedium: .liveActionRealistic, colorScript: ["opening": "amber"])
        try ProductionStyleStoreV1.write(design: design, selection: .init(
            directorID: "director-wes-anderson-symmetry-deadpan"
        ), clearStyle: false, dataRoot: root)
        let store = YAMLArtifactStore(dataRoot: root)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        gates.set("production_design", Gate(approved: true))
        try store.save(gates, to: PipelineLayout.gatesFile)
        let still = home.appendingPathComponent("still.png")
        try Data("fixture still".utf8).write(to: still)
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "still", name: "Still", type: .image,
            source: .project(relativePath: "still.png"), duration: 1)]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { home })
        let timeline = Timeline(tracks: [Track(type: .video, clips: [
            Clip(mediaRef: "still", mediaType: .image, sourceClipType: .image,
                 startFrame: 0, durationFrames: 30),
        ])])
        let snapshot = try #require(try await TimelineStyleReview.capture(
            timeline: timeline,
            resolver: resolver
        ))
        let timing = try #require(snapshot.style.criteria.first {
            $0.source.dimension == .timing
        })
        #expect(snapshot.targetsByCriterion[timing.auditKey]?.isEmpty == true)
        let falsePass = TimelineStyleReview.makeFinding(
            criterion: timing,
            result: .pass,
            acceptedDeviation: false,
            observation: "Only a still image was available.",
            snapshot: snapshot
        )
        let remaining = snapshot.style.criteria.filter {
            $0.auditKey != timing.auditKey
        }.map {
            TimelineStyleReview.makeFinding(
                criterion: $0,
                result: snapshot.targetsByCriterion[$0.auditKey]?.isEmpty == true
                    ? .notObserved : .pass,
                acceptedDeviation: false,
                observation: "Reviewed against the matching evidence.",
                snapshot: snapshot
            )
        }
        #expect(throws: (any Error).self) {
            try TimelineStyleReview.validate([falsePass] + remaining, snapshot: snapshot)
        }
    }

    @Test("projects without a selected style retain their existing export path")
    func noStyle() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try ProjectScaffold.initProject(home: home, name: "legacy")
        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { home })
        #expect(try await TimelineStyleReview.capture(timeline: Timeline(), resolver: resolver) == nil)
    }
}
