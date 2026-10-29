import AppKit
import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Deferred media imports keep their original destination")
struct MediaImportDestinationTests {
    @Test func refusedCopyCommitCannotDeleteTheFollowingImportsSource() async throws {
        let (editor, directory, source) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: directory) }
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        editor.mediaImportTail = Task { @MainActor in
            for await _ in gate { break }
            return .init(assetCount: 0, folderCount: 0)
        }
        let first = Task { @MainActor in
            do {
                _ = try await editor.durableProjectMediaCopies(for: [source]) { _ in throw MediaImportError.projectChanged }
                return false
            } catch { return (error as? MediaImportError) == .projectChanged }
        }
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while editor.mediaImportSequence < 1 && ContinuousClock.now < firstDeadline { await Task.yield() }
        #expect(editor.mediaImportSequence == 1)
        let second = Task { @MainActor in await editor.importFinderItems([source], into: nil) }
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while editor.mediaImportSequence < 2 && ContinuousClock.now < secondDeadline { await Task.yield() }
        #expect(editor.mediaImportSequence == 2)
        release.finish()
        #expect(await first.value)
        let result = await second.value
        #expect(result.assetCount == 1 && result.failure == nil)
        let imported = try #require(editor.mediaAssets.first)
        #expect(try Data(contentsOf: imported.url) == Data(contentsOf: source))
    }

    @Test func restoredIncompleteMediaResumesFinalization() async throws {
        let (editor, directory, _) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: directory) }
        let media = try #require(editor.workingRoot).appendingPathComponent(Project.mediaDirectoryName)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let source = media.appendingPathComponent("Restored.png")
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<2 { for x in 0..<2 { pixels.setColor(.blue, atX: x, y: y) } }
        try #require(pixels.representation(using: .png, properties: [:])).write(to: source)
        let asset = MediaAsset(id: "restored", url: source, type: .image, name: "Restored")
        editor.mediaAssets = [asset]
        editor.mediaManifest.entries = [asset.toManifestEntry(projectURL: editor.workingRoot)]
        let snapshot = editor.mediaLibraryUndoSnapshot()
        editor.mediaAssets = []; editor.mediaManifest.entries = []
        let finalizations = editor.applyMediaLibrarySnapshot(snapshot)
        #expect(finalizations.count == 1)
        for finalization in finalizations { #expect(await finalization.value) }
        #expect(editor.mediaAssets.first === asset)
        #expect(asset.sourceWidth == 2 && asset.sourceHeight == 2)
        #expect(editor.mediaManifest.entries.first?.sourceWidth == 2)
        #expect(editor.mediaManifest.entries.first?.sourceHeight == 2)
    }

    @Test func namedCaptureIsOneUndoableImportAndDoesNotRenameDuplicate() async throws {
        let (editor, directory, _) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: directory) }
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<2 { for x in 0..<2 { pixels.setColor(.red, atX: x, y: y) } }
        let png = try #require(pixels.representation(using: .png, properties: [:]))
        undo.beginUndoGrouping()
        let asset = try #require(await editor.importPastedImageData(png, originalFilename: "Opening 60.png"))
        undo.endUndoGrouping()
        #expect(asset.name == "Opening 60" && asset.originalFilename == "Opening 60.png")
        undo.undo()
        #expect(editor.mediaAssets.isEmpty && editor.mediaManifest.entries.isEmpty)
        undo.redo()
        #expect(editor.mediaManifest.entries.count == 1)
        #expect(editor.mediaManifest.entries.first?.name == "Opening 60")
        #expect(editor.mediaManifest.entries.first?.originalFilename == "Opening 60.png")
        let duplicate = try #require(await editor.importPastedImageData(png, originalFilename: "Different name.png"))
        #expect(duplicate.id == asset.id && editor.mediaManifest.entries.count == 1)
        #expect(editor.mediaManifest.entries.first?.name == "Opening 60")
        #expect(duplicate.name == "Opening 60" && duplicate.originalFilename == "Opening 60.png")
    }

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
