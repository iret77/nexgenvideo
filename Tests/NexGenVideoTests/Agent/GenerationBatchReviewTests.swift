import Foundation
import NexGenEngine
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Generation batch review policy and actions", .serialized)
@MainActor
struct GenerationBatchReviewTests {
    @Test(arguments: [1, 13, 50])
    func preparedOrderAndNumberingRemainStable(count: Int) async throws {
        let (root, _, batch) = try await fixture(count: count)
        defer { cleanup(root) }
        var selection = GenerationBatchReviewSelection(batch: batch)
        #expect(selection.rows(in: batch).map(\.item.id) == batch.payload.items.map(\.id))
        #expect(selection.rows(in: batch).map(\.number) == Array(1...count))
        #expect(batch.totalEUR == Double(count) * 0.25)
        guard count > 1 else { return }
        selection.selectedIDs = [batch.payload.items[1].id]
        let reduced = try batch.removing(itemIDs: selection.selectedIDs)
        selection.reconcile(batch: reduced)
        #expect(selection.rows(in: reduced).map(\.number) == [1] + Array(3...count))
        #expect(selection.rows(in: reduced).map(\.item.id) == batch.payload.items.enumerated()
            .filter { $0.offset != 1 }.map(\.element.id))
        #expect(selection.selectedIDs.isEmpty)
        #expect(reduced.totalEUR == Double(count - 1) * 0.25)
    }

    @Test func repricingPreservesNumbersAndANewReviewResetsSelection() async throws {
        let (root, _, batch) = try await fixture(count: 3, unpriced: [0])
        defer { cleanup(root) }
        var selection = GenerationBatchReviewSelection(batch: batch)
        let reduced = try batch.removing(itemIDs: [batch.payload.items[1].id])
        selection.reconcile(batch: reduced)
        selection.selectedIDs = [batch.payload.items[0].id]
        let priced = try reduced.replacingPackages(reduced.payload.items.map {
            try $0.package.replacingEstimate(GenerationPackageFixture.money())
        })
        selection.reconcile(batch: priced)
        #expect(selection.rows(in: priced).map(\.number) == [1, 3])
        #expect(selection.selectedIDs == [batch.payload.items[0].id])
        let fresh = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: priced.payload.projectKey,
            phase: nil, items: priced.payload.items))
        selection.reconcile(batch: fresh)
        #expect(selection.rows(in: fresh).map(\.number) == [1, 2])
        #expect(selection.selectedIDs.isEmpty)
    }

    @Test func priceAndRecoveryPolicyFailsClosedWithoutPreventingSelection() async throws {
        let (root, _, batch) = try await fixture(count: 3, unpriced: [1, 2])
        defer { cleanup(root) }
        let selected = Set(batch.payload.items.prefix(2).map(\.id))
        let policy = GenerationBatchReviewPolicy(batch: batch, selectedIDs: selected, isBusy: false)
        #expect(!policy.canApprove)
        #expect(policy.canRemove)
        #expect(policy.showsPricingRecovery)
        #expect(policy.canRetryPricing)
        #expect(policy.canChangeRoute)
        #expect(policy.routeItemIDs == [batch.payload.items[1].id])
        #expect(batch.totalEUR == nil)
        let busy = GenerationBatchReviewPolicy(batch: batch, selectedIDs: selected, isBusy: true)
        #expect(busy.showsPricingRecovery)
        #expect(!busy.canApprove && !busy.canRemove && !busy.canRetryPricing && !busy.canChangeRoute)
        let empty = GenerationBatchReviewPolicy(batch: batch, selectedIDs: [], isBusy: false)
        #expect(empty.canRetryPricing && !empty.canChangeRoute && !empty.canRemove)
        let priced = try batch.removing(itemIDs: Set(batch.payload.items.suffix(2).map(\.id)))
        let ready = GenerationBatchReviewPolicy(batch: priced, selectedIDs: [], isBusy: false)
        #expect(ready.canApprove && !ready.showsPricingRecovery)
    }

    @Test(arguments: [false, true])
    func pointerAndDeleteReachTheSamePendingBatchAndOwnerSession(keyboard: Bool) async throws {
        let (root, editor, batch) = try await fixture(count: 3)
        defer { cleanup(root) }
        let service = editor.agentService
        service.newChat()
        let other = try #require(service.currentSessionId)
        service.draft = "Other conversation"
        service.newChat()
        let owner = try #require(service.currentSessionId)
        _ = try service.presentGenerationBatch(batch, origin: .inAppChat(sessionID: owner), editor: editor)
        service.selectSession(other)
        service.isStreaming = true
        let actions = GenerationBatchReviewActions(editor: editor)
        let selected: Set<String> = [batch.payload.items[1].id]
        let handled = keyboard
            ? actions.handleRemovalKey(.delete, modifiers: [], batchID: batch.id, itemIDs: selected)
            : actions.remove(batchID: batch.id, itemIDs: selected)
        #expect(handled)
        let updated = try #require(editor.generationBatchCoordinator.pending)
        #expect(updated.id != batch.id)
        #expect(updated.payload.items.map(\.id) == [batch.payload.items[0].id, batch.payload.items[2].id])
        #expect(updated.totalEUR == 0.5)
        try service.requireGenerationBatchOrigin(updated.id)
        #expect(throws: (any Error).self) { try service.requireGenerationBatchOrigin(batch.id) }
        #expect(service.sessionAttention(for: owner) == .actionRequired)
        #expect(service.currentSessionId == other)
        #expect(service.sessionAttention(for: other) != .actionRequired)
        #expect(!actions.remove(batchID: batch.id, itemIDs: [batch.payload.items[0].id]))
        #expect(editor.generationBatchCoordinator.pending == updated)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func removalCommandsRejectModifiedKeysAndForeignOrEmptySelection() async throws {
        let (root, editor, batch) = try await fixture(count: 1)
        defer { cleanup(root) }
        editor.generationBatchCoordinator.pending = batch
        let actions = GenerationBatchReviewActions(editor: editor)
        let selected = Set(batch.payload.items.map(\.id))
        #expect(!actions.handleRemovalKey(.delete, modifiers: .command, batchID: batch.id, itemIDs: selected))
        #expect(!actions.handleRemovalKey(.space, modifiers: [], batchID: batch.id, itemIDs: selected))
        #expect(!actions.remove(batchID: batch.id, itemIDs: []))
        #expect(!actions.remove(batchID: batch.id, itemIDs: [UUID().uuidString]))
        #expect(editor.generationBatchCoordinator.pending == batch)
        #expect(actions.remove(batchID: batch.id, itemIDs: selected))
        #expect(editor.generationBatchCoordinator.pending == nil)
        #expect(editor.mediaAssets.isEmpty && editor.generationLog.spendEvents.isEmpty)
    }

    @Test func retryActionQuotesAllUnpricedRowsRegardlessOfSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-review-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: root)
        defer { cleanup(root) }
        let (_, editor, batch) = try await fixture(count: 3, unpriced: [0, 2], root: root)
        editor.generationBatchCoordinator.pending = batch
        var quotes = 0
        let actions = GenerationBatchReviewActions(editor: editor)
        await actions.retryPricing(batchID: batch.id, quoteLoader: { _, _ in
            quotes += 1
            #expect(editor.generationBatchCoordinator.recoveringPricing)
            #expect(!actions.remove(batchID: batch.id, itemIDs: [batch.payload.items[0].id]))
            return GenerationPackageFixture.money()
        })
        #expect(quotes == 2)
        let priced = try #require(editor.generationBatchCoordinator.pending)
        #expect(priced.totalEUR == 0.75)
        #expect(priced.payload.items[1] == batch.payload.items[1])
        #expect(!editor.generationBatchCoordinator.recoveringPricing)
        #expect(editor.generationLog.spendEvents.isEmpty && editor.mediaAssets.isEmpty)
    }

    @Test func unpricedOrSupersededApprovalActionsNeverAcquireAuthority() async throws {
        let (root, editor, batch) = try await fixture(count: 3, unpriced: [1])
        defer { cleanup(root) }
        editor.generationBatchCoordinator.pending = batch
        let actions = GenerationBatchReviewActions(editor: editor)
        await actions.approve(batchID: batch.id)
        #expect(editor.generationBatchCoordinator.pending == batch)
        #expect(editor.generationBatchCoordinator.error == nil)
        let replacement = try batch.removing(itemIDs: [batch.payload.items[1].id])
        editor.generationBatchCoordinator.pending = replacement
        await actions.approve(batchID: batch.id)
        #expect(editor.generationBatchCoordinator.pending == replacement)
        #expect(editor.mediaAssets.isEmpty && editor.generationLog.spendEvents.isEmpty)
        #expect(try GenerationBatchStore.all(home: #require(editor.workingRoot)).isEmpty)
    }

    @Test func changeRouteActionUsesOnlySelectedUnpricedRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-route-review-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: root)
        defer { cleanup(root) }
        let (_, editor, batch) = try await fixture(count: 3, unpriced: [1, 2], root: root)
        editor.agentService.newChat()
        let owner = try #require(editor.agentService.currentSessionId)
        _ = try editor.agentService.presentGenerationBatch(batch, origin: .inAppChat(sessionID: owner), editor: editor)
        editor.agentService.isStreaming = true
        GenerationBatchReviewActions(editor: editor).changeRoute(batchID: batch.id,
            itemIDs: Set(batch.payload.items.prefix(2).map(\.id)))
        let recovery = try #require(try GenerationBatchStore.retirement(requestID: batch.payload.nonce,
            home: #require(editor.workingRoot)))
        #expect(recovery.continuation.items.map(\.itemID) == [batch.payload.items[1].id])
        #expect(editor.generationBatchCoordinator.pending == nil)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func unpricedSinglePackageDisablesApprovalAndRepreparesSelectedOption() async throws {
        let (root, _, batch) = try await fixture(count: 1, unpriced: [0])
        defer { cleanup(root) }
        let package = batch.payload.items[0].package
        let option = SpendOption(modelId: package.payload.target.modelId, modelName: "Fixture", target: package.payload.target,
            credits: 0, requiresCatalogAvailability: false, generationPackage: package)
        let approval = SpendApproval(id: UUID().uuidString, recommendedOptionId: option.id, options: [option],
            actionLabel: "Generate", requiresGenerationPackage: true)
        var approvals = 0
        var prepared: [SpendOption] = []
        let card = SpendApprovalCard(approval: approval, onApprove: { _ in approvals += 1 }, onDecline: {},
            onPrepare: { prepared.append($0) })
        #expect(!card.canApproveSelection)
        #expect(card.showsPreparationRecovery)
        card.approveSelection()
        card.prepareSelectionAgain()
        #expect(approvals == 0)
        #expect(prepared == [option])
        let busy = SpendApprovalCard(approval: approval, isWorking: true, onApprove: { _ in approvals += 1 },
            onDecline: {}, onPrepare: { prepared.append($0) })
        busy.approveSelection()
        busy.prepareSelectionAgain()
        #expect(approvals == 0 && prepared.count == 1)
        var priced = option
        priced.generationPackage = try package.replacingEstimate(GenerationPackageFixture.money())
        let ready = SpendApprovalCard(approval: approval.replacingOptions([priced]), onApprove: { _ in approvals += 1 }, onDecline: {})
        #expect(ready.canApproveSelection && !ready.showsPreparationRecovery)
        ready.approveSelection()
        #expect(approvals == 1)
        var missing = option
        missing.generationPackage = nil
        let preparing = SpendApprovalCard(approval: approval.replacingOptions([missing]), onApprove: { _ in approvals += 1 }, onDecline: {})
        #expect(!preparing.canApproveSelection && !preparing.showsPreparationRecovery)
        preparing.approveSelection()
        let failed = SpendApprovalCard(approval: approval.replacingOptions([missing]), error: "fixture error",
            onApprove: { _ in approvals += 1 }, onDecline: {}, onPrepare: { prepared.append($0) })
        #expect(!failed.canApproveSelection && failed.showsPreparationRecovery)
        failed.prepareSelectionAgain()
        #expect(prepared == [option, missing] && approvals == 1)
    }

    @Test func previewReadsOnlyTheExactArchivedImageAndRejectsReplacementOrEscape() async throws {
        let (root, editor, batch) = try await fixture(count: 1)
        defer { cleanup(root) }
        let home = try #require(editor.workingRoot)
        let source = root.appendingPathComponent("reference.png")
        let bytes = Data("approved reference bytes".utf8)
        try bytes.write(to: source)
        let snapshot = try await GenerationReferenceSnapshot.capture(sources: [
            .init(assetID: "reference", displayName: "Character.png", type: "image", url: source)
        ])
        let p = batch.payload.items[0].package.payload
        var input = p.generationInput
        input.referenceReceipts = snapshot.receipts
        let package = try GenerationPackageV1(payload: .init(target: p.target, modality: p.modality,
            operation: p.operation, intent: p.intent, prompt: p.prompt, promptRevisionID: p.promptRevisionID,
            generationInput: input, binding: p.binding, compilerInputsSHA256: p.compilerInputsSHA256,
            recipe: p.recipe, repairPlanID: p.repairPlanID, destination: p.destination, outputCount: p.outputCount,
            references: snapshot.receipts, referenceRoles: ["image_reference"], requestParametersJSON: p.requestParametersJSON,
            routing: p.routing, routeReceipt: p.routeReceipt, estimate: p.estimate))
        try await GenerationPackageInputs.persist(package: package, snapshot: snapshot, editor: editor)
        #expect(try GenerationPackageInputs.previewData(package: package, referenceIndex: 0, home: home) == bytes)
        #expect(throws: (any Error).self) { try GenerationPackageInputs.previewData(package: package, referenceIndex: 1, home: home) }
        let archive = home.appendingPathComponent(Project.mediaDirectoryName + "/generation-inputs/\(package.id)/0.png")
        try Data("changed archive".utf8).write(to: archive, options: .atomic)
        #expect(throws: (any Error).self) { try GenerationPackageInputs.previewData(package: package, referenceIndex: 0, home: home) }
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: source)
        #expect(throws: (any Error).self) { try GenerationPackageInputs.previewData(package: package, referenceIndex: 0, home: home) }
        let record = GenerationPackageInputs(packageID: package.id, paths: ["reference.png"])
        try GenerationPackageV1.canonicalData(record).write(to: home.appendingPathComponent("generation-packages/\(package.id).inputs.json"), options: .atomic)
        #expect(throws: (any Error).self) { try GenerationPackageInputs.previewData(package: package, referenceIndex: 0, home: home) }
    }

    private func fixture(count: Int, unpriced: Set<Int> = [], root: URL? = nil) async throws -> (URL, EditorViewModel, GenerationBatch) {
        let project = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("batch-policy-\(UUID().uuidString).ngv")
        if root == nil { try Fixtures.prepareProjectPackage(at: project) }
        let editor = EditorViewModel()
        editor.projectURL = project
        editor.agentService.editor = editor
        let (generation, priced) = try await GenerationPackageFixture.prepare(editor: editor)
        let missing = try priced.replacingEstimate(nil)
        if root != nil {
            let snapshot = try #require(generation.references)
            try await GenerationPackageInputs.persist(package: priced, snapshot: snapshot, editor: editor)
            try await GenerationPackageInputs.persist(package: missing, snapshot: snapshot, editor: editor)
        }
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: priced.payload.binding.projectKey,
            phase: nil, items: (0..<count).map {
                .init(id: UUID().uuidString, purpose: "Frame \($0 + 1)", package: unpriced.contains($0) ? missing : priced)
            }))
        return (project, editor, batch)
    }

    private func cleanup(_ root: URL) {
        if let key = ProjectIdentity.existingKey(for: root) { ProjectWorkingCopy.discard(key: key) }
        try? FileManager.default.removeItem(at: root)
    }
}
