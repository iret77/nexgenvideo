import Foundation
import NexGenEngine

struct NativeGateApprovalReadiness: Sendable, Equatable {
    let blocker: String?

    var isReady: Bool { blocker == nil }

    static let ready = NativeGateApprovalReadiness(blocker: nil)

    static func blocked(_ reason: String) -> NativeGateApprovalReadiness {
        NativeGateApprovalReadiness(blocker: reason)
    }
}

struct NativeGateControlReadiness: Sendable, Equatable {
    let mutations: NativeGateApprovalReadiness
    let approval: NativeGateApprovalReadiness
}

private struct NativeGateApprovalCheckContext: Sendable {
    let dataRoot: URL
    let phase: String
    let order: [String]
    let phaseAccess: PipelinePhaseAccess.Prepared
    let requirement: EngineRegistry.GateRequirement?
}

private struct NativeGateResolvedRegistry: Sendable {
    let name: String?
    let registry: EngineRegistry
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
        executionCoordinator: PipelinePhaseRunCoordinator,
        notes: String? = nil
    ) async throws {
        try await requireApprovalReady(
            projectDir: projectDir,
            phase: phase,
            declaredPack: declaredPack,
            executionCoordinator: executionCoordinator
        )
        try mutate(projectDir: projectDir) { gates in
            GatesOperations.approve(&gates, phase: phase, notes: notes)
        }
    }

    static func controlReadiness(
        projectDir: URL,
        phase: String?,
        declaredPack: String?,
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
                declaredPack: declaredPack
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
        executionCoordinator: PipelinePhaseRunCoordinator,
        notes: String? = nil
    ) async throws {
        try requireIdle(
            projectDir: projectDir,
            executionCoordinator: executionCoordinator
        )
        if state == .approved || state == .approvedWithNotes {
            try await requireApprovalReady(
                projectDir: projectDir,
                phase: phase,
                declaredPack: declaredPack,
                executionCoordinator: executionCoordinator
            )
        }
        let registry = try resolvedRegistry(
            projectDir: projectDir,
            declaredPack: declaredPack
        )
        let order = PhaseOrder.merged(
            packPlacements: registry.phasePlacements
        )
        try mutate(projectDir: projectDir) { gates in
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
        declaredPack: String?
    ) throws -> NativeGateApprovalCheckContext {
        guard let root = DataRootResolver.dataRoot(of: projectDir) else {
            throw WriteError.notInitialized
        }
        let resolved = try resolvedRegistryContext(
            projectDir: projectDir,
            declaredPack: declaredPack
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
        return NativeGateApprovalCheckContext(
            dataRoot: dataRoot,
            phase: phase,
            order: PhaseOrder.merged(
                packPlacements: resolved.registry.phasePlacements
            ),
            phaseAccess: try PipelinePhaseAccess.prepare(
                packName: resolved.name,
                registry: resolved.registry
            ),
            requirement: resolved.registry.gateRequirements[phase]
        )
    }

    nonisolated private static func checkApproval(
        context: NativeGateApprovalCheckContext,
        gates: Gates
    ) throws {
        try PipelinePhaseAccess.requireCurrentPhaseAndIntake(
            context.phase,
            dataRoot: context.dataRoot,
            prepared: context.phaseAccess
        )
        try GateGuard.requirePriorApproved(
            gates,
            order: context.order,
            phase: context.phase
        )
        try GateGuard.checkApprovable(
            phase: context.phase,
            dataRoot: context.dataRoot,
            requirement: context.requirement
        )
    }

    /// Reset `phase` and every following phase to unapproved. Port of `gates.rewind_to` /
    /// MCP `rewind`. The order is the merged pipeline (core + the active pack's phases at their
    /// declared placement, via `PhaseOrder.merged`) so a pack gate like `analysis` is rewindable and
    /// resets the correct downstream span.
    static func rewind(
        projectDir: URL,
        targetPhase: String,
        declaredPack: String?,
        executionCoordinator: PipelinePhaseRunCoordinator
    ) throws {
        try requireIdle(
            projectDir: projectDir,
            executionCoordinator: executionCoordinator
        )
        let registry = try resolvedRegistry(
            projectDir: projectDir,
            declaredPack: declaredPack
        )
        let order = PhaseOrder.merged(
            packPlacements: registry.phasePlacements
        )
        try mutate(projectDir: projectDir) { gates in
            _ = try GatesOperations.rewindTo(&gates, target: targetPhase, order: order)
        }
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
        executionCoordinator: PipelinePhaseRunCoordinator
    ) async throws {
        try requireIdle(
            projectDir: projectDir,
            executionCoordinator: executionCoordinator
        )
        let context = try approvalCheckContext(
            projectDir: projectDir,
            phase: phase,
            declaredPack: declaredPack
        )
        do {
            try await Task.detached(priority: .utility) {
                let gates = try YAMLArtifactStore(
                    dataRoot: context.dataRoot
                ).load(
                    Gates.self,
                    at: PipelineLayout.gatesFile
                )
                try checkApproval(
                    context: context,
                    gates: gates
                )
            }.value
        } catch let blocked as GateBlocked {
            throw WriteError.failed(blocked.message)
        } catch let error as WriteError {
            throw error
        } catch {
            throw WriteError.failed(error.localizedDescription)
        }
        try requireIdle(
            dataRoot: context.dataRoot,
            executionCoordinator: executionCoordinator
        )
    }

    nonisolated private static func structuralApprovalReadiness(
        context: NativeGateApprovalCheckContext,
        gates: Gates
    ) -> NativeGateApprovalReadiness {
        do {
            try checkApproval(context: context, gates: gates)
            return .ready
        } catch {
            return .blocked(error.localizedDescription)
        }
    }

    nonisolated private static func resolvedRegistry(
        projectDir: URL,
        declaredPack: String?
    ) throws -> EngineRegistry {
        try resolvedRegistryContext(
            projectDir: projectDir,
            declaredPack: declaredPack
        ).registry
    }

    nonisolated private static func resolvedRegistryContext(
        projectDir: URL,
        declaredPack: String?
    ) throws -> NativeGateResolvedRegistry {
        let resolved: String?
        do {
            resolved = try ProjectPluginSettings.resolvedPlugin(
                projectURL: projectDir,
                declaredPack: declaredPack
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
        return NativeGateResolvedRegistry(
            name: resolved,
            registry: registry
        )
    }

    /// Load → mutate → save gates.yaml at the project's data root.
    private static func mutate(projectDir: URL, _ body: (inout Gates) throws -> Void) throws {
        guard let root = DataRootResolver.dataRoot(of: projectDir) else {
            throw WriteError.notInitialized
        }
        let store = YAMLArtifactStore(dataRoot: root)
        do {
            var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
            try body(&gates)
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
