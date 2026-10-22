import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Review input validation survives asynchronous preparation")
struct PipelineRenderReviewSnapshotCheckTests {
    @Test func changedSourceCannotPassTheFinalCheckEvenWithItsOriginalModificationDate() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly(presentation: .editorSession)
        defer { context.document.close() }
        let snapshot = try await PipelineRenderReviewWriter.capture(editor: context.editor)
        let root = context.dataRoot
        let work = Task.detached { try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root) }
        let check = try await work.value
        try check.requireCurrent()
        let source = try #require(snapshot.shots.first?.sourceInput)
        let url = try ProjectLocalFile.resolve(source.path, dataRoot: root)
        let original = try Data(contentsOf: url)
        let modifiedAt = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        defer { try? original.write(to: url, options: .atomic) }
        var changed = original
        let index = try #require(changed.indices.last)
        changed[index] ^= 1
        try changed.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        #expect(changed.count == original.count)
        #expect(throws: (any Error).self) { try check.requireCurrent() }
        #expect(throws: (any Error).self) { try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root) }
    }

    @Test func projectIdentityAndCancellationInvalidatePreparedReviewInputs() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly(presentation: .editorSession)
        defer { context.document.close() }
        let snapshot = try await PipelineRenderReviewWriter.capture(editor: context.editor)
        let root = context.dataRoot
        let check = try await Task.detached { try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root) }.value
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try check.requireCurrent(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await cancelled.value)
        let identity = FrameInventory.projectHome(of: root).appendingPathComponent(ProjectPluginSettings.filename)
        let before = try Data(contentsOf: identity)
        defer { try? before.write(to: identity, options: .atomic) }
        var json = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
        json["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: identity, options: .atomic)
        #expect(throws: (any Error).self) { try check.requireCurrent() }
    }
    @Test func changesOutsideSnapshotReferencesInvalidateTheWholePipelineTransaction() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly(presentation: .editorSession)
        defer { context.document.close() }
        let snapshot = try await PipelineRenderReviewWriter.capture(editor: context.editor)
        let root = context.dataRoot
        #expect(!snapshot.references.contains { $0.path == RenderReviewV1.currentPath })
        let check = try await Task.detached { try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root) }.value
        let reviewURL = try ProjectLocalFile.resolve(RenderReviewV1.currentPath, dataRoot: root)
        let before = try Data(contentsOf: reviewURL)
        defer { try? before.write(to: reviewURL, options: .atomic) }
        try (before + Data(" ".utf8)).write(to: reviewURL, options: .atomic)
        #expect(throws: (any Error).self) { try check.requireCurrent() }
    }

    @Test func creationOfAnAbsentDirectionArtifactInvalidatesPreparedReview() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly(presentation: .editorSession)
        defer { context.document.close() }
        let snapshot = try await PipelineRenderReviewWriter.capture(editor: context.editor)
        let path = try #require(snapshot.absentPaths.first)
        let root = context.dataRoot
        let check = try await Task.detached { try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root) }.value
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("changed direction".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try check.requireCurrent() }
        #expect(throws: (any Error).self) { try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root) }
    }

}
