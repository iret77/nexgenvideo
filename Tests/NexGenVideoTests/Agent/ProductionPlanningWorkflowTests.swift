import AppKit
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Production planning through real writers and approval gates")
struct ProductionPlanningWorkflowTests {
    @Test func missingAndChangedSketchesBlockApprovalButRemainRepairable() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeScript()
        try await ProductionPlanningAcceptanceFixture.approve("script", in: fixture)
        let missing = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: fixture)
        #expect(missing.timing.shots.count == 2)
        await #expect(throws: (any Error).self) {
            try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: fixture)
        }
        let assigned = try await ProductionPlanningAcceptanceFixture.attachSketches(in: fixture)
        #expect(assigned.timing.shots.map(\.id) == missing.timing.shots.map(\.id))
        let image = try #require(assigned.timing.shots.first?.moments.first?.asset?.image)
        let imageURL = fixture.dataRoot.appendingPathComponent(image.path)
        try Data("changed image bytes".utf8).write(to: imageURL)
        await #expect(throws: (any Error).self) {
            try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: fixture)
        }
        let repairable = try PlanningWriterIO.storyboard(dataRoot: fixture.dataRoot, requireVisuals: false)
        #expect(repairable.timing.shots.map(\.id) == assigned.timing.shots.map(\.id))
        let repaired = try await ProductionPlanningAcceptanceFixture.attachSketches(in: fixture)
        #expect(repaired.fingerprint != assigned.fingerprint)
        try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: fixture)
        #expect(fixture.editor.projectState?.nextPhaseName == "shot_planning")
        let draft = try await ProductionPlanningAcceptanceFixture.writeShotPlanning(in: fixture)
        #expect(draft.shots.map(\.shotID) == assigned.timing.shots.map(\.id))
    }

    @Test func staleNativeStoryboardEditCannotOverwriteANewerRevision() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeScript()
        try await ProductionPlanningAcceptanceFixture.approve("script", in: fixture)
        _ = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: fixture)
        let original = try await ProductionPlanningAcceptanceFixture.attachSketches(in: fixture)
        let reordered = try await PipelineStoryboardEditor.apply(.reorder(shotIDs: Array(original.timing.shots.map(\.id).reversed())),
            expectedFingerprint: original.fingerprint, editor: fixture.editor)
        #expect(reordered.fingerprint != original.fingerprint)
        let before = try Data(contentsOf: fixture.dataRoot.appendingPathComponent(StoryboardTimingV1.currentPath))
        await #expect(throws: (any Error).self) {
            try await PipelineStoryboardEditor.apply(.reorder(shotIDs: original.timing.shots.map(\.id)),
                expectedFingerprint: original.fingerprint, editor: fixture.editor)
        }
        #expect(try Data(contentsOf: fixture.dataRoot.appendingPathComponent(StoryboardTimingV1.currentPath)) == before)
        let restored = try await PipelineStoryboardEditor.undo(expectedFingerprint: reordered.fingerprint, editor: fixture.editor)
        #expect(restored.timing.shots.map(\.id) == original.timing.shots.map(\.id))
        let redone = try await PipelineStoryboardEditor.redo(expectedFingerprint: restored.fingerprint, editor: fixture.editor)
        #expect(redone.timing.shots.map(\.id) == reordered.timing.shots.map(\.id))
        #expect(redone.storyboard.header.revision > restored.storyboard.header.revision)
        _ = try await PipelineStoryboardEditor.undo(expectedFingerprint: redone.fingerprint, editor: fixture.editor)
        try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: fixture)
    }
    @Test func rapidNativeUndoAndRedoSerializeRealWriterRevisions() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeScript()
        try await ProductionPlanningAcceptanceFixture.approve("script", in: fixture)
        _ = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: fixture)
        let original = try await ProductionPlanningAcceptanceFixture.attachSketches(in: fixture)
        let moved = try await PipelineStoryboardEditor.apply(.reorder(shotIDs: Array(original.timing.shots.map(\.id).reversed())),
            expectedFingerprint: original.fingerprint, editor: fixture.editor)
        let shot = try #require(moved.timing.shots.first)
        let moment = try #require(shot.moments.first)
        let edited = try await PipelineStoryboardEditor.apply(.setMoment(shotID: shot.id, momentID: moment.id,
            offsetTicks: moment.offsetTicks, intent: "Native second revision"), expectedFingerprint: moved.fingerprint, editor: fixture.editor)
        let manager = PipelineStoryboardEditor.undoManager(editor: fixture.editor)
        manager.undo()
        manager.undo()
        #expect(throws: PipelineStoryboardEditor.EditError.self) { try PipelineStoryboardEditor.requireAvailable(editor: fixture.editor) }
        let restored = try await PipelineStoryboardEditor.waitForPendingRestore(editor: fixture.editor)
        #expect(restored.timing.shots.map(\.id) == original.timing.shots.map(\.id))
        #expect(restored.timing.shots.flatMap(\.moments).map(\.intent) == original.timing.shots.flatMap(\.moments).map(\.intent))
        #expect(restored.sketchProblems.isEmpty)
        #expect(restored.timing.shots.flatMap(\.moments).map { $0.asset?.image } == original.timing.shots.flatMap(\.moments).map { $0.asset?.image })
        #expect(restored.storyboard.header.revision >= edited.storyboard.header.revision + 2)
        manager.redo()
        manager.redo()
        let redone = try await PipelineStoryboardEditor.waitForPendingRestore(editor: fixture.editor)
        #expect(redone.timing.shots.map(\.id) == edited.timing.shots.map(\.id))
        #expect(redone.timing.shots.flatMap(\.moments).map(\.intent) == edited.timing.shots.flatMap(\.moments).map(\.intent))
        #expect(redone.storyboard.header.revision >= restored.storyboard.header.revision + 2)
    }

    @Test func nativeStoryboardWindowRoutesItsActualUndoManagerAndPreservesDocumentUndoElsewhere() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeScript()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let controller = EditorWindowController(editorViewModel: fixture.editor, window: window)
        fixture.editor.workspaceFocus = .production
        fixture.editor.productionSelectedPhase = "storyboard"
        fixture.editor.focusedPanel = .project
        #expect(controller.windowWillReturnUndoManager(window) === PipelineStoryboardEditor.undoManager(editor: fixture.editor))
        fixture.editor.productionSelectedPhase = "shot_planning"
        #expect(controller.windowWillReturnUndoManager(window) === fixture.document.undoManager)
    }

}
