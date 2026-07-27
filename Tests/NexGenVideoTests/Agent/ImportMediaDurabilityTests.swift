import Foundation
import Testing
@testable import NexGenVideo

@Suite("ToolExecutor — durable media import")
@MainActor
struct ImportMediaDurabilityTests {
    @Test func completedImportMarksProjectChanged() throws {
        let editor = EditorViewModel()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-change-count-\(UUID().uuidString).mp4")
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-change-count-\(UUID().uuidString).ngv", isDirectory: true)
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: projectURL)
        }
        try Data("source".utf8).write(to: source)
        try Fixtures.prepareProjectPackage(at: projectURL)
        editor.projectURL = projectURL
        var changeCount = 0
        editor.onPipelineChanged = { changeCount += 1 }

        _ = try editor.addMediaAssetThrowing(from: source)

        #expect(changeCount == 1)
    }

    @Test func pathImportRequiresSavedProject() async throws {
        let harness = ToolHarness()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-unsaved-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("source".utf8).write(to: source)

        let result = await harness.runRaw("import_media", args: [
            "source": ["path": source.path]
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Save the project before importing media"))
        #expect(harness.editor.mediaAssets.isEmpty)
        #expect(harness.editor.mediaManifest.entries.isEmpty)
    }

    @Test func pathCopyFailureReturnsReasonWithoutRegisteringAsset() async throws {
        let harness = ToolHarness()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-copy-failure-\(UUID().uuidString).mp4")
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-copy-failure-\(UUID().uuidString).ngv", isDirectory: true)
        defer {
            harness.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: projectURL)
        }
        try Data("source".utf8).write(to: source)
        try Fixtures.prepareProjectPackage(at: projectURL)
        try Data("blocked".utf8).write(
            to: projectURL.appendingPathComponent(Project.mediaDirectoryName)
        )
        harness.editor.projectURL = projectURL

        let result = await harness.runRaw("import_media", args: [
            "source": ["path": source.path]
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("project media folder couldn't be prepared"))
        #expect(harness.editor.mediaAssets.isEmpty)
        #expect(harness.editor.mediaManifest.entries.isEmpty)
    }
}
