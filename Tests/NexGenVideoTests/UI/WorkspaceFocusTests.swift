import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Workspace focus", .serialized)
struct WorkspaceFocusTests {
    @Test func canonicalOrderAndLabels() {
        #expect(EditorViewModel.WorkspaceFocus.allCases == [
            .media, .production, .edit, .postproduction, .export,
        ])
        #expect(EditorViewModel.WorkspaceFocus.allCases.map(\.label) == [
            "Media", "Production", "Edit", "Postproduction", "Export",
        ])
    }

    @Test func persistedValuesMigrateAndUnknownValuesFailSafe() {
        let expected: [(String?, EditorViewModel.WorkspaceFocus)] = [
            ("media", .media),
            ("produce", .production),
            ("production", .production),
            ("edit", .edit),
            ("post", .postproduction),
            ("postproduction", .postproduction),
            ("finish", .export),
            ("export", .export),
            ("future-workspace", .production),
            (nil, .production),
        ]

        for (rawValue, focus) in expected {
            #expect(EditorViewModel.WorkspaceFocus(persistedValue: rawValue) == focus)
        }
    }

    @Test func switchingPreservesEditProjectAndUndoState() {
        let editor = EditorViewModel()
        var clip = Clip(mediaRef: "asset-1", startFrame: 0, durationFrames: 60)
        clip.id = "clip-1"
        var timeline = Timeline()
        timeline.fps = 24
        timeline.settingsConfigured = true
        timeline.tracks = [Track(type: .video, clips: [clip])]
        editor.timeline = timeline
        editor.mediaAssets = [MediaAsset(
            id: "asset-1",
            url: URL(fileURLWithPath: "/tmp/asset-1.mov"),
            type: .video,
            name: "Asset 1"
        )]
        editor.selectedClipIds = ["clip-1"]
        editor.selectedMediaAssetIds = ["asset-1"]
        editor.selectedTimelineRange = TimelineRangeSelection(startFrame: 12, endFrame: 48)
        editor.inspectedObject = .clip("clip-1")
        editor.toolMode = .razor
        editor.pendingSwapClipId = "clip-1"
        editor.cropEditingActive = true

        let undoManager = UndoManager()
        undoManager.registerUndo(withTarget: editor) { _ in }
        undoManager.setActionName("Sentinel")
        editor.undoManager = undoManager

        let originalTimeline = editor.timeline
        let originalManifest = editor.mediaManifest
        let originalRange = editor.selectedTimelineRange

        for focus in EditorViewModel.WorkspaceFocus.allCases {
            editor.setWorkspaceFocus(focus)
        }
        editor.setWorkspaceFocus(.production)

        #expect(editor.timeline == originalTimeline)
        #expect(editor.mediaManifest == originalManifest)
        #expect(editor.selectedClipIds == ["clip-1"])
        #expect(editor.selectedMediaAssetIds == ["asset-1"])
        #expect(editor.selectedTimelineRange == originalRange)
        #expect(editor.inspectedObject == .clip("clip-1"))
        #expect(editor.pendingSwapClipId == "clip-1")
        #expect(editor.cropEditingActive)
        if case .razor = editor.toolMode {} else {
            Issue.record("Workspace switching changed the active edit tool")
        }
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "Sentinel")
    }

    @Test func panelPresentationIsIndependentPerWorkspace() {
        let restoreDefaults = preservePanelDefaults()
        defer { restoreDefaults() }
        let editor = EditorViewModel()

        editor.setWorkspaceFocus(.production)
        editor.mediaPanelVisible = false
        editor.inspectorPanelVisible = true
        editor.focusedPanel = .project
        editor.maximizedPanel = .project

        editor.setWorkspaceFocus(.edit)
        editor.mediaPanelVisible = true
        editor.inspectorPanelVisible = false
        editor.focusedPanel = .timeline
        editor.maximizedPanel = .preview

        editor.setWorkspaceFocus(.production)
        #expect(!editor.mediaPanelVisible)
        #expect(editor.inspectorPanelVisible)
        #expect(editor.focusedPanel == .project)
        #expect(editor.maximizedPanel == .project)

        editor.setWorkspaceFocus(.edit)
        #expect(editor.mediaPanelVisible)
        #expect(!editor.inspectorPanelVisible)
        #expect(editor.focusedPanel == .timeline)
        #expect(editor.maximizedPanel == .preview)
    }

    @Test func mediaCommandOwnershipIsIndependentPerWorkspace() {
        let restoreDefaults = preservePanelDefaults()
        defer { restoreDefaults() }
        let editor = EditorViewModel()

        editor.setWorkspaceFocus(.media)
        editor.mediaPanelVisible = true
        editor.focusedPanel = .preview
        editor.mediaCommandFocus = .browser

        editor.setWorkspaceFocus(.edit)
        editor.mediaPanelVisible = true
        editor.focusedPanel = .media
        editor.mediaCommandFocus = .browser

        editor.setWorkspaceFocus(.production)
        editor.setWorkspaceFocus(.media)
        #expect(editor.focusedPanel == .preview)
        #expect(editor.mediaCommandFocus == .browser)

        editor.setWorkspaceFocus(.edit)
        #expect(editor.focusedPanel == .media)
        #expect(editor.mediaCommandFocus == .browser)
    }

    @Test func mediaCommandOwnershipDoesNotRestoreIntoAHiddenHost() {
        let restoreDefaults = preservePanelDefaults()
        defer { restoreDefaults() }
        let editor = EditorViewModel()

        editor.setWorkspaceFocus(.edit)
        editor.mediaPanelVisible = false
        editor.focusedPanel = .media
        editor.mediaCommandFocus = .browser
        editor.setWorkspaceFocus(.production)
        editor.setWorkspaceFocus(.edit)

        #expect(editor.mediaCommandFocus == nil)
    }

    @Test func restoringWorkspacePanelsDoesNotRewriteUserDefaults() {
        let restoreDefaults = preservePanelDefaults()
        defer { restoreDefaults() }
        let editor = EditorViewModel()

        editor.mediaPanelVisible = false
        editor.inspectorPanelVisible = false
        #expect(UserDefaults.standard.bool(forKey: "mediaPanelVisible") == false)
        #expect(UserDefaults.standard.bool(forKey: "inspectorPanelVisible") == false)

        editor.setWorkspaceFocus(.edit)

        #expect(UserDefaults.standard.bool(forKey: "mediaPanelVisible") == false)
        #expect(UserDefaults.standard.bool(forKey: "inspectorPanelVisible") == false)
    }

    @Test func selectionAndPreviewContextAreIndependentPerWorkspace() {
        let editor = EditorViewModel()
        var clip = Clip(mediaRef: "asset-1", startFrame: 0, durationFrames: 60)
        clip.id = "clip-1"
        editor.timeline.tracks = [Track(type: .video, clips: [clip])]
        let asset = MediaAsset(
            id: "asset-1",
            url: URL(fileURLWithPath: "/tmp/asset-1.mov"),
            type: .video,
            name: "Asset 1"
        )
        editor.mediaAssets = [asset]

        editor.selectedClipIds = [clip.id]
        editor.inspectedObject = .clip(clip.id)
        editor.currentFrame = 12

        editor.setWorkspaceFocus(.media)
        editor.selectMediaAsset(asset, atSourceFrame: 18)
        editor.inspectedObject = .mediaAsset(asset.id)

        editor.setWorkspaceFocus(.production)
        #expect(editor.selectedClipIds == [clip.id])
        #expect(editor.selectedMediaAssetIds.isEmpty)
        #expect(editor.inspectedObject == .clip(clip.id))
        #expect(editor.activePreviewTab == .timeline)
        #expect(editor.currentFrame == 12)

        editor.setWorkspaceFocus(.media)
        #expect(editor.selectedClipIds.isEmpty)
        #expect(editor.selectedMediaAssetIds == [asset.id])
        #expect(editor.inspectedObject == .mediaAsset(asset.id))
        #expect(editor.activePreviewTabId == PreviewTab.mediaAssetTabId(for: asset.id))
        #expect(editor.sourcePlayheadFrame == 18)
    }

    @Test func revealingAgentRoutesToProduction() {
        let restoreDefaults = preservePanelDefaults()
        defer { restoreDefaults() }
        let editor = EditorViewModel()
        editor.setWorkspaceFocus(.postproduction)

        editor.agentPanelVisible = true

        #expect(editor.workspaceFocus == .production)
        #expect(editor.mediaPanelVisible)
        #expect(editor.leftSidebarTab == .agent)

        editor.maximizedPanel = .agent
        editor.agentPanelVisible = false

        #expect(!editor.mediaPanelVisible)
        #expect(!editor.agentPanelVisible)
        #expect(editor.maximizedPanel == nil)
    }

    @Test func panelToggleExitsMaximizeAndRevealsRequestedSide() {
        let restoreDefaults = preservePanelDefaults()
        defer { restoreDefaults() }
        let editor = EditorViewModel()

        editor.mediaPanelVisible = false
        editor.maximizedPanel = .preview
        editor.toggleSidebarPresentation()

        #expect(editor.maximizedPanel == nil)
        #expect(editor.mediaPanelVisible)
        #expect(editor.isSidebarPresented)

        editor.inspectorPanelVisible = false
        editor.maximizedPanel = .preview
        editor.toggleInspectorPresentation()

        #expect(editor.maximizedPanel == nil)
        #expect(editor.inspectorPanelVisible)
        #expect(editor.isInspectorPresented)

        editor.setWorkspaceFocus(.media)
        editor.mediaPanelVisible = true
        editor.maximizedPanel = .media
        editor.toggleSidebarPresentation()

        #expect(editor.maximizedPanel == nil)
        #expect(!editor.mediaPanelVisible)

        editor.theaterActive = true
        editor.maximizedPanel = .preview
        editor.toggleSidebarPresentation()

        #expect(!editor.theaterActive)
        #expect(editor.maximizedPanel == nil)
        #expect(editor.mediaPanelVisible)
    }

    @Test func mediaPresentationIsIndependentPerWorkspace() {
        let editor = EditorViewModel()

        editor.setWorkspaceFocus(.media)
        editor.setMediaPanelTab(.music, for: .media)
        editor.publishMediaPanelFolder("media-folder", for: .media)

        editor.setWorkspaceFocus(.edit)
        editor.setMediaPanelTab(.captions, for: .edit)
        editor.publishMediaPanelFolder("edit-folder", for: .edit)

        #expect(editor.mediaPanelTab(for: .media) == .music)
        #expect(editor.mediaPanelTab(for: .edit) == .captions)

        editor.setWorkspaceFocus(.media)
        #expect(editor.mediaPanelTab == .music)
        #expect(editor.mediaPanelCurrentFolderId == "media-folder")

        editor.setWorkspaceFocus(.edit)
        #expect(editor.mediaPanelTab == .captions)
        #expect(editor.mediaPanelCurrentFolderId == "edit-folder")
    }

    @Test func revealingMediaToolsMountsAVisibleMediaHost() {
        let restoreDefaults = preservePanelDefaults()
        defer { restoreDefaults() }
        let editor = EditorViewModel()
        editor.setWorkspaceFocus(.postproduction)
        editor.mediaPanelVisible = false
        editor.maximizedPanel = .preview

        editor.revealMediaTools()

        #expect(editor.workspaceFocus == .media)
        #expect(editor.mediaPanelVisible)
        #expect(editor.maximizedPanel == nil)
        #expect(editor.focusedPanel == .preview)
        #expect(editor.mediaCommandFocus == .browser)
        #expect(editor.mediaPanelTab == .assets)

        editor.setWorkspaceFocus(.edit)
        editor.mediaPanelVisible = false
        editor.maximizedPanel = .preview

        editor.revealMediaTools()

        #expect(editor.workspaceFocus == .edit)
        #expect(editor.mediaPanelVisible)
        #expect(editor.maximizedPanel == nil)
        #expect(editor.focusedPanel == .media)
        #expect(editor.mediaCommandFocus == .browser)
        #expect(editor.mediaPanelTab == .assets)
    }

    private func preservePanelDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let sidebar = defaults.object(forKey: "mediaPanelVisible")
        let inspector = defaults.object(forKey: "inspectorPanelVisible")
        let sidebarTab = defaults.object(forKey: "leftSidebarTab")
        return {
            if let sidebar { defaults.set(sidebar, forKey: "mediaPanelVisible") }
            else { defaults.removeObject(forKey: "mediaPanelVisible") }
            if let inspector { defaults.set(inspector, forKey: "inspectorPanelVisible") }
            else { defaults.removeObject(forKey: "inspectorPanelVisible") }
            if let sidebarTab { defaults.set(sidebarTab, forKey: "leftSidebarTab") }
            else { defaults.removeObject(forKey: "leftSidebarTab") }
        }
    }
}
