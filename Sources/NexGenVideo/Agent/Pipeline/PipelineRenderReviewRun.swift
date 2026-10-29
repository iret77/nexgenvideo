import Foundation
import NexGenEngine
import Observation

@MainActor
@Observable
final class PipelineRenderReviewRun {
    enum State: String { case idle, preparing, awaitingApproval, running, stopping, interrupted, failed, completed }
    struct Proposal: Sendable {
        let manifestID: String
        let pageCount: Int
        let remainingPages: Int
        let maximumSynthesisContexts: Int
        let estimatedInputTokens: Int
        let backend: String
        let modelID: String?
        let costDescription: String
        let isResume: Bool
    }

    private struct Prepared {
        let manifest: PipelineRenderReviewManifest
        let reference: CanonicalArtifactReferenceV1
        let binding: AgentReviewChildBinding
        let hostContext: AgentRuntimeHostContext
        let backend: AgentBackend
        let selectedModelID: String?
        let journal: PipelineRenderReviewRunStore.Journal?
        let phaseGrant: PhaseSpendApproval?
        let snapshotCheck: PipelineRenderReviewSnapshotCheck
    }

    private(set) var state: State = .idle
    private(set) var proposal: Proposal?
    private(set) var completedPages = 0
    private(set) var currentStage = ""
    private(set) var errorMessage: String?
    @ObservationIgnored private var prepared: Prepared?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var preparationID: UUID?
    private var preparationTask: Task<Proposal, Error>?
    @ObservationIgnored private var registry: AgentReviewChildRegistry?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private var automaticStartAttempted = false

    var isPreparingInputs: Bool { preparationTask != nil || preparationID != nil }

    @discardableResult
    func prepare(editor: EditorViewModel) async throws -> Proposal {
        try await prepare(editor: editor, revalidate: {})
    }

    @discardableResult
    func prepareNewReview(editor: EditorViewModel) async throws -> Proposal {
        try await prepare(editor: editor, reuse: false, revalidate: {})
    }

    @discardableResult
    func prepare(editor: EditorViewModel, reuse: Bool = true,
                 revalidate callerValidation: @escaping @MainActor @Sendable () throws -> Void) async throws -> Proposal {
        guard task == nil, preparationTask == nil else { throw GateBlocked("Wait for the current review to finish stopping.") }
        let work = Task { [self, editor] in try await prepareInputs(editor: editor, reuse: reuse, revalidate: callerValidation) }
        preparationTask = work
        defer { preparationTask = nil }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func prepareInputs(editor: EditorViewModel, reuse: Bool,
                                revalidate callerValidation: @escaping @MainActor @Sendable () throws -> Void) async throws -> Proposal {
        guard task == nil, preparationID == nil else { throw GateBlocked("Wait for the current review to finish stopping.") }
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "render_review") else {
            throw GateBlocked("Wait for the current production job before preparing the review.")
        }
        let attempt = UUID()
        preparationID = attempt
        state = .preparing; errorMessage = nil; proposal = nil; prepared = nil; completedPages = 0
        automaticStartAttempted = false
        defer {
            preparationID = nil
            editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease)
        }
        do {
            let binding = try editor.agentService.reviewChildBinding(leaseID: lease)
            let backend = editor.agentService.backend
            let selectedModelID = editor.agentService.reviewChildModelID
            let validate: @MainActor @Sendable () throws -> Void = { [weak self, weak editor] in
                try Task.checkCancellation()
                try callerValidation()
                guard let self, self.preparationID == attempt, let editor,
                      editor.agentService.backend == backend, editor.agentService.reviewChildModelID == selectedModelID else {
                    throw GateBlocked("The review context changed while preparing its inputs.")
                }
                try editor.agentService.requireReviewChildBinding(binding)
                _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: binding.trustedDeclaration, phase: "render_review")
            }
            try validate()
            let snapshot = try await PipelineRenderReviewWriter.capture(editor: editor, revalidate: validate)
            let preparation = Task.detached(priority: .userInitiated) {
                try PipelineRenderReviewManifest.prepare(snapshot: snapshot, dataRoot: root)
            }
            let files = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            defer { files.discard() }
            try validate()
            try await Self.checkSnapshot(snapshot, root: root, revalidate: validate)
            try ProjectWorkingCopy.markDirty(key: binding.workingCopyKey)
            let publishing = Task.detached(priority: .userInitiated) {
                try PipelineRenderReviewRunStore.publish(files, dataRoot: root)
            }
            try await withTaskCancellationHandler { try await publishing.value } onCancel: { publishing.cancel() }
            try validate()
            let manifest = files.manifest
            let reference = files.reference
            let loading = Task.detached(priority: .userInitiated) {
                let persisted = try PipelineRenderReviewRunStore.read(PipelineRenderReviewManifest.self, reference, dataRoot: root)
                guard try PlanningWriterIO.json(persisted) == PlanningWriterIO.json(manifest) else {
                    throw GateBlocked("The persisted review manifest changed while preparing it.")
                }
                try PipelineRenderReviewManifest.verify(manifest: manifest, snapshot: snapshot, dataRoot: root)
                let journal = reuse ? try PipelineRenderReviewRunStore.load(manifest: reference, dataRoot: root) : nil
                var completed = Set<String>()
                let pageIDs = Set(manifest.pages.map(\.id))
                if let journal {
                    for child in journal.children {
                        let verified = try PipelineRenderReviewRunVerification.verifyChild(child, manifest: manifest,
                            authorizationReferences: journal.authorizations, runID: journal.runID, dataRoot: root)
                        if pageIDs.contains(verified.page.submission.pageID) { completed.insert(verified.page.submission.pageID) }
                    }
                }
                return (journal, try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root), completed.count)
            }
            let (journal, snapshotCheck, completed) = try await withTaskCancellationHandler { try await loading.value } onCancel: { loading.cancel() }
            try validate()
            try snapshotCheck.requireCurrent()
            guard journal.map({ $0.backend == backend.rawValue && (selectedModelID == nil || $0.modelID == selectedModelID) }) ?? true else {
                throw GateBlocked("Resume this review with the same backend and exact model used for its completed pages.")
            }
            let context = try await editor.agentService.reviewChildHostContext(tools: PipelineRenderReviewRunReceipt.tools)
            try validate()
            let maximum = try PipelineRenderReviewSummary.maximumContexts(pageCount: manifest.pages.count)
            let tokens = try manifest.pages.reduce(0) { total, page in
                let sum = total.addingReportingOverflow(page.estimatedInputTokens)
                guard !sum.overflow else { throw GateBlocked("The review input estimate is too large.") }
                return sum.partialValue
            }
            let cost = backend == .claudeCode
                ? "Uses the connected Claude plan for the remaining page reviews and their summaries. Usage depends on the model responses."
                : "Uses the configured Anthropic API key for the remaining page reviews and their summaries. The exact cost is not known in advance."
            prepared = Prepared(manifest: manifest, reference: reference, binding: binding, hostContext: context,
                backend: backend, selectedModelID: selectedModelID, journal: journal,
                phaseGrant: reuse ? editor.phaseSpendApproval.active(phase: "render_review", editor: editor) : nil,
                snapshotCheck: snapshotCheck)
            let proposal = Proposal(manifestID: manifest.id, pageCount: manifest.pages.count, remainingPages: max(0, manifest.pages.count - completed),
                maximumSynthesisContexts: maximum, estimatedInputTokens: tokens, backend: backend.displayName,
                modelID: journal?.modelID ?? selectedModelID, costDescription: cost, isResume: journal != nil)
            self.proposal = proposal
            completedPages = completed
            currentStage = "Review inputs prepared"
            state = .awaitingApproval
            editor.onPipelineChanged?()
            return proposal
        } catch {
            state = error is CancellationError ? .interrupted : .failed
            errorMessage = error is CancellationError ? nil : error.localizedDescription
            throw error
        }
    }

    func approve(editor: EditorViewModel) throws {
        guard task == nil, preparationTask == nil, preparationID == nil, let prepared, let proposal,
              state == .awaitingApproval else { throw GateBlocked("Prepare the current review inputs before approving this run.") }
        try editor.agentService.requireReviewParentIdle()
        let root = prepared.binding.dataRoot
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "render_review") else {
            throw GateBlocked("Wait for the current production job before starting this review.")
        }
        do {
            let binding = prepared.binding.replacingLease(lease)
            try requireCurrent(prepared: prepared, binding: binding, editor: editor)
            try prepared.snapshotCheck.requireCurrent()
            let grant = editor.phaseSpendApproval.active(phase: "render_review", editor: editor)
            var journal = prepared.journal ?? .init(schema: "render-review-run/v2", runID: UUID(), manifest: prepared.reference,
                backend: prepared.backend.rawValue, modelID: prepared.selectedModelID, authorizations: [], children: [], status: .running, message: nil)
            let authorization = PipelineRenderReviewRunReceipt.Authorization(schema: "render-review-authorization/v2", id: UUID(),
                runID: journal.runID, manifest: prepared.reference, backend: prepared.backend.rawValue,
                requestedModelID: journal.modelID ?? prepared.selectedModelID, phaseGrantID: grant?.id,
                pageCount: proposal.pageCount, maximumSynthesisContexts: proposal.maximumSynthesisContexts,
                bounds: PipelineRenderReviewRunStore.bounds(), costDescription: proposal.costDescription, approvedAt: currentTimestamp())
            try ProjectWorkingCopy.markDirty(key: binding.workingCopyKey)
            let auth = try PipelineRenderReviewRunReceipt.publish(authorization,
                path: "render-review/runs/\(journal.runID.uuidString.lowercased())/authorizations/\(authorization.id.uuidString.lowercased()).v2.json",
                id: authorization.id.uuidString.lowercased(), role: "host.render-review-authorization", dataRoot: root)
            journal.authorizations.append(auth); journal.status = .running; journal.message = nil
            try PipelineRenderReviewRunStore.save(journal, dataRoot: root)
            activeRunID = journal.runID; registry = editor.agentService.reviewChildRegistry
            state = .running; errorMessage = nil
            if grant != nil {
                editor.phaseSpendApproval.recordRun(label: "Review render inputs", detail: proposal.costDescription, editor: editor)
            }
            task = Task { [self, editor] in
                await execute(prepared: prepared, binding: binding, authorization: authorization, authorizationReference: auth,
                    journal: journal, grant: grant, editor: editor)
            }
        } catch {
            editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease)
            throw error
        }
    }

    func startIfCovered(editor: EditorViewModel) {
        guard !automaticStartAttempted, state == .awaitingApproval, proposal?.isResume == false, let grant = prepared?.phaseGrant,
              editor.phaseSpendApproval.isActive(grant, editor: editor) else { return }
        automaticStartAttempted = true
        do { try approve(editor: editor) }
        catch { errorMessage = error.localizedDescription }
    }

    func cancel() async {
        if let task {
            state = .stopping
            task.cancel()
            if let activeRunID { await registry?.cancel(runID: activeRunID) }
            await task.value
            return
        }
        if let preparationTask {
            state = .stopping; proposal = nil; prepared = nil
            preparationTask.cancel()
            _ = await preparationTask.result
            if state == .stopping { state = .interrupted; errorMessage = nil }
            return
        }
        state = .idle; proposal = nil; prepared = nil
    }

    private func requireCurrent(prepared: Prepared, binding: AgentReviewChildBinding, editor: EditorViewModel) throws {
        try Task.checkCancellation()
        try editor.agentService.requireReviewChildBinding(binding)
        guard editor.agentService.backend == prepared.backend,
              editor.agentService.reviewChildModelID == prepared.selectedModelID else { throw GateBlocked("The review backend or model changed.") }
        _ = try PipelinePlanningWriteAccess(dataRoot: binding.dataRoot, declaration: binding.trustedDeclaration, phase: "render_review")
    }

    private func execute(prepared: Prepared, binding: AgentReviewChildBinding,
                         authorization: PipelineRenderReviewRunReceipt.Authorization,
                         authorizationReference: CanonicalArtifactReferenceV1,
                         journal initialJournal: PipelineRenderReviewRunStore.Journal,
                         grant: PhaseSpendApproval?, editor: EditorViewModel) async {
        var journal = initialJournal
        let root = binding.dataRoot
        let registry = editor.agentService.reviewChildRegistry
        let validate: @MainActor @Sendable () throws -> Void = { [self, editor] in
            try requireCurrent(prepared: prepared, binding: binding, editor: editor)
            guard state == .running, activeRunID == initialJournal.runID else { throw CancellationError() }
            if let grant, !editor.phaseSpendApproval.isActive(grant, editor: editor) { throw PhaseSpendApprovalEnded() }
        }
        defer {
            editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: binding.mutationLeaseID)
            task = nil; activeRunID = nil; self.registry = nil
            editor.onPipelineChanged?()
        }
        do {
            var pages: [CanonicalArtifactReferenceV1] = []
            for (index, page) in prepared.manifest.pages.enumerated() {
                try validate()
                currentStage = "Review page \(index + 1) of \(prepared.manifest.pages.count)"
                let scope = prepared.manifest.items.filter { page.itemIDs.contains($0.id) }.flatMap(\.shotIDs)
                let reference = try await child(kind: .page, pageID: page.id, itemIDs: page.itemIDs,
                    shotIDs: scope.isEmpty ? prepared.manifest.snapshot.shots.map(\.shotID) : Array(Set(scope)).sorted(),
                    sources: [], summary: nil, prepared: prepared, binding: binding, authorization: authorization,
                    authorizationReference: authorizationReference, journal: &journal, editor: editor, validate: validate)
                pages.append(reference); completedPages = pages.count
            }
            var reductions: [CanonicalArtifactReferenceV1] = []
            var units = try PipelineRenderReviewSummary.units(references: pages, dataRoot: root, includeFindings: true)
            while units.count > PipelineRenderReviewSummary.maximumUnits {
                let previousCount = units.count
                let contexts = try PipelineRenderReviewSummary.contexts(manifestID: prepared.manifest.id, units: units, kind: .reducer)
                var level: [CanonicalArtifactReferenceV1] = []
                for context in contexts {
                    try validate()
                    guard reductions.count < authorization.maximumSynthesisContexts - 1 else {
                        throw GateBlocked("The review exceeded its authorized summary contexts. Its completed pages are retained.")
                    }
                    currentStage = "Summarize completed review observations"
                    let reference = try await child(kind: .reducer, pageID: context.id, itemIDs: context.itemIDs,
                        shotIDs: prepared.manifest.snapshot.shots.map(\.shotID), sources: context.sourceReceipts,
                        summary: context, prepared: prepared, binding: binding, authorization: authorization,
                        authorizationReference: authorizationReference, journal: &journal, editor: editor, validate: validate)
                    reductions.append(reference); level.append(reference)
                }
                units = try PipelineRenderReviewSummary.units(references: level, dataRoot: root, includeFindings: false)
                guard units.count < previousCount else { throw GateBlocked("The review summaries did not fit the next context. Completed observations are retained.") }
            }
            guard let context = try PipelineRenderReviewSummary.contexts(manifestID: prepared.manifest.id, units: units, kind: .synthesis).first else {
                throw GateBlocked("The review has no final synthesis context.")
            }
            currentStage = "Synthesize review findings"
            let synthesis = try await child(kind: .synthesis, pageID: context.id, itemIDs: context.itemIDs,
                shotIDs: prepared.manifest.snapshot.shots.map(\.shotID), sources: context.sourceReceipts,
                summary: context, prepared: prepared, binding: binding, authorization: authorization,
                authorizationReference: authorizationReference, journal: &journal, editor: editor, validate: validate)
            try validate()
            let findings = try (pages + reductions + [synthesis]).flatMap {
                try PipelineRenderReviewRunStore.read(PipelineRenderReviewRunReceipt.Page.self, $0, dataRoot: root).submission.namespacedFindings(reviewID: $0.sha256)
            }
            let aggregate = PipelineRenderReviewRunReceipt.Aggregate(schema: "render-review-aggregate/v2", runID: journal.runID,
                manifest: prepared.reference, authorizations: journal.authorizations, pages: pages, reductions: reductions,
                synthesis: synthesis, findings: findings, completedAt: currentTimestamp())
            let aggregateReference = try PipelineRenderReviewRunReceipt.publish(aggregate,
                path: "render-review/runs/\(journal.runID.uuidString.lowercased())/aggregates/\(UUID().uuidString.lowercased()).v2.json",
                id: journal.runID.uuidString.lowercased(), role: "host.render-review-aggregate", dataRoot: root)
            try validate()
            _ = try await PipelineRenderReviewWriter.recordAggregateReview(snapshot: prepared.manifest.snapshot,
                aggregate: aggregateReference, binding: binding, editor: editor, revalidate: validate)
            journal.status = .completed; journal.message = nil
            state = .completed; currentStage = "Review recorded"; self.proposal = nil; self.prepared = nil
            do { try PipelineRenderReviewRunStore.save(journal, dataRoot: root) }
            catch { errorMessage = "The complete review is recorded, but its progress display could not be saved: " + error.localizedDescription }
        } catch {
            let interrupted = error is CancellationError || state == .stopping
            await registry.cancel(runID: initialJournal.runID)
            state = interrupted ? .interrupted : .failed
            currentStage = interrupted ? "Review interrupted" : "Review stopped"
            errorMessage = interrupted ? nil : error.localizedDescription
            journal.status = interrupted ? .interrupted : .failed; journal.message = errorMessage
            if (try? editor.agentService.requireReviewChildBinding(binding)) != nil {
                do { try PipelineRenderReviewRunStore.save(journal, dataRoot: root) }
                catch { errorMessage = "The review stopped; its progress could not be saved: " + error.localizedDescription }
            }
            self.proposal = nil; self.prepared = nil
        }
    }

    private final class ChildReceipt {
        var delivery: CanonicalArtifactReferenceV1?
        var page: CanonicalArtifactReferenceV1?
        var journal: PipelineRenderReviewRunStore.Journal

        init(journal: PipelineRenderReviewRunStore.Journal) { self.journal = journal }
    }

    private static func checkSnapshot(_ snapshot: PipelineRenderReviewWriter.Snapshot, root: URL,
                                      revalidate: @MainActor @Sendable () throws -> Void) async throws {
        let checking = Task.detached(priority: .userInitiated) {
            try PipelineRenderReviewSnapshotCheck.capture(snapshot, root: root)
        }
        let check = try await withTaskCancellationHandler { try await checking.value } onCancel: { checking.cancel() }
        try revalidate()
        try check.requireCurrent()
    }

    private func child(kind: AgentReviewChildKind, pageID: String, itemIDs: [String], shotIDs: [String],
                       sources: [CanonicalArtifactReferenceV1], summary: PipelineRenderReviewSummary.Context?,
                       prepared: Prepared, binding: AgentReviewChildBinding,
                       authorization: PipelineRenderReviewRunReceipt.Authorization,
                       authorizationReference: CanonicalArtifactReferenceV1,
                       journal: inout PipelineRenderReviewRunStore.Journal, editor: EditorViewModel,
                       validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> CanonicalArtifactReferenceV1 {
        try validate()
        let root = binding.dataRoot
        try await Self.checkSnapshot(prepared.manifest.snapshot, root: root, revalidate: validate)
        for reference in journal.children {
            let page = try PipelineRenderReviewRunStore.read(PipelineRenderReviewRunReceipt.Page.self, reference, dataRoot: root)
            guard page.submission.pageID == pageID else { continue }
            let saved = try PipelineRenderReviewRunVerification.verifyChild(reference, manifest: prepared.manifest,
                authorizationReferences: journal.authorizations, runID: journal.runID, dataRoot: root)
            guard saved.delivery.kind == kind, saved.delivery.itemIDs == itemIDs, saved.delivery.sourceReceipts == sources,
                  saved.page.writeEvidence.response.modelID == journal.modelID else {
                throw GateBlocked("The saved page belongs to a different review context or model.")
            }
            return reference
        }
        let bootstrap = "Review only the bound \(kind.rawValue) context \(pageID) in manifest \(prepared.manifest.id). "
            + "First call get_render_review_page with {}. After reading its result, call write_render_review_page in a later response. "
            + "Return one specific observation per item and any additional findings. Never accept a finding or claim unseen motion or audio."
        let request = AgentReviewChildRequest(runID: journal.runID, authID: authorization.id,
            manifestID: prepared.manifest.id, pageID: pageID, kind: kind, phase: "render_review", binding: binding,
            backend: prepared.backend, modelID: journal.modelID ?? authorization.requestedModelID,
            hostContext: prepared.hostContext, bootstrap: bootstrap, bounds: authorization.bounds)
        let receipts = ChildReceipt(journal: journal)
        defer { journal = receipts.journal }
        let directory = "render-review/runs/\(journal.runID.uuidString.lowercased())/\(authorization.id.uuidString.lowercased())/\(pageID)"
        let manifest = prepared.manifest
        let manifestReference = prepared.reference
        let completion = try await editor.agentService.reviewChildRegistry.perform(request, revalidate: validate,
            handler: { name, json, evidence in
                try validate()
                try editor.agentService.reviewChildRegistry.requireCurrent(evidence)
                if name == AgentReviewChildRequest.readTool {
                    let reading = Task.detached(priority: .userInitiated) {
                        if let summary { return try summary.content() }
                        return try manifest.pageContent(pageID: pageID, dataRoot: root)
                    }
                    let result = try await withTaskCancellationHandler { try await reading.value } onCancel: { reading.cancel() }
                    try validate()
                    try editor.agentService.reviewChildRegistry.requireCurrent(evidence)
                    try await Self.checkSnapshot(manifest.snapshot, root: root, revalidate: validate)
                    try editor.agentService.reviewChildRegistry.requireCurrent(evidence)
                    let images: [PipelineRenderReviewRunReceipt.DeliveredImage]
                    if kind == .page {
                        let page = try manifest.page(id: pageID)
                        images = try page.imageIDs.map { id in
                            guard let image = manifest.derivatives.first(where: { $0.id == id }) else { throw GateBlocked("The review image is missing.") }
                            return .init(reference: image.reference, mediaType: image.mediaType,
                                width: image.width, height: image.height, byteCount: image.byteCount)
                        }
                    } else { images = [] }
                    let text = result.content.compactMap { block -> String? in
                        if case .text(let text) = block { return text }; return nil
                    }.joined(separator: "\n")
                    let delivery = PipelineRenderReviewRunReceipt.Delivery(schema: "render-review-child-delivery/v2",
                        authorization: authorizationReference, manifest: manifestReference, kind: kind, pageID: pageID,
                        itemIDs: itemIDs, shotIDs: shotIDs, sourceReceipts: sources, requestedModelID: request.modelID,
                        bootstrap: bootstrap, systemInstructions: request.hostContext.systemInstructions,
                        toolSchemasJSON: try PipelineRenderReviewRunStore.schemasJSON(), deliveredText: text,
                        deliveredImages: images, toolResultSHA256: try PipelineRenderReviewRunReceipt.contentSHA256(result.content),
                        readEvidence: evidence)
                    receipts.delivery = try PipelineRenderReviewRunReceipt.publish(delivery,
                        path: directory + "/delivery.v2.json", id: pageID, role: "host.render-review-child-delivery", dataRoot: root)
                    return result
                }
                guard name == AgentReviewChildRequest.writeTool, let delivery = receipts.delivery else {
                    throw GateBlocked("Read the complete review context before recording its findings.")
                }
                let submission = try PipelineRenderReviewRunReceipt.decodeSubmission(json)
                try submission.validate(manifestID: manifest.id, pageID: pageID, itemIDs: itemIDs,
                    shotIDs: Set(shotIDs), references: manifest.snapshot.references, kind: kind)
                try validate()
                try editor.agentService.reviewChildRegistry.requireCurrent(evidence)
                try await Self.checkSnapshot(manifest.snapshot, root: root, revalidate: validate)
                try editor.agentService.reviewChildRegistry.requireCurrent(evidence)
                let page = PipelineRenderReviewRunReceipt.Page(schema: "render-review-child-page/v2", authorization: authorizationReference,
                    delivery: delivery, submission: submission, writeEvidence: evidence)
                let recorded = try PipelineRenderReviewRunStore.recordPage(page, journal: receipts.journal, dataRoot: root)
                receipts.page = recorded.reference
                receipts.journal = recorded.journal
                return .suspended("This review context is recorded. The host will continue the remaining review.")
            }, progress: { [weak self] progress in
                guard let self, self.activeRunID == progress.runID else { return }
                if progress.stage == .reading { self.currentStage = "Inspect review inputs" }
                if progress.stage == .recording { self.currentStage = "Record review observations" }
                if progress.stage == .stopping { self.currentStage = "Finish review context" }
            })
        try validate()
        try await Self.checkSnapshot(manifest.snapshot, root: root, revalidate: validate)
        guard let reference = receipts.page, receipts.journal.modelID == completion.modelID else {
            throw GateBlocked("The completed review context has no exact model receipt.")
        }
        return reference
    }
}

private extension AgentReviewChildBinding {
    func replacingLease(_ lease: UUID) -> Self {
        .init(originalChatID: originalChatID, projectID: projectID, projectGenerationID: projectGenerationID,
            workingCopyKey: workingCopyKey, workingCopyGeneration: workingCopyGeneration,
            projectRoot: projectRoot, dataRoot: dataRoot, trustedDeclaration: trustedDeclaration,
            workflow: workflow, mutationLeaseID: lease)
    }
}

extension PipelineRenderReviewRun {
    func cancelActiveWork() async {
        guard task != nil || preparationTask != nil else { return }
        await cancel()
    }
}
