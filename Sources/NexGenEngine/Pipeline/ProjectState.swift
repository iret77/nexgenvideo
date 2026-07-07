import Foundation

/// Read-only project-state aggregator — the engine's view of where a project
/// stands: meta, gate/phase status, budget spent (from render manifests), and
/// the next open phase. Port of `state.py`.
public enum ProjectStateBuilder {
    /// One phase's approval status. Port of `state.py::PhaseStatus`.
    public struct PhaseStatus: Sendable, Equatable {
        public let phase: String
        public let approved: Bool
        public let state: GateState
        public let notes: String?
    }

    /// A project snapshot. Port of `state.py::ProjectState`.
    public struct ProjectState: Sendable, Equatable {
        public let project: String
        public let mode: String
        public let budgetEur: Double
        public let budgetSpentEur: Double
        public let budgetRemainingEur: Double
        public let phases: [PhaseStatus]
        public let nextPhase: String?
    }

    /// Aggregate ProjectMeta + Gates + render-manifest spend into a snapshot.
    /// The phase order is the core order with the active pack's declared phases
    /// merged in via `PhaseOrder.merged` (the single ordering helper used at
    /// every surface). Spent is summed across every `renders/manifest-*.json` and
    /// rounded once to 2 dp, matching `costs.already_spent_in_project`.
    /// Port of `state.py::build_snapshot`.
    public static func buildSnapshot(
        dataRoot: URL, core: [String] = coreGatePhases, packPlacements: [PhasePlacement] = []
    ) throws -> ProjectState {
        let order = PhaseOrder.merged(core: core, packPlacements: packPlacements)
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        let meta = try store.load(ProjectMeta.self, at: StudioLayout.projectFile)
        let gates = try store.load(Gates.self, at: StudioLayout.gatesFile)

        let phases = order.map { phase -> PhaseStatus in
            let gate = gates.get(phase)
            return PhaseStatus(phase: phase, approved: gate.approved, state: gate.state, notes: gate.notes)
        }
        let nextPhase = phases.first { !$0.approved }?.phase
        let spent = spentInProject(dataRoot: dataRoot)

        return ProjectState(
            project: meta.project,
            mode: meta.mode.rawValue,
            budgetEur: meta.budgetEur,
            budgetSpentEur: spent,
            budgetRemainingEur: max(0.0, meta.budgetEur - spent),
            phases: phases,
            nextPhase: nextPhase
        )
    }

    /// Sum of `costEur` across all render manifests in `renders/`, rounded to 2
    /// dp. No manifests / no renders dir ⇒ 0.0. Port of the aggregation
    /// `state.build_snapshot` does via `costs.already_spent_in_project`.
    static func spentInProject(dataRoot: URL) -> Double {
        let rendersDir = StudioLayout.url(StudioLayout.rendersDir, in: dataRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rendersDir, includingPropertiesForKeys: nil
        ) else { return 0.0 }
        var total = 0.0
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("manifest-"), name.hasSuffix(".json") else { continue }
            // manifest-<phase>.json
            let phase = String(name.dropFirst("manifest-".count).dropLast(".json".count))
            guard !phase.isEmpty, let manifest = try? loadRenderManifest(dataRoot: dataRoot, phase: phase)
            else { continue }
            total += manifest.entries.values.reduce(0.0) { $0 + $1.costEur }
        }
        return (total * 100).rounded() / 100
    }
}
