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
        let routeReference: CanonicalArtifactReferenceV1
        let artifactReferences: [CanonicalArtifactReferenceV1]
        let routeSHA256: String
        let inputPlanSHA256: String
        let orderedBindingsSHA256: String
    }

    static func workflow(editor: EditorViewModel?) throws -> HostWorkflowKey? {
        guard let editor, let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return nil }
        return try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: editor.declaredPluginBinding,
            expectedProductionContract: editor.declaredProductionContract)
    }

    static func shotProjection(shotID: String, dataRoot: URL, boundaryRole: String? = nil) throws -> PromptComposer.ShotProjection {
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
        let visual = try PipelineMusicvideoPromptContextV2.current(projection: plan, dataRoot: dataRoot).map {
            PipelineMusicvideoPromptContextV2.visual(music: $0, shotID: shotID, still: boundaryRole != nil)
        } ?? []
        return PromptComposer.ShotProjection(execution: shot, intent: intent, bible: bible, entityIDs: ids.sorted(),
            boundaryRole: boundaryRole, visualDirectives: visual)
    }

    static func framePlan(shotID: String, modelID: String, dataRoot: URL, catalog: ModelCatalog, frameRole: String? = nil) async throws -> FrameReferencePlanV1 {
        guard let model = catalog.image.first(where: { $0.id == modelID }) else {
            throw GateBlocked("The selected image model is unavailable.")
        }
        let capacity = model.maxReferenceImages
        return try await Task.detached(priority: .userInitiated) {
            try makeFramePlan(shotID: shotID, dataRoot: dataRoot, capacity: capacity, frameRole: frameRole)
        }.value
    }

    nonisolated private static func makeFramePlan(shotID: String, dataRoot: URL, capacity: Int, frameRole: String?) throws -> FrameReferencePlanV1 {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        guard !projection.requiredFrameRoles(for: shotID).isEmpty else {
            throw GateBlocked("This shot has no Frames work.")
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
                try PipelineProductionAssetEvidence.requireReferencePurpose(path: evidence.path, sha256: evidence.sha256,
                    semanticJobID: obligation.kind.rawValue, dataRoot: dataRoot)
                bindings.append(.init(path: evidence.path, sha256: evidence.sha256, role: obligation.kind.rawValue,
                    entityID: asset.entityID ?? "", viewID: asset.viewID ?? "", purpose: obligation.requirement, requirementIDs: [obligation.id],
                    isRequired: obligation.required, priority: bindings.count))
            }
        }
        if let frameRole {
            guard projection.requiredFrameRoles(for: shotID).contains(frameRole) else { throw GateBlocked("This shot has no requested production frame role.") }
            if let geometry = try PipelineSpatialDerivationWriter.planningFrameReference(shotID: shotID, role: frameRole, dataRoot: dataRoot) {
                _ = try FrameRasterizer.loadImage(at: ProjectLocalFile.requireHash(geometry.sha256, at: geometry.path, dataRoot: dataRoot))
                bindings.insert(.init(path: geometry.path, sha256: geometry.sha256, role: "geometry", entityID: "", viewID: frameRole,
                    purpose: "Exact verified shot pose, camera and spatial layout only; appearance comes from the approved identity and style references.",
                    requirementIDs: ["native-shot-geometry-" + frameRole], isRequired: true, priority: 0), at: 0)
            }
        }
        let required = bindings.filter(\.isRequired)
        let optional = bindings.filter { !$0.isRequired }
        let optionalCount = max(0, capacity - required.count)
        if required.count > capacity {
            deficits.append(.init(requirementID: "reference-capacity", detail: "The selected model cannot accept every required reference."))
        }
        let selected = required + Array(optional.prefix(optionalCount))
        let result = FrameReferencePlanV1(shotID: shotID, maxReferenceImages: capacity,
            bindings: selected, optionalDrops: Array(optional.dropFirst(optionalCount)), deficits: deficits)
        guard result.isExecutable else { throw GateBlocked(result.deficits.map(\.detail).joined(separator: " ")) }
        return result
    }

    static func videoInputs(shotID: String, dataRoot: URL, editor: EditorViewModel?, catalog: ModelCatalog) throws -> VideoInputs {
        let inventory = try PipelineProductionPlanReadStore.inventory(dataRoot: dataRoot)
        let projection = inventory.projection
        guard let shot = projection.shots.first(where: { $0.id == shotID }), let plannedRequirement = shot.generationRequirement,
              let stored = inventory.shots.first(where: { $0.shotID == shotID }), let plannedRoute = stored.route,
              let template = stored.inputTemplate else { throw GateBlocked("Resolve this shot's current route and planned inputs first.") }
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: dataRoot)
        let chain = projection.chains.first { $0.shotID == shotID }
        let materialized: PipelineProductionInputMaterializer.Bundle? = chain == nil
            ? try PipelineProductionInputMaterializer.requireCurrent(shotID: shotID, dataRoot: dataRoot) : nil
        let route = materialized?.route ?? plannedRoute
        let requirement = materialized?.receipt.requirement ?? plannedRequirement
        guard let plannedRouteRef = promotion.routes.first(where: { $0.shotID == shotID })?.route else {
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
        let routeRef = materialized?.receipt.route ?? plannedRouteRef
        let plan: ReferencePlanV2?
        let conditioning: [CanonicalArtifactReferenceV1]
        let references: [VideoPromptReferenceV1]
        let predecessor: RenderReviewV1.PredecessorRecipe?
        let inputPlanSHA256: String
        let orderedBindingsSHA256: String
        var knownAudioReferences: [CanonicalArtifactReferenceV1] = []
        if let chain {
            let strategy: RenderReviewV1.PredecessorRecipe.Strategy = chain.kind == .frameContinuation ? .frameContinuation : .nativeExtension
            let graph = try PipelineShotPlanningPromotionStore.plannedGraph(promotion: promotion, dataRoot: dataRoot)
            let demand = try PipelineShotPlanningPromotionStore.plannedDemands(for: shotID, promotion: promotion, dataRoot: dataRoot)
            if strategy == .frameContinuation, !demand.demands.isEmpty {
                throw GateBlocked("Frame continuation must use only its declared predecessor last frame.")
            }
            struct RecipeInput {
                let index: Int
                let slot: String
                let asset: AssetGraphNodeV1?
                let demand: ReferenceDemandV1?
            }
            var recipeInputs = try demand.demands.enumerated().map { index, item -> RecipeInput in
                guard let asset = graph.assets.first(where: { $0.id == item.assetID }), asset.approval == .approved else {
                    throw GateBlocked("The extension recipe has no actual approved original conditioning asset.")
                }
                _ = try ProjectLocalFile.requireHash(asset.sha256, at: asset.path, dataRoot: dataRoot)
                try PlanningSpatialAssetV1.requireDemandPurpose(item, asset: asset, targetShotID: shotID)
                try PipelineProductionAssetEvidence.requireReferencePurpose(path: asset.path, sha256: asset.sha256,
                    semanticJobID: item.semanticJobID, dataRoot: dataRoot,
                    geometry: asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID)
                return RecipeInput(index: index, slot: item.inputSlotID, asset: asset, demand: item)
            }
            let futureSlot = strategy == .frameContinuation ? CoreReferenceInputSlotIDV1.firstFrame : CoreReferenceInputSlotIDV1.sourceVideo
            recipeInputs.append(RecipeInput(index: recipeInputs.count, slot: futureSlot, asset: nil, demand: nil))
            if let audioMode = template.coreInputs.audioTimingModeID {
                guard strategy == .nativeExtension else { throw GateBlocked("Frame continuation accepts only its predecessor last frame.") }
                let known = try PipelineProductionKnownAudio.requirePrepared(shotID: shotID, projection: projection,
                    modeID: audioMode, dataRoot: dataRoot)
                knownAudioReferences += known.references
                recipeInputs.append(RecipeInput(index: recipeInputs.count, slot: known.demand.inputSlotID,
                    asset: known.asset, demand: known.demand))
            }
            let slots = Dictionary(uniqueKeysWithValues: candidate.candidate.inputSlots.map { ($0.id, $0) })
            recipeInputs.sort {
                let left = ProductionInputSlotAliasV1.slot($0.slot, in: slots)?.requestOrder ?? Int.max
                let right = ProductionInputSlotAliasV1.slot($1.slot, in: slots)?.requestOrder ?? Int.max
                return left == right ? $0.index < $1.index : left < right
            }
            var actualReferences: [CanonicalArtifactReferenceV1] = []
            var promptReferences: [VideoPromptReferenceV1] = []
            var counts: [AssetPhysicalModalityV1: Int] = [:]
            for input in recipeInputs {
                if let asset = input.asset, let item = input.demand {
                    actualReferences.append(.init(id: asset.id, role: item.semanticJobID, path: asset.path, sha256: asset.sha256))
                    counts[asset.modality, default: 0] += 1
                    promptReferences.append(.init(planIndex: promptReferences.count, modalityIndex: counts[asset.modality] ?? 1,
                        modality: modality(asset.modality), role: asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID ? .other : role(item.semanticJobID),
                        semanticJobID: item.semanticJobID, assetID: asset.id, entityID: asset.entityID, stateID: asset.stateID, viewID: asset.viewID,
                        preservationScopeIDs: item.preservationScopeIDs))
                } else {
                    let physical: AssetPhysicalModalityV1 = strategy == .frameContinuation ? .image : .video
                    counts[physical, default: 0] += 1
                    promptReferences.append(.init(planIndex: promptReferences.count, modalityIndex: counts[physical] ?? 1,
                        modality: modality(physical), role: strategy == .frameContinuation ? .startFrame : .sourceVideo,
                        semanticJobID: strategy == .frameContinuation ? CoreReferenceSemanticJobIDV1.predecessorLastFrame : CoreReferenceSemanticJobIDV1.sourceVideo,
                        assetID: "planned-predecessor-" + chain.predecessorShotID))
                }
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
            guard let materialized else { throw GateBlocked("Prepare the actual shot inputs before compiling.") }
            let graph = materialized.graph
            let referencePlan = materialized.plan
            let assets = Dictionary(uniqueKeysWithValues: graph.assets.map { ($0.id, $0) })
            var counts: [AssetPhysicalModalityV1: Int] = [:]
            references = try referencePlan.bindings.enumerated().map { index, binding in
                guard let asset = assets[binding.assetID] else { throw GateBlocked("A planned conditioning asset is missing.") }
                try PipelineProductionAssetEvidence.requireReferencePurpose(path: asset.path, sha256: asset.sha256,
                    semanticJobID: binding.semanticJobID, dataRoot: dataRoot,
                    geometry: asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID)
                counts[binding.modality, default: 0] += 1
                return .init(planIndex: index, modalityIndex: counts[binding.modality] ?? 1,
                    modality: modality(binding.modality), role: asset.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID ? .other : role(binding.semanticJobID),
                    semanticJobID: binding.semanticJobID,
                    assetID: binding.assetID, entityID: asset.entityID, stateID: asset.stateID,
                    viewID: asset.viewID, preservationScopeIDs: binding.preservationScopeIDs)
            }
            plan = referencePlan
            conditioning = referencePlan.bindings.map { .init(id: $0.assetID, role: $0.semanticJobID, path: $0.path, sha256: $0.sha256) }
            predecessor = nil
            inputPlanSHA256 = materialized.receipt.referencePlan.sha256
            orderedBindingsSHA256 = FileDigest.sha256(of: try PlanningWriterIO.json(referencePlan.bindings))
        }
        return VideoInputs(route: route, target: target, modelID: candidate.modelID, modeID: mode, dialect: dialect,
            plan: plan, conditioning: conditioning, references: references, predecessor: predecessor,
            routeReference: routeRef, artifactReferences: (materialized.map {
                [$0.reference, $0.receipt.graph, $0.receipt.demands, $0.receipt.route, $0.receipt.referencePlan]
                    + $0.receipt.inputs + $0.receipt.sourceMedia
            } ?? []) + knownAudioReferences + promotion.artifactReferences + [try PlanningWriterIO.reference(ShotPlanningPromotionV1.currentPath,
                id: "current-production-promotion", role: "core.production-promotion", dataRoot: dataRoot)],
            routeSHA256: try FileDigest.sha256(of: ProjectLocalFile.resolve(routeRef.path, dataRoot: dataRoot)),
            inputPlanSHA256: inputPlanSHA256, orderedBindingsSHA256: orderedBindingsSHA256)
    }

    static func binding(shotID: String, modality: PromptComposer.Modality, modelID: String?, dataRoot: URL,
                        editor: EditorViewModel?, catalog: ModelCatalog, projectKey: String,
                        styleFingerprint: String, compilerInputsSHA256: String, frameRole: String? = nil) async throws -> PromptBinding {
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
        let frames = try await framePlan(shotID: shotID, modelID: modelID, dataRoot: dataRoot, catalog: catalog, frameRole: frameRole)
        return PromptBinding(projectKey: projectKey, shotId: shotID, shotFingerprint: fingerprint,
            styleFingerprint: styleFingerprint, compilerInputsSHA256: compilerInputsSHA256,
            frameReferencePlanSHA256: frames.fingerprint, frameRole: frameRole)
    }

    static func videoContext(shotID: String, modelID: String, dataRoot: URL, editor: EditorViewModel?,
                             catalog: ModelCatalog, binding: PromptBinding) throws -> PromptComposer.VideoContext {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let inputs = try videoInputs(shotID: shotID, dataRoot: dataRoot, editor: editor, catalog: catalog)
        guard inputs.modelID == modelID, inputs.routeSHA256 == binding.routeArtifactSHA256,
              inputs.inputPlanSHA256 == binding.referencePlanSHA256,
              inputs.orderedBindingsSHA256 == binding.orderedBindingsSHA256,
              let shot = projection.shots.first(where: { $0.id == shotID }) else { throw GateBlocked("The compiled production route changed.") }
        let music = try PipelineMusicvideoPromptContextV2.current(projection: projection, dataRoot: dataRoot)
        let performance = try music.map {
            try PipelineMusicvideoPromptContextV2.performance(music: $0, shotID: shotID,
                audioLabel: inputs.references.first(where: { $0.role == .audioTiming })?.providerLabel)
        } ?? []
        return .init(modeID: inputs.modeID, dialect: inputs.dialect, references: inputs.references,
            startState: shot.startState.summary, endState: shot.endState.summary,
            blocking: shot.blocking.map { [$0.entityID, $0.relation, $0.performance ?? ""].filter { !$0.isEmpty }.joined(separator: ": ") },
            timedActionBeats: shot.timedActionBeats, continuityLocks: shot.continuityLocks + performance, transitionIntent: shot.transitionIntent)
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
