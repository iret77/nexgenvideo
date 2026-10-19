import AppKit
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Visible media selection")
struct MediaSelectionTests {
    @Test func commandTogglesAndShiftSelectsContiguousDisplayedRange() {
        let editor = fixture()
        editor.updateMediaPanelItems(["d", "c", "b", "a"])
        editor.selectMediaPanelItem("d")
        editor.selectMediaPanelItem("b", modifiers: .shift)
        #expect(editor.selectedMediaAssetIds == ["d", "c", "b"])
        editor.selectMediaPanelItem("c", modifiers: .command)
        #expect(editor.selectedMediaAssetIds == ["d", "b"])
        editor.selectMediaPanelItem("a", modifiers: [.command, .shift])
        #expect(editor.selectedMediaAssetIds == ["d", "c", "b", "a"])
    }

    @Test func commandDeselectDoesNotOpenOrActivateTheRemovedAsset() {
        let editor = fixture()
        editor.updateMediaPanelItems(["a", "b", "c", "d"])
        editor.selectAllMediaPanelItems()
        #expect(editor.previewTabs == [.timeline])
        editor.selectMediaPanelItem("b", modifiers: .command)
        #expect(editor.selectedMediaAssetIds == ["a", "c", "d"])
        #expect(editor.previewTabs == [.timeline])
        #expect(editor.activePreviewTab == .timeline)
        editor.selectMediaPanelItem("b", modifiers: .command)
        #expect(editor.selectedMediaAssetIds == ["a", "b", "c", "d"])
        #expect(editor.activePreviewTab.id == PreviewTab.mediaAsset(id: "b", name: "b", type: .image).id)
        let tabs = editor.previewTabs
        let active = editor.activePreviewTabId
        editor.selectMediaPanelItem("a", modifiers: .command)
        #expect(editor.selectedMediaAssetIds == ["b", "c", "d"])
        #expect(editor.previewTabs == tabs && editor.activePreviewTabId == active)
    }

    @Test func filteringPrunesHiddenAssetsAndSelectAllUsesVisibleRowsOnly() {
        let editor = fixture()
        editor.updateMediaPanelItems(["a", "b", "c", "d"])
        editor.selectAllMediaPanelItems()
        editor.updateMediaPanelItems(["c", "d"])
        #expect(editor.selectedMediaAssetIds == ["c", "d"])
        #expect(editor.mediaPanelSelectionAnchor == nil)
        editor.clearMediaPanelSelection()
        editor.selectAllMediaPanelItems()
        #expect(editor.selectedMediaAssetIds == ["c", "d"])
        #expect(editor.timeline.tracks.isEmpty)
    }

    @Test func mixedFolderAndAssetRangeKeepsTypedIdentityAndInspectorHonest() {
        let editor = fixture()
        editor.mediaManifest.folders = [.init(id: "folder", name: "Folder")]
        editor.updateMediaPanelItems([MediaPanelItemKey.folder("folder"), "a", "b"])
        editor.selectMediaPanelItem(MediaPanelItemKey.folder("folder"))
        editor.selectMediaPanelItem("a", modifiers: .shift)
        #expect(editor.inspectedObject == nil)
        editor.selectMediaPanelItem("b", modifiers: .shift)
        #expect(editor.selectedFolderIds == ["folder"] && editor.selectedMediaAssetIds == ["a", "b"])
        #expect(editor.inspectedObject == nil)
        editor.updateMediaPanelItems(["a", "b"])
        #expect(editor.selectedFolderIds.isEmpty)
    }

    private func fixture() -> EditorViewModel {
        let editor = EditorViewModel()
        editor.timeline.tracks = []
        editor.mediaAssets = ["a", "b", "c", "d"].map {
            MediaAsset(id: $0, url: URL(fileURLWithPath: "/" + $0 + ".png"), type: .image, name: $0)
        }
        return editor
    }
}
