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
        let image = home.appendingPathComponent("image.png")
        try Data("fixture image".utf8).write(to: image)
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "image", name: "Image", type: .image, source: .project(relativePath: "image.png"), duration: 1)]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { home })
        var timeline = Timeline(tracks: [Track(type: .video, clips: [Clip(mediaRef: "image", mediaType: .image, startFrame: 0, durationFrames: 30)])])
        let snapshot = try #require(try await TimelineStyleReview.capture(timeline: timeline, resolver: resolver))
        #expect(throws: (any Error).self) { try TimelineStyleReview.requireCurrent(snapshot) }
        let findings = snapshot.style.criteria.map {
            TimelineStyleFinding(criterionID: $0.auditKey, verdict: .acceptedDeviation, observation: "Reviewed the full one-second cut; accepted its limited motion and silence.")
        }
        #expect(throws: (any Error).self) { try TimelineStyleReview.validate(Array(findings.dropLast()), style: snapshot.style) }
        let review = TimelineStyleReview(schema: "timeline-style-review/v1", fingerprint: snapshot.fingerprint, findings: findings, reviewedAt: "fixture")
        let receipt = root.appendingPathComponent(TimelineStyleReview.relativePath)
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(review).write(to: receipt)
        try TimelineStyleReview.requireCurrent(snapshot)
        try await TimelineStyleReview.revalidate(snapshot, timeline: timeline, resolver: resolver)
        timeline.tracks[0].clips[0].durationFrames = 60
        await #expect(throws: (any Error).self) { try await TimelineStyleReview.revalidate(snapshot, timeline: timeline, resolver: resolver) }
        timeline.tracks[0].clips[0].durationFrames = 30
        try Data("changed source image".utf8).write(to: image)
        await #expect(throws: (any Error).self) { try await TimelineStyleReview.revalidate(snapshot, timeline: timeline, resolver: resolver) }
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
