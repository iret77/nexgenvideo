import Foundation
import Testing
@testable import NexGenVideo

@Suite("Workspace media browser state")
@MainActor
struct MediaBrowserStateTests {
    @Test("browser filters, folder, and scroll position survive remounts independently")
    func independentBrowsers() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let media = editor.mediaBrowserState(for: .media)
        media.searchQuery = "scene"
        media.filterTypes = [.document]
        media.currentFolderId = "scripts"
        media.viewMode = .list
        media.scrollAssetID = "last-script"
        let edit = editor.mediaBrowserState(for: .edit)
        #expect(edit !== media)
        #expect(edit.viewMode == .flat)
        #expect(edit.searchQuery.isEmpty)
        edit.searchQuery = "take"
        #expect(editor.mediaBrowserState(for: .media) === media)
        #expect(media.searchQuery == "scene")
        #expect(media.currentFolderId == "scripts")
        #expect(media.scrollAssetID == "last-script")
    }

    @Test("source ranges are restored with their workspace without modifying timeline data")
    func sourceRangesPerWorkspace() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.timeline.fps = 30
        let source = MediaAsset(id: "source", url: URL(fileURLWithPath: "/missing/source.mov"),
                               type: .video, name: "Source", duration: 10)
        editor.mediaAssets = [source]
        let timeline = editor.timeline
        editor.setWorkspaceFocus(.edit)
        editor.selectMediaAsset(source, atSourceFrame: 30)
        editor.markSourceIn(source)
        editor.setWorkspaceFocus(.media)
        editor.selectMediaAsset(source, atSourceFrame: 90)
        editor.markSourceIn(source)
        editor.setWorkspaceFocus(.edit)
        #expect(editor.sourcePlayheadFrame == 30)
        #expect(editor.sourceFrameRange(for: source)?.lowerBound == 30)
        editor.setWorkspaceFocus(.media)
        #expect(editor.sourcePlayheadFrame == 90)
        #expect(editor.sourceFrameRange(for: source)?.lowerBound == 90)
        #expect(editor.timeline == timeline)
    }
    @Test("folder rename reveals its parent without changing the edit browser or timeline")
    func folderRenameTargetsMediaBrowser() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let parent = editor.createFolder(name: "Parent")
        let child = editor.createFolder(name: "Child", in: parent)
        let media = editor.mediaBrowserState(for: .media)
        media.viewMode = .list
        media.searchQuery = "unrelated search"
        let edit = editor.mediaBrowserState(for: .edit)
        edit.searchQuery = "edit search"
        let timeline = editor.timeline

        editor.requestMediaFolderRename(child)

        #expect(media.currentFolderId == parent)
        #expect(media.pendingRenameFolderID == child)
        #expect(media.viewMode == .folder)
        #expect(media.searchQuery.isEmpty)
        #expect(edit.searchQuery == "edit search")
        #expect(edit.pendingRenameFolderID == nil)
        #expect(editor.timeline == timeline)
        #expect(editor.folder(id: child)?.name == "Child")
    }

}
