import AppKit
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Storyboard history is committed before UI refresh")
struct PipelineStoryboardPublicationHistoryTests {
    @Test func nativeUndoAtPublicationNotificationRestoresThePublishedEdit() async throws {
        let (context, board) = try await fixture()
        defer { context.document.close() }
        let shot = try #require(board.timing.shots.first), moment = try #require(shot.moments.first)
        let manager = PipelineStoryboardEditor.undoManager(editor: context.editor)
        var notified = false
        var undoWasAvailable = false
        context.editor.onPipelineChanged = {
            guard !notified else { return }
            notified = true
            undoWasAvailable = manager.canUndo
            if undoWasAvailable { manager.undo() }
        }
        let changed = try await PipelineStoryboardEditor.apply(.setMomentIntent(shotID: shot.id, momentID: moment.id,
            intent: "A visible turn toward the doorway"), expectedFingerprint: board.fingerprint, editor: context.editor)
        #expect(changed.fingerprint != board.fingerprint)
        #expect(notified && undoWasAvailable)
        let restored = try await PipelineStoryboardEditor.waitForPendingRestore(editor: context.editor)
        #expect(restored.timing.shots.first?.moments.first?.intent == moment.intent)
        #expect(manager.canRedo)
        manager.redo()
        let redone = try await PipelineStoryboardEditor.waitForPendingRestore(editor: context.editor)
        #expect(redone.timing.shots.first?.moments.first?.intent == "A visible turn toward the doorway")
    }

    @Test func unchangedCommandDoesNotRegisterUndoOrPublishAnotherRevision() async throws {
        let (context, board) = try await fixture()
        defer { context.document.close() }
        let shot = try #require(board.timing.shots.first), moment = try #require(shot.moments.first)
        let manager = PipelineStoryboardEditor.undoManager(editor: context.editor)
        let unchanged = try await PipelineStoryboardEditor.apply(.setMomentIntent(shotID: shot.id,
            momentID: moment.id, intent: moment.intent), expectedFingerprint: board.fingerprint, editor: context.editor)
        #expect(unchanged.fingerprint == board.fingerprint)
        #expect(!manager.canUndo)
        #expect(try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false).fingerprint == board.fingerprint)
    }

    @Test func documentCloseAtPublicationNotificationCannotRegisterHistoryInTheClosedEditor() async throws {
        let (context, board) = try await fixture()
        let shot = try #require(board.timing.shots.first), moment = try #require(shot.moments.first)
        var notified = false
        context.editor.onPipelineChanged = {
            guard !notified else { return }
            notified = true
            context.document.close()
        }
        _ = try await PipelineStoryboardEditor.apply(.setMomentIntent(shotID: shot.id, momentID: moment.id,
            intent: "A turn before the document closes"), expectedFingerprint: board.fingerprint, editor: context.editor)
        #expect(notified)
        #expect(!PipelineStoryboardEditor.undoManager(editor: context.editor).canUndo)
    }

    private func fixture() async throws -> (ProductionPlanningAcceptanceFixture.Context, StoryboardBundleSnapshot) {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        return (context, try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: context))
    }
}
