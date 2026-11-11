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

    @Test func shownStoryboardIsBoundToTheOpenApprovalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try StoryboardStore.save(storyboard("Approved", version: 1), to: root)
        let requested = try StoryboardReviewSnapshot.read(root: root)
        #expect(requested.sha256 == FileDigest.sha256(of: requested.bytes))
        let fingerprint = GateArtifactFingerprint(path: PipelineLayout.storyboardCurrentFile,
            sha256: requested.sha256, lineageSHA256: nil, phase: "storyboard")
        let approval = GateApproval(phase: "storyboard", dataRoot: root, artifactFingerprint: fingerprint)

        #expect(StoryboardReviewBinding.resolve(approval: approval, dataRoot: root, shown: requested) == .current)
        #expect(StoryboardReviewBinding.resolve(approval: nil, dataRoot: root, shown: requested) == .unrelated)
        #expect(StoryboardReviewBinding.resolve(approval: GateApproval(phase: "bible", dataRoot: root,
            artifactFingerprint: fingerprint), dataRoot: root, shown: requested) == .unrelated)
        #expect(StoryboardReviewBinding.resolve(approval: approval,
            dataRoot: root.appendingPathComponent("other"), shown: requested) == .unrelated)
        #expect(StoryboardReviewBinding.resolve(approval: GateApproval(phase: "storyboard", dataRoot: root,
            action: .rewind(gatesSHA256: "gates", phases: ["storyboard"])), dataRoot: root, shown: requested) == .unrelated)
        #expect(StoryboardReviewBinding.resolve(approval: GateApproval(phase: "storyboard", dataRoot: root),
            dataRoot: root, shown: requested) == .changed)

        _ = try StoryboardStore.save(storyboard("Revised", version: 2), to: root)
        let revised = try StoryboardReviewSnapshot.read(root: root)
        #expect(StoryboardReviewBinding.resolve(approval: approval, dataRoot: root, shown: revised) == .changed)
        #expect(StoryboardReviewBinding.resolve(approval: approval, dataRoot: root, shown: requested) == .changed)

        let current = root.appendingPathComponent(PipelineLayout.storyboardCurrentFile)
        try requested.bytes.write(to: current)
        #expect(StoryboardReviewBinding.resolve(approval: approval, dataRoot: root, shown: requested) == .current)

        let lineage = PipelineLayout.url(PipelineLayout.lineageFile, in: root)
        try FileManager.default.createDirectory(at: lineage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("changed lineage".utf8).write(to: lineage)
        #expect(StoryboardReviewBinding.resolve(approval: approval, dataRoot: root, shown: requested) == .changed)
        try FileManager.default.removeItem(at: lineage)

        try FileManager.default.removeItem(at: current)
        #expect(StoryboardReviewBinding.resolve(approval: approval, dataRoot: root, shown: nil) == .changed)
    }

    @Test func cockpitReadUsesTheSharedStatesAndBindsInTheSameRead() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let notProject = await CockpitDataService.storyboard(projectDir: tmp, approval: nil)
        #expect(notProject.result == .failure(.notInitialized))
        #expect(notProject.binding == .unrelated)

        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "storyboard-read")
        let empty = await CockpitDataService.storyboard(projectDir: home, approval: nil)
        #expect(empty.result == .success(nil))

        _ = try StoryboardStore.save(storyboard("Approved", version: 1), to: dataRoot)
        let requested = try StoryboardReviewSnapshot.read(root: dataRoot)
        let approval = GateApproval(phase: "storyboard", dataRoot: dataRoot,
            artifactFingerprint: GateArtifactFingerprint(path: PipelineLayout.storyboardCurrentFile,
                sha256: requested.sha256, lineageSHA256: nil, phase: "storyboard"))
        let loaded = await CockpitDataService.storyboard(projectDir: home, approval: approval)
        #expect(loaded.result == .success(requested))
        #expect(loaded.binding == .current)

        _ = try StoryboardStore.save(storyboard("Revised", version: 2), to: dataRoot)
        let revised = try StoryboardReviewSnapshot.read(root: dataRoot)
        let changed = await CockpitDataService.storyboard(projectDir: home, approval: approval)
        #expect(changed.result == .success(revised))
        #expect(changed.binding == .changed)

        let current = dataRoot.appendingPathComponent(PipelineLayout.storyboardCurrentFile)
        try Data("not a storyboard".utf8).write(to: current)
        let unreadable = await CockpitDataService.storyboard(projectDir: home, approval: approval)
        #expect(unreadable.result == .failure(.decode("Couldn't read the storyboard.")))
        #expect(unreadable.binding == .changed)

        try FileManager.default.removeItem(at: current)
        let missing = await CockpitDataService.storyboard(projectDir: home, approval: approval)
        #expect(missing.result == .success(nil))
        #expect(missing.binding == .changed)
    }

    private func storyboard(_ subject: String, version: Int) throws -> Storyboard {
        try Storyboard(
            meta: StoryboardMeta(project: "Review", version: version, generated: "2026-09-05"),
            sections: [Section(id: "verse1", steps: [Step(id: "verse1.01", function: .story,
                                                         subject: subject, camera: "Wide")])]
        )
    }
}
