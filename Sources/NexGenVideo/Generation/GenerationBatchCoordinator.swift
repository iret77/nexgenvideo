import Foundation
import Observation
import NexGenEngine

@MainActor
final class GenerationBatchRecovery {
    let options: [SpendOption]
    private let pipelineScope: SpendPipelineScope?
    private let prepareOperation: @MainActor (EditorViewModel, SpendOption) async throws -> GenerationPackageV1

    init(
        options: [SpendOption],
        pipelineScope: SpendPipelineScope? = nil,
        prepare: @escaping @MainActor (EditorViewModel, SpendOption) async throws -> GenerationPackageV1
    ) {
        self.options = options
        self.pipelineScope = pipelineScope
        prepareOperation = prepare
    }

    func prepare(editor: EditorViewModel, option: SpendOption) async throws -> GenerationPackageV1 {
        guard let selected = options.first(where: { $0.id == option.id }),
              selected.target == option.target,
              selected.isCurrentlyAvailable else {
            throw GenerationRequestError.gate("The selected generation route is no longer available.")
        }
        let lease = try pipelineScope?.acquireMutation(
            editor: editor,
            label: "Prepare generation batch route"
        )
        defer {
            if let lease {
                lease.coordinator.endMutation(projectRoot: lease.dataRoot, id: lease.id)
            }
        }
        return try await prepareOperation(editor, selected)
    }
}

@MainActor
final class GenerationBatchPreparation {
    @TaskLocal static var current: GenerationBatchPreparation?
    var entries: [(package: GenerationPackageV1, recovery: GenerationBatchRecovery)] = []
}

@MainActor
@Observable
final class GenerationBatchCoordinator {
    var pending: GenerationBatch?
    private(set) var snapshots: [GenerationBatchStore.Snapshot] = []
    private(set) var error: String?
    private(set) var approving = false
    @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var recoveries: [String: GenerationBatchRecovery] = [:]
    private(set) var recoveringItemIDs: Set<String> = []

    var isRecovering: Bool { !recoveringItemIDs.isEmpty }
    var canRetryPricing: Bool {
        pending?.payload.items.contains {
            $0.package.payload.estimate == nil
                && ($0.package.payload.pricingFailure?.isRetryable ?? true)
        } == true
    }

    func present(_ batch: GenerationBatch, recoveries: [String: GenerationBatchRecovery]) throws {
        try batch.validate()
        guard pending == nil,
              Set(recoveries.keys) == Set(batch.payload.items.map(\.id)) else {
            throw GenerationRequestError.gate("Every batch item needs an explicit pricing and route recovery path.")
        }
        self.recoveries = recoveries
        pending = batch
        error = nil
    }

    func record(_ snapshot: GenerationBatchStore.Snapshot) {
        readID = UUID()
        if let index = snapshots.firstIndex(where: { $0.batch.id == snapshot.batch.id }) { snapshots[index] = snapshot }
        else { snapshots.append(snapshot) }
    }

    func remove(itemID: String, editor: EditorViewModel) {
        guard let pending, !approving else { return }
        if pending.payload.items.count == 1 { decline(editor: editor); return }
        do {
            let updated = try pending.removing(itemIDs: [itemID])
            var updatedRecoveries = recoveries
            updatedRecoveries.removeValue(forKey: itemID)
            editor.agentService.replaceGenerationBatchPresentation(oldID: pending.id, newID: updated.id)
            recoveries = updatedRecoveries
            recoveringItemIDs.remove(itemID)
            self.pending = updated
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }

    func decline(editor: EditorViewModel) {
        guard !approving, let pending else { return }
        self.pending = nil
        error = nil
        recoveries = [:]
        recoveringItemIDs = []
        editor.agentService.completeGenerationBatch(pending.id, message: "The user declined the generation batch. No batch item was submitted.")
    }

    func approve(editor: EditorViewModel) async {
        guard let manifest = pending, !approving, !isRecovering, manifest.totalEUR != nil else { return }
        approving = true
        defer { approving = false }
        do {
            _ = try await GenerationBatchStore.approve(manifest, editor: editor)
            pending = nil
            recoveries = [:]
            error = nil
            start(batchID: manifest.id, editor: editor)
        } catch { self.error = error.localizedDescription }
    }

    func routeOptions(itemID: String) -> [SpendOption] {
        guard let item = pending?.payload.items.first(where: { $0.id == itemID }) else { return [] }
        return recoveries[itemID]?.options.filter {
            $0.target != item.package.payload.target && $0.isCurrentlyAvailable
        } ?? []
    }

    func retryPricing(
        editor: EditorViewModel,
        quoteLoader: GenerationBudgetGuard.QuoteLoader = LiveGenerationPricing.quote
    ) async {
        guard let original = pending, !approving, !isRecovering else { return }
        let items = original.payload.items.filter {
            $0.package.payload.estimate == nil
                && ($0.package.payload.pricingFailure?.isRetryable ?? true)
        }
        guard !items.isEmpty else { return }
        let itemIDs = Set(items.map(\.id))
        recoveringItemIDs.formUnion(itemIDs)
        error = nil
        defer {
            if pending == nil || pending?.payload.nonce == original.payload.nonce {
                recoveringItemIDs.subtract(itemIDs)
            }
        }
        do {
            for item in items {
                guard pending?.payload.nonce == original.payload.nonce,
                      pending?.payload.items.contains(where: { $0.id == item.id }) == true else {
                    continue
                }
                do {
                    try await item.package.requireCurrentContext(editor: editor)
                    let snapshot = try await GenerationPackageInputs.restore(package: item.package, editor: editor)
                    let pricingInput = try item.package.pricingInput()
                    let estimate: GenerationMoney?
                    let failure: GenerationPricingFailure?
                    do {
                        estimate = try await quoteLoader(item.package.payload.target, pricingInput)
                        failure = nil
                    } catch {
                        try Task.checkCancellation()
                        estimate = nil
                        failure = .classified(
                            error,
                            provider: item.package.payload.target.provider,
                            endpoint: item.package.payload.target.endpoint
                        )
                    }
                    guard pending?.payload.nonce == original.payload.nonce,
                          pending?.payload.items.contains(where: { $0.id == item.id }) == true else {
                        continue
                    }
                    let package = try item.package.replacingPricing(estimate: estimate, failure: failure)
                    try await GenerationPackageInputs.persist(package: package, snapshot: snapshot, editor: editor)
                    guard let current = pending,
                          current.payload.nonce == original.payload.nonce,
                          current.payload.items.contains(where: { $0.id == item.id }) else {
                        continue
                    }
                    let updated = try current.replacingPackage(itemID: item.id, with: package)
                    editor.agentService.replaceGenerationBatchPresentation(oldID: current.id, newID: updated.id)
                    pending = updated
                } catch {
                    guard pending?.payload.nonce == original.payload.nonce,
                          pending?.payload.items.contains(where: { $0.id == item.id }) == true else {
                        continue
                    }
                    throw error
                }
            }
        } catch {
            if pending?.payload.nonce == original.payload.nonce {
                self.error = error.localizedDescription
            }
        }
    }

    func changeRoute(itemID: String, option: SpendOption, editor: EditorViewModel) async {
        guard let original = pending, !approving, !recoveringItemIDs.contains(itemID),
              let recovery = recoveries[itemID],
              let item = original.payload.items.first(where: { $0.id == itemID }),
              option.target != item.package.payload.target else { return }
        recoveringItemIDs.insert(itemID)
        error = nil
        defer {
            if pending == nil || pending?.payload.nonce == original.payload.nonce {
                recoveringItemIDs.remove(itemID)
            }
        }
        do {
            let package = try await recovery.prepare(editor: editor, option: option)
            guard package.payload.target == option.target else {
                throw GenerationRequestError.gate("The prepared request did not use the selected route.")
            }
            try await package.requireCurrentContext(editor: editor)
            guard let current = pending,
                  current.payload.nonce == original.payload.nonce,
                  current.payload.items.contains(where: { $0.id == itemID }) else {
                return
            }
            let updated = try current.replacingPackage(itemID: itemID, with: package)
            editor.agentService.replaceGenerationBatchPresentation(oldID: current.id, newID: updated.id)
            pending = updated
        } catch {
            if pending?.payload.nonce == original.payload.nonce,
               pending?.payload.items.contains(where: { $0.id == itemID }) == true {
                self.error = error.localizedDescription
            }
        }
    }

    func cancelRemaining(batchID: String, editor: EditorViewModel) {
        do {
            guard let home = editor.workingRoot else { return }
            let snapshot = try GenerationBatchStore.load(id: batchID, home: home)
            _ = try GenerationBatchStore.update(snapshot, editor: editor) { $0.cancelRemaining() }
        } catch { self.error = error.localizedDescription }
    }

    func resume(editor: EditorViewModel, retryKnownJobs: Bool = true) {
        guard jobs.isEmpty, let home = editor.workingRoot else { return }
        let requestID = UUID()
        readID = requestID
        Task { @MainActor [weak self, weak editor] in
            do {
                let snapshots = try await Task.detached(priority: .utility) { try GenerationBatchStore.all(home: home) }.value
                guard let self, let editor, editor.workingRoot == home, self.readID == requestID else { return }
                try GenerationBatchStore.reconcileRuntime(snapshots, editor: editor)
                self.snapshots = snapshots
                self.error = nil
                let candidates = snapshots.filter { snapshot in snapshot.authorityAvailable && snapshot.journal.executions.contains(where: {
                    [.queued, .submitting, .running].contains($0.state) || (retryKnownJobs && $0.state == .blocked && $0.providerRequestResumable)
                }) }.map(\.batch.id)
                if let first = candidates.first {
                    self.start(batchID: first, editor: editor, resumeBlocked: retryKnownJobs,
                               remainingBatchIDs: Array(candidates.dropFirst()))
                }
            } catch {
                guard let self, let editor, editor.workingRoot == home, self.readID == requestID else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func start(batchID: String, editor: EditorViewModel, resumeBlocked: Bool = false,
               remainingBatchIDs: [String] = []) {
        guard jobs.isEmpty, let home = editor.workingRoot else { return }
        jobs[batchID] = Task { @MainActor [weak self, weak editor] in
            guard let self, let editor else { return }
            var settled = false
            defer {
                self.jobs.removeValue(forKey: batchID)
                if editor.workingRoot == home {
                    if let next = remainingBatchIDs.first {
                        self.start(batchID: next, editor: editor, resumeBlocked: resumeBlocked,
                                   remainingBatchIDs: Array(remainingBatchIDs.dropFirst()))
                    } else if settled { self.resume(editor: editor, retryKnownJobs: false) }
                }
            }
            do {
                await CatalogDiscovery.ensureCurrent()
                guard editor.workingRoot == home else { return }
                let manifest = try GenerationBatchStore.load(id: batchID, home: home).batch
                for item in manifest.payload.items {
                    guard editor.workingRoot == home else { return }
                    let snapshot = try GenerationBatchStore.load(id: batchID, home: home)
                    guard let state = snapshot.journal.executions.first(where: { $0.itemID == item.id }) else { continue }
                    let authorization = GenerationBatchAuthorization(batchID: batchID, itemID: item.id)
                    do {
                        var lease: (root: URL, id: UUID)?
                        if [.queued, .submitting, .running].contains(state.state) || (state.state == .blocked && resumeBlocked),
                           let root = DataRootResolver.dataRoot(of: home) {
                            guard let id = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: manifest.payload.phase ?? "Generation batch") else {
                                throw GenerationRequestError.gate("Another pipeline job is running. Resume this batch when that work finishes.")
                            }
                            lease = (root, id)
                        }
                        defer {
                            if let lease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: lease.root, id: lease.id) }
                        }
                        switch state.state {
                        case .queued:
                            let generation = try await GenerationController.restoreApprovedBatchItem(authorization, editor: editor)
                            let result = try await GenerationController.submitPrepared(generation, editor: editor).get()
                            await editor.generationService.waitForGeneration(placeholderId: result.placeholderId)
                        case .running:
                            try await editor.generationService.resumeBatchJob(authorization, editor: editor)
                        case .submitting:
                            guard let transaction = state.transactionID,
                                  let receipt = editor.generationLog.spendEvents.first(where: {
                                      $0.transactionId == transaction && $0.kind == .submitted && $0.providerRequestResumable == true
                                  }), let requestID = receipt.providerRequestId else {
                                throw GenerationRequestError.gate("Submission was interrupted before a provider receipt was saved. This item will not be sent again.")
                            }
                            try authorization.recordProviderRequest(transactionID: transaction, requestID: requestID, resumable: true, editor: editor)
                            try await editor.generationService.resumeBatchJob(authorization, editor: editor)
                        case .blocked where resumeBlocked && state.providerRequestResumable:
                            try await editor.generationService.resumeBatchJob(authorization, editor: editor)
                        case .complete, .failed, .canceled, .blocked: break
                        }
                    } catch {
                        guard editor.workingRoot == home else { return }
                        let current = try GenerationBatchStore.load(id: batchID, home: home)
                        if let execution = current.journal.executions.first(where: { $0.itemID == item.id }),
                           [.queued, .submitting, .running].contains(execution.state) {
                            _ = try GenerationBatchStore.update(current, editor: editor) {
                                try $0.stop(itemID: item.id, state: .blocked, detail: error.localizedDescription)
                            }
                        }
                    }
                }
                editor.agentService.completeGenerationBatch(batchID,
                    message: "Generation batch \(batchID) has settled. Read get_generation_batches for completed outputs and any failed or blocked items before continuing the phase.")
                settled = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
