import Foundation
import NexGenEngine

enum PipelinePhaseMutationRecorder {
    static func record(
        phase: String,
        dataRoot: URL,
        captureLineage: Bool,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        declaredProductionContract: HostProductionContractBinding? = nil
    ) throws {
        let packName: String?
        do {
            packName = try ProjectPackGate.requireMutation(
                projectURL: FrameInventory.projectHome(of: dataRoot),
                declaredPack: declaredPack,
                declaredBinding: declaredBinding,
                declaredProductionContract: declaredProductionContract
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let registry = PackCatalog.registry(activePack: packName)
        let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: declaredBinding,
            expectedProductionContract: declaredProductionContract)
        let order = try workflow.map { try PhaseContractRuntime.order(workflow: $0) }
            ?? PhaseContractRuntime.order(activePack: packName)
        guard let index = order.firstIndex(of: phase) else {
            throw ToolError("The pipeline has no registered phase named '\(phase)'.")
        }
        let lineageSnapshot: PhaseLineageSnapshot?
        let lineageFailure: String?
        let provider: EngineRegistry.PhaseLineageProvider?
        if let workflow {
            provider = try PhaseContractRuntime.lineageProvider(workflow: workflow, phase: phase, registry: registry)
        } else {
            provider = try PhaseContractRuntime.lineageProvider(activePack: packName, phase: phase, registry: registry)
        }
        if captureLineage, let provider {
            do {
                lineageSnapshot = try provider(dataRoot)
                lineageFailure = nil
            } catch {
                lineageSnapshot = nil
                lineageFailure = error.localizedDescription
            }
        } else {
            lineageSnapshot = nil
            lineageFailure = nil
        }
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates: Gates
        do {
            gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        } catch {
            throw ToolError(
                "Couldn't read gates.yaml. Repair or restore the project before continuing: \(error)"
            )
        }
        let affected = order[index...]
        if affected.contains(where: {
            let gate = gates.get($0)
            return gate.state != .pending || gate.notes != nil
        }) {
            do {
                _ = try GatesOperations.rewindTo(
                    &gates,
                    target: phase,
                    order: order
                )
                _ = try ProjectPackGate.requireMutation(
                    projectURL: FrameInventory.projectHome(of: dataRoot),
                    declaredPack: declaredPack,
                    declaredBinding: declaredBinding,
                    declaredProductionContract: declaredProductionContract
                )
                try store.save(gates, to: PipelineLayout.gatesFile)
            } catch {
                throw ToolError(
                    "The artifact changed, but its gate chain could not be invalidated: \(error)"
                )
            }
        }
        if let lineageFailure {
            throw ToolError(
                "The artifact changed, but its verified input lineage could not "
                    + "be recorded: \(lineageFailure)"
            )
        }
        do {
            if let lineageSnapshot {
                _ = try ProjectPackGate.requireMutation(
                    projectURL: FrameInventory.projectHome(of: dataRoot),
                    declaredPack: declaredPack,
                    declaredBinding: declaredBinding,
                    declaredProductionContract: declaredProductionContract
                )
                try PipelineLineageStore.record(
                    phase: phase,
                    snapshot: lineageSnapshot,
                    dataRoot: dataRoot
                )
            }
            if captureLineage, phase == "shotlist" {
                _ = try ProjectPackGate.requireMutation(
                    projectURL: FrameInventory.projectHome(of: dataRoot),
                    declaredPack: declaredPack,
                    declaredBinding: declaredBinding,
                    declaredProductionContract: declaredProductionContract
                )
                try PipelineLineageStore.record(
                    phase: PipelineExecutionPlanWriter.lineagePhaseID,
                    snapshot: try PipelineExecutionPlanWriter.lineageSnapshot(
                        dataRoot: dataRoot
                    ),
                    dataRoot: dataRoot
                )
            }
        } catch {
            throw ToolError(
                "The artifact changed, but its verified input lineage could not "
                    + "be recorded: \(error)"
            )
        }
    }
}
