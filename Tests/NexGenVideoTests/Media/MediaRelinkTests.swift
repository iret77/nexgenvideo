import AppKit
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Media relink identity and ambiguity")
@MainActor
struct MediaRelinkTests {
    @Test func duplicateNamesAreNeverSelectedByEnumerationOrder() async throws {
        let (editor, root, asset) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("Candidates", isDirectory: true)
        for (folder, content) in [("First", "one"), ("Second", "two")] {
            let directory = sources.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: directory.appendingPathComponent("Original.mp4"))
        }
        let manifest = editor.mediaManifest
        let timeline = editor.timeline
        let result = await editor.relinkOfflineAssets(fromFolder: sources)
        #expect(result.relinked == 0)
        #expect(result.total == 1)
        #expect(result.failure?.contains("Original.mp4") == true)
        #expect(result.failure?.contains("individually") == true)
        #expect(editor.mediaManifest == manifest)
        #expect(editor.timeline == timeline)
        #expect(asset.url.lastPathComponent == "missing.mp4")
    }

    @Test func unsupportedReplacementLeavesExactBindingUntouched() async throws {
        let (editor, root, asset) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: root) }
        let replacement = root.appendingPathComponent("Unsupported.xyz")
        try Data("unrecognized".utf8).write(to: replacement)
        let manifest = editor.mediaManifest
        await editor.relinkAsset(id: asset.id, to: replacement)
        #expect(editor.mediaManifest == manifest)
        #expect(asset.url.lastPathComponent == "missing.mp4")
        #expect(editor.mediaPanelToast?.message.contains("supported video") == true)
    }

    @Test func relinkUndoRedoPreservesAssetAndClipIdentity() async throws {
        let (editor, root, asset) = try fixture()
        defer { editor.releaseWorkingCopy(); try? FileManager.default.removeItem(at: root) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let replacement = root.appendingPathComponent("Replacement.mp4")
        try Data("copied bytes".utf8).write(to: replacement)
        let manifest = editor.mediaManifest
        let timeline = editor.timeline
        undo.beginUndoGrouping()
        await editor.relinkAsset(id: asset.id, to: replacement)
        undo.endUndoGrouping()
        let linked = editor.mediaManifest
        let linkedURL = asset.url
        #expect(linked != manifest)
        #expect(try Data(contentsOf: linkedURL) == Data("copied bytes".utf8))
        undo.undo()
        #expect(editor.mediaManifest == manifest)
        #expect(editor.timeline == timeline)
        #expect(editor.mediaAssets.first === asset)
        #expect(asset.originalFilename == "Original.mp4")
        undo.redo()
        #expect(editor.mediaManifest == linked)
        #expect(asset.url == linkedURL)
        #expect(editor.timeline == timeline)
        #expect(editor.mediaAssets.first === asset)
    }

    private func fixture() throws -> (EditorViewModel, URL, MediaAsset) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relink-owner-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Relink.ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let home = try #require(editor.workingRoot)
        let asset = MediaAsset(id: "original", url: home.appendingPathComponent("media/missing.mp4"), type: .video,
            name: "Opening", duration: 2, originalFilename: "Original.mp4")
        asset.sourceWidth = 320; asset.sourceHeight = 180; asset.sourceFPS = 30
        editor.mediaAssets = [asset]
        editor.mediaManifest.entries = [asset.toManifestEntry(projectURL: home)]
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "same-instance", mediaRef: asset.id, start: 0, duration: 30)
        ])])
        editor.missingMediaRefs = [asset.id]
        return (editor, root, asset)
    }
}
