import Foundation
import Testing
@testable import NexGenVideo

@Suite("Direct source preview selection")
@MainActor
struct SourcePreviewSelectionTests {
    @Test("source positions survive direct source and timeline selection without moving the film playhead")
    func independentPlayheads() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.timeline.fps = 24
        editor.currentFrame = 48
        let first = asset("first")
        let second = asset("second")
        editor.mediaAssets = [first, second]
        editor.selectedClipIds = ["remembered-clip"]

        editor.selectMediaAsset(first, atSourceFrame: 72)
        editor.sourcePlayheadFrame = 96
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        #expect(editor.currentFrame == 48)
        #expect(editor.selectedMediaAssetIds == [first.id])
        #expect(editor.selectedClipIds == ["remembered-clip"])

        editor.selectMediaAsset(first)
        #expect(editor.sourcePlayheadFrame == 96)
        #expect(editor.inspectedObject == .mediaAsset(first.id))
        editor.selectMediaAsset(second, atSourceFrame: 12)
        editor.selectMediaAsset(first)
        #expect(editor.sourcePlayheadFrame == 96)
        editor.selectMediaAsset(second)
        #expect(editor.sourcePlayheadFrame == 12)
        #expect(editor.currentFrame == 48)
    }

    @Test("an explicit transcript hit seeks while ordinary reselection remembers the position")
    func explicitSeek() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.timeline.fps = 24
        let source = asset("source")
        editor.mediaAssets = [source]
        editor.selectMediaAsset(source, atSourceFrame: 120)
        editor.selectMediaAsset(source)
        #expect(editor.sourcePlayheadFrame == 120)
        editor.selectMediaAsset(source, atSourceFrame: 0)
        #expect(editor.sourcePlayheadFrame == 0)
    }

    @Test("remembered source positions use source time across timeline framerate changes")
    func frameRateChange() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.timeline.fps = 24
        let source = asset("source")
        editor.mediaAssets = [source]
        editor.selectMediaAsset(source, atSourceFrame: 72)
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        editor.timeline.fps = 48
        editor.selectMediaAsset(source)
        #expect(editor.sourcePlayheadFrame == 144)
    }

    @Test("source ranges and transport stay independent of a remembered timeline selection")
    func rangesAndTransport() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.timeline.fps = 30
        editor.currentFrame = 90
        let first = asset("first")
        let second = asset("second")
        editor.mediaAssets = [first, second]
        editor.selectMediaAsset(first, atSourceFrame: 59)
        editor.markSourceIn(first)
        editor.seekSourceToFrame(62)
        editor.markSourceOut(first)
        editor.stepActivePreview(by: 5)
        #expect(editor.sourcePlayheadFrame == 67)
        #expect(editor.currentFrame == 90)
        editor.selectMediaAsset(second)
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        editor.selectMediaAsset(first)
        #expect(editor.sourcePlayheadFrame == 67)
        #expect(editor.sourceFrameRange(for: first) == 59..<62)
        editor.clearSourceRange(first)
        #expect(editor.sourceFrameRange(for: first) == 0..<300)
    }

    @Test("context activation preserves a selected group and replaces an unrelated selection")
    func contextSelection() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let first = asset("first"), second = asset("second"), third = asset("third")
        editor.mediaAssets = [first, second, third]
        editor.selectedClipIds = ["remembered"]
        editor.selectedMediaAssetIds = [first.id, second.id]
        editor.activateMediaContext(first)
        #expect(editor.selectedMediaAssetIds == [first.id, second.id])
        #expect(editor.activePreviewTab == .mediaAsset(id: first.id, name: first.name, type: first.type))
        #expect(editor.selectedClipIds == ["remembered"])
        editor.activateMediaContext(third)
        #expect(editor.selectedMediaAssetIds == [third.id])
        #expect(editor.inspectedObject == .mediaAsset(third.id))
    }

    @Test("insert and overwrite preserve exact frame bounds and undo the entire edit", arguments: [false, true])
    func exactSourceEdit(overwrite: Bool) throws {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.setWorkspaceFocus(.edit)
        editor.timeline.fps = 30
        editor.currentFrame = 20
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data("fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = MediaAsset(id: "source", url: url, type: .video, name: "source", duration: 10)
        editor.mediaAssets = [source]
        let original = Clip(mediaRef: "other", mediaType: .video, startFrame: 0, durationFrames: 100)
        editor.timeline.tracks = [Track(id: "target", type: .video, clips: [original])]
        editor.selectMediaAsset(source, atSourceFrame: 59)
        editor.markSourceIn(source)
        editor.seekSourceToFrame(62)
        editor.markSourceOut(source)
        editor.sourcePreviewStates[source.id]?.targetTrackID = "target"
        let before = editor.timeline
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        undo.beginUndoGrouping()
        #expect(editor.editSource(source, operation: overwrite ? .overwrite : .insert))
        undo.endUndoGrouping()
        let placed = try #require(editor.timeline.tracks.flatMap(\.clips).first { $0.mediaRef == source.id })
        #expect(placed.startFrame == 20)
        #expect(placed.durationFrames == 3)
        #expect(placed.trimStartFrame == 59)
        #expect(placed.trimEndFrame == 238)
        #expect(editor.timeline.totalFrames == (overwrite ? 100 : 103))
        #expect(editor.currentFrame == 20)
        #expect(editor.sourcePlayheadFrame == 62)
        #expect(editor.inspectedObject == .mediaAsset(source.id))
        let after = editor.timeline
        undo.undo()
        #expect(editor.timeline == before)
        #expect(editor.sourceFrameRange(for: source) == 59..<62)
        undo.redo()
        #expect(editor.timeline == after)
    }

    @Test("offline sources and documents cannot mutate the timeline")
    func unavailableSource() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.setWorkspaceFocus(.edit)
        let source = asset(UUID().uuidString)
        editor.mediaAssets = [source]
        editor.selectMediaAsset(source)
        let before = editor.timeline
        #expect(editor.sourceEditUnavailableReason(for: source) != nil)
        #expect(!editor.editSource(source, operation: .insert))
        #expect(editor.timeline == before)
        let document = MediaAsset(id: "doc", url: source.url, type: .document, name: "notes", duration: 10)
        editor.mediaAssets.append(document)
        editor.selectMediaAsset(document)
        editor.markSourceIn(document)
        #expect(editor.sourceFrameRange(for: document) == nil)
        #expect(!editor.editSource(document, operation: .overwrite))
        #expect(editor.timeline == before)
    }

    @Test("deleting the active source chooses a surviving source and undo restores its context")
    func deleteSourceUndo() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let first = asset("first"), second = asset("second")
        editor.mediaAssets = [first, second]
        editor.selectMediaAsset(first, atSourceFrame: 30)
        editor.markSourceIn(first)
        editor.selectMediaAsset(second, atSourceFrame: 60)
        editor.markSourceIn(second)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        undo.beginUndoGrouping()
        editor.deleteMediaAssets(ids: [second.id])
        undo.endUndoGrouping()
        #expect(editor.inspectedObject == .mediaAsset(first.id))
        #expect(editor.selectedMediaAssetIds == [first.id])
        #expect(editor.sourcePlayheadFrame == 30)
        undo.undo()
        #expect(editor.inspectedObject == .mediaAsset(second.id))
        #expect(editor.selectedMediaAssetIds == [second.id])
        #expect(editor.sourcePlayheadFrame == 60)
        #expect(editor.sourceFrameRange(for: second)?.lowerBound == 60)
        editor.goBackPreviewTab()
        #expect(editor.inspectedObject == .mediaAsset(first.id))
        undo.redo()
        #expect(!editor.mediaAssets.contains { $0.id == second.id })
    }

    @Test("a shorter relinked source clamps the remembered range to an editable frame")
    func shorterRelink() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.timeline.fps = 30
        let source = asset("source")
        editor.mediaAssets = [source]
        editor.selectMediaAsset(source, atSourceFrame: 240)
        editor.markSourceIn(source)
        source.duration = 1
        #expect(editor.sourceFrameRange(for: source) == 29..<30)
        editor.clearSourceRange(source)
        #expect(editor.sourceFrameRange(for: source) == 0..<30)
    }

    private func asset(_ id: String) -> MediaAsset {
        MediaAsset(
            id: id, url: URL(fileURLWithPath: "/tmp/\(id).mov"),
            type: .video, name: id, duration: 10
        )
    }
}
