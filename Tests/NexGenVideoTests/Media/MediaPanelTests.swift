import AppKit
import Foundation
import Testing
@testable import NexGenVideo

@MainActor
private func editor() -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline()
    return e
}

@MainActor
private func savedEditor() throws -> (editor: EditorViewModel, cleanup: URL) {
    let cleanup = FileManager.default.temporaryDirectory
        .appendingPathComponent("media-panel-\(UUID().uuidString)", isDirectory: true)
    let package = cleanup.appendingPathComponent("Project.ngv", isDirectory: true)
    try Fixtures.prepareProjectPackage(at: package)
    let e = editor()
    e.projectURL = package
    return (e, cleanup)
}

private func writeImportFixture(in directory: URL, name: String, contents: String = "fixture") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

@MainActor
private func asset(name: String, folderId: String? = nil) -> MediaAsset {
    let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\(name).mp4")
    let a = MediaAsset(url: url, type: .video, name: name)
    a.folderId = folderId
    return a
}

@Suite("EditorViewModel — folder reads")
@MainActor
struct FolderReadTests {

    @Test func subfoldersReturnsImmediateChildrenSortedByName() {
        let e = editor()
        let root = e.createFolder(name: "Root")
        _ = e.createFolder(name: "Beta", in: root)
        _ = e.createFolder(name: "alpha", in: root)
        _ = e.createFolder(name: "Gamma", in: root)
        // Grand-child should not appear in root's subfolders.
        let alphaId = e.subfolders(of: root).first(where: { $0.name == "alpha" })!.id
        _ = e.createFolder(name: "Nested", in: alphaId)

        let names = e.subfolders(of: root).map(\.name)
        #expect(names == ["alpha", "Beta", "Gamma"])
    }

    @Test func folderPathWalksFromRootToTarget() {
        let e = editor()
        let a = e.createFolder(name: "A")
        let b = e.createFolder(name: "B", in: a)
        let c = e.createFolder(name: "C", in: b)
        #expect(e.folderPath(for: c).map(\.name) == ["A", "B", "C"])
        #expect(e.folderPath(for: nil).isEmpty)
    }

    @Test func assetsInFiltersByFolderId() {
        let e = editor()
        let folderId = e.createFolder(name: "Clips")
        let inside = asset(name: "in", folderId: folderId)
        let outside = asset(name: "out", folderId: nil)
        e.importMediaAsset(inside)
        e.importMediaAsset(outside)

        #expect(e.assetsIn(folderId: folderId).map(\.name) == ["in"])
        #expect(e.assetsIn(folderId: nil).map(\.name) == ["out"])
    }

    @Test func importFinderItemsMirrorsFolderTree() async throws {
        let e = editor()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-import-\(UUID().uuidString)", isDirectory: true)
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-import-project-\(UUID().uuidString).ngv", isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: projectURL)
        }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Fixtures.prepareProjectPackage(at: projectURL)
        e.projectURL = projectURL
        try Data("video".utf8).write(to: root.appendingPathComponent("root.mp4"))
        try Data("audio".utf8).write(to: nested.appendingPathComponent("child.wav"))
        try Data().write(to: nested.appendingPathComponent("ignored.zip"))
        // A story script inside an imported folder must come WITH it — silently dropping the user's
        // script because it sat in a folder is the failure this guards.
        try Data("script".utf8).write(to: nested.appendingPathComponent("script.md"))

        let summary = await e.importFinderItems([root], into: nil)

        #expect(summary.assetCount == 3)
        #expect(summary.folderCount == 2)
        #expect(summary.failure == nil)
        let rootFolder = try #require(e.folders.first { $0.name == root.lastPathComponent })
        let nestedFolder = try #require(e.folders.first { $0.name == "Nested" })
        #expect(nestedFolder.parentFolderId == rootFolder.id)
        #expect(e.assetsIn(folderId: rootFolder.id).map(\.name) == ["root"])
        #expect(e.assetsIn(folderId: nestedFolder.id).map(\.name).sorted() == ["child", "script"])
    }

    @Test func importFinderItemsFailsWithoutPartialImportWhenDirectoryCannotBeRead() async throws {
        let e = editor()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-import-denied-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let summary = await e.importFinderItems([root], into: nil)

        #expect(summary.assetCount == 0)
        #expect(summary.folderCount == 0)
        #expect(summary.failure?.contains("contents couldn't be read") == true)
        #expect(e.folders.isEmpty)
        #expect(e.mediaAssets.isEmpty)
    }
}

@Suite("EditorViewModel — durable media import")
@MainActor
struct DurableMediaImportTests {

    @Test func unsavedProjectRejectsImportWithoutRegisteringAsset() throws {
        let e = editor()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsaved-import-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("source".utf8).write(to: source)

        let imported = e.addMediaAsset(from: source)

        #expect(imported == nil)
        #expect(e.mediaAssets.isEmpty)
        #expect(e.mediaManifest.entries.isEmpty)
        #expect(e.mediaPanelToast?.message == "Save the project before importing media.")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func copyFailureDoesNotRegisterAsset() throws {
        let e = editor()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-import-\(UUID().uuidString).mp4")
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-import-project-\(UUID().uuidString).ngv", isDirectory: true)
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: projectURL)
        }
        try Data("source".utf8).write(to: source)
        try Fixtures.prepareProjectPackage(at: projectURL)
        try Data("blocked".utf8).write(
            to: projectURL.appendingPathComponent(Project.mediaDirectoryName)
        )
        e.projectURL = projectURL

        let imported = e.addMediaAsset(from: source)

        #expect(imported == nil)
        #expect(e.mediaAssets.isEmpty)
        #expect(e.mediaManifest.entries.isEmpty)
        #expect(e.mediaPanelToast?.message.contains("project media folder couldn't be prepared") == true)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func successfulImportCopiesIntoWorkingCopyAndPersistsRelativeSource() throws {
        let e = editor()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-import-\(UUID().uuidString).mp4")
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-import-project-\(UUID().uuidString).ngv", isDirectory: true)
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: projectURL)
        }
        let contents = Data("source".utf8)
        try contents.write(to: source)
        try Fixtures.prepareProjectPackage(at: projectURL)
        e.projectURL = projectURL

        let imported = try #require(e.addMediaAsset(from: source))
        let entry = try #require(e.mediaManifest.entries.first { $0.id == imported.id })
        let workingRoot = try #require(e.workingRoot)

        #expect(imported.url.path.hasPrefix(workingRoot.path + "/media/"))
        #expect(!imported.url.path.hasPrefix(projectURL.path + "/media/"))
        #expect(try Data(contentsOf: imported.url) == contents)
        switch entry.source {
        case .project(let relativePath):
            #expect(relativePath == "media/\(imported.url.lastPathComponent)")
        case .external:
            Issue.record("new imports must not persist an external source")
        }
    }

    @Test func folderImportRollsBackPreparedCopiesWhenALaterSourceFails() async throws {
        let e = editor()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollback-import-\(UUID().uuidString)", isDirectory: true)
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollback-import-project-\(UUID().uuidString).ngv", isDirectory: true)
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: projectURL)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Fixtures.prepareProjectPackage(at: projectURL)
        try Data("source".utf8).write(to: root.appendingPathComponent("a-valid.mp4"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("z-missing.mp4"),
            withDestinationURL: root.appendingPathComponent("missing-target.mp4")
        )
        e.projectURL = projectURL

        let summary = await e.importFinderItems([root], into: nil)

        #expect(summary.failure != nil)
        #expect(e.mediaAssets.isEmpty)
        #expect(e.mediaManifest.entries.isEmpty)
        #expect(e.mediaManifest.folders.isEmpty)
        let mediaDir = try #require(e.workingRoot).appendingPathComponent(
            Project.mediaDirectoryName
        )
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: mediaDir.path)) ?? []
        #expect(remaining.isEmpty)
    }

    @Test func folderImportDoesNotFollowDirectorySymlinkCycles() async throws {
        let e = editor()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cycle-import-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cycle-import-project-\(UUID().uuidString).ngv",
                isDirectory: true
            )
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: projectURL)
        }
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: nested.appendingPathComponent("clip.mp4"))
        try FileManager.default.createSymbolicLink(
            at: nested.appendingPathComponent("loop"),
            withDestinationURL: root
        )
        try Fixtures.prepareProjectPackage(at: projectURL)
        e.projectURL = projectURL

        let summary = await e.importFinderItems([root], into: nil)

        #expect(summary.failure == nil)
        #expect(summary.assetCount == 1)
        #expect(summary.folderCount == 2)
        #expect(e.mediaAssets.count == 1)
    }

    @Test func contentIdentityDistinguishesSameSizeAndMtimeAndDeduplicatesReimport() async throws {
        let e = editor()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-import-\(UUID().uuidString).mp4")
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-import-project-\(UUID().uuidString).ngv", isDirectory: true)
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: projectURL)
        }
        try Fixtures.prepareProjectPackage(at: projectURL)
        e.projectURL = projectURL
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        try Data("aaaa".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: timestamp],
            ofItemAtPath: source.path
        )
        let first = await e.importFinderItems([source], into: nil)
        let firstURL = try #require(e.mediaAssets.first?.url)

        try Data("bbbb".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: timestamp],
            ofItemAtPath: source.path
        )
        let changed = await e.importFinderItems([source], into: nil)
        let unchanged = await e.importFinderItems([source], into: nil)
        let lastURL = try #require(e.mediaAssets.last?.url)

        #expect(first.assetCount == 1)
        #expect(changed.assetCount == 1)
        #expect(unchanged.assetCount == 0)
        #expect(e.mediaAssets.count == 2)
        #expect(e.mediaAssets.last?.url != firstURL)
        #expect(try Data(contentsOf: firstURL) == Data("aaaa".utf8))
        #expect(try Data(contentsOf: lastURL) == Data("bbbb".utf8))
    }

    @Test func undoRemovesNewWorkingCopyMedia() async throws {
        let e = editor()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("undo-import-\(UUID().uuidString).mp4")
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("undo-import-project-\(UUID().uuidString).ngv", isDirectory: true)
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: projectURL)
        }
        try Data("undo".utf8).write(to: source)
        try Fixtures.prepareProjectPackage(at: projectURL)
        e.projectURL = projectURL
        let undo = UndoManager()
        e.undoManager = undo

        let summary = await e.importFinderItems([source], into: nil)
        let importedURL = try #require(e.mediaAssets.first?.url)
        undo.undo()

        #expect(summary.assetCount == 1)
        #expect(e.mediaAssets.isEmpty)
        #expect(e.mediaManifest.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: importedURL.path))

        undo.redo()
        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaManifest.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: importedURL.path))
        #expect(try Data(contentsOf: importedURL) == Data("undo".utf8))
    }

    @Test func cancelledLargeImportLeavesNoAssetsOrPartialFiles() async throws {
        let e = editor()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-import-\(UUID().uuidString).mp4")
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cancel-import-project-\(UUID().uuidString).ngv",
                isDirectory: true
            )
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: projectURL)
        }
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 128 * 1024 * 1024)
        try handle.close()
        try Fixtures.prepareProjectPackage(at: projectURL)
        e.projectURL = projectURL

        let importTask = Task { @MainActor in
            await e.importFinderItems([source], into: nil)
        }
        for _ in 0..<10_000 where e.mediaImportProgress == nil {
            await Task.yield()
        }
        #expect(e.mediaImportProgress != nil)
        e.cancelMediaImport()
        let summary = await importTask.value

        #expect(summary.failure == MediaImportError.cancelled.localizedDescription)
        #expect(e.mediaAssets.isEmpty)
        #expect(e.mediaManifest.entries.isEmpty)
        let mediaDirectory = try #require(e.workingRoot).appendingPathComponent(
            Project.mediaDirectoryName
        )
        let remaining = try FileManager.default.contentsOfDirectory(
            atPath: mediaDirectory.path
        )
        #expect(remaining.isEmpty)
    }

    @Test func concurrentImportsSerializeWithoutLosingEitherBatch() async throws {
        let e = editor()
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("concurrent-a-\(UUID().uuidString).mp4")
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("concurrent-b-\(UUID().uuidString).mp4")
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "concurrent-import-project-\(UUID().uuidString).ngv",
                isDirectory: true
            )
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            try? FileManager.default.removeItem(at: projectURL)
        }
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try Fixtures.prepareProjectPackage(at: projectURL)
        e.projectURL = projectURL

        async let firstSummary = e.importFinderItems([first], into: nil)
        async let secondSummary = e.importFinderItems([second], into: nil)
        let (firstResult, secondResult) = await (firstSummary, secondSummary)
        let summaries = [firstResult, secondResult]

        #expect(summaries.map(\.assetCount).reduce(0, +) == 2)
        #expect(e.mediaAssets.count == 2)
        #expect(e.mediaManifest.entries.count == 2)
        #expect(Set(e.mediaAssets.map(\.name)).count == 2)
    }

    @Test func manifestDoesNotTreatPrefixSiblingAsProjectMedia() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("containment-\(UUID().uuidString).ngv", isDirectory: true)
        let sibling = URL(fileURLWithPath: root.path + "-copy", isDirectory: true)
            .appendingPathComponent("clip.mp4")
        let entry = MediaAsset(url: sibling, type: .video, name: "clip")
            .toManifestEntry(projectURL: root)

        switch entry.source {
        case .project:
            Issue.record("a path-prefix sibling is outside the project package")
        case .external(let absolutePath):
            #expect(absolutePath == sibling.path)
        }
    }

    @Test func relinkCopiesReplacementIntoWorkingCopy() throws {
        let e = editor()
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("relink-project-\(UUID().uuidString).ngv", isDirectory: true)
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("replacement-\(UUID().uuidString).mp4")
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: projectURL)
            try? FileManager.default.removeItem(at: replacement)
        }
        try Fixtures.prepareProjectPackage(at: projectURL)
        try Data("replacement".utf8).write(to: replacement)
        e.projectURL = projectURL
        let workingRoot = try #require(e.workingRoot)
        let missing = workingRoot.appendingPathComponent("media/missing.mp4")
        let asset = MediaAsset(id: "relink", url: missing, type: .video, name: "Missing")
        e.mediaAssets = [asset]
        e.mediaManifest.entries = [
            MediaManifestEntry(
                id: asset.id,
                name: asset.name,
                type: asset.type,
                source: .project(relativePath: "media/missing.mp4"),
                duration: 1
            )
        ]

        e.relinkAsset(id: asset.id, to: replacement)

        #expect(asset.url.path.hasPrefix(workingRoot.path + "/media/"))
        #expect(try Data(contentsOf: asset.url) == Data("replacement".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent("media")
                .appendingPathComponent(asset.url.lastPathComponent).path
        ))
        if case .project(let relativePath) = e.mediaManifest.entries[0].source {
            #expect(relativePath == "media/\(asset.url.lastPathComponent)")
        } else {
            Issue.record("relinked media must remain project-relative")
        }
    }
}

@Suite("EditorViewModel — deleteFolders")
@MainActor
struct DeleteFoldersTests {

    @Test func deleteCascadesIntoDescendants() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child", in: parent)
        let grand = e.createFolder(name: "Grand", in: child)

        e.deleteFolders(ids: [parent])

        #expect(e.folder(id: parent) == nil)
        #expect(e.folder(id: child) == nil)
        #expect(e.folder(id: grand) == nil)
    }

    @Test func deleteRemovesAssetsAndReferencingClips() {
        let e = editor()
        let folder = e.createFolder(name: "Trash")
        let a = asset(name: "doomed", folderId: folder)
        e.importMediaAsset(a)
        // Place a clip on the timeline that references the asset.
        let clip = Fixtures.clip(id: "c1", mediaRef: a.id, start: 0, duration: 30)
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        e.deleteFolders(ids: [folder])

        #expect(e.mediaAssets.contains(where: { $0.id == a.id }) == false)
        #expect(e.mediaManifest.entries.contains(where: { $0.id == a.id }) == false)
        // Empty track is pruned after the only clip referencing the deleted asset goes.
        #expect(e.timeline.tracks.flatMap(\.clips).contains(where: { $0.id == "c1" }) == false)
    }

    @Test func deleteSubtractsFromSelectedFolderIds() {
        let e = editor()
        let a = e.createFolder(name: "A")
        let b = e.createFolder(name: "B")
        e.selectedFolderIds = [a, b]

        e.deleteFolders(ids: [a])

        #expect(e.selectedFolderIds == [b])
    }

    @Test func deleteEmptySetIsNoOp() {
        let e = editor()
        _ = e.createFolder(name: "Keep")
        let before = e.folders.count
        e.deleteFolders(ids: [])
        #expect(e.folders.count == before)
    }
}

@Suite("EditorViewModel — moveAssetsToFolder & moveFoldersToFolder")
@MainActor
struct MoveFoldersTests {

    @Test func moveAssetsUpdatesAssetAndManifestEntry() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)

        e.moveAssetsToFolder(assetIds: [a.id], folderId: dest)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == dest)
        #expect(e.mediaManifest.entries.first(where: { $0.id == a.id })?.folderId == dest)
    }

    @Test func moveFoldersRejectsCycleIntoOwnDescendant() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child", in: parent)

        // Attempting to make `parent` a child of its own descendant `child` must be ignored.
        e.moveFoldersToFolder(folderIds: [parent], parentFolderId: child)

        #expect(e.folder(id: parent)?.parentFolderId == nil)
        #expect(e.folder(id: child)?.parentFolderId == parent)
    }

    @Test func moveFoldersRejectsSelfParent() {
        let e = editor()
        let f = e.createFolder(name: "Solo")
        e.moveFoldersToFolder(folderIds: [f], parentFolderId: f)
        #expect(e.folder(id: f)?.parentFolderId == nil)
    }

    @Test func moveAssetsToNilReparentsToRoot() {
        let e = editor()
        let folder = e.createFolder(name: "Box")
        let a = asset(name: "x", folderId: folder)
        e.importMediaAsset(a)

        e.moveAssetsToFolder(assetIds: [a.id], folderId: nil)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == nil)
        #expect(e.mediaManifest.entries.first(where: { $0.id == a.id })?.folderId == nil)
    }
}

@Suite("EditorViewModel — folder edge cases")
@MainActor
struct FolderEdgeCaseTests {

    /// A cycle in `parentFolderId` shouldn't exist in practice, but if a corrupted
    /// manifest produces one, folderPath must terminate rather than spin forever.
    @Test func folderPathTerminatesOnCycle() {
        let e = editor()
        let a = MediaFolder(id: "A", name: "A", parentFolderId: "B")
        let b = MediaFolder(id: "B", name: "B", parentFolderId: "A")
        e.mediaManifest.folders = [a, b]

        let path = e.folderPath(for: "A")
        // Both folders appear exactly once, in some valid order.
        #expect(Set(path.map(\.id)) == ["A", "B"])
        #expect(path.count == 2)
    }

    /// Passing both an ancestor and one of its descendants should delete the
    /// whole subtree exactly once (the descendant is also reachable via cascade).
    @Test func deleteHandlesOverlappingAncestorAndDescendant() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child", in: parent)
        let other = e.createFolder(name: "Other")

        e.deleteFolders(ids: [parent, child])

        #expect(e.folder(id: parent) == nil)
        #expect(e.folder(id: child) == nil)
        #expect(e.folder(id: other) != nil)
    }

    @Test func deleteSubtractsFromSelectedMediaAssetIds() {
        let e = editor()
        let folder = e.createFolder(name: "Doomed")
        let inside = asset(name: "in", folderId: folder)
        let outside = asset(name: "out", folderId: nil)
        e.importMediaAsset(inside)
        e.importMediaAsset(outside)
        e.selectedMediaAssetIds = [inside.id, outside.id]

        e.deleteFolders(ids: [folder])

        #expect(e.selectedMediaAssetIds == [outside.id])
    }

    @Test func renameFolderIgnoresUnknownId() {
        let e = editor()
        let real = e.createFolder(name: "Real")
        let before = e.folders.count

        e.renameFolder(id: "not-a-real-id", name: "Whatever")

        #expect(e.folders.count == before)
        #expect(e.folder(id: real)?.name == "Real")
    }
}

// MARK: - Drag payload contract

/// Locks in the `nexgen-asset://` / `nexgen-folder://` sentinel schemes that
/// keep in-panel drags distinguishable from Finder file URLs. The 35586d4 fix
/// switched the asset payload from a raw file:// URL to this scheme — if it
/// reverts, the file-URL conformance check in handleProviderDrop would
/// re-route in-panel asset drags as Finder drops (duplicate imports).
@Suite("MediaTab — drag payload contract")
@MainActor
struct DragPayloadContractTests {

    @Test func assetStringRoundTrips() {
        let id = "asset-123"
        let line = MediaTab.assetDragString(forAssetId: id)
        #expect(MediaTab.assetId(fromDragString: line) == id)
    }

    @Test func folderStringRoundTrips() {
        let id = "folder-abc"
        let line = MediaTab.folderDragString(forFolderId: id)
        #expect(MediaTab.folderId(fromDragString: line) == id)
    }

    @Test func sentinelsDoNotCrossDecode() {
        let assetLine = MediaTab.assetDragString(forAssetId: "x")
        let folderLine = MediaTab.folderDragString(forFolderId: "y")
        #expect(MediaTab.folderId(fromDragString: assetLine) == nil)
        #expect(MediaTab.assetId(fromDragString: folderLine) == nil)
    }

    @Test func fileURLDoesNotDecodeAsAssetOrFolder() {
        let line = "file:///tmp/foo.mp4"
        #expect(MediaTab.assetId(fromDragString: line) == nil)
        #expect(MediaTab.folderId(fromDragString: line) == nil)
    }
}

// MARK: - resolveTextDrop routing

@Suite("MediaTab — resolveTextDrop")
@MainActor
struct ResolveTextDropTests {

    @Test func routesSingleAssetIntoDestinationFolder() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)
        let payload = MediaTab.assetDragString(forAssetId: a.id)

        MediaTab.resolveTextDrop(payload, into: dest, editor: e)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == dest)
    }

    @Test func routesSingleFolderUnderDestinationParent() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child")
        let payload = MediaTab.folderDragString(forFolderId: child)

        MediaTab.resolveTextDrop(payload, into: parent, editor: e)

        #expect(e.folder(id: child)?.parentFolderId == parent)
    }

    @Test func multiLinePayloadRoutesAssetsAndFoldersTogether() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let movableFolder = e.createFolder(name: "Movable")
        let a1 = asset(name: "a1", folderId: nil)
        let a2 = asset(name: "a2", folderId: nil)
        e.importMediaAsset(a1)
        e.importMediaAsset(a2)
        let payload = [
            MediaTab.assetDragString(forAssetId: a1.id),
            MediaTab.folderDragString(forFolderId: movableFolder),
            MediaTab.assetDragString(forAssetId: a2.id),
        ].joined(separator: "\n")

        MediaTab.resolveTextDrop(payload, into: dest, editor: e)

        #expect(e.mediaAssets.first(where: { $0.id == a1.id })?.folderId == dest)
        #expect(e.mediaAssets.first(where: { $0.id == a2.id })?.folderId == dest)
        #expect(e.folder(id: movableFolder)?.parentFolderId == dest)
    }

    @Test func nilDestinationReparentsToRoot() {
        let e = editor()
        let folder = e.createFolder(name: "Box")
        let a = asset(name: "x", folderId: folder)
        e.importMediaAsset(a)
        let payload = MediaTab.assetDragString(forAssetId: a.id)

        MediaTab.resolveTextDrop(payload, into: nil, editor: e)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == nil)
    }

    @Test func unknownAssetIdIsIgnored() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let payload = MediaTab.assetDragString(forAssetId: "ghost-asset")

        MediaTab.resolveTextDrop(payload, into: dest, editor: e)

        // No phantom asset row should be inserted.
        #expect(e.mediaAssets.isEmpty)
    }

    @Test func unrecognizedLinesAreIgnored() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)
        let payload = [
            "file:///tmp/garbage.mp4",
            "",
            "random nonsense",
            MediaTab.assetDragString(forAssetId: a.id),
        ].joined(separator: "\n")

        MediaTab.resolveTextDrop(payload, into: dest, editor: e)

        // The one valid line routed; the rest were skipped without side effects.
        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == dest)
    }

    @Test func cycleIntoOwnDescendantIsRejected() {
        let e = editor()
        let parent = e.createFolder(name: "Parent")
        let child = e.createFolder(name: "Child", in: parent)
        // Try to make parent a child of its own descendant.
        let payload = MediaTab.folderDragString(forFolderId: parent)

        MediaTab.resolveTextDrop(payload, into: child, editor: e)

        #expect(e.folder(id: parent)?.parentFolderId == nil)
    }

    @Test func emptyPayloadIsNoOp() {
        let e = editor()
        let dest = e.createFolder(name: "Dest")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)

        MediaTab.resolveTextDrop("", into: dest, editor: e)

        #expect(e.mediaAssets.first(where: { $0.id == a.id })?.folderId == nil)
    }
}

// MARK: - moveMediaSelection (keyboard navigation)

/// Arrow-key navigation in the media panel. The model logic in
/// `moveMediaSelection(direction:)` is driven by an `NSEvent` handler in
/// `EditorWindowController`, so the wiring isn't unit-testable — but the
/// step / clamp / selection-routing logic is.
@Suite("EditorViewModel — moveMediaSelection")
@MainActor
struct MoveMediaSelectionTests {

    /// Helper: seed an ordered grid of `count` assets with the given column
    /// width. Returns the asset ids in grid order.
    @discardableResult
    private func seedAssetGrid(_ e: EditorViewModel, count: Int, columns: Int) -> [String] {
        var ids: [String] = []
        for i in 0..<count {
            let a = asset(name: "a\(i)", folderId: nil)
            e.importMediaAsset(a)
            ids.append(a.id)
        }
        e.mediaPanelOrderedItemIds = ids
        e.mediaPanelColumnCount = columns
        return ids
    }

    @Test func emptyOrderedListIsNoOp() {
        let e = editor()
        e.mediaPanelOrderedItemIds = []

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds.isEmpty)
        #expect(e.selectedFolderIds.isEmpty)
        #expect(e.mediaPanelScrollTarget == nil)
    }

    @Test func noSelectionRightSelectsFirstItem() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds == [ids[0]])
        #expect(e.mediaPanelScrollTarget == ids[0])
    }

    @Test func noSelectionLeftSelectsLastItem() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)

        e.moveMediaSelection(direction: .left)

        #expect(e.selectedMediaAssetIds == [ids[3]])
        #expect(e.mediaPanelScrollTarget == ids[3])
    }

    @Test func noSelectionUpSelectsLastItem() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)

        e.moveMediaSelection(direction: .up)

        #expect(e.selectedMediaAssetIds == [ids[3]])
    }

    @Test func rightAdvancesToNextItem() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)
        e.selectedMediaAssetIds = [ids[1]]

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds == [ids[2]])
    }

    @Test func rightAtEndClampsAndDoesNothing() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)
        e.selectedMediaAssetIds = [ids[3]]
        e.mediaPanelScrollTarget = nil

        e.moveMediaSelection(direction: .right)

        // Selection unchanged. No scroll target set (early-return on same idx).
        #expect(e.selectedMediaAssetIds == [ids[3]])
        #expect(e.mediaPanelScrollTarget == nil)
    }

    @Test func leftAtStartClampsAndDoesNothing() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)
        e.selectedMediaAssetIds = [ids[0]]
        e.mediaPanelScrollTarget = nil

        e.moveMediaSelection(direction: .left)

        #expect(e.selectedMediaAssetIds == [ids[0]])
        #expect(e.mediaPanelScrollTarget == nil)
    }

    @Test func downJumpsByColumnCount() {
        let e = editor()
        // 2 rows of 3: [0 1 2 / 3 4 5]. Down from idx 1 → idx 4.
        let ids = seedAssetGrid(e, count: 6, columns: 3)
        e.selectedMediaAssetIds = [ids[1]]

        e.moveMediaSelection(direction: .down)

        #expect(e.selectedMediaAssetIds == [ids[4]])
    }

    @Test func downAtPartialBottomRowClampsToLast() {
        let e = editor()
        // 5 items in 3-wide grid: [0 1 2 / 3 4]. Down from idx 2 → would be 5,
        // but list ends at 4, so clamp to last.
        let ids = seedAssetGrid(e, count: 5, columns: 3)
        e.selectedMediaAssetIds = [ids[2]]

        e.moveMediaSelection(direction: .down)

        #expect(e.selectedMediaAssetIds == [ids[4]])
    }

    @Test func navigatingOntoFolderClearsAssetSelection() {
        let e = editor()
        let folderId = e.createFolder(name: "F")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)
        // Ordered: [folder, asset]. Start on the asset, go left → land on folder.
        e.mediaPanelOrderedItemIds = [MediaPanelItemKey.folder(folderId), a.id]
        e.mediaPanelColumnCount = 2
        e.selectedMediaAssetIds = [a.id]

        e.moveMediaSelection(direction: .left)

        #expect(e.selectedFolderIds == [folderId])
        #expect(e.selectedMediaAssetIds.isEmpty)
    }

    @Test func navigatingOntoAssetClearsFolderSelection() {
        let e = editor()
        let folderId = e.createFolder(name: "F")
        let a = asset(name: "x", folderId: nil)
        e.importMediaAsset(a)
        e.mediaPanelOrderedItemIds = [MediaPanelItemKey.folder(folderId), a.id]
        e.mediaPanelColumnCount = 2
        e.selectedFolderIds = [folderId]

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds == [a.id])
        #expect(e.selectedFolderIds.isEmpty)
    }

    @Test func ghostSelectionDoesNotAnchorNavigation() {
        let e = editor()
        let ids = seedAssetGrid(e, count: 4, columns: 4)
        // A selection id that isn't in the ordered list (e.g., a stale selection
        // from a previous filter) shouldn't anchor navigation — fall back to
        // the no-selection branch.
        e.selectedMediaAssetIds = ["ghost-id"]

        e.moveMediaSelection(direction: .right)

        #expect(e.selectedMediaAssetIds == [ids[0]])
    }
}

// MARK: - handlePanelFinderDrop

@Suite("MediaTab — handlePanelFinderDrop")
@MainActor
struct HandlePanelFinderDropTests {

    @Test func addsAssetAtRootWhenDestinationIsNil() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let url = try writeImportFixture(in: cleanup, name: "clip.mp4")

        await MediaTab.handlePanelFinderDrop(urls: [url], into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.folderId == nil)
    }

    @Test func addsAssetAndMovesIntoDestinationFolder() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let dest = e.createFolder(name: "Dest")
        let url = try writeImportFixture(in: cleanup, name: "clip.mp4")

        await MediaTab.handlePanelFinderDrop(urls: [url], into: dest, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.folderId == dest)
    }

    @Test func skipsUnsupportedFileExtensions() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let url = try writeImportFixture(in: cleanup, name: "archive.zip")

        await MediaTab.handlePanelFinderDrop(urls: [url], into: nil, editor: e)

        #expect(e.mediaAssets.isEmpty)
    }

    @Test func addsMultipleAssetsIntoDestination() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let dest = e.createFolder(name: "Dest")
        let urls = try (0..<3).map { index in
            try writeImportFixture(
                in: cleanup,
                name: "clip-\(index).mp4",
                contents: "fixture-\(index)"
            )
        }

        await MediaTab.handlePanelFinderDrop(urls: urls, into: dest, editor: e)

        #expect(e.mediaAssets.count == 3)
        #expect(e.mediaAssets.allSatisfy { $0.folderId == dest })
    }
}

// MARK: - clipboardHasImportableMedia

/// Drives Edit > Paste menu validation. Uses a unique pasteboard per test so
/// parallel tests don't collide on `NSPasteboard.general`.
@Suite("MediaTab — clipboardHasImportableMedia")
@MainActor
struct ClipboardProbeTests {

    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        return pb
    }

    @Test func emptyPasteboardIsFalse() {
        let pb = freshPasteboard()
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb) == false)
    }

    @Test func textOnlyIsFalse() {
        let pb = freshPasteboard()
        pb.setString("hello", forType: .string)
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb) == false)
    }

    @Test func pngIsTrue() {
        let pb = freshPasteboard()
        pb.setData(Data([0]), forType: .png)
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb))
    }

    @Test func tiffIsTrue() {
        let pb = freshPasteboard()
        pb.setData(Data([0]), forType: .tiff)
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb))
    }

    @Test func fileURLIsTrue() {
        let pb = freshPasteboard()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/x.mp4") as NSURL])
        #expect(MediaTab.clipboardHasImportableMedia(pasteboard: pb))
    }
}

// MARK: - handleClipboardPaste

@Suite("MediaTab — handleClipboardPaste")
@MainActor
struct HandleClipboardPasteTests {

    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        return pb
    }

    @Test func pngBytesImportAtRootWhenDestinationIsNil() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let pb = freshPasteboard()
        pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.type == .image)
        #expect(e.mediaAssets.first?.url.pathExtension == "png")
        #expect(e.mediaAssets.first?.folderId == nil)
    }

    @Test func pngBytesLandInDestinationFolder() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let dest = e.createFolder(name: "Dest")
        let pb = freshPasteboard()
        pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: dest, editor: e)

        #expect(e.mediaAssets.first?.folderId == dest)
        #expect(e.mediaManifest.entries.first?.folderId == dest)
    }

    @Test func tiffBytesImportWithTiffExtension() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let pb = freshPasteboard()
        pb.setData(Data([0x4D, 0x4D, 0x00, 0x2A]), forType: .tiff)

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.url.pathExtension == "tiff")
    }

    @Test func fileURLRoutesThroughFinderDrop() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let url = try writeImportFixture(in: cleanup, name: "clip.mp4")
        let pb = freshPasteboard()
        pb.writeObjects([url as NSURL])

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.type == .video)
    }

    @Test func fileURLLandsInDestinationFolder() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let dest = e.createFolder(name: "Dest")
        let url = try writeImportFixture(in: cleanup, name: "clip.mp4")
        let pb = freshPasteboard()
        pb.writeObjects([url as NSURL])

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: dest, editor: e)

        #expect(e.mediaAssets.first?.folderId == dest)
    }

    /// When both a file URL and raw image bytes are on the pasteboard (Finder
    /// items always carry a TIFF preview alongside the file URL), the URL wins —
    /// avoids creating both the file-imported asset and a duplicate "pasted-*"
    /// image asset for the same payload.
    @Test func fileURLTakesPrecedenceOverImageData() async throws {
        let (e, cleanup) = try savedEditor()
        defer {
            e.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let url = try writeImportFixture(in: cleanup, name: "clip.mp4")
        let pb = freshPasteboard()
        pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pb.writeObjects([url as NSURL])

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.count == 1)
        #expect(e.mediaAssets.first?.type == .video)
    }

    @Test func emptyPasteboardIsNoOp() async {
        let e = editor()
        let pb = freshPasteboard()

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.isEmpty)
    }

    @Test func textOnlyPasteboardIsNoOp() async {
        let e = editor()
        let pb = freshPasteboard()
        pb.setString("just some text", forType: .string)

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.isEmpty)
    }

    @Test func fileURLWithUnsupportedExtensionIsNoOp() async {
        let e = editor()
        let pb = freshPasteboard()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-archive.zip") as NSURL])

        await MediaTab.handleClipboardPaste(pasteboard: pb, into: nil, editor: e)

        #expect(e.mediaAssets.isEmpty)
    }
}
