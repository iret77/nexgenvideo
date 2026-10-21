import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Canonical Ledger transactions and native history")
struct PipelineLedgerWriterTests {
    @Test func lockedRemovalPreservesActualBytesAndReconciliationKeepsSourceAndOtherObjects() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeBible()
        defer { context.document.close() }
        let target: [String: Any] = ["kind": "film", "key": "lighting"]
        try await ProductionPlanningAcceptanceFixture.run("set_ledger_attribute", args: target.merging([
            "tag": "Hard side light", "directive": "Leave the opposite wall dark.", "source": "Actual director note", "locked": true]) { _, new in new }, in: context)
        try await ProductionPlanningAcceptanceFixture.run("set_ledger_attribute", args: ["kind": "look", "key": "palette", "tag": "Pale walls", "locked": true], in: context)
        let before = try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.ledgerFile))
        let refused = await context.executor.execute(name: "remove_ledger_attribute", args: target)
        #expect(refused.isError)
        #expect(refused.content.contains { if case .text(let text) = $0 { text.contains("attributeLocked") } else { false } })
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.ledgerFile)) == before)
        try await ProductionPlanningAcceptanceFixture.run("lock_ledger_attribute", args: target.merging(["locked": false]) { _, new in new }, in: context)
        try await ProductionPlanningAcceptanceFixture.run("set_ledger_attribute", args: target.merging([
            "tag": "Warm side light", "directive": "Keep warm light on one side.", "source": "Actual revised note"]) { _, new in new }, in: context)
        let ledger = try YAMLArtifactStore(dataRoot: context.dataRoot).load(Ledger.self, at: PipelineLayout.ledgerFile)
        #expect(ledger.objects["film"]?.count == 1)
        #expect(ledger.objects["film"]?["lighting"]?.source == "Actual revised note")
        #expect(ledger.objects["film"]?["lighting"]?.locked == false)
        #expect(ledger.objects["look"]?["palette"]?.tag == "Pale walls")
        #expect(ledger.objects["look"]?["palette"]?.locked == true)
    }

    @Test func nativeUndoRedoRestoresWholeLedgerAfterToolLeaseEnds() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeBible()
        defer { context.document.close() }
        let target: [String: Any] = ["kind": "film", "key": "lighting", "tag": "Side light", "source": "Director", "directive": "One side only"]
        try await ProductionPlanningAcceptanceFixture.run("set_ledger_attribute", args: target, in: context)
        let original = try YAMLArtifactStore(dataRoot: context.dataRoot).load(Ledger.self, at: PipelineLayout.ledgerFile)
        try await ProductionPlanningAcceptanceFixture.run("lock_ledger_attribute", args: ["kind": "film", "key": "lighting", "locked": true], in: context)
        let locked = try YAMLArtifactStore(dataRoot: context.dataRoot).load(Ledger.self, at: PipelineLayout.ledgerFile)
        let manager = try #require(context.editor.undoManager)
        manager.undo()
        #expect(try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: context.editor) == original)
        manager.redo()
        #expect(try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: context.editor) == locked)
        let access = try PipelineNativeEditAccess(editor: context.editor, label: "Ledger publication Undo regression")
        let transaction = try PipelineLedgerWriter.ToolTransaction(editor: context.editor, dataRoot: context.dataRoot,
            declaration: access.declaration, lease: access.lease)
        var finished = false
        defer { if !finished { access.end(editor: context.editor); transaction.finish() } }
        _ = try await PipelineLedgerWriter.mutate(dataRoot: context.dataRoot, editor: context.editor, transaction: transaction) {
            try setLocked(&$0, kind: .film, key: "lighting", locked: false)
        }
        #expect(context.editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: access.root, id: access.lease))
        let stagingPrefix = ".pipeline-transaction-" + access.home.lastPathComponent + "-"
        #expect(try FileManager.default.contentsOfDirectory(atPath: access.home.deletingLastPathComponent().path)
            .allSatisfy { !$0.hasPrefix(stagingPrefix) })
        manager.undo()
        access.end(editor: context.editor)
        transaction.finish(); finished = true
        #expect(try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: context.editor) == locked)
    }

    @Test func nativeUndoRejectsChangedLedgerInsteadOfBlindYamlRestore() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeBible()
        defer { context.document.close() }
        try await ProductionPlanningAcceptanceFixture.run("set_ledger_attribute", args: ["kind": "film", "key": "lighting", "tag": "Side light"], in: context)
        var external = try YAMLArtifactStore(dataRoot: context.dataRoot).load(Ledger.self, at: PipelineLayout.ledgerFile)
        external.objects["film"]?["lighting"]?.tag = "Changed outside the captured native revision"
        try YAMLArtifactStore(dataRoot: context.dataRoot).save(external, to: PipelineLayout.ledgerFile)
        let bytes = try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.ledgerFile))
        let manager = try #require(context.editor.undoManager)
        manager.undo()
        await #expect(throws: (any Error).self) { try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: context.editor) }
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.ledgerFile)) == bytes)
        #expect(context.editor.mediaPanelToast != nil)
    }

    @Test func expiredBorrowedLeaseCannotPublishLedgerBytes() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeBible()
        defer { context.document.close() }
        let access = try PipelineNativeEditAccess(editor: context.editor, label: "Ledger stale lease regression")
        let transaction = try PipelineLedgerWriter.ToolTransaction(editor: context.editor, dataRoot: context.dataRoot,
            declaration: access.declaration, lease: access.lease)
        defer { transaction.finish() }
        let path = context.dataRoot.appendingPathComponent(PipelineLayout.ledgerFile)
        let before = try? Data(contentsOf: path)
        access.end(editor: context.editor)
        await #expect(throws: (any Error).self) {
            try await PipelineLedgerWriter.mutate(dataRoot: context.dataRoot, editor: context.editor, transaction: transaction) {
                try setAttribute(&$0, kind: .film, key: "lighting", tag: "Must not publish")
            }
        }
        #expect((try? Data(contentsOf: path)) == before)
    }
}
