import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
extension FilmFlowSnapshotTests {
    @Test func explicitOmissionsAreRequiredAndAcceptanceDoesNotApproveAWorkflow() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        let prepared = try await FilmFlowSnapshotTests.prepared()
        defer { prepared.discard() }
        let gates = try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.gatesFile))
        let lineage = try ProductionPlanningLineageV2.snapshot(phase: "script", dataRoot: context.dataRoot)
        await #expect(throws: (any Error).self) {
            _ = try await FilmFlowSnapshotStore.accept(prepared, omittedImages: [], editor: context.editor)
        }
        #expect(try FilmFlowSnapshotStore.list(dataRoot: context.dataRoot).isEmpty)
        let retained = try await FilmFlowSnapshotStore.accept(prepared,
            omittedImages: Set(prepared.snapshot.missingImages.map(\.pointer)), editor: context.editor)
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.gatesFile)) == gates)
        let after = try ProductionPlanningLineageV2.snapshot(phase: "script", dataRoot: context.dataRoot)
        #expect(after.inputFingerprint == lineage.inputFingerprint && after.artifactFingerprint == lineage.artifactFingerprint)
        #expect(try FilmFlowSnapshotStore.list(dataRoot: context.dataRoot).first?.sha256 == retained.sha256)
        #expect(try Data(contentsOf: retained.directory.appendingPathComponent("snapshot.v1.json"))
            == Data(contentsOf: prepared.directory.appendingPathComponent("snapshot.v1.json")))
    }

    @Test func scriptUsesRetainedSourceAndReceiptArchivesTheActualNativeRevision() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        let prepared = try await FilmFlowSnapshotTests.prepared()
        defer { prepared.discard() }
        let retained = try await FilmFlowSnapshotStore.accept(prepared,
            omittedImages: Set(prepared.snapshot.missingImages.map(\.pointer)), editor: context.editor)
        let material = try FilmFlowMaterial.load(directory: retained.directory, snapshot: retained.snapshot)
        let item = try #require(material.items.first { $0.kind == .shot })
        let manager = try #require(context.editor.undoManager)
        manager.removeAllActions(); manager.groupsByEvent = false
        #expect(manager.groupingLevel == 0)
        let before = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        let scene = try #require(before.scenes.first), event = try #require(scene.events.first)
        try await FilmFlowAdoptionCoordinator.script(retained, item: item, sceneID: scene.id, eventID: event.id, expected: before, editor: context.editor)
        let after = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        #expect(manager.groupingLevel == 0)
        #expect(manager.canUndo && manager.undoActionName == "Edit Script")
        #expect(after.scenes[0].events[0].id == event.id)
        #expect(after.scenes[0].events[0].treatmentBeatIDs == event.treatmentBeatIDs)
        #expect(after.scenes[0].events[0].action == item.notes)
        let receiptFolder = context.dataRoot.appendingPathComponent("import/filmflow-adoptions/" + retained.id.uuidString.lowercased())
        let receiptFiles = try FileManager.default.contentsOfDirectory(at: receiptFolder, includingPropertiesForKeys: nil)
        #expect(receiptFiles.count == 1)
        let receiptURL = try #require(receiptFiles.first)
        let receiptBytes = try Data(contentsOf: receiptURL)
        let receipt = try FilmFlowSnapshot.decode(FilmFlowAdoption.Receipt.self, from: receiptBytes)
        #expect(receipt.phase == "script" && receipt.mapping.targetID == event.id)
        #expect(receipt.outputs.map(\.path) == [ScriptV1.versionPath(after.header.revision)])
        #expect(try FileDigest.sha256(of: context.dataRoot.appendingPathComponent(receipt.outputs[0].path)) == receipt.outputs[0].sha256)
        manager.undo()
        let undone = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        #expect(undone.summary == before.summary && undone.scenes == before.scenes)
        #expect(manager.groupingLevel == 0 && !manager.canUndo)
        #expect(manager.canRedo && manager.redoActionName == "Edit Script")
        #expect(try Data(contentsOf: receiptURL) == receiptBytes)
        #expect(try FileDigest.sha256(of: context.dataRoot.appendingPathComponent(receipt.outputs[0].path)) == receipt.outputs[0].sha256)
        manager.redo()
        let redone = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        #expect(redone.summary == after.summary && redone.scenes == after.scenes)
        #expect(manager.groupingLevel == 0 && !manager.canRedo)
        #expect(manager.canUndo && manager.undoActionName == "Edit Script")
        do {
            manager.beginUndoGrouping()
            defer { manager.endUndoGrouping() }
            let outerLevel = manager.groupingLevel
            try PipelineScriptEditor.replaceScene(scene, in: redone, editor: context.editor)
            #expect(manager.groupingLevel == outerLevel)
        }
        #expect(manager.groupingLevel == 0)
        #expect(try PlanningWriterIO.script(dataRoot: context.dataRoot).scenes == before.scenes)
        manager.undo()
        #expect(try PlanningWriterIO.script(dataRoot: context.dataRoot).scenes == after.scenes)
        #expect(manager.groupingLevel == 0)
        manager.redo()
        #expect(try PlanningWriterIO.script(dataRoot: context.dataRoot).scenes == before.scenes)
        #expect(manager.groupingLevel == 0)
        #expect(try FileManager.default.contentsOfDirectory(at: receiptFolder, includingPropertiesForKeys: nil) == receiptFiles)
        #expect(try Data(contentsOf: receiptURL) == receiptBytes)
        #expect(try FileDigest.sha256(of: context.dataRoot.appendingPathComponent(receipt.outputs[0].path)) == receipt.outputs[0].sha256)
        #expect(try FilmFlowSnapshot.verify(directory: retained.directory, expectedSHA256: retained.sha256) == retained.snapshot)
    }

    @Test func preparedScriptCannotPublishAfterRetainedSourceChanges() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        let prepared = try await FilmFlowSnapshotTests.prepared()
        defer { prepared.discard() }
        let retained = try await FilmFlowSnapshotStore.accept(prepared,
            omittedImages: Set(prepared.snapshot.missingImages.map(\.pointer)), editor: context.editor)
        let script = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        let scene = try #require(script.scenes.first), event = try #require(scene.events.first)
        let mapping = FilmFlowAdoption(snapshotID: retained.id, snapshotSHA256: retained.sha256,
            sourceObjectID: "get_shotlist#/scenes/0/shots/0", targetID: event.id, fields: ["action"])
        let (candidate, _) = try mapping.prepareScript(dataRoot: context.dataRoot)
        let before = try Data(contentsOf: context.dataRoot.appendingPathComponent(ScriptV1.currentPath))
        let manager = try #require(context.editor.undoManager)
        manager.removeAllActions(); manager.groupsByEvent = false
        #expect(manager.groupingLevel == 0 && !manager.canUndo)
        try Data("{}".utf8).write(to: retained.directory.appendingPathComponent("dto/get_shotlist.json"), options: .atomic)
        let replacement = ScriptV1.Scene(id: scene.id, title: scene.title, adaptation: scene.adaptation,
            events: scene.events.map { .init(id: $0.id, action: $0.action + " Changed action.", dialogue: $0.dialogue,
                treatmentBeatIDs: $0.treatmentBeatIDs, sourceAnchors: $0.sourceAnchors) })
        #expect(throws: (any Error).self) {
            try PipelineScriptEditor.replaceScene(replacement, in: script, editor: context.editor, filmFlow: candidate)
        }
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(ScriptV1.currentPath)) == before)
        #expect(manager.groupingLevel == 0 && !manager.canUndo)
    }
}
