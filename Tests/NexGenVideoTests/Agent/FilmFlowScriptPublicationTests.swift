import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
extension FilmFlowSnapshotTests {
    @Test func repeatedIdenticalActionRefusesWithoutAnotherReceiptOrRevision() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        let prepared = try await FilmFlowSnapshotTests.prepared()
        defer { prepared.discard() }
        let retained = try await FilmFlowSnapshotStore.accept(prepared,
            omittedImages: Set(prepared.snapshot.missingImages.map(\.pointer)), editor: context.editor)
        let material = try FilmFlowMaterial.load(directory: retained.directory, snapshot: retained.snapshot)
        let item = try #require(material.items.first { $0.kind == .shot })
        let original = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        let scene = try #require(original.scenes.first), event = try #require(scene.events.first)
        try await FilmFlowAdoptionCoordinator.script(retained, item: item, sceneID: scene.id, eventID: event.id,
            expected: original, editor: context.editor)
        let current = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        #expect(current.scenes[0].events[0].action == item.notes)
        #expect(current.header.revision == original.header.revision + 1)
        let folder = context.dataRoot.appendingPathComponent("import/filmflow-adoptions/" + retained.id.uuidString.lowercased())
        let receipts = try inventory(folder)
        #expect(receipts.count == 2)
        let script = try Data(contentsOf: context.dataRoot.appendingPathComponent(ScriptV1.currentPath))
        let gates = try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.gatesFile))
        do {
            try await FilmFlowAdoptionCoordinator.script(retained, item: item, sceneID: scene.id, eventID: event.id,
                expected: current, editor: context.editor)
            Issue.record("An unchanged FilmFlow action reported another successful adoption.")
        } catch let error as GateBlocked {
            #expect(error.message == "The selected FilmFlow action already matches this Script event. No adoption was applied.")
        }
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(ScriptV1.currentPath)) == script)
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.gatesFile)) == gates)
        #expect(try inventory(folder) == receipts)
    }

    @Test func finalPublicationRefusalPrecedesScriptAndReceiptWrites() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        let prepared = try await FilmFlowSnapshotTests.prepared()
        defer { prepared.discard() }
        let retained = try await FilmFlowSnapshotStore.accept(prepared,
            omittedImages: Set(prepared.snapshot.missingImages.map(\.pointer)), editor: context.editor)
        let current = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        let scene = try #require(current.scenes.first), event = try #require(scene.events.first)
        let mapping = FilmFlowAdoption(snapshotID: retained.id, snapshotSHA256: retained.sha256,
            sourceObjectID: "get_shotlist#/scenes/0/shots/0", targetID: event.id, fields: ["action"])
        let (selection, source) = try mapping.prepareScript(dataRoot: context.dataRoot)
        let key = try #require(context.editor.openWorkingCopyKey)
        try #require(ProjectWorkingCopy.home(key).standardizedFileURL == context.dataRoot.deletingLastPathComponent().standardizedFileURL)
        try ProjectWorkingCopy.markDirty(key: key)
        _ = try selection.file(outputs: [], dataRoot: context.dataRoot)
        let changed = ScriptV1.Scene(id: scene.id, title: scene.title, adaptation: scene.adaptation,
            events: scene.events.map { value in
                value.id == event.id ? .init(id: value.id, action: source.notes, dialogue: value.dialogue,
                    treatmentBeatIDs: value.treatmentBeatIDs, sourceAnchors: []) : value
            })
        let editor = context.editor
        let access = try PipelinePlanningWriteAccess(dataRoot: context.dataRoot,
            declaration: .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                productionContract: editor.declaredProductionContract), phase: "script")
        let folder = context.dataRoot.appendingPathComponent("import/filmflow-adoptions/" + retained.id.uuidString.lowercased())
        let receipts = try inventory(folder)
        let script = try Data(contentsOf: context.dataRoot.appendingPathComponent(ScriptV1.currentPath))
        let gates = try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.gatesFile))
        do {
            _ = try PipelineScriptWriter.write(summary: current.summary,
                scenes: current.scenes.map { $0.id == scene.id ? changed : $0 }, origin: .userRevision,
                access: access, filmFlow: selection, beforePublish: { throw GateBlocked("Final Script publication withdrawn.") })
            Issue.record("A withdrawn publication wrote its Script or receipt.")
        } catch let error as GateBlocked { #expect(error.message == "Final Script publication withdrawn.") }
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(ScriptV1.currentPath)) == script)
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.gatesFile)) == gates)
        #expect(try inventory(folder) == receipts)
        #expect(!FileManager.default.fileExists(atPath: context.dataRoot.appendingPathComponent(ScriptV1.versionPath(current.header.revision + 1)).path))
    }

    private func inventory(_ directory: URL) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try FileDigest.sha256(of: $0)) })
    }
}
