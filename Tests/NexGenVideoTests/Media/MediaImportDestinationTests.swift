import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Deferred media imports keep their original destination")
struct MediaImportDestinationTests {
    @Test func queuedImportCannotResurrectDeletedDestination() async throws {
        let (editor, directory, source) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: directory) }
        let folder = editor.createFolder(name: "Incoming")
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        editor.mediaImportTail = Task { @MainActor in
            for await _ in gate { break }
            return .init(assetCount: 0, folderCount: 0)
        }
        let sequence = editor.mediaImportSequence
        let pending = Task { @MainActor in await editor.importFinderItems([source], into: folder) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while editor.mediaImportSequence == sequence, ContinuousClock.now < deadline { await Task.yield() }
        try #require(editor.mediaImportSequence == sequence + 1)
        editor.deleteFolders(ids: [folder])
        release.finish()
        let result = await pending.value
        #expect(result.failure == MediaImportError.destinationChanged.localizedDescription)
        #expect(editor.mediaAssets.isEmpty && editor.mediaManifest.entries.isEmpty && editor.folders.isEmpty)
        let media = try #require(editor.workingRoot).appendingPathComponent(Project.mediaDirectoryName)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: media.path).isEmpty) ?? true)
    }

    @Test func destinationDeletedDuringCopyRollsBackExactCopiedFile() async throws {
        let (editor, directory, source) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: directory) }
        let folder = editor.createFolder(name: "Incoming")
        let result = await DurableMediaStore.$copyChunkObserver.withValue({ _ in
            await MainActor.run { editor.deleteFolders(ids: [folder]) }
        }) {
            await editor.importFinderItems([source], into: folder)
        }
        #expect(result.failure == MediaImportError.destinationChanged.localizedDescription)
        #expect(editor.mediaAssets.isEmpty && editor.mediaManifest.entries.isEmpty && editor.folders.isEmpty)
        let media = try #require(editor.workingRoot).appendingPathComponent(Project.mediaDirectoryName)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: media.path).isEmpty) ?? true)
        #expect(try Data(contentsOf: source) == Data("original import bytes".utf8))
    }

    @Test func delayedDropSnapshotRejectsDifferentWorkingCopy() throws {
        let (editor, directory, _) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: directory) }
        let destination = MediaLibraryDestination(editor, folderID: nil)
        try destination.validate(editor)
        let other = directory.appendingPathComponent("Other.ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: other)
        editor.projectURL = other
        #expect(throws: MediaImportError.projectChanged) { try destination.validate(editor) }
    }

    @Test func movingToMissingFolderPreservesAssetsAndFolderTree() {
        let editor = EditorViewModel()
        let folder = editor.createFolder(name: "Existing")
        let asset = MediaAsset(id: "image", url: URL(fileURLWithPath: "/image.png"), type: .image, name: "Image")
        editor.mediaAssets = [asset]
        editor.mediaManifest.entries = [asset.toManifestEntry(projectURL: nil)]
        let before = editor.mediaManifest
        editor.moveAssetsToFolder(assetIds: [asset.id], folderId: "removed")
        editor.moveFoldersToFolder(folderIds: [folder], parentFolderId: "removed")
        #expect(editor.mediaManifest == before && asset.folderId == nil)
    }

    private func fixture() throws -> (EditorViewModel, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImportDestination-" + UUID().uuidString)
        let package = directory.appendingPathComponent("Project.ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: package)
        let source = directory.appendingPathComponent("Original.mp4")
        try Data("original import bytes".utf8).write(to: source)
        let editor = EditorViewModel(); editor.projectURL = package
        return (editor, directory, source)
    }
}
