import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Storyboard review source")
struct StoryboardReviewTests {
    @Test func currentVersionIsReReadAfterRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try storyboard("First", version: 1)
        _ = try StoryboardStore.save(first, to: root)
        let before = try StoryboardReviewSnapshot.read(root: root)
        #expect(before.storyboard == first)
        let second = try storyboard("Revised", version: 2)
        _ = try StoryboardStore.save(second, to: root)
        let after = try StoryboardReviewSnapshot.read(root: root)
        #expect(after.storyboard == second)
        #expect(after.bytes != before.bytes)
    }

    @Test func missingOrUnreadableArtifactNeverProducesAReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try StoryboardReviewSnapshot.read(root: root) }
        let file = root.appendingPathComponent(PipelineLayout.storyboardCurrentFile)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a storyboard".utf8).write(to: file)
        #expect(throws: (any Error).self) { try StoryboardReviewSnapshot.read(root: root) }
    }

    @Test func symlinkCannotOpenAnArtifactOutsideTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        _ = try StoryboardStore.save(storyboard("Outside", version: 1), to: outside)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("storyboard"),
            withDestinationURL: outside.appendingPathComponent("storyboard")
        )
        #expect(throws: (any Error).self) { try StoryboardReviewSnapshot.read(root: project) }
    }

    private func storyboard(_ subject: String, version: Int) throws -> Storyboard {
        try Storyboard(
            meta: StoryboardMeta(project: "Review", version: version, generated: "2026-09-05"),
            sections: [Section(id: "verse1", steps: [Step(id: "verse1.01", function: .story,
                                                         subject: subject, camera: "Wide")])]
        )
    }
}
