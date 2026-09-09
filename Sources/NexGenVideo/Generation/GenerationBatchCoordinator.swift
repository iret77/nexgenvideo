import Foundation
import Observation
import NexGenEngine

@MainActor
final class GenerationBatchPreparation {
    @TaskLocal static var current: GenerationBatchPreparation?
    var packages: [GenerationPackageV1] = []
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
            editor.agentService.replaceGenerationBatchPresentation(oldID: pending.id, newID: updated.id)
            self.pending = updated
        }
        catch { self.error = error.localizedDescription }
    }

    func decline(editor: EditorViewModel) {
        guard !approving, let pending else { return }
        self.pending = nil; error = nil
        editor.agentService.completeGenerationBatch(pending.id, message: "The user declined the generation batch. No batch item was submitted.")
    }

    func approve(editor: EditorViewModel) async {
        guard let manifest = pending, !approving else { return }
        approving = true
        defer { approving = false }
        do {
            _ = try await GenerationBatchStore.approve(manifest, editor: editor)
            pending = nil
            error = nil
            start(batchID: manifest.id, editor: editor)
        } catch { self.error = error.localizedDescription }
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
                self.snapshots = snapshots
                self.error = nil
                let candidates = snapshots.filter { snapshot in snapshot.journal.executions.contains(where: {
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
