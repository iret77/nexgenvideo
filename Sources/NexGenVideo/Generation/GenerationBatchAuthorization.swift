import Foundation
import NexGenEngine

struct GenerationBatchAuthorization: Sendable, Equatable {
    let batchID: String
    let itemID: String

    @MainActor
    func requireQueued(package: GenerationPackageV1, editor: EditorViewModel) throws {
        let snapshot = try current(package: package, editor: editor)
        guard snapshot.journal.executions.first(where: { $0.itemID == itemID })?.state == .queued else {
            throw GenerationRequestError.gate("This batch item already has an execution. Join its recorded job instead of generating again.")
        }
    }

    @MainActor
    func pricingOverride(package: GenerationPackageV1, editor: EditorViewModel) throws -> Bool {
        let snapshot = try approvedSnapshot(package: package, editor: editor)
        guard snapshot.authorityAvailable,
              snapshot.journal.executions.first(where: { $0.itemID == itemID })?.state == .queued else {
            throw GenerationRequestError.gate("This batch item has no unused approval on this Mac.")
        }
        return snapshot.journal.pricingOverrideItemIDs?.contains(itemID) == true
    }

    @MainActor
    func hasPricingOverride(editor: EditorViewModel) throws -> Bool {
        guard let home = editor.workingRoot else { return false }
        let snapshot = try GenerationBatchStore.load(id: batchID, home: home)
        guard snapshot.authorityAvailable, snapshot.batch.payload.projectKey == editor.projectId,
              let overrideIDs = snapshot.journal.pricingOverrideItemIDs else { return false }
        return !overrideIDs.isEmpty && snapshot.batch.payload.items.contains { $0.id == itemID }
    }

    @MainActor
    func consume(authorization: GenerationAuthorization, editor: EditorViewModel) throws {
        guard let package = authorization.generationPackage, let transactionID = authorization.transactionId,
              authorization.target == package.payload.target else {
            throw GenerationRequestError.gate("A batch submission needs its exact package and spend reservation.")
        }
        try authorization.projectMutationScope?.requireCurrent(editor: editor)
        let snapshot = try current(package: package, editor: editor)
        if let ceiling = package.payload.estimate {
            guard let quote = authorization.estimate, quote.eurAmount <= ceiling.eurAmount else {
                throw GenerationRequestError.gate("The batch submission exceeds its reviewed price.")
            }
        } else {
            guard snapshot.journal.pricingOverrideItemIDs?.contains(itemID) == true else {
                throw GenerationRequestError.gate("This batch item has no explicit unknown-price approval.")
            }
        }
        let events = editor.generationLog.spendEvents.filter { $0.transactionId == transactionID }
        guard events.count == 1, let reservation = events.first, reservation.kind == .reserved,
              reservation.model == authorization.target.modelId, reservation.provider == authorization.target.provider,
              reservation.transport == authorization.target.transport, reservation.endpoint == authorization.target.endpoint,
              reservation.money == authorization.estimate else {
            throw GenerationRequestError.gate("The batch item's central spend reservation is missing or already consumed.")
        }
        let placeholders = editor.mediaAssets.filter {
            $0.generationInput?.spendTransactionId == transactionID && $0.generationInput?.generationPackageID == package.id
        }.map { $0.toManifestEntry(projectURL: editor.workingRoot) }
        guard placeholders.count == package.payload.outputCount else {
            throw GenerationRequestError.gate("The batch's output destinations were not recorded before submission.")
        }
        _ = try GenerationBatchStore.update(snapshot, editor: editor, addingSpendEvents: [reservation]) {
            try $0.beginSubmission(itemID: itemID, packageID: package.id, transactionID: transactionID,
                placeholders: placeholders, batch: snapshot.batch)
        }
    }

    @MainActor
    func recordProviderRequest(transactionID: String, requestID: String, resumable: Bool, editor: EditorViewModel) throws {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The batch project is closed.") }
        let snapshot = try GenerationBatchStore.load(id: batchID, home: home)
        _ = try GenerationBatchStore.update(snapshot, editor: editor) {
            try $0.recordProviderRequest(itemID: itemID, transactionID: transactionID, requestID: requestID, resumable: resumable)
        }
    }

    @MainActor
    func settle(editor: EditorViewModel) async throws {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The batch project is closed.") }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let snapshot = try GenerationBatchStore.load(id: batchID, home: home)
        guard let execution = snapshot.journal.executions.first(where: { $0.itemID == itemID }),
              [.queued, .submitting, .running, .blocked].contains(execution.state) else { return }
        let item = snapshot.batch.payload.items.first { $0.id == itemID }!
        let assets = editor.mediaAssets.filter {
            execution.transactionID != nil && $0.generationInput?.spendTransactionId == execution.transactionID
                && $0.generationInput?.generationPackageID == item.package.id
        }
        let ready = assets.filter {
            if case .none = $0.generationStatus { return FileManager.default.fileExists(atPath: $0.url.path) }
            return false
        }
        let readyIDs = ready.map(\.id)
        let receipts = try await Task.detached(priority: .utility) {
            try readyIDs.compactMap { try GenerationBatchOutput.load(authorization: self, assetID: $0, home: home) }
        }.value
        try scope.requireCurrent(editor: editor)
        for receipt in receipts {
            guard let asset = editor.mediaAssets.first(where: { $0.id == receipt.asset.id }),
                  asset.generationStatus == .none,
                  asset.toManifestEntry(projectURL: home).source == receipt.asset.source,
                  asset.generationInput?.spendTransactionId == execution.transactionID,
                  asset.generationInput.map(GenerationPackageV1.normalized) == item.package.payload.generationInput else {
                throw GenerationRequestError.storage("A completed batch output changed while its receipt was verified.")
            }
        }
        _ = try GenerationBatchStore.updateExecution(snapshot, itemID: itemID, editor: editor) { journal in
            if [.running, .blocked].contains(execution.state), ready.count == item.package.payload.outputCount,
               Set(receipts.map(\.asset.id)) == Set(readyIDs) {
                try journal.finish(itemID: itemID, outputAssetIDs: ready.map(\.id), batch: snapshot.batch)
            } else if execution.state != .blocked {
                let failure = assets.compactMap { asset -> String? in
                    if case .failed(let message) = asset.generationStatus { return message }
                    return nil
                }.first
                try journal.stop(itemID: itemID, state: execution.state == .queued ? .failed : .blocked,
                    detail: failure ?? "The provider job has not produced every requested output. Reconcile the recorded request before retrying.")
            }
        }
    }

    @MainActor
    private func approvedSnapshot(package: GenerationPackageV1, editor: EditorViewModel) throws -> GenerationBatchStore.Snapshot {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The batch project is closed.") }
        let snapshot = try GenerationBatchStore.load(id: batchID, home: home)
        guard snapshot.authorityAvailable, snapshot.batch.payload.projectKey == editor.projectId,
              snapshot.batch.payload.items.first(where: { $0.id == itemID })?.package == package else {
            throw GenerationRequestError.gate("The generation request is not part of this project's approved batch.")
        }
        return snapshot
    }

    @MainActor
    private func current(package: GenerationPackageV1, editor: EditorViewModel) throws -> GenerationBatchStore.Snapshot {
        let snapshot = try approvedSnapshot(package: package, editor: editor)
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The batch project is closed.") }
        let option = SpendOption(modelId: package.payload.target.modelId, modelName: package.payload.target.modelId,
            target: package.payload.target, credits: nil, requiresCatalogAvailability: true)
        guard option.isCurrentlyAvailable else {
            throw GenerationRequestError.gate("The approved provider and model are unavailable. This item cannot switch routes automatically.")
        }
        if let root = DataRootResolver.dataRoot(of: home) {
            let phase = try editor.pipelineAgentHarness.guardCurrentPhaseWork(
                tool: package.payload.modality == "image" ? .generateImage : .generateVideo,
                dataRoot: root, declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
            guard phase == snapshot.batch.payload.phase else {
                throw GenerationRequestError.gate("The pipeline phase changed after batch approval.")
            }
        } else if snapshot.batch.payload.phase != nil {
            throw GenerationRequestError.gate("The approved batch's pipeline is no longer available.")
        }
        return snapshot
    }
}
