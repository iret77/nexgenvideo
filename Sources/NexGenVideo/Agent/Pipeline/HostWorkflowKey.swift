import Foundation
import NexGenEngine

struct HostWorkflowKey: Equatable, Sendable {
    let packID: String?
    let packVersion: String?
    let projectSchema: String
    let manifestSchema: String
    let contractID: String
    let engineContract: Int

    var isProductionV2: Bool {
        contractID == "musicvideo.pipeline.v2" || contractID == "core.production.v2"
    }

    static let musicvideoV2Version = "0.6.0"
    static let musicvideoV2Schema = "musicvideo/3.0.0"
    static let musicvideoV2Contract = "musicvideo.pipeline.v2"

    static func resolve(
        binding: ProjectPackBinding,
        contract: ResolvedPhaseContract
    ) throws -> Self {
        guard contract.packID == binding.id, contract.packVersion == binding.version,
              contract.manifest.schema == PackPipelineManifest.currentSchema else {
            throw PhaseContractError.registryMismatch("the exact project and loaded workflow identities differ")
        }
        if binding.id == "musicvideo" {
            if binding.version == musicvideoV2Version || binding.projectSchema == musicvideoV2Schema
                || contract.manifest.contractID == musicvideoV2Contract {
                guard binding.version == musicvideoV2Version,
                      binding.projectSchema == musicvideoV2Schema,
                      contract.manifest.contractID == musicvideoV2Contract,
                      contract.projectSchema == binding.projectSchema,
                      contract.engineContract == 11 else {
                    throw PhaseContractError.registryMismatch("the Music Video production workflow tuple is unsupported")
                }
            } else {
                guard contract.manifest.contractID == "musicvideo.pipeline.v1",
                      ["musicvideo/legacy", "musicvideo/1.0.0", "musicvideo/2.0.0"].contains(binding.projectSchema),
                      SemanticVersion(binding.version).map({ $0 < SemanticVersion(musicvideoV2Version)! }) == true else {
                    throw PhaseContractError.registryMismatch("the legacy Music Video workflow tuple is unsupported")
                }
            }
        }
        return Self(packID: binding.id, packVersion: binding.version,
                    projectSchema: binding.projectSchema, manifestSchema: contract.manifest.schema,
                    contractID: contract.manifest.contractID, engineContract: contract.engineContract)
    }

    static func core(_ binding: HostProductionContractBinding) throws -> Self {
        guard binding == .current else {
            throw PhaseContractError.registryMismatch("the Core production workflow is unsupported")
        }
        return Self(packID: nil, packVersion: nil, projectSchema: binding.version,
                    manifestSchema: PackPipelineManifest.currentSchema,
                    contractID: binding.id, engineContract: EngineContract.current)
    }
}

extension PhaseContractRuntime {
    static func resolveWorkflow(
        dataRoot: URL,
        expectedPack: ProjectPackBinding?,
        expectedProductionContract: HostProductionContractBinding?
    ) throws -> HostWorkflowKey? {
        let projectURL = FrameInventory.projectHome(of: dataRoot)
        let expectedPackResolution: ProjectPluginSettings.BindingResolution = expectedPack.map {
            .bound($0)
        } ?? .absent
        let expectedCoreResolution: ProjectPluginSettings.ProductionContractResolution = expectedProductionContract.map {
            .bound($0)
        } ?? .absent
        guard ProjectPluginSettings.bindingResolution(projectURL: projectURL) == expectedPackResolution,
              ProjectPluginSettings.productionContractResolution(projectURL: projectURL) == expectedCoreResolution,
              expectedPack == nil || expectedProductionContract == nil else {
            throw PhaseContractError.registryMismatch("the project workflow differs from the trusted session declaration")
        }
        if let expectedPack {
            let contract = try exactPackContract(binding: expectedPack)
            return try HostWorkflowKey.resolve(binding: expectedPack, contract: contract)
        }
        if let expectedProductionContract { return try .core(expectedProductionContract) }
        return nil
    }

    static func contract(workflow: HostWorkflowKey) throws -> ResolvedPhaseContract {
        if workflow.packID == nil {
            guard try HostWorkflowKey.core(.current) == workflow else {
                throw PhaseContractError.registryMismatch("the Core production workflow changed during this session")
            }
            return try CoreProductionPhaseContract.resolve()
        }
        guard let id = workflow.packID, let version = workflow.packVersion,
              let binding = ProjectPackBinding(id: id, version: version, projectSchema: workflow.projectSchema) else {
            throw PhaseContractError.unavailable(workflow.contractID)
        }
        let resolved = try exactPackContract(binding: binding)
        guard try HostWorkflowKey.resolve(binding: binding, contract: resolved) == workflow else {
            throw PhaseContractError.registryMismatch("the loaded workflow changed during this session")
        }
        return resolved
    }

    static func order(workflow: HostWorkflowKey) throws -> [String] {
        try contract(workflow: workflow).order
    }

    static func gateRequirement(workflow: HostWorkflowKey, phase: String,
                                registry: EngineRegistry) throws -> EngineRegistry.GateRequirement? {
        let resolved = try contract(workflow: workflow)
        guard resolved.phase(phase) != nil else { throw PhaseContractError.unknownPhase(phase) }
        if workflow.isProductionV2 {
            return { root in
                try HostProductionPhaseGate.requireCurrent(phase: phase, dataRoot: root, workflow: workflow)
                if workflow.packID != nil { try registry.gateRequirements[phase]?(root) }
            }
        }
        return try gateRequirement(activePack: workflow.packID, phase: phase, registry: registry)
    }

    static func lineageProvider(workflow: HostWorkflowKey, phase: String,
                                registry: EngineRegistry) throws -> EngineRegistry.PhaseLineageProvider? {
        let resolved = try contract(workflow: workflow)
        guard let declaration = resolved.phase(phase) else { throw PhaseContractError.unknownPhase(phase) }
        if workflow.packID == nil { return declaration.nativeLineageProvider }
        return registry.phaseLineageProviders[phase]
    }

    static func initializeWorkflowState(dataRoot: URL, workflow: HostWorkflowKey) throws {
        guard workflow.isProductionV2 else { throw PhaseContractError.registryMismatch("only a new production workflow may be initialized") }
        let expectedPack: ProjectPackBinding?
        if let id = workflow.packID, let version = workflow.packVersion {
            expectedPack = ProjectPackBinding(id: id, version: version, projectSchema: workflow.projectSchema)
        } else { expectedPack = nil }
        guard try resolveWorkflow(dataRoot: dataRoot, expectedPack: expectedPack,
            expectedProductionContract: workflow.packID == nil ? .current : nil) == workflow else {
            throw PhaseContractError.registryMismatch("the production declaration changed before initialization")
        }
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        let existing = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        guard existing.gates.values.allSatisfy({ !$0.approved && $0.notes == nil }),
              try PipelineLineageStore.loadIfPresent(dataRoot: dataRoot) == nil else {
            throw GateBlocked("Existing production history requires an explicit Recovery-copy upgrade.")
        }
        let legacyCanonical = [PipelineLayout.briefFile, PipelineLayout.productionDesignFile,
            PipelineLayout.treatmentCurrentFile, PipelineLayout.storyboardCurrentFile, PipelineLayout.bibleFile]
        let existingShotVersions = try FileManager.default.contentsOfDirectory(atPath: dataRoot.appendingPathComponent("shotlist").path)
        guard legacyCanonical.allSatisfy({ !FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent($0).path) }),
              existingShotVersions.isEmpty else {
            throw GateBlocked("Existing creative artifacts require an explicit Recovery-copy upgrade.")
        }
        let phases = try order(workflow: workflow)
        let gates = Gates(project: existing.project, gates: Dictionary(uniqueKeysWithValues: phases.map { ($0, Gate()) }))
        try store.save(gates, to: PipelineLayout.gatesFile)
    }

    private static func exactPackContract(binding: ProjectPackBinding) throws -> ResolvedPhaseContract {
        guard let pack = PackCatalog.pack(named: binding.id), pack.version == binding.version else {
            throw PhaseContractError.unavailable(binding.id)
        }
        if let loaded = PhaseContractStore.contract(packID: binding.id),
           loaded.packVersion == binding.version,
           FileManager.default.fileExists(atPath: loaded.resourceRoot.path) {
            return loaded
        }
        if binding.version == HostWorkflowKey.musicvideoV2Version, binding.id == "musicvideo" {
            throw PhaseContractError.unavailable("Music Video production")
        }
        guard let legacy = try contract(activePack: binding.id) else {
            throw PhaseContractError.unavailable(binding.id)
        }
        return legacy
    }
}
