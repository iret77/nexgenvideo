import Foundation
import Testing
@testable import NexGenVideo

@Suite("Media context commands")
@MainActor
struct MediaContextCommandTests {
    @Test func contextClickPreservesMixedSelectionAndDoesNotDelete() {
        let editor = EditorViewModel()
        let folder = editor.createFolder(name: "Shots")
        let other = editor.createFolder(name: "Audio")
        let asset = MediaAsset(id: "asset", url: URL(fileURLWithPath: "/tmp/context.mov"), type: .video, name: "Context")
        editor.mediaAssets = [asset]
        editor.selectedFolderIds = [folder]
        editor.selectedMediaAssetIds = [asset.id]
        editor.activateMediaContext(asset)
        #expect(editor.selectedFolderIds == [folder])
        editor.activateFolderContext(folder)
        #expect(editor.selectedMediaAssetIds == [asset.id])
        #expect(editor.mediaAssets.count == 1)
        #expect(editor.folders.count == 2)
        editor.activateFolderContext(other)
        #expect(editor.selectedFolderIds == [other])
        #expect(editor.selectedMediaAssetIds.isEmpty)
        #expect(editor.focusedPanel == .media)
    }

    @Test func mixedDeletionHasOneUndoAndRestoresSelection() {
        let editor = EditorViewModel()
        let folder = editor.createFolder(name: "Shots")
        let asset = MediaAsset(id: "asset", url: URL(fileURLWithPath: "/tmp/context.mov"), type: .video, name: "Context")
        editor.mediaAssets = [asset]
        editor.selectedFolderIds = [folder]
        editor.selectedMediaAssetIds = [asset.id]
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        #expect(editor.deleteMediaSelection())
        #expect(editor.folders.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
        undo.undo()
        #expect(editor.folders.map(\.id) == [folder])
        #expect(editor.mediaAssets.map(\.id) == [asset.id])
        #expect(editor.selectedFolderIds == [folder])
        #expect(editor.selectedMediaAssetIds == [asset.id])
        #expect(!undo.canUndo)
        undo.redo()
        #expect(editor.folders.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
    }
    @Test func previewFallbackIsNeverAddedToTheDeletionScope() {
        let editor = EditorViewModel()
        let folder = editor.createFolder(name: "Shots")
        let inside = MediaAsset(id: "inside", url: URL(fileURLWithPath: "/tmp/inside.mov"), type: .video, name: "Inside")
        inside.folderId = folder
        let outside = MediaAsset(id: "outside", url: URL(fileURLWithPath: "/tmp/outside.mov"), type: .video, name: "Outside")
        editor.mediaAssets = [inside, outside]
        editor.selectMediaAsset(outside)
        editor.selectMediaAsset(inside)
        editor.selectedFolderIds = [folder]
        #expect(editor.deleteMediaSelection())
        #expect(editor.mediaAssets.map(\.id) == [outside.id])
        #expect(editor.folders.isEmpty)
    }

}
