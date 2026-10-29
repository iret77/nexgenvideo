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
        defer { fixture.document.close() }
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
        let firstImage = try #require(repaired.timing.shots.first?.moments.first?.asset?.image)
        let target = try #require(repaired.timing.shots.last)
        let targetMoment = try #require(target.moments.first)
        let duplicated = try await PipelineStoryboardEditor.attachImage(
            from: fixture.dataRoot.appendingPathComponent(firstImage.path), shotID: target.id, momentID: targetMoment.id,
            expectedFingerprint: repaired.fingerprint, editor: fixture.editor)
        let secondImage = try #require(duplicated.timing.shots.last?.moments.first?.asset?.image)
        #expect(firstImage.id == secondImage.id)
        #expect(firstImage.sha256 == secondImage.sha256)
        #expect(firstImage.path != secondImage.path)
        try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: fixture)
        #expect(fixture.editor.projectState?.nextPhaseName == "shot_planning")
        let draft = try await ProductionPlanningAcceptanceFixture.writeShotPlanning(in: fixture)
        #expect(draft.shots.map(\.shotID) == assigned.timing.shots.map(\.id))
        #expect(Set(draft.header.inputs.map(\.id)).count == draft.header.inputs.count)
        #expect(Set(draft.header.inputs.map(\.path)) == Set(duplicated.references.map(\.path)))
        for reference in duplicated.references {
            #expect(draft.header.inputs.contains { $0.path == reference.path && $0.sha256 == reference.sha256 && $0.role == reference.role })
        }
        var imported = draft
        let video = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        for (index, original) in draft.shots.enumerated() {
            let candidate = ShotPlanningDraftV1.ShotIntent(shotID: original.shotID, sourceMode: .imported,
                camera: original.camera, obligations: [])
            imported = try await PipelineShotPlanningEditor.attachSource(from: video, to: candidate, in: imported, editor: fixture.editor)
            let selected = try #require(imported.shots.first { $0.shotID == original.shotID })
            let source = try #require(selected.source)
            imported = try await PipelineShotPlanningEditor.replace(.init(shotID: original.shotID, sourceMode: .imported,
                source: source, camera: selected.camera, obligations: [], sourceInputRange: .init(source: source,
                    timebase: ProductionPlanningAcceptanceFixture.timebase, startTicks: Int64(index) * 2_400, durationTicks: 2_400)),
                in: imported, editor: fixture.editor)
        }
        try await ProductionPlanningAcceptanceFixture.approve("shot_planning", in: fixture)
        try await ProductionPlanningAcceptanceFixture.writeBible(in: fixture)
        _ = try await ProductionPlanningAcceptanceFixture.prepareImportedAssets(in: fixture)
        try await ProductionPlanningAcceptanceFixture.approve("bible", in: fixture)
        let projection = try await ProductionPlanningAcceptanceFixture.promoteImported(in: fixture)
        #expect(projection.shots.map(\.id) == draft.shots.map(\.shotID))
        for reference in duplicated.references {
            #expect(projection.header.inputs.contains { $0.path == reference.path && $0.sha256 == reference.sha256 })
        }
    }

    @Test func staleNativeStoryboardEditCannotOverwriteANewerRevision() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { fixture.document.close() }
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
        defer { fixture.document.close() }
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
        defer { fixture.document.close(); fixture.editor.releaseWorkingCopy() }
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let controller = EditorWindowController(editorViewModel: fixture.editor, window: window)
        let documentManager = try #require(fixture.document.undoManager)
        let storyboardManager = PipelineStoryboardEditor.undoManager(editor: fixture.editor)
        #expect(storyboardManager !== documentManager)
        fixture.editor.setWorkspaceFocus(.production)
        fixture.editor.productionSelectedPhase = "storyboard"
        fixture.editor.focusedPanel = .project
        let routedStoryboardManager = try #require(controller.windowWillReturnUndoManager(window))
        #expect(routedStoryboardManager === storyboardManager)
        fixture.editor.productionSelectedPhase = "shot_planning"
        let routedDocumentManager = try #require(controller.windowWillReturnUndoManager(window))
        #expect(routedDocumentManager === documentManager)
    }

}
