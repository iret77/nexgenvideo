import Foundation
import NexGenEngine

struct NativeGateApprovalReadiness: Sendable, Equatable {
    let blocker: String?
    var userMessage: String? = nil

    var isReady: Bool { blocker == nil }

    static let ready = NativeGateApprovalReadiness(blocker: nil)

    static func blocked(_ reason: String, userMessage: String? = nil) -> NativeGateApprovalReadiness {
        NativeGateApprovalReadiness(blocker: reason, userMessage: userMessage)
    }
}

struct NativeGateControlReadiness: Sendable, Equatable {
    let mutations: NativeGateApprovalReadiness
    let approval: NativeGateApprovalReadiness
}

enum NativeGateApprovalStage: Sendable {
    case phaseAccess, priorApprovals, artifact, productionStyle, treatment, storyboard, frames, render, executionPlan

}

private struct NativeGateApprovalCheckContext: Sendable {
    let dataRoot: URL
    let phase: String
    let order: [String]
    let phaseAccess: PipelinePhaseAccess.Prepared
    let requirement: EngineRegistry.GateRequirement?
    let workflow: HostWorkflowKey?
}

private struct NativeGateResolvedRegistry: Sendable {
    let name: String?
    let registry: EngineRegistry
    let workflow: HostWorkflowKey?
}

private enum NativeGateApprovalPreparation: Sendable {
    case context(NativeGateApprovalCheckContext?)
    case blocked(NativeGateApprovalReadiness)
}

// Direct, in-process gate mutations for the Pipeline panel — load gates.yaml via the engine, apply
// approve / set_state / rewind, save. No venv, no subprocess, no agent round-trip. Mirrors the
// engine MCP's approve_gate / set_gate_state / rewind, using the same GatesOperations the Python
// module functions wrap.
@MainActor
enum NativeGateWriter {
    nonisolated private static let readinessDigests = FileDigestReadinessCache()

    enum WriteError: LocalizedError, Sendable, Equatable {
        case notInitialized
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized:
                "The project pipeline is not initialized."
            case .failed(let message):
                message
            }
        }
    }

    /// Approve `phase` (with optional notes) and persist. Port of `gates.approve` / MCP `approve_gate`.
    /// Enforces the active pack's deterministic hard-gate precondition first — the same guard the agent
    /// tool path uses — so a manual Pipeline-panel approval can't rubber-stamp a phase whose real
    /// artifact is missing.
    static func approve(
        projectDir: URL,
        phase: String,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        declaredProductionContract: HostProductionContractBinding? = nil,
        executionCoordinator: PipelinePhaseRunCoordinator,
        notes: String? = nil
    ) async throws {
        let lease = try beginGateMutation(
            projectDir: projectDir,
            label: "Approve \(phase)",
            executionCoordinator: executionCoordinator
        )
        defer {
            executionCoordinator.endMutation(
                projectRoot: lease.root,
                id: lease.id
            )
        }
        try await requireApprovalReady(
            projectDir: projectDir,
            phase: phase,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            declaredProductionContract: declaredProductionContract,
            executionCoordinator: executionCoordinator,
            mutationID: lease.id
        )
        try mutate(
            projectDir: projectDir,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            declaredProductionContract: declaredProductionContract
        ) { gates in
            GatesOperations.approve(&gates, phase: phase, notes: notes)
        }
    }

    static func controlReadiness(
        projectDir: URL,
        phase: String?,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        declaredProductionContract: HostProductionContractBinding? = nil,
        executionCoordinator: PipelinePhaseRunCoordinator
    ) async -> NativeGateControlReadiness {
        let root: URL
        do {
            guard let resolvedRoot = DataRootResolver.dataRoot(of: projectDir) else {
                throw WriteError.notInitialized
            }
            root = resolvedRoot
            try requireIdle(
                dataRoot: root,
                executionCoordinator: executionCoordinator
            )
        } catch {
            let blocked = NativeGateApprovalReadiness.blocked(
                error.localizedDescription
            )
            return NativeGateControlReadiness(
                mutations: blocked,
                approval: blocked
            )
        }
        let resolved: NativeGateResolvedRegistry
        do {
            resolved = try resolvedRegistryContext(
                projectDir: projectDir,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding,
                declaredProductionContract: declaredProductionContract
            )
        } catch {
            let blocked = NativeGateApprovalReadiness.blocked(
                error.localizedDescription
            )
            return NativeGateControlReadiness(
                mutations: blocked,
                approval: blocked
            )
        }
        let approvalContext: NativeGateApprovalPreparation
        if let phase {
            do {
                approvalContext = .context(
                    try approvalCheckContext(
                        dataRoot: root,
                        phase: phase,
                        resolved: resolved
                    )
                )
            } catch {
                approvalContext = .blocked(
                    .blocked(error.localizedDescription)
                )
            }
        } else {
            approvalContext = .context(nil)
        }
        let readiness = await Task.detached(priority: .utility) {
            let gates: Gates
            do {
                gates = try YAMLArtifactStore(
                    dataRoot: root
                ).load(
                    Gates.self,
                    at: PipelineLayout.gatesFile
                )
            } catch {
                let blocked = NativeGateApprovalReadiness.blocked(
                    error.localizedDescription
                )
                return NativeGateControlReadiness(
                    mutations: blocked,
                    approval: blocked
                )
            }
            let approval: NativeGateApprovalReadiness
            switch approvalContext {
            case .context(.some(let context)):
                approval = structuralApprovalReadiness(
                    context: context,
                    gates: gates
                )
            case .context(nil):
                approval = .blocked("Every pipeline phase is already approved.")
            case .blocked(let blocker):
                approval = blocker
            }
            return NativeGateControlReadiness(
                mutations: .ready,
                approval: approval
            )
        }.value
        do {
            try requireIdle(
                dataRoot: root,
                executionCoordinator: executionCoordinator
            )
            return readiness
        } catch {
            let blocked = NativeGateApprovalReadiness.blocked(
                error.localizedDescription
            )
            return NativeGateControlReadiness(
                mutations: blocked,
                approval: blocked
            )
        }
    }

    /// Record the multi-state verdict (approved / approved_with_notes / needs_revision / pending).
    /// Port of `gates.set_state` / MCP `set_gate_state`.
    static func setState(
        projectDir: URL,
        phase: String,
        state: GateState,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        declaredProductionContract: HostProductionContractBinding? = nil,
        executionCoordinator: PipelinePhaseRunCoordinator,
        notes: String? = nil
    ) async throws {
        let lease = try beginGateMutation(
            projectDir: projectDir,
            label: "Update \(phase)",
            executionCoordinator: executionCoordinator
        )
        defer {
            executionCoordinator.endMutation(
                projectRoot: lease.root,
                id: lease.id
            )
        }
        if state == .approved || state == .approvedWithNotes {
            try await requireApprovalReady(
                projectDir: projectDir,
                phase: phase,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding,
                declaredProductionContract: declaredProductionContract,
                executionCoordinator: executionCoordinator,
                mutationID: lease.id
            )
        }
        let resolved = try resolvedRegistryContext(
            projectDir: projectDir,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            declaredProductionContract: declaredProductionContract
        )
        let order = try resolved.workflow.map { try PhaseContractRuntime.order(workflow: $0) }
            ?? PhaseContractRuntime.order(activePack: resolved.name)
        try mutate(
            projectDir: projectDir,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            declaredProductionContract: declaredProductionContract
        ) { gates in
            let current = order.first {
                !gates.get($0).approved
            }
            guard gates.get(phase).approved || current == phase else {
                throw GateBlocked(
                    "Can't revise future phase \"\(phase)\" before reaching it."
                )
            }
            try GatesOperations.setStateAndInvalidateDownstream(
                &gates,
                phase: phase,
                state: state,
                order: order,
                notes: notes
            )
        }
    }

    /// Enforce the same deterministic gate rules the agent tool path does — fail-closed pack wiring,
    /// approve in order (all predecessors approved), and the active pack's per-phase artifact
    /// precondition (nil ⇒ approvable). `declaredPack` is the trusted session declaration.
    private static func approvalCheckContext(
        projectDir: URL,
        phase: String,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?,
        declaredProductionContract: HostProductionContractBinding? = nil
    ) throws -> NativeGateApprovalCheckContext {
        guard let root = DataRootResolver.dataRoot(of: projectDir) else {
            throw WriteError.notInitialized
        }
        let resolved = try resolvedRegistryContext(
            projectDir: projectDir,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            declaredProductionContract: declaredProductionContract
        )
        return try approvalCheckContext(
            dataRoot: root,
            phase: phase,
            resolved: resolved
        )
    }

    private static func approvalCheckContext(
        dataRoot: URL,
        phase: String,
        resolved: NativeGateResolvedRegistry
    ) throws -> NativeGateApprovalCheckContext {
        let phaseAccess: PipelinePhaseAccess.Prepared
        let requirement: EngineRegistry.GateRequirement?
        if let workflow = resolved.workflow {
            phaseAccess = try PipelinePhaseAccess.prepare(workflow: workflow)
            requirement = try PhaseContractRuntime.gateRequirement(workflow: workflow, phase: phase, registry: resolved.registry)
        } else {
            phaseAccess = try PipelinePhaseAccess.prepare(packName: resolved.name)
            requirement = try PhaseContractRuntime.gateRequirement(activePack: resolved.name, phase: phase, registry: resolved.registry)
        }
        return NativeGateApprovalCheckContext(
            dataRoot: dataRoot,
            phase: phase,
            order: phaseAccess.order,
            phaseAccess: phaseAccess,
            requirement: requirement,
            workflow: resolved.workflow
        )
    }

    nonisolated private static func checkApproval(
        context: NativeGateApprovalCheckContext,
        gates: Gates,
        onStage: ((NativeGateApprovalStage) -> Void)? = nil
    ) throws {
        onStage?(.phaseAccess)
        try PipelinePhaseAccess.requireCurrentPhaseAndIntake(
            context.phase,
            dataRoot: context.dataRoot,
            prepared: context.phaseAccess
        )
        onStage?(.priorApprovals)
        try GateGuard.requirePriorApproved(
            gates,
            order: context.order,
            phase: context.phase
        )
        onStage?(.artifact)
        try PipelineGateEvidenceValidator.requireCurrent(

            phase: context.phase,
            dataRoot: context.dataRoot,
            requirement: context.requirement,
            workflow: context.workflow
        )
        if context.workflow?.isProductionV2 == true { return }
        if context.phase == "production_design" {
            onStage?(.productionStyle)
            _ = try ProductionStyleStoreV1.load(dataRoot: context.dataRoot)
        }
        if context.phase == "treatment" {
            onStage?(.treatment)
            _ = try StoryCausalityStoreV1.requireCurrent(dataRoot: context.dataRoot)
        }
        if context.phase == "storyboard" {
            onStage?(.storyboard)
            _ = try StoryboardCausalityV1.requireCurrent(dataRoot: context.dataRoot)
        }
        if context.phase == "frames" {
            onStage?(.frames)
            try FrameObservationStoreV1.requireProjectStyleFrames(dataRoot: context.dataRoot)
        }
        if context.phase == "render" {
            onStage?(.render)
            try TakeReview.requireSelected(dataRoot: context.dataRoot, phase: "final")
        }
        if context.phase == "shotlist" {
            onStage?(.executionPlan)
            try PipelineExecutionPlanWriter.requireCurrent(dataRoot: context.dataRoot)
            try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(
                dataRoot: context.dataRoot
            )
            try PipelineLineageStore.requireCurrent(
                phase: PipelineExecutionPlanWriter.lineagePhaseID,
                snapshot: try PipelineExecutionPlanWriter.lineageSnapshot(
                    dataRoot: context.dataRoot
                ),
                dataRoot: context.dataRoot
            )
        }

    }

    /// Reset `phase` and every following phase to unapproved. Port of `gates.rewind_to` /
    /// MCP `rewind`. The active pack contract supplies the exact downstream span.
    static func rewind(
        projectDir: URL,
        targetPhase: String,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        declaredProductionContract: HostProductionContractBinding? = nil,
        executionCoordinator: PipelinePhaseRunCoordinator
    ) throws {
        let lease = try beginGateMutation(
            projectDir: projectDir,
            label: "Rewind \(targetPhase)",
            executionCoordinator: executionCoordinator
        )
        defer {
            executionCoordinator.endMutation(
                projectRoot: lease.root,
                id: lease.id
            )
        }
        let resolved = try resolvedRegistryContext(
            projectDir: projectDir,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            declaredProductionContract: declaredProductionContract
        )
        let order = try resolved.workflow.map { try PhaseContractRuntime.order(workflow: $0) }
            ?? PhaseContractRuntime.order(activePack: resolved.name)
        try mutate(
            projectDir: projectDir,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            declaredProductionContract: declaredProductionContract
        ) { gates in
            _ = try GatesOperations.rewindTo(&gates, target: targetPhase, order: order)
        }
    }

    static func acceptFrameFindings(editor: EditorViewModel, expectedProject: URL?, audit: FrameAudit, snapshot: String, reason: String) async throws {
        guard let home = editor.workingRoot, home == expectedProject, let key = editor.openWorkingCopyKey else { throw WriteError.notInitialized }
        let lease = try beginGateMutation(projectDir: home, label: "Accept frame deviations", executionCoordinator: editor.pipelinePhaseRunCoordinator)
        var ownsLease = true
        defer { if ownsLease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: lease.root, id: lease.id) } }
        let resolved = try resolvedRegistryContext(projectDir: home, declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
        let order = try resolved.workflow.map { try PhaseContractRuntime.order(workflow: $0) }
            ?? PhaseContractRuntime.order(activePack: resolved.name)
        try validateFrameFindings(audit, dataRoot: lease.root, order: order)
        try ProjectWorkingCopy.markDirty(key: key)
        let path = try FrameAuditAcceptanceStoreV1.location(audit: audit, dataRoot: lease.root)
        let paths = [path, PipelineLayout.url(PipelineLayout.gatesFile, in: lease.root),
                     PipelineLayout.url(PipelineLayout.lineageFile, in: lease.root)]
        try ArtifactTransaction.perform(paths: paths, dataRoot: lease.root) {
            try FrameAuditAcceptanceStoreV1.accept(audit: audit, expectedSnapshot: snapshot, reason: reason, dataRoot: lease.root)
            try PipelinePhaseMutationRecorder.record(phase: "frames", dataRoot: lease.root, captureLineage: true,
                declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
        }
        editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: lease.root, id: lease.id)
        ownsLease = false
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
    }

    private nonisolated static func validateFrameFindings(_ audit: FrameAudit, dataRoot: URL, order: [String]) throws {
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        guard order.first(where: { !gates.get($0).approved }) == "frames" else {
            throw WriteError.failed("Accept deviations only while Frames is the current phase. Explicitly rewind Frames to change an approved review.")
        }
        try GateGuard.requirePriorApproved(gates, order: order, phase: "frames")
        let manifest = try loadFramesManifest(dataRoot: dataRoot)
        guard let frame = manifest.shot(audit.shotId)?.frames.first(where: { $0.role == audit.role }),
              try ProjectLocalFile.resolve(frame.path, dataRoot: dataRoot) == ProjectLocalFile.resolve(audit.renderPath, dataRoot: dataRoot),
              Set(standardAuditCheckKeys).isSubset(of: Set(audit.checks.keys)) else {
            throw WriteError.failed("The findings do not belong to the current selected frame.")
        }
        try FrameAuditExpectations.requireCurrent(audit, dataRoot: dataRoot)
        if let style = try ProductionStyleStoreV1.load(dataRoot: dataRoot) {
            try FrameObservationStoreV1.requireStyleAudit(audit, style: style, dataRoot: dataRoot, requireAcceptedFindings: false)
        }
    }

    static func frameFindingsReadiness(editor: EditorViewModel, project: URL?, audit: FrameAudit, snapshot: String) async -> NativeGateApprovalReadiness {
        do {
            guard let home = project, editor.workingRoot == home,
                  let root = DataRootResolver.dataRoot(of: home) else { throw WriteError.notInitialized }
            try requireIdle(dataRoot: root, executionCoordinator: editor.pipelinePhaseRunCoordinator)
            let resolved = try resolvedRegistryContext(projectDir: home, declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
            let order = try resolved.workflow.map { try PhaseContractRuntime.order(workflow: $0) }
            ?? PhaseContractRuntime.order(activePack: resolved.name)
            try await Task.detached(priority: .utility) {
                try validateFrameFindings(audit, dataRoot: root, order: order)
                guard try FrameAuditAcceptanceStoreV1.snapshot(audit: audit, dataRoot: root) == snapshot else {
                    throw WriteError.failed("The frame findings changed. Refresh the review.")
                }
            }.value
            guard editor.workingRoot == home else { throw WriteError.notInitialized }
            try requireIdle(dataRoot: root, executionCoordinator: editor.pipelinePhaseRunCoordinator)
            return .ready
        } catch { return .blocked(error.localizedDescription) }
    }

    private static func requireIdle(
        projectDir: URL,
        executionCoordinator: PipelinePhaseRunCoordinator
    ) throws {
        guard let root = DataRootResolver.dataRoot(of: projectDir) else {
            throw WriteError.notInitialized
        }
        try requireIdle(
            dataRoot: root,
            executionCoordinator: executionCoordinator
        )
    }

    private static func beginGateMutation(
        projectDir: URL,
        label: String,
        executionCoordinator: PipelinePhaseRunCoordinator
    ) throws -> (root: URL, id: UUID) {
        guard let root = DataRootResolver.dataRoot(of: projectDir) else {
            throw WriteError.notInitialized
        }
        guard let id = executionCoordinator.beginMutation(
            projectRoot: root,
            label: label
        ) else {
            let active = executionCoordinator.runningPhase(projectRoot: root)
                ?? "pipeline work"
            throw WriteError.failed(
                "Can't change pipeline gates while \(active) is running. "
                    + "Wait for it to finish."
            )
        }
        return (root, id)
    }

    private static func requireIdle(
        dataRoot: URL,
        executionCoordinator: PipelinePhaseRunCoordinator
    ) throws {
        guard let running = executionCoordinator.runningPhase(
            projectRoot: dataRoot
        )
        else { return }
        throw WriteError.failed(
            "Can't change pipeline gates while \(running) is running. Wait for the phase to finish."
        )
    }

    static func requireApprovalReady(
        projectDir: URL,
        phase: String,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        declaredProductionContract: HostProductionContractBinding? = nil,
        executionCoordinator: PipelinePhaseRunCoordinator,
        mutationID: UUID? = nil
    ) async throws {
        if let mutationID {
            try requireMutation(
                projectDir: projectDir,
                id: mutationID,
                executionCoordinator: executionCoordinator
            )
        } else {
            try requireIdle(
                projectDir: projectDir,
                executionCoordinator: executionCoordinator
            )
        }
        let context = try approvalCheckContext(
            projectDir: projectDir,
            phase: phase,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            declaredProductionContract: declaredProductionContract
        )
        do {
            try await Task.detached(priority: .utility) {
                let gates = try YAMLArtifactStore(
                    dataRoot: context.dataRoot
                ).load(
                    Gates.self,
                    at: PipelineLayout.gatesFile
                )
                try FileDigest.$readinessCache.withValue(nil) {
                    try checkApproval(context: context, gates: gates)
                }
            }.value
        } catch let blocked as GateBlocked {
            throw WriteError.failed(blocked.message)
        } catch let error as WriteError {
            throw error
        } catch {
            throw WriteError.failed(error.localizedDescription)
        }
        if let mutationID {
            try requireMutation(
                dataRoot: context.dataRoot,
                id: mutationID,
                executionCoordinator: executionCoordinator
            )
        } else {
            try requireIdle(
                dataRoot: context.dataRoot,
                executionCoordinator: executionCoordinator
            )
        }
    }

    private static func requireMutation(
        projectDir: URL,
        id: UUID,
        executionCoordinator: PipelinePhaseRunCoordinator
    ) throws {
        guard let root = DataRootResolver.dataRoot(of: projectDir) else {
            throw WriteError.notInitialized
        }
        try requireMutation(
            dataRoot: root,
            id: id,
            executionCoordinator: executionCoordinator
        )
    }

    private static func requireMutation(
        dataRoot: URL,
        id: UUID,
        executionCoordinator: PipelinePhaseRunCoordinator
    ) throws {
        guard executionCoordinator.holdsMutation(
            projectRoot: dataRoot,
            id: id
        ) else {
            throw WriteError.failed(
                "The pipeline gate mutation lost its execution reservation. Try again."
            )
        }
    }

    nonisolated private static func structuralApprovalReadiness(
        context: NativeGateApprovalCheckContext,
        gates: Gates
    ) -> NativeGateApprovalReadiness {
        var stage = NativeGateApprovalStage.phaseAccess
        do {
            try FileDigest.$readinessCache.withValue(readinessDigests) {
                try checkApproval(context: context, gates: gates, onStage: { stage = $0 })
            }
            return .ready
        } catch {
            var message = (error as? PhaseArtifactFailure).map {
                PipelineReadinessPresentation.message(for: $0.requirement, phase: context.phase)
            } ?? PipelineReadinessPresentation.message(for: stage, phase: context.phase)
            if case .phaseAccess = stage {
                let current = context.order.first { !gates.get($0).approved }
                if current != context.phase {
                    message = current.map { "Continue with \(PhaseDisplay.label($0)) before approving this phase." }
                        ?? "All phases are approved. Rewind explicitly before changing an approved artifact."
                } else if let manifest = context.phaseAccess.manifest,
                          let step = IntakePlanner.next(manifest.steps(for: context.phase), dataRoot: context.dataRoot,
                              ledger: IntakeLedger.load(dataRoot: context.dataRoot), workflowID: context.phaseAccess.contract?.manifest.contractID) {
                    message = "Complete the \(step.title) card before continuing."
                }
            }
            Log.project.debug("Pipeline approval blocked phase=\(context.phase): \(error.localizedDescription)")
            return .blocked(error.localizedDescription, userMessage: message)
        }
    }

    private static func resolvedRegistryContext(
        projectDir: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?,
        declaredProductionContract: HostProductionContractBinding? = nil
    ) throws -> NativeGateResolvedRegistry {
        let resolved: String?
        do {
            resolved = try ProjectPackGate.requireLiveMutation(
                projectURL: projectDir,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding,
                declaredProductionContract: declaredProductionContract
            )
        } catch {
            throw WriteError.failed(error.localizedDescription)
        }
        let registry = PackCatalog.registry(activePack: resolved)
        do {
            try GateGuard.requireWiredPack(
                declared: declaredPack,
                resolved: resolved,
                registry: registry
            )
        } catch let blocked as GateBlocked {
            throw WriteError.failed(blocked.message)
        }
        guard let dataRoot = DataRootResolver.dataRoot(of: projectDir) else { throw WriteError.notInitialized }
        let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: declaredBinding,
            expectedProductionContract: declaredProductionContract)
        return NativeGateResolvedRegistry(name: resolved, registry: registry, workflow: workflow)
    }

    /// Load → mutate → save gates.yaml at the project's data root.
    private static func mutate(
        projectDir: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?,
        declaredProductionContract: HostProductionContractBinding? = nil,
        _ body: (inout Gates) throws -> Void
    ) throws {
        guard let root = DataRootResolver.dataRoot(of: projectDir) else {
            throw WriteError.notInitialized
        }
        let store = YAMLArtifactStore(dataRoot: root)
        do {
            _ = try ProjectPackGate.requireLiveMutation(
                projectURL: projectDir,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding,
                declaredProductionContract: declaredProductionContract
            )
            var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
            try body(&gates)
            _ = try ProjectPackGate.requireLiveMutation(
                projectURL: projectDir,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding,
                declaredProductionContract: declaredProductionContract
            )
            try store.save(gates, to: PipelineLayout.gatesFile)
        } catch let error as WriteError {
            throw error
        } catch let blocked as GateBlocked {
            throw WriteError.failed(blocked.message)
        } catch {
            throw WriteError.failed(error.localizedDescription)
        }
    }
}
