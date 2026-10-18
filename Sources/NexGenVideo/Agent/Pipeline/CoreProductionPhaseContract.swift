import Foundation
import NexGenEngine

enum CoreProductionPhaseContract {
    static func resolve() throws -> ResolvedPhaseContract {
        guard let root = Bundle.module.url(forResource: "ProductionWorkflow", withExtension: nil) else {
            throw PhaseContractError.missingResource("ProductionWorkflow")
        }
        let phases = try ProductionWorkflowV2.corePhases.enumerated().map { index, id in
            let bound = try toolSet(ProductionWorkflowV2.phaseBound(id))
            let supporting = try toolSet(ProductionWorkflowV2.supporting(id))
            let declaration = PackPipelineManifest.Phase(id: id, executionIndex: index,
                dependencies: index == 0 ? [] : [ProductionWorkflowV2.corePhases[index - 1]],
                roles: [.canonicalWriter, .reviewGate], selectors: .init(artifact: "host.\(id)",
                    writer: "host.\(id)_writer", gate: "host.\(id)", lineage: "host.\(id)"),
                capabilities: .init(phaseBound: bound.map(\.rawValue).sorted(), supporting: supporting.map(\.rawValue).sorted()),
                instructions: "\(id).md", display: .init(label: PhaseDisplay.label(id)))
            return ResolvedPhaseContract.Phase(declaration: declaration, phaseBoundCapabilities: bound,
                supportingCapabilities: supporting, nativeLineageProvider: { root in
                    try HostProductionPhaseLineage.snapshot(phase: id, dataRoot: root)
                }, nativeArtifactProvider: { root in
                    try HostProductionPhaseLineage.artifactPaths(phase: id, dataRoot: root)
                }, nativeLineageRequiresRecord: true)
        }
        let manifest = PackPipelineManifest(contractID: "core.production.v2", packID: "core",
            resourceRoot: "ProductionWorkflow", hardStepsManifestID: HardStepManifest.empty.schema,
            display: .init(title: "Production"),
            postPipelineCapabilities: PipelineAgentContract.postPipelineUtilityCapabilities.map(\.rawValue).sorted(),
            phases: phases.map(\.declaration))
        let result = ResolvedPhaseContract(packID: "core", packVersion: HostProductionContractBinding.current.version,
            engineContract: EngineContract.current, historicalCompatibility: false, manifest: manifest,
            hardSteps: .empty, resourceRoot: root, phases: phases, projectSchema: HostProductionContractBinding.current.version)
        try ProductionWorkflowV2.validate(result)
        return result
    }

    private static func toolSet(_ names: Set<String>) throws -> Set<ToolName> {
        try Set(names.map { name in
            guard let tool = ToolName(rawValue: name) else {
                throw PhaseContractError.registryMismatch("Core production requires unavailable tool \(name)")
            }
            return tool
        })
    }
}

enum HostProductionPhaseGate {
    static func requireCurrent(phase: String, dataRoot: URL) throws {
        switch phase {
        case "script": _ = try PlanningWriterIO.script(dataRoot: dataRoot)
        case "storyboard": _ = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        case "shot_planning":
            let storyboard = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
            _ = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: storyboard)
        case "treatment": _ = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot, approval: true)
        default:
            throw PhaseContractError.registryMismatch("\(phase) has no normalized production artifact validator")
        }
    }
}

enum HostProductionPhaseLineage {
    static func artifactPaths(phase: String, dataRoot: URL) throws -> [String] {
        try ProductionPlanningLineageV2.artifactPaths(phase: phase, dataRoot: dataRoot)
    }

    static func snapshot(phase: String, dataRoot: URL) throws -> PhaseLineageSnapshot {
        try ProductionPlanningLineageV2.snapshot(phase: phase, dataRoot: dataRoot)
    }
}
