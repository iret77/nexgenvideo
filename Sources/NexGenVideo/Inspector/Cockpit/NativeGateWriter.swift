import Foundation
import NexGenEngine

// Direct, in-process gate mutations for the Pipeline panel — load gates.yaml via the engine, apply
// approve / set_state / rewind, save. No venv, no subprocess, no agent round-trip. Mirrors the
// engine MCP's approve_gate / set_gate_state / rewind, using the same GatesOperations the Python
// module functions wrap.
enum NativeGateWriter {

    enum WriteError: Error, Sendable, Equatable {
        case notInitialized
        case failed(String)
    }

    /// Approve `phase` (with optional notes) and persist. Port of `gates.approve` / MCP `approve_gate`.
    /// Enforces the active pack's deterministic hard-gate precondition first — the same guard the agent
    /// tool path uses — so a manual Pipeline-panel approval can't rubber-stamp a phase whose real
    /// artifact is missing. A blocked gate surfaces its message to the panel's toast.
    static func approve(projectDir: URL, phase: String, declaredPack: String?, notes: String? = nil) throws {
        try enforceRequirement(projectDir: projectDir, phase: phase, declaredPack: declaredPack)
        try mutate(projectDir: projectDir) { gates in
            GatesOperations.approve(&gates, phase: phase, notes: notes)
        }
    }

    /// Record the multi-state verdict (approved / approved_with_notes / needs_revision / pending).
    /// Port of `gates.set_state` / MCP `set_gate_state`.
    static func setState(projectDir: URL, phase: String, state: GateState, declaredPack: String?, notes: String? = nil) throws {
        if state == .approved || state == .approvedWithNotes {
            try enforceRequirement(projectDir: projectDir, phase: phase, declaredPack: declaredPack)
        }
        try mutate(projectDir: projectDir) { gates in
            GatesOperations.setState(&gates, phase: phase, state: state, notes: notes)
        }
    }

    /// Enforce the same deterministic gate rules the agent tool path does — fail-closed pack wiring,
    /// approve in order (all predecessors approved), and the active pack's per-phase artifact
    /// precondition (nil ⇒ approvable). `declaredPack` is the ground truth from the package.
    private static func enforceRequirement(projectDir: URL, phase: String, declaredPack: String?) throws {
        guard let root = DataRootResolver.dataRoot(of: projectDir) else { throw WriteError.notInitialized }
        let resolved = ProjectPluginSettings.activePlugin(projectURL: projectDir)
        let registry = PackCatalog.registry(activePack: resolved)
        let order = PhaseOrder.merged(packPlacements: registry.phasePlacements)
        let gates = (try? YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile))
            ?? Gates(project: "")
        // FAIL-CLOSED: a declared pack must be wired, or the manual panel can't approve anything either.
        try GateGuard.requireWiredPack(declared: declaredPack, resolved: resolved, registry: registry)
        try GateGuard.requirePriorApproved(gates, order: order, phase: phase)
        try GateGuard.checkApprovable(phase: phase, dataRoot: root, requirement: registry.gateRequirements[phase])
    }

    /// Reset `phase` and every following phase to unapproved. Port of `gates.rewind_to` /
    /// MCP `rewind`. The order is the merged pipeline (core + the active pack's phases at their
    /// declared placement, via `PhaseOrder.merged`) so a pack gate like `analysis` is rewindable and
    /// resets the correct downstream span.
    static func rewind(projectDir: URL, targetPhase: String) throws {
        let pack = ProjectPluginSettings.activePlugin(projectURL: projectDir)
        let order = PhaseOrder.merged(packPlacements: PackCatalog.registry(activePack: pack).phasePlacements)
        try mutate(projectDir: projectDir) { gates in
            _ = try GatesOperations.rewindTo(&gates, target: targetPhase, order: order)
        }
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
        } catch {
            throw WriteError.failed(String(describing: error))
        }
    }
}
