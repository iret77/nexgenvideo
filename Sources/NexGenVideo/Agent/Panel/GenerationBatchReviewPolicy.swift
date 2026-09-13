import SwiftUI

struct GenerationBatchReviewSelection {
    struct Row: Identifiable {
        let number: Int
        let item: GenerationBatch.Item
        var id: String { item.id }
    }

    private var nonce: UUID
    private var numbers: [String: Int]
    var selectedIDs: Set<String> = []

    init(batch: GenerationBatch) {
        nonce = batch.payload.nonce
        numbers = Dictionary(uniqueKeysWithValues: batch.payload.items.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    func rows(in batch: GenerationBatch) -> [Row] {
        batch.payload.items.compactMap { item in numbers[item.id].map { Row(number: $0, item: item) } }
    }

    mutating func reconcile(batch: GenerationBatch) {
        guard nonce == batch.payload.nonce else { self = Self(batch: batch); return }
        selectedIDs.formIntersection(batch.payload.items.map(\.id))
        var next = (numbers.values.max() ?? 0) + 1
        for item in batch.payload.items where numbers[item.id] == nil {
            numbers[item.id] = next
            next += 1
        }
    }
}

struct GenerationBatchReviewPolicy {
    let batch: GenerationBatch
    let selectedIDs: Set<String>
    let isBusy: Bool

    var showsPricingRecovery: Bool { batch.totalEUR == nil }
    var canApprove: Bool { !isBusy && batch.totalEUR != nil }
    var canRemove: Bool { !isBusy && !selectedIDs.isEmpty && selectedIDs.isSubset(of: Set(batch.payload.items.map(\.id))) }
    var canRetryPricing: Bool { !isBusy && showsPricingRecovery }
    var routeItemIDs: Set<String> {
        Set(batch.payload.items.filter { selectedIDs.contains($0.id) && $0.package.payload.estimate == nil }.map(\.id))
    }
    var canChangeRoute: Bool { !isBusy && !routeItemIDs.isEmpty }
}

@MainActor
struct GenerationBatchReviewActions {
    let editor: EditorViewModel

    @discardableResult
    func remove(batchID: String, itemIDs: Set<String>) -> Bool {
        let coordinator = editor.generationBatchCoordinator
        guard let batch = coordinator.pending, batch.id == batchID,
              policy(batch: batch, itemIDs: itemIDs).canRemove else { return false }
        for item in batch.payload.items where itemIDs.contains(item.id) {
            coordinator.remove(itemID: item.id, editor: editor)
        }
        return true
    }

    func handleRemovalKey(_ key: KeyEquivalent, modifiers: EventModifiers, batchID: String, itemIDs: Set<String>) -> Bool {
        guard key == .delete || key == .deleteForward, modifiers.isEmpty else { return false }
        return remove(batchID: batchID, itemIDs: itemIDs)
    }

    func retryPricing(batchID: String, quoteLoader: GenerationBudgetGuard.QuoteLoader = LiveGenerationPricing.quote) async {
        let coordinator = editor.generationBatchCoordinator
        guard let batch = coordinator.pending, batch.id == batchID,
              policy(batch: batch, itemIDs: []).canRetryPricing else { return }
        await coordinator.retryPricing(editor: editor, quoteLoader: quoteLoader)
    }

    func approve(batchID: String) async {
        let coordinator = editor.generationBatchCoordinator
        guard let batch = coordinator.pending, batch.id == batchID,
              policy(batch: batch, itemIDs: []).canApprove else { return }
        await coordinator.approve(editor: editor)
    }

    func changeRoute(batchID: String, itemIDs: Set<String>) {
        let coordinator = editor.generationBatchCoordinator
        guard let batch = coordinator.pending, batch.id == batchID else { return }
        let policy = policy(batch: batch, itemIDs: itemIDs)
        guard policy.canChangeRoute else { return }
        coordinator.changeRoute(itemIDs: policy.routeItemIDs, editor: editor)
    }

    private func policy(batch: GenerationBatch, itemIDs: Set<String>) -> GenerationBatchReviewPolicy {
        let coordinator = editor.generationBatchCoordinator
        return .init(batch: batch, selectedIDs: itemIDs, isBusy: coordinator.approving || coordinator.recoveringPricing)
    }
}
