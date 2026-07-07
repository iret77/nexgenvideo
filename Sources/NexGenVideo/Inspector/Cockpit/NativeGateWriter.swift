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
    static func approve(projectDir: URL, phase: String, notes: String? = nil) throws {
        try mutate(projectDir: projectDir) { gates in
            GatesOperations.approve(&gates, phase: phase, notes: notes)
        }
    }

    /// Record the multi-state verdict (approved / approved_with_notes / needs_revision / pending).
    /// Port of `gates.set_state` / MCP `set_gate_state`.
    static func setState(projectDir: URL, phase: String, state: GateState, notes: String? = nil) throws {
        try mutate(projectDir: projectDir) { gates in
            GatesOperations.setState(&gates, phase: phase, state: state, notes: notes)
        }
    }

    /// Reset `phase` and every following phase to unapproved. Port of `gates.rewind_to` /
    /// MCP `rewind`. The order includes the active pack's phases (appended sorted, Python
    /// semantics) so a pack gate like `analysis` is rewindable and gets reset with the rest.
    static func rewind(projectDir: URL, targetPhase: String) throws {
        let pack = ProjectPluginSettings.activePlugin(projectURL: projectDir)
        let packPhases = PackCatalog.registry(activePack: pack).phases.keys
            .filter { !coreGatePhases.contains($0) }
            .sorted()
        try mutate(projectDir: projectDir) { gates in
            _ = try GatesOperations.rewindTo(&gates, target: targetPhase, order: coreGatePhases + packPhases)
        }
    }

    /// Load → mutate → save gates.yaml at the project's data root.
    private static func mutate(projectDir: URL, _ body: (inout Gates) throws -> Void) throws {
        guard let root = DataRootResolver.dataRoot(of: projectDir) else {
            throw WriteError.notInitialized
        }
        let store = YAMLArtifactStore(dataRoot: root)
        do {
            var gates = try store.load(Gates.self, at: StudioLayout.gatesFile)
            try body(&gates)
            try store.save(gates, to: StudioLayout.gatesFile)
        } catch let error as WriteError {
            throw error
        } catch {
            throw WriteError.failed(String(describing: error))
        }
    }
}
