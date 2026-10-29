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
                }, nativeLineageRequiresRecord: id != "project_init")
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
    static func requireCurrent(phase: String, dataRoot: URL, workflow: HostWorkflowKey) throws {
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        try project.validate()
        guard !project.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GateBlocked("The production project has no identity.")
        }
        if !["project_init", "analysis"].contains(phase) {
            let source = try PlanningWriterIO.read(StorySourceV1.self, at: StorySourceV1.currentPath, dataRoot: dataRoot)
            try PipelineStorySourceWriter.requireConfirmed(source, workflowID: workflow.contractID, dataRoot: dataRoot)
        }
        switch phase {
        case "project_init": break
        case "analysis":
            guard workflow.packID == "musicvideo" else { throw GateBlocked("This workflow has no audio analysis phase.") }
        case "brief":
            let brief = try YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
            try brief.validate()
            guard brief.project == project.project, brief.projectMode == project.mode.rawValue else {
                throw GateBlocked("The Brief belongs to another project or workflow mode.")
            }
            if workflow.packID == "musicvideo" {
                let range = try PlanningWriterIO.read(PlaybackRangeV1.self, at: PlaybackRangeV1.currentPath, dataRoot: dataRoot)
                try PipelinePlaybackRangeWriter.requireCanonicalCurrent(range, dataRoot: dataRoot, workflowID: workflow.contractID)
            }
        case "production_design": try PipelineProductionAssetEvidence.requireDesign(dataRoot: dataRoot)
        case "bible":
            guard let bible = try loadBible(dataRoot: dataRoot) else { throw GateBlocked("Create the canonical Bible before approving it.") }
            try bible.validate()
            try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: dataRoot)
            let design = try YAMLArtifactStore(dataRoot: dataRoot).load(ProductionDesign.self, at: PipelineLayout.productionDesignFile)
            let brief = try YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
            guard bible.look.lightingAnchor == design.lightingAnchor,
                  brief.visualMedium == .liveActionRealistic
                    || bible.look.style.trimmingCharacters(in: .whitespacesAndNewlines) == design.visualMediumNotes.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw GateBlocked("The Bible must preserve the approved Production Design style and lighting anchor.")
            }
        case "shotlist":
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
            _ = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: dataRoot)
        case "render_review":
            guard let review = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: dataRoot) else {
                throw GateBlocked("Review the actual compiled production inputs before rendering.")
            }
            try PipelineRenderReviewWriter.requireCurrent(review, dataRoot)
        case "sanity":
            _ = try ProductionPlanAuditV1.requireCurrent(projection: ProductionPlanningLineageV2.projection(dataRoot: dataRoot), dataRoot: dataRoot)
        case "frames":
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
            _ = try ProductionPlanFramesV1.requireCurrent(projection: projection, dataRoot: dataRoot)
            try PipelineProductionFramesWriter.requireCurrent(projection: projection, dataRoot: dataRoot)
            let frames = try loadFramesManifest(dataRoot: dataRoot)
            for shot in frames.shots {
                for frame in shot.frames {
                    guard let audit = try loadFrameAudit(dataRoot: dataRoot, shotId: shot.shotId, role: frame.role) else {
                        throw GateBlocked("Inspect and audit each actual current production frame before approval.")
                    }
                    try FrameAuditExpectations.requireCurrent(audit, dataRoot: dataRoot)
                }
            }
        case "render":
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
            for shot in projection.shots where shot.sourceMode != .imported {
                if ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill {
                    _ = try PipelineProductionRenderWriter.requireStill(shotID: shot.id, dataRoot: dataRoot)
                } else { _ = try PipelineProductionRenderWriter.requireSelected(shotID: shot.id, dataRoot: dataRoot) }
            }
            _ = try PipelineProductionAssemblyWriter.requireCurrent(dataRoot: dataRoot)
        case "script": _ = try PlanningWriterIO.script(dataRoot: dataRoot)
        case "storyboard": _ = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        case "shot_planning":
            let storyboard = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
            let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: storyboard)
            try ShotPlanningValidatorV1.validate(draft, timing: storyboard.timing, approval: true)
            try PipelineShotPlanningWriter.requireSpatialInputs(draft, dataRoot: dataRoot)
        case "treatment": _ = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot, approval: true)
        default:
            throw PhaseContractError.registryMismatch("\(phase) has no normalized production artifact validator")
        }
    }
}

enum HostProductionPhaseLineage {
    static func artifactPaths(phase: String, dataRoot: URL) throws -> [String] {
        let base = try ProductionPlanningLineageV2.artifactPaths(phase: phase, dataRoot: dataRoot,
            evidenceReferences: PipelineStoryboardSketchEvidence.references,
            bibleEvidenceReferences: PipelineProductionAssetEvidence.spatialBibleReferences)
        guard phase == "render" else { return base }
        return Array(Set(base + (try PipelineProductionAssemblyWriter.artifactReferences(dataRoot: dataRoot)).map(\.path))).sorted()
    }

    static func snapshot(phase: String, dataRoot: URL) throws -> PhaseLineageSnapshot {
        let base = try ProductionPlanningLineageV2.snapshot(phase: phase, dataRoot: dataRoot,
            evidenceReferences: PipelineStoryboardSketchEvidence.references,
            bibleEvidenceReferences: PipelineProductionAssetEvidence.spatialBibleReferences)
        guard phase == "render" else { return base }
        let refs = try PipelineProductionAssemblyWriter.artifactReferences(dataRoot: dataRoot)
        let own = Set([ProductionPlanAssemblyProofV1.relativePath, PipelineProductionAssemblyWriter.receiptPath])
        let inputs = refs.filter { !own.contains($0.path) }
        let artifacts = refs.filter { own.contains($0.path) }
        return .init(inputFingerprint: FileDigest.sha256(of: try PlanningWriterIO.json([base.inputFingerprint,
            FileDigest.sha256(of: try PlanningWriterIO.json(inputs))])),
            artifactFingerprint: FileDigest.sha256(of: try PlanningWriterIO.json([base.artifactFingerprint,
                FileDigest.sha256(of: try PlanningWriterIO.json(artifacts))])))
    }
}
