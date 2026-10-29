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
    /// Set while a batch is approved under the user's phase approval, so the dock shows no card.
    private(set) var autoApprovingPhase: String?
    @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]
    /// Tests compare approval records without starting provider work.
    @ObservationIgnored var startsApprovedBatches = true
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var recoveries: [String: GenerationBatchRecovery] = [:]
    private(set) var recoveringItemIDs: Set<String> = []
    private(set) var activeBatchID: String?
    private(set) var lastProgressAt: [String: Date] = [:]
    private(set) var providerConfirmedAt: [String: Date] = [:]
    private(set) var preflightIssue: String?
    private(set) var preflighting = false
    @ObservationIgnored private var preflightID = UUID()
    private var preflightApprovedBatchID: String?
    @ObservationIgnored var catalogReadiness: @MainActor () async -> Void = { _ = await CatalogDiscovery.ensureCurrent() }
    @ObservationIgnored var quoteLoader: GenerationBudgetGuard.QuoteLoader = LiveGenerationPricing.quote
    @ObservationIgnored var providerActivation: @MainActor () -> ProviderActivation = { .current() }
    @ObservationIgnored var modelCatalog: ModelCatalog = .shared
    private(set) var pausedBatches: [String: Pause] = [:]
    @ObservationIgnored private var continuationAfterCancellation: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var executionLifetimes: [String: GenerationBatchExecutionLifetime] = [:]
    @ObservationIgnored private var closeDrain: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var restorationReads: [UUID: Task<Void, Never>] = [:]
    private struct PreparationTask {
        let lifetime: GenerationBatchExecutionLifetime
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var preparationTasks: [UUID: PreparationTask] = [:]
    @ObservationIgnored private var preventingNewWork = false

    var hasCloseWork: Bool { !jobs.isEmpty || !restorationReads.isEmpty || !preparationTasks.isEmpty || continuationAfterCancellation != nil || closeDrain != nil }

    struct Pause: Equatable {
        enum Reason: String { case hostBusy, requestRefused }
        let reason: Reason
        let detail: String
    }

    var canApprovePending: Bool {
        !preventingNewWork && closeDrain == nil && pending != nil && preflightApprovedBatchID == pending?.id && preflightIssue == nil && !preflighting
    }

    func preflightKey(editor: EditorViewModel) -> String {
        let referenceIDs = Set(pending?.payload.items.flatMap { $0.package.payload.references.map(\.assetID) } ?? [])
        let sources = editor.mediaAssets.filter { referenceIDs.contains($0.id) }.map {
            [$0.id, $0.type.rawValue, $0.url.absoluteString].joined(separator: "|")
        }.sorted().joined(separator: "\n")
        return [pending?.id ?? "none", editor.workingRoot?.absoluteString ?? "closed", sources].joined(separator: "\n")
    }

    func preflight(editor: EditorViewModel, expectedBatchID: String) async {
        await prepareOwned(editor: editor) { await self.performPreflight(editor: editor, expectedBatchID: expectedBatchID) }
    }

    private func performPreflight(editor: EditorViewModel, expectedBatchID: String) async {
        guard let batch = pending, batch.id == expectedBatchID else { return }
        let requestID = UUID()
        let key = preflightKey(editor: editor)
        preflightID = requestID
        preflighting = true
        preflightApprovedBatchID = nil
        defer { if preflightID == requestID { preflighting = false } }
        do {
            var checked = Set<String>()
            for item in batch.payload.items where checked.insert(item.package.id).inserted {
                try await item.package.requireCurrentContext(editor: editor)
                try await GenerationPackageInputs.validate(package: item.package, editor: editor)
            }
            guard !Task.isCancelled, GenerationBatchExecutionLifetime.current?.isAbandoned != true,
                  preflightID == requestID, pending?.id == expectedBatchID,
                  preflightKey(editor: editor) == key else { return }
            preflightIssue = nil
            preflightApprovedBatchID = expectedBatchID
        } catch {
            guard !Task.isCancelled, GenerationBatchExecutionLifetime.current?.isAbandoned != true,
                  preflightID == requestID, pending?.id == expectedBatchID else { return }
            preflightIssue = error.localizedDescription
        }
    }

    var isRecovering: Bool { !recoveringItemIDs.isEmpty }
    var canRetryPricing: Bool {
        pending?.payload.items.contains {
            $0.package.payload.estimate == nil
                && ($0.package.payload.pricingFailure?.isRetryable ?? true)
        } == true
    }

    func present(_ batch: GenerationBatch, recoveries: [String: GenerationBatchRecovery]) throws {
        try batch.validate()
        guard !preventingNewWork, closeDrain == nil else { throw GenerationRequestError.gate("The project is closing. This batch was not presented or approved.") }
        guard pending == nil,
              Set(recoveries.keys) == Set(batch.payload.items.map(\.id)) else {
            throw GenerationRequestError.gate("Every batch item needs an explicit pricing and route recovery path.")
        }
        self.recoveries = recoveries
        pending = batch
        error = nil
        preflightIssue = nil
        preflightApprovedBatchID = nil
    }

    func record(_ snapshot: GenerationBatchStore.Snapshot) {
        if let previous = snapshots.first(where: { $0.batch.id == snapshot.batch.id }),
           previous.journal.revision != snapshot.journal.revision {
            lastProgressAt[snapshot.batch.id] = Date()
        }
        readID = UUID()
        if let index = snapshots.firstIndex(where: { $0.batch.id == snapshot.batch.id }) { snapshots[index] = snapshot }
        else { snapshots.append(snapshot) }
    }

    func remove(itemID: String, editor: EditorViewModel) {
        guard !preventingNewWork, let pending, !approving else { return }
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
        guard !preventingNewWork, !approving, let pending else { return }
        self.pending = nil
        error = nil
        recoveries = [:]
        recoveringItemIDs = []
        editor.agentService.completeGenerationBatch(pending.id, message: "The user declined the generation batch. No batch item was submitted.")
    }

    func requestRevision(editor: EditorViewModel) {
        guard !preventingNewWork, !approving, let pending else { return }
        let message = revisionMessage()
        self.pending = nil
        error = nil
        recoveries = [:]
        recoveringItemIDs = []
        editor.agentService.completeGenerationBatch(pending.id, message: message)
    }

    func revisionMessage() -> String {
        var message = "The user requests a revised generation proposal. Nothing was submitted. Explain the intended outputs briefly, "
            + "then offer a concrete next step. Preserve the user's chosen model; ask before substituting it. "
            + "Do not re-present the same unresolved proposal. A missing price estimate is not a blocker and does not require changing the request."
        if let failure = preflightIssue ?? error {
            message += "\nRequest failure to resolve before preparing a new batch:\n" + failure
            let references = pending?.payload.items.flatMap { $0.package.payload.references } ?? []
            if !references.isEmpty {
                message += "\nReference identities:\n" + Set(references.map {
                    "\($0.displayName ?? "Unnamed reference"): \($0.assetID)"
                }).sorted().joined(separator: "\n")
            }
        }
        return message
    }

    /// Under a phase grant, authority is created only while that grant still holds; else the batch stays pending.
    @discardableResult
    func approve(editor: EditorViewModel, expectedBatchID: String, approval: GenerationBatchApproval = .verifiedPrices,
                 underPhaseApproval grant: PhaseSpendApproval? = nil) async -> Bool {
        var approved = false
        await prepareOwned(editor: editor) {
            approved = await self.performApprove(editor: editor, expectedBatchID: expectedBatchID, approval: approval, underPhaseApproval: grant)
        }
        return approved
    }

    private func performApprove(editor: EditorViewModel, expectedBatchID: String, approval: GenerationBatchApproval,
                                underPhaseApproval grant: PhaseSpendApproval?) async -> Bool {
        guard let manifest = pending, manifest.id == expectedBatchID, !approving, !isRecovering,
              manifest.totalEUR != nil || approval == .acceptUnknownPrices else { return false }
        approving = true
        defer { approving = false }
        await preflight(editor: editor, expectedBatchID: expectedBatchID)
        guard pending?.id == expectedBatchID, canApprovePending else { return false }
        let confirm: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try GenerationBatchExecutionLifetime.requireActive()
            if let grant, !editor.phaseSpendApproval.isActive(grant, editor: editor) { throw PhaseSpendApprovalEnded() }
        }
        do {
            _ = try await GenerationBatchStore.approve(manifest, editor: editor, approval: approval, confirm: confirm)
            pending = nil
            recoveries = [:]
            error = nil
            editor.agentService.noteGenerationBatchStarted(manifest.id)
            if startsApprovedBatches, !Task.isCancelled, GenerationBatchExecutionLifetime.current?.isAbandoned != true {
                start(batchID: manifest.id, editor: editor)
            }
            return true
        } catch is PhaseSpendApprovalEnded {
            return false
        } catch {
            guard !Task.isCancelled, GenerationBatchExecutionLifetime.current?.isAbandoned != true else { return false }
            self.error = "Generation approval failed: " + error.localizedDescription
            await preflight(editor: editor, expectedBatchID: expectedBatchID)
            return false
        }
    }

    /// The user approves every paid agent run of this batch's phase, starting with this batch.
    func approveForPhase(editor: EditorViewModel, expectedBatchID: String) async {
        await prepareOwned(editor: editor) { await self.performApproveForPhase(editor: editor, expectedBatchID: expectedBatchID) }
    }

    private func performApproveForPhase(editor: EditorViewModel, expectedBatchID: String) async {
        guard let manifest = pending, manifest.id == expectedBatchID, let phase = manifest.payload.phase,
              !approving, !isRecovering else { return }
        await preflight(editor: editor, expectedBatchID: expectedBatchID)
        guard pending?.id == expectedBatchID, canApprovePending, !approving, !isRecovering else { return }
        guard let grant = editor.phaseSpendApproval.grant(phase: phase, editor: editor) else {
            error = "This phase can't be approved as a whole right now. Approve this batch on its own."
            return
        }
        await approveRecordingPhaseRun(manifest, editor: editor, grant: grant)
    }

    /// Approves a presented batch under an active phase approval through the same call the approve
    /// button makes, so its manifest and execution authority are identical to a manual approval.
    func approveUnderPhaseApproval(editor: EditorViewModel, expectedBatchID: String, grant: PhaseSpendApproval) {
        guard !preventingNewWork, closeDrain == nil else { return }
        let phase = grant.phase
        autoApprovingPhase = phase
        Task { @MainActor [weak self, weak editor] in
            guard let self else { return }
            defer { if self.autoApprovingPhase == phase { self.autoApprovingPhase = nil } }
            guard let editor, let manifest = self.pending, manifest.id == expectedBatchID,
                  editor.phaseSpendApproval.isActive(grant, editor: editor) else { return }
            await self.approveRecordingPhaseRun(manifest, editor: editor, grant: grant)
        }
    }

    func approveRecordingPhaseRun(_ manifest: GenerationBatch, editor: EditorViewModel,
                                  grant: PhaseSpendApproval?) async {
        await prepareOwned(editor: editor) { await self.performApproveRecordingPhaseRun(manifest, editor: editor, grant: grant) }
    }

    private func performApproveRecordingPhaseRun(_ manifest: GenerationBatch, editor: EditorViewModel,
                                                 grant: PhaseSpendApproval?) async {
        let approved = await approve(editor: editor, expectedBatchID: manifest.id,
            approval: manifest.totalEUR == nil ? .acceptUnknownPrices : .verifiedPrices, underPhaseApproval: grant)
        guard approved, !Task.isCancelled, GenerationBatchExecutionLifetime.current?.isAbandoned != true else { return }
        let count = manifest.payload.items.count
        editor.phaseSpendApproval.recordRun(
            label: count == 1 ? String(localized: "Batch of 1 request") : String(localized: "Batch of \(count) requests"),
            detail: manifest.payload.items.map(\.purpose).joined(separator: ", "),
            editor: editor
        )
    }

    func routeOptions(itemID: String) -> [SpendOption] {
        guard let item = pending?.payload.items.first(where: { $0.id == itemID }) else { return [] }
        return recoveries[itemID]?.options.filter {
            $0.target != item.package.payload.target && $0.isCurrentlyAvailable
        } ?? []
    }

    func retryPricing(
        editor: EditorViewModel,
        quoteLoader: @escaping GenerationBudgetGuard.QuoteLoader = LiveGenerationPricing.quote
    ) async {
        await prepareOwned(editor: editor) { await self.performRetryPricing(editor: editor, quoteLoader: quoteLoader) }
    }

    private func performRetryPricing(editor: EditorViewModel, quoteLoader: GenerationBudgetGuard.QuoteLoader) async {
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
                    try Task.checkCancellation()
                    try GenerationBatchExecutionLifetime.requireActive()
                    let package = try item.package.replacingPricing(estimate: estimate, failure: failure)
                    try await GenerationPackageInputs.persist(package: package, snapshot: snapshot, editor: editor)
                    try Task.checkCancellation()
                    try GenerationBatchExecutionLifetime.requireActive()
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
            if !Task.isCancelled, GenerationBatchExecutionLifetime.current?.isAbandoned != true,
               pending?.payload.nonce == original.payload.nonce {
                self.error = error.localizedDescription
            }
        }
    }

    func changeRoute(itemID: String, option: SpendOption, editor: EditorViewModel) async {
        await prepareOwned(editor: editor) { await self.performChangeRoute(itemID: itemID, option: option, editor: editor) }
    }

    private func performChangeRoute(itemID: String, option: SpendOption, editor: EditorViewModel) async {
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
            try Task.checkCancellation()
            try GenerationBatchExecutionLifetime.requireActive()
            guard package.payload.target == option.target else {
                throw GenerationRequestError.gate("The prepared request did not use the selected route.")
            }
            try await package.requireCurrentContext(editor: editor)
            try Task.checkCancellation()
            try GenerationBatchExecutionLifetime.requireActive()
            guard let current = pending,
                  current.payload.nonce == original.payload.nonce,
                  current.payload.items.contains(where: { $0.id == itemID }) else {
                return
            }
            let updated = try current.replacingPackage(itemID: itemID, with: package)
            editor.agentService.replaceGenerationBatchPresentation(oldID: current.id, newID: updated.id)
            pending = updated
        } catch {
            if !Task.isCancelled, GenerationBatchExecutionLifetime.current?.isAbandoned != true,
               pending?.payload.nonce == original.payload.nonce,
               pending?.payload.items.contains(where: { $0.id == itemID }) == true {
                self.error = error.localizedDescription
            }
        }
    }

    func cancelRemaining(batchID: String, editor: EditorViewModel) {
        guard !preventingNewWork else { return }
        readID = UUID()
        do {
            guard let home = editor.workingRoot else { return }
            let snapshot = try GenerationBatchStore.load(id: batchID, home: home)
            let canceled = try GenerationBatchStore.update(snapshot, editor: editor) { $0.cancelRemaining() }
            if activeBatchID != batchID,
               !canceled.journal.executions.contains(where: { [.queued, .submitting, .running].contains($0.state) }) {
                pausedBatches.removeValue(forKey: batchID)
                editor.agentService.completeGenerationBatch(batchID,
                    message: "Generation batch \(batchID) has settled after cancellation. Read get_generation_batches for completed outputs and canceled or blocked items before continuing the phase.")
                resumeAfterTerminalCancellation(editor: editor)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func resumeAfterTerminalCancellation(editor: EditorViewModel) {
        guard !preventingNewWork, closeDrain == nil, jobs.isEmpty, let home = editor.workingRoot else { return }
        let projectID = editor.projectId, generation = editor.openWorkingCopyGeneration
        let runner = editor.pipelinePhaseRunCoordinator
        let root = DataRootResolver.dataRoot(of: home)
        continuationAfterCancellation?.task.cancel()
        let id = UUID()
        let task = Task { @MainActor [weak self, weak editor] in
            if let root {
                while runner.runningPhase(projectRoot: root) != nil {
                    do { try await Task.sleep(for: .milliseconds(50)) }
                    catch { return }
                }
            }
            guard let self else { return }
            defer { if self.continuationAfterCancellation?.id == id { self.continuationAfterCancellation = nil } }
            guard !Task.isCancelled, let editor, editor.workingRoot == home,
                  editor.projectId == projectID, editor.openWorkingCopyGeneration == generation,
                  self.jobs.isEmpty else { return }
            self.resume(editor: editor, retryKnownJobs: false)
        }
        continuationAfterCancellation = (id, task)
    }

    @discardableResult
    func resume(editor: EditorViewModel, retryKnownJobs: Bool = true) -> Task<Void, Never>? {
        guard !preventingNewWork, jobs.isEmpty, closeDrain == nil, let home = editor.workingRoot else { return nil }
        editor.generationService.flushPendingReceipts(editor: editor)
        let requestID = UUID()
        let projectID = editor.projectId, generation = editor.openWorkingCopyGeneration
        readID = requestID
        let task = Task { @MainActor [weak self, weak editor] in
            defer { self?.restorationReads.removeValue(forKey: requestID) }
            do {
                let snapshots = try await Task.detached(priority: .utility) { try GenerationBatchStore.all(home: home) }.value
                guard !Task.isCancelled, let self, let editor, editor.workingRoot == home,
                      editor.projectId == projectID, editor.openWorkingCopyGeneration == generation,
                      self.readID == requestID, self.jobs.isEmpty else { return }
                try GenerationBatchStore.reconcileRuntime(snapshots, editor: editor)
                self.snapshots = snapshots
                self.error = nil
                let candidates = snapshots.filter { snapshot in snapshot.authorityAvailable
                    && self.pausedBatches[snapshot.batch.id] == nil && snapshot.journal.executions.contains(where: {
                    [.queued, .submitting, .running].contains($0.state) || (retryKnownJobs && $0.state == .blocked && $0.providerRequestResumable)
                }) }.map(\.batch.id)
                if let first = candidates.first {
                    self.start(batchID: first, editor: editor, resumeBlocked: retryKnownJobs,
                               remainingBatchIDs: Array(candidates.dropFirst()))
                }
            } catch {
                guard !Task.isCancelled, let self, let editor, editor.workingRoot == home,
                      editor.projectId == projectID, editor.openWorkingCopyGeneration == generation,
                      self.readID == requestID, self.jobs.isEmpty else { return }
                self.error = error.localizedDescription
            }
        }
        restorationReads[requestID] = task
        return task
    }

    func start(batchID: String, editor: EditorViewModel, resumeBlocked: Bool = false,
               remainingBatchIDs: [String] = []) {
        guard !preventingNewWork, jobs.isEmpty, closeDrain == nil, let home = editor.workingRoot else { return }
        activeBatchID = batchID
        pausedBatches.removeValue(forKey: batchID)
        providerConfirmedAt.removeValue(forKey: batchID)
        let projectID = editor.projectId, generation = editor.openWorkingCopyGeneration
        let lifetime = GenerationBatchExecutionLifetime()
        executionLifetimes[batchID] = lifetime
        jobs[batchID] = Task { @MainActor [weak self, weak editor] in
            guard let self else { return }
            guard let editor else {
                self.jobs.removeValue(forKey: batchID)
                self.executionLifetimes.removeValue(forKey: batchID)
                if self.activeBatchID == batchID { self.activeBatchID = nil }
                return
            }
            await GenerationBatchExecutionLifetime.$current.withValue(lifetime) {
                await ProviderStatusSignal.$observer.withValue({ [weak self] in
                    Task { @MainActor in self?.recordProviderStatus(batchID: batchID) }
                }) {
                    await self.run(batchID: batchID, editor: editor, home: home, projectID: projectID,
                        generation: generation, lifetime: lifetime, resumeBlocked: resumeBlocked, remainingBatchIDs: remainingBatchIDs)
                }
            }
        }
    }

    @discardableResult
    func cancelForClose(preventNewWork: Bool = false) -> Task<Void, Never> {
        if preventNewWork { preventingNewWork = true }
        if let closeDrain { return closeDrain.task }
        readID = UUID()
        preflightID = UUID()
        preflightApprovedBatchID = nil
        preflighting = false
        let preparations = Array(preparationTasks.values)
        preparations.forEach { $0.lifetime.abandon(); $0.task.cancel() }
        let continuation = continuationAfterCancellation?.task
        continuationAfterCancellation = nil
        continuation?.cancel()
        executionLifetimes.values.forEach { $0.abandon() }
        let tasks = Array(jobs.values)
        tasks.forEach { $0.cancel() }
        let readers = Array(restorationReads.values)
        readers.forEach { $0.cancel() }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await continuation?.value
            for task in tasks { await task.value }
            for task in readers { await task.value }
            for preparation in preparations { await preparation.task.value }
            if self?.closeDrain?.id == id { self?.closeDrain = nil }
        }
        closeDrain = (id, task)
        return task
    }

    private func prepareOwned(editor: EditorViewModel, operation: @escaping @MainActor () async -> Void) async {
        guard !Task.isCancelled, !preventingNewWork, closeDrain == nil,
              GenerationBatchExecutionLifetime.current?.isAbandoned != true,
              let home = editor.workingRoot else { return }
        let project = editor.projectId, generation = editor.openWorkingCopyGeneration
        let lifetime = GenerationBatchExecutionLifetime.current ?? GenerationBatchExecutionLifetime()
        let id = UUID()
        let task = Task { @MainActor in
            defer { self.preparationTasks.removeValue(forKey: id) }
            guard !Task.isCancelled, !lifetime.isAbandoned, !self.preventingNewWork,
                  editor.workingRoot == home, editor.projectId == project, editor.openWorkingCopyGeneration == generation else { return }
            await GenerationBatchExecutionLifetime.$current.withValue(lifetime) { await operation() }
        }
        preparationTasks[id] = PreparationTask(lifetime: lifetime, task: task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func recordProviderStatus(batchID: String, at date: Date = Date()) {
        guard activeBatchID == batchID, executionLifetimes[batchID]?.isAbandoned != true else { return }
        providerConfirmedAt[batchID] = date
    }

    enum Continuation: Equatable {
        case queuedRequests
        case recordedJobs
    }

    func continuation(for snapshot: GenerationBatchStore.Snapshot, editor: EditorViewModel? = nil) -> Continuation? {
        guard snapshot.authorityAvailable else { return nil }
        if snapshot.journal.executions.contains(where: { $0.state == .queued }) { return .queuedRequests }
        if snapshot.journal.executions.contains(where: {
            [.running, .blocked].contains($0.state) && $0.providerRequestResumable
                && $0.providerRequestID != nil && $0.transactionID != nil
        }) { return .recordedJobs }
        if let editor, snapshot.journal.executions.contains(where: { execution in
            execution.state == .submitting && execution.transactionID.map { transaction in
                editor.generationLog.spendEvents.contains {
                    $0.transactionId == transaction && $0.kind == .submitted && $0.providerRequestResumable == true
                        && $0.providerRequestId?.isEmpty == false
                }
            } == true
        }) { return .recordedJobs }
        return nil
    }

    func canContinue(_ snapshot: GenerationBatchStore.Snapshot, editor: EditorViewModel) -> Bool {
        guard !preventingNewWork, continuation(for: snapshot, editor: editor) != nil, activeBatchID == nil, jobs.isEmpty,
              closeDrain == nil,
              !approving, !isRecovering, !editor.agentService.isStreaming,
              let home = editor.workingRoot else { return false }
        if let root = DataRootResolver.dataRoot(of: home) {
            return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
        }
        return true
    }

    func continueBatch(batchID: String, editor: EditorViewModel) {
        do {
            guard let home = editor.workingRoot else { return }
            let current = try GenerationBatchStore.load(id: batchID, home: home)
            record(current)
            guard canContinue(current, editor: editor) else { return }
            error = nil
            start(batchID: batchID, editor: editor, resumeBlocked: true)
        } catch { self.error = error.localizedDescription }
    }

    func requireAfterGenerationWait(_ authorization: GenerationBatchAuthorization, placeholderID: String,
                                    editor: EditorViewModel) throws {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The batch project is closed.") }
        let current = try GenerationBatchStore.load(id: authorization.batchID, home: home)
        guard current.authorityAvailable,
              let execution = current.journal.executions.first(where: { $0.itemID == authorization.itemID }) else {
            throw GenerationRequestError.gate("The generation execution authority is no longer available.")
        }
        if execution.state == .queued {
            let message: String
            if let asset = editor.mediaAssets.first(where: { $0.id == placeholderID }), case .failed(let detail) = asset.generationStatus {
                message = detail
            } else { message = "The approved request was refused before submission." }
            throw GenerationRequestError.gate(message)
        }
    }

    private func run(batchID: String, editor: EditorViewModel, home: URL, projectID: String?, generation: UUID?,
                     lifetime: GenerationBatchExecutionLifetime, resumeBlocked: Bool,
                     remainingBatchIDs: [String]) async {
        func isCurrent() -> Bool {
            !Task.isCancelled && !lifetime.isAbandoned && editor.workingRoot == home
                && editor.projectId == projectID && editor.openWorkingCopyGeneration == generation
        }
        var settled = false
        var pausedForHost = false
        defer {
            if executionLifetimes[batchID] === lifetime {
                self.jobs.removeValue(forKey: batchID)
                executionLifetimes.removeValue(forKey: batchID)
                if activeBatchID == batchID { self.activeBatchID = nil }
            }
            if isCurrent(), !pausedForHost {
                if let next = remainingBatchIDs.first {
                    self.start(batchID: next, editor: editor, resumeBlocked: resumeBlocked,
                               remainingBatchIDs: Array(remainingBatchIDs.dropFirst()))
                } else if settled { self.resume(editor: editor, retryKnownJobs: false) }
            }
        }
        do {
            guard isCurrent() else { return }
            await catalogReadiness()
            guard isCurrent() else { return }
            let manifest = try GenerationBatchStore.load(id: batchID, home: home).batch
            for item in manifest.payload.items {
                guard isCurrent() else { return }
                let snapshot = try GenerationBatchStore.load(id: batchID, home: home)
                guard let state = snapshot.journal.executions.first(where: { $0.itemID == item.id }) else { continue }
                let authorization = GenerationBatchAuthorization(batchID: batchID, itemID: item.id)
                do {
                    var lease: (root: URL, id: UUID)?
                    if [.queued, .submitting, .running].contains(state.state) || (state.state == .blocked && resumeBlocked),
                       let root = DataRootResolver.dataRoot(of: home) {
                        guard let id = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: manifest.payload.phase ?? "Generation batch") else {
                            record(snapshot)
                            pausedBatches[batchID] = Pause(reason: .hostBusy,
                                detail: editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) ?? "Pipeline work")
                            error = "Generation is paused while another pipeline job runs. Continue the approved requests when that work finishes."
                            pausedForHost = true
                            return
                        }
                        lease = (root, id)
                    }
                    defer {
                        if let lease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: lease.root, id: lease.id) }
                    }
                    switch state.state {
                    case .queued:
                        let generation = try await GenerationController.restoreApprovedBatchItem(authorization, editor: editor)
                        guard isCurrent() else { return }
                        let result = try await GenerationController.submitPrepared(generation, editor: editor, quoteLoader: quoteLoader).get()
                        await editor.generationService.waitForBatchGeneration(placeholderId: result.placeholderId)
                        guard isCurrent() else { return }
                        try requireAfterGenerationWait(authorization, placeholderID: result.placeholderId, editor: editor)
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
                    guard isCurrent() else { return }
                    let current = try GenerationBatchStore.load(id: batchID, home: home)
                    if let execution = current.journal.executions.first(where: { $0.itemID == item.id }), execution.state == .queued {
                        record(current)
                        pausedBatches[batchID] = Pause(reason: .requestRefused, detail: error.localizedDescription)
                        self.error = "The approved request has not been sent. \(error.localizedDescription) Continue after resolving this issue, or cancel the remaining requests."
                        pausedForHost = true
                        return
                    }
                    if let execution = current.journal.executions.first(where: { $0.itemID == item.id }),
                       [.submitting, .running].contains(execution.state) {
                        _ = try GenerationBatchStore.update(current, editor: editor) {
                            try $0.stop(itemID: item.id, state: .blocked, detail: error.localizedDescription)
                        }
                    }
                }
            }
            guard isCurrent() else { return }
            editor.agentService.completeGenerationBatch(batchID,
                message: "Generation batch \(batchID) has settled. Read get_generation_batches for completed outputs and any failed or blocked items before continuing the phase.")
            settled = true
        } catch { if isCurrent() { self.error = error.localizedDescription } }
    }
}
