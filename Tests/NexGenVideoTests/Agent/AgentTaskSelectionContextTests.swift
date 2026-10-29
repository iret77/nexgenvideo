import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Task selection snapshots")
struct AgentTaskSelectionContextTests {
    @Test func timelineRangeFreezesItsClipBindingsAndSurvivesLaterWorkspaceChanges() throws {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.setWorkspaceFocus(.edit)
        editor.timeline = Timeline(fps: 30, tracks: [Track(id: "video", type: .video, clips: [
            Clip(id: "inside", mediaRef: "source", startFrame: 0, durationFrames: 90, trimStartFrame: 12),
            Clip(id: "outside", mediaRef: "other", startFrame: 100, durationFrames: 90),
        ])])
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        editor.selectedTimelineRange = .init(startFrame: 15, endFrame: 45)
        editor.currentFrame = 22
        editor.inspectedObject = .shot("old-shot")
        let task = try #require(editor.selectedObjectRevisionTask)
        #expect(task.title.contains("Timeline range"))
        #expect(editor.agentService.stageTask(task))
        editor.selectedTimelineRange = .init(startFrame: 60, endFrame: 90)
        editor.currentFrame = 70
        editor.setWorkspaceFocus(.production)
        editor.revealCockpit(.review)
        let frozen = try decode(#require(editor.agentService.pendingFunction?.originContext))
        #expect(frozen.timelineRange == .init(start: 15, end: 45))
        #expect(frozen.timelineFrame == 22)
        #expect(frozen.editingFPS == 30)
        #expect(frozen.clips.map(\.clipID) == ["inside"])
        #expect(frozen.clips.first?.trimStartFrame == 12)
        #expect(frozen.target?.contains("old-shot") == false)
        #expect(editor.agentService.pendingFunction?.title == task.title)
    }

    @Test func activeSourceUsesActualMarksAndEditingClock() throws {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let source = MediaAsset(id: "source", url: URL(fileURLWithPath: "/fixture/Source.mov"), type: .video,
            name: "Source.mov", duration: 8)
        editor.mediaAssets = [source]
        editor.timeline.fps = 30
        editor.setWorkspaceFocus(.edit)
        editor.openPreviewTab(for: source)
        editor.sourcePreviewStates[source.id] = .init(positionSeconds: 1, inSeconds: 0.5, outSeconds: 1.5, targetTrackID: "target")
        editor.sourcePlayheadFrame = 24
        editor.inspectedObject = .shot("hidden-shot")
        let task = try #require(editor.selectedObjectRevisionTask)
        let captured = try decode(#require(task.originContext))
        #expect(task.title.contains("Source.mov"))
        #expect(captured.source?.assetID == source.id)
        #expect(captured.source?.range == .init(start: 15, end: 45))
        #expect(captured.source?.inSeconds == 0.5)
        #expect(captured.source?.outSeconds == 1.5)
        #expect(captured.source?.playheadFrame == 24)
        #expect(captured.source?.targetTrackID == "target")
        #expect(captured.timelineRange == nil)
        #expect(captured.target?.contains("hidden-shot") == false)
    }

    @Test func productionFocusIgnoresHiddenTimelineRange() throws {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.setWorkspaceFocus(.production)
        editor.revealCockpit(.review)
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        editor.selectedTimelineRange = .init(startFrame: 15, endFrame: 45)
        editor.inspectedObject = .shot("selected-production-shot")
        let value = AgentTaskSelectionContext.capture(editor: editor)
        #expect(value.target == "shot ID selected-production-shot")
        #expect(value.timelineRange == nil)
    }

    @Test func visibleV2ShotBeatsStaleClipAndRange() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly()
        defer { context.document.close() }
        let editor = context.editor
        let snapshot = try #require(try ProductionPlanPresentation.load(dataRoot: context.dataRoot))
        let shot = try #require(snapshot.projection.shots.first)
        editor.setWorkspaceFocus(.production)
        editor.revealCockpit(.shotlist)
        editor.productionPlanSelection = .init(home: try #require(editor.workingRoot), snapshot: snapshot, shotID: shot.id)
        editor.inspectedObject = .clip("old-clip")
        editor.selectedTimelineRange = .init(startFrame: 15, endFrame: 45)
        let value = try decode(#require(editor.selectedObjectRevisionTask?.originContext))
        #expect(value.planningShotID == shot.id)
        #expect(value.planningRevision == snapshot.projection.header.revision)
        #expect(value.target == "production shot ID " + shot.id)
        #expect(value.timelineRange == nil)
        #expect(value.label == "Shot 1")
        editor.productionPlanSelection = nil
        editor.inspectedObject = .clip("hidden-old-clip")
        #expect(AgentTaskSelectionContext.capture(editor: editor).target == nil)
        editor.revealCockpit(.shotPlanning)
        #expect(AgentTaskSelectionContext.capture(editor: editor).target == nil)
    }

    @Test func ordinaryMessageSelectionDoesNotClaimAFrozenTask() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.setWorkspaceFocus(.edit)
        editor.inspectedObject = .look
        let context = AgentTaskSelectionContext.capture(editor: editor)
        #expect(context.hint.contains("this task's target"))
        #expect(!context.hint(frozenTask: false).contains("this task's target"))
        #expect(context.hint(frozenTask: false).contains("visible selection for this message"))
    }

    @Test func explicitTaskOriginAndPersistedDraftAreNotRebased() throws {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let task = AgentTask(title: "Original scope", systemImage: "pencil", prompt: "Keep this target.", originContext: "Original immutable scope")
        #expect(editor.agentService.stageTask(task))
        #expect(editor.agentService.pendingFunction?.originContext == task.originContext)
        let draft = ChatSessionDraft(text: "Direction", mentions: [], task: editor.agentService.pendingFunction)
        let restored = try JSONDecoder().decode(ChatSessionDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored == draft)
    }

    private func decode(_ hint: String) throws -> AgentTaskSelectionContext {
        let start = try #require(hint.firstIndex(of: "{")), end = try #require(hint.lastIndex(of: "}"))
        return try JSONDecoder().decode(AgentTaskSelectionContext.self, from: Data(hint[start...end].utf8))
    }
}
