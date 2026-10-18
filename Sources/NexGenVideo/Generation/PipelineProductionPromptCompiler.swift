import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionPromptCompiler {
    struct VideoInputs {
        let route: ProductionRouteV1
        let target: ResolvedGenerationTarget
        let modelID: String
        let modeID: String
        let dialect: VideoPromptDialectV1
        let plan: ReferencePlanV2?
        let conditioning: [CanonicalArtifactReferenceV1]
        let references: [VideoPromptReferenceV1]
        let predecessor: RenderReviewV1.PredecessorRecipe?
        let routeSHA256: String
        let inputPlanSHA256: String
        let orderedBindingsSHA256: String
    }

    static func workflow(editor: EditorViewModel?) throws -> HostWorkflowKey? {
        guard let editor, let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return nil }
        return try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: editor.declaredPluginBinding,
            expectedProductionContract: editor.declaredProductionContract)
    }

    static func shotProjection(shotID: String, dataRoot: URL) throws -> PromptComposer.ShotProjection {
        let plan = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let board = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: board)
        guard let shot = plan.shots.first(where: { $0.id == shotID }),
              let intent = draft.shots.first(where: { $0.shotID == shotID }),
              let bible = try loadBible(dataRoot: dataRoot) else { throw GateBlocked("The current production shot or Bible is missing.") }
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: plan, dataRoot: dataRoot)
        let graph = try PipelineShotPlanningPromotionStore.plannedGraph(promotion: promotion, dataRoot: dataRoot)
        let ids = Set(promotion.resolutions.filter { $0.shotID == shotID }.compactMap { resolution -> String? in
            guard case .asset(let id, _) = resolution.outcome else { return nil }
            return graph.assets.first { $0.id == id }?.entityID
        })
        return PromptComposer.ShotProjection(execution: shot, intent: intent, bible: bible, entityIDs: ids.sorted())
    }

    static func framePlan(shotID: String, modelID: String, dataRoot: URL, catalog: ModelCatalog) throws -> FrameReferencePlanV1 {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        guard !projection.requiredFrameRoles(for: shotID).isEmpty,
              let model = catalog.image.first(where: { $0.id == modelID }) else {
            throw GateBlocked("This shot has no Frames work for the selected image model.")
        }
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: dataRoot)
        let board = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: board)
        guard let intent = draft.shots.first(where: { $0.shotID == shotID }) else { throw GateBlocked("The current shot draft is missing.") }
        let graph = try PipelineShotPlanningPromotionStore.plannedGraph(promotion: promotion, dataRoot: dataRoot)
        var bindings: [FrameReferenceBindingV1] = []
        var deficits: [FrameReferenceDeficitV1] = []
        for obligation in intent.obligations where obligation.kind != .sourceFootage && obligation.kind != .geometry {
            guard let resolution = promotion.resolutions.first(where: { $0.shotID == shotID && $0.obligationID == obligation.id }) else {
                deficits.append(.init(requirementID: obligation.id, detail: "Resolve \(obligation.subject) before generating Frames."))
                continue
            }
            switch resolution.outcome {
            case .skipped:
                if obligation.required { deficits.append(.init(requirementID: obligation.id, detail: "A required reference was skipped.")) }
            case .asset(let id, let evidence):
                _ = try ProjectLocalFile.requireHash(evidence.sha256, at: evidence.path, dataRoot: dataRoot)
                _ = try FrameRasterizer.loadImage(at: ProjectLocalFile.resolve(evidence.path, dataRoot: dataRoot))
                guard let asset = graph.assets.first(where: { $0.id == id }), asset.approval == .approved,
                      asset.path == evidence.path, asset.sha256 == evidence.sha256 else {
                    throw GateBlocked("The frame reference does not match its actual approved planning asset.")
                }
                bindings.append(.init(path: evidence.path, sha256: evidence.sha256, role: obligation.kind.rawValue,
                    entityID: asset.entityID ?? "", viewID: asset.viewID ?? "", purpose: obligation.requirement, requirementIDs: [obligation.id],
                    isRequired: obligation.required, priority: bindings.count))
            }
        }
        let required = bindings.filter(\.isRequired)
        let optional = bindings.filter { !$0.isRequired }
        let optionalCount = max(0, model.maxReferenceImages - required.count)
        if required.count > model.maxReferenceImages {
            deficits.append(.init(requirementID: "reference-capacity", detail: "The selected model cannot accept every required reference."))
        }
        let selected = required + Array(optional.prefix(optionalCount))
        let result = FrameReferencePlanV1(shotID: shotID, maxReferenceImages: model.maxReferenceImages,
            bindings: selected, optionalDrops: Array(optional.dropFirst(optionalCount)), deficits: deficits)
        guard result.isExecutable else { throw GateBlocked(result.deficits.map(\.detail).joined(separator: " ")) }
        return result
    }

    static func videoInputs(shotID: String, dataRoot: URL, editor: EditorViewModel?, catalog: ModelCatalog) throws -> VideoInputs {
        let inventory = try PipelineProductionPlanReadStore.inventory(dataRoot: dataRoot)
        let projection = inventory.projection
        guard let shot = projection.shots.first(where: { $0.id == shotID }), let requirement = shot.generationRequirement,
              let stored = inventory.shots.first(where: { $0.shotID == shotID }), let route = stored.route,
              let template = stored.inputTemplate else { throw GateBlocked("Resolve this shot's current route and planned inputs first.") }
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: dataRoot)
        guard let routeRef = promotion.routes.first(where: { $0.shotID == shotID })?.route else {
            throw GateBlocked("The planned shot has no immutable route binding.")
        }
        let activation = editor?.generationBatchCoordinator.providerActivation() ?? .current()
        let actualCatalog = catalog === ModelCatalog.shared ? (editor?.generationBatchCoordinator.modelCatalog ?? catalog) : catalog
        let candidates = actualCatalog.productionRouteCandidates(activation: activation)
        guard let candidate = candidates.first(where: { record in
            guard record.candidate.providerActivated, record.candidate.liveAvailable,
                  record.candidate.capabilities.offering == route.offering, record.target != nil,
                  let hashes = try? ProductionRequirementResolverV1.fingerprints(requirement: requirement, candidate: record.candidate) else { return false }
            return hashes.requirementSHA256 == route.requirementSHA256 && hashes.capabilitiesSHA256 == route.capabilitiesSHA256
                && hashes.routeSHA256 == route.routeSHA256
        }), let target = candidate.target else { throw GateBlocked("The planned provider route is no longer active with its reviewed capabilities.") }
        let modes = Set([template.coreInputs.firstFrameModeID, template.coreInputs.lastFrameModeID,
            template.coreInputs.predecessorLastFrameModeID, template.coreInputs.sourceVideoModeID,
            template.coreInputs.audioTimingModeID].compactMap { $0 }.map(ProductionIdentifierNormalizerV1.canonical))
        let mode: String
        if modes.count == 1, let selected = modes.first { mode = selected }
        else if modes.isEmpty, requirement.modeIDs.count == 1, let selected = requirement.modeIDs.first { mode = selected }
        else { throw GateBlocked("Choose one executable production mode for this shot.") }
        let dialect = try PromptDialectRegistry.requireVideoDialect(modelID: candidate.modelID, endpointID: target.endpoint, modeID: mode)
        let chain = projection.chains.first { $0.shotID == shotID }
        let plan: ReferencePlanV2?
        let conditioning: [CanonicalArtifactReferenceV1]
        let references: [VideoPromptReferenceV1]
        let predecessor: RenderReviewV1.PredecessorRecipe?
        let inputPlanSHA256: String
        let orderedBindingsSHA256: String
        if let chain {
            let strategy: RenderReviewV1.PredecessorRecipe.Strategy = chain.kind == .frameContinuation ? .frameContinuation : .nativeExtension
            let graph = try PipelineShotPlanningPromotionStore.plannedGraph(promotion: promotion, dataRoot: dataRoot)
            let demand = try PipelineShotPlanningPromotionStore.plannedDemands(for: shotID, promotion: promotion, dataRoot: dataRoot)
            if strategy == .frameContinuation, !demand.demands.isEmpty {
                throw GateBlocked("Frame continuation must use only its declared predecessor last frame.")
            }
            let ordered = demand.demands.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority }
            var actualReferences: [CanonicalArtifactReferenceV1] = []
            var promptReferences: [VideoPromptReferenceV1] = [.init(planIndex: 0, modalityIndex: 1,
                modality: strategy == .frameContinuation ? .image : .video,
                role: strategy == .frameContinuation ? .startFrame : .sourceVideo,
                semanticJobID: strategy == .frameContinuation ? CoreReferenceSemanticJobIDV1.predecessorLastFrame : CoreReferenceSemanticJobIDV1.sourceVideo,
                assetID: "planned-predecessor-" + chain.predecessorShotID)]
            var counts: [AssetPhysicalModalityV1: Int] = [(strategy == .frameContinuation ? .image : .video): 1]
            for item in ordered {
                guard let asset = graph.assets.first(where: { $0.id == item.assetID }), asset.approval == .approved else {
                    throw GateBlocked("The extension recipe has no actual approved original conditioning asset.")
                }
                _ = try ProjectLocalFile.requireHash(asset.sha256, at: asset.path, dataRoot: dataRoot)
                actualReferences.append(.init(id: asset.id, role: item.semanticJobID, path: asset.path, sha256: asset.sha256))
                counts[asset.modality, default: 0] += 1
                promptReferences.append(.init(planIndex: promptReferences.count, modalityIndex: counts[asset.modality] ?? 1,
                    modality: modality(asset.modality), role: role(item.semanticJobID), semanticJobID: item.semanticJobID,
                    assetID: asset.id, entityID: asset.entityID, stateID: asset.stateID, viewID: asset.viewID,
                    preservationScopeIDs: []))
            }
            predecessor = .init(strategy: strategy, predecessorShotID: chain.predecessorShotID,
                extensionModeID: strategy == .nativeExtension ? mode : nil, permittedOriginalReferences: actualReferences)
            plan = nil
            conditioning = actualReferences
            references = promptReferences
            struct Recipe: Encodable { let chain: ProductionPlanProjectionV1.ChainBinding; let originalReferences: [CanonicalArtifactReferenceV1] }
            inputPlanSHA256 = FileDigest.sha256(of: try PlanningWriterIO.json(Recipe(chain: chain, originalReferences: actualReferences)))
            orderedBindingsSHA256 = FileDigest.sha256(of: try PlanningWriterIO.json(references))
        } else {
            let graph = try PlanningWriterIO.read(AssetGraphV1.self, at: PipelineLayout.assetGraphFile, dataRoot: dataRoot)
            try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: dataRoot)
            let demand = try PlanningWriterIO.read(ReferenceDemandSetV1.self,
                at: PipelineLayout.referenceDemandSetFile(shotID: shotID), dataRoot: dataRoot)
            let referencePlan = try PlanningWriterIO.read(ReferencePlanV2.self,
                at: PipelineLayout.referencePlanFile(shotID: shotID), dataRoot: dataRoot)
            try ReferencePlannerV2.validate(referencePlan, dataRoot: dataRoot, route: route,
                requirement: requirement, demandSet: demand, graph: graph, candidate: candidate.candidate)
            try ReferencePlannerV2.validateProjectFiles(referencePlan, dataRoot: dataRoot)
            let assets = Dictionary(uniqueKeysWithValues: graph.assets.map { ($0.id, $0) })
            var counts: [AssetPhysicalModalityV1: Int] = [:]
            references = try referencePlan.bindings.enumerated().map { index, binding in
                guard let asset = assets[binding.assetID] else { throw GateBlocked("A planned conditioning asset is missing.") }
                counts[binding.modality, default: 0] += 1
                return .init(planIndex: index, modalityIndex: counts[binding.modality] ?? 1,
                    modality: modality(binding.modality), role: role(binding.semanticJobID), semanticJobID: binding.semanticJobID,
                    assetID: binding.assetID, entityID: asset.entityID, stateID: asset.stateID,
                    viewID: asset.viewID, preservationScopeIDs: binding.preservationScopeIDs)
            }
            plan = referencePlan
            conditioning = referencePlan.bindings.map { .init(id: $0.assetID, role: $0.semanticJobID, path: $0.path, sha256: $0.sha256) }
            predecessor = nil
            inputPlanSHA256 = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.referencePlanFile(shotID: shotID), dataRoot: dataRoot))
            orderedBindingsSHA256 = FileDigest.sha256(of: try PlanningWriterIO.json(referencePlan.bindings))
        }
        return VideoInputs(route: route, target: target, modelID: candidate.modelID, modeID: mode, dialect: dialect,
            plan: plan, conditioning: conditioning, references: references, predecessor: predecessor,
            routeSHA256: try FileDigest.sha256(of: ProjectLocalFile.resolve(routeRef.path, dataRoot: dataRoot)),
            inputPlanSHA256: inputPlanSHA256, orderedBindingsSHA256: orderedBindingsSHA256)
    }

    static func binding(shotID: String, modality: PromptComposer.Modality, modelID: String?, dataRoot: URL,
                        editor: EditorViewModel?, catalog: ModelCatalog, projectKey: String,
                        styleFingerprint: String, compilerInputsSHA256: String) throws -> PromptBinding {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        guard let shot = projection.shots.first(where: { $0.id == shotID }) else { throw GateBlocked("The production shot is missing.") }
        let fingerprint = FileDigest.sha256(of: try PlanningWriterIO.json(projection))
        if case .video = modality {
            let inputs = try videoInputs(shotID: shotID, dataRoot: dataRoot, editor: editor, catalog: catalog)
            guard modelID == nil || modelID == inputs.modelID else { throw GateBlocked("Compile this shot with its current planned model.") }
            return PromptBinding(projectKey: projectKey, shotId: shotID, shotFingerprint: fingerprint,
                routeArtifactSHA256: inputs.routeSHA256, requirementSHA256: inputs.route.requirementSHA256,
                capabilitiesSHA256: inputs.route.capabilitiesSHA256, routeSHA256: inputs.route.routeSHA256,
                referencePlanSHA256: inputs.inputPlanSHA256, orderedBindingsSHA256: inputs.orderedBindingsSHA256,
                styleFingerprint: styleFingerprint, compilerInputsSHA256: compilerInputsSHA256,
                promptDialectID: inputs.dialect.id, promptDialectVersion: inputs.dialect.version)
        }
        guard shot.sourceMode == .generated, let modelID else { throw GateBlocked("Only generated production shots enter Frames.") }
        let frames = try framePlan(shotID: shotID, modelID: modelID, dataRoot: dataRoot, catalog: catalog)
        return PromptBinding(projectKey: projectKey, shotId: shotID, shotFingerprint: fingerprint,
            styleFingerprint: styleFingerprint, compilerInputsSHA256: compilerInputsSHA256,
            frameReferencePlanSHA256: frames.fingerprint)
    }

    static func videoContext(shotID: String, modelID: String, dataRoot: URL, editor: EditorViewModel?,
                             catalog: ModelCatalog, binding: PromptBinding) throws -> PromptComposer.VideoContext {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let inputs = try videoInputs(shotID: shotID, dataRoot: dataRoot, editor: editor, catalog: catalog)
        guard inputs.modelID == modelID, inputs.routeSHA256 == binding.routeArtifactSHA256,
              inputs.inputPlanSHA256 == binding.referencePlanSHA256,
              inputs.orderedBindingsSHA256 == binding.orderedBindingsSHA256,
              let shot = projection.shots.first(where: { $0.id == shotID }) else { throw GateBlocked("The compiled production route changed.") }
        return .init(modeID: inputs.modeID, dialect: inputs.dialect, references: inputs.references,
            startState: shot.startState.summary, endState: shot.endState.summary,
            blocking: shot.blocking.map { [$0.entityID, $0.relation, $0.performance ?? ""].filter { !$0.isEmpty }.joined(separator: ": ") },
            timedActionBeats: shot.timedActionBeats, continuityLocks: shot.continuityLocks, transitionIntent: shot.transitionIntent)
    }

    private static func modality(_ value: AssetPhysicalModalityV1) -> VideoPromptReferenceModalityV1 {
        switch value { case .image: .image; case .video: .video; case .audio: .audio; case .geometry: .geometry }
    }

    private static func role(_ value: String) -> VideoPromptReferenceRoleV1 {
        switch ProductionIdentifierNormalizerV1.canonical(value) {
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.firstFrame),
             ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.predecessorLastFrame): .startFrame
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.lastFrame): .endFrame
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.sourceVideo): .sourceVideo
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.audioTiming): .audioTiming
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.styleReference): .style
        case ProductionIdentifierNormalizerV1.canonical(CoreReferenceSemanticJobIDV1.lightingReference): .lighting
        default: .other
        }
    }
}
