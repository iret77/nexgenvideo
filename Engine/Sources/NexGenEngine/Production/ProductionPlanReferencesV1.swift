import Foundation

public typealias ProductionPlanMaterializedEvidenceVerifierV1 = @Sendable
    (ProductionPlanProjectionV1, String, GenerationRequirementV1, [CanonicalArtifactReferenceV1], URL) throws -> Void

public enum ProductionPlanReferencesV1 {
    @discardableResult
    public static func requireCurrent(projection: ProductionPlanProjectionV1, shotID: String,
        graphReference: CanonicalArtifactReferenceV1, demandReference: CanonicalArtifactReferenceV1,
        routeReference: CanonicalArtifactReferenceV1, referencePlanReference: CanonicalArtifactReferenceV1,
        materializationReceipt: CanonicalArtifactReferenceV1, materializedRequirement: GenerationRequirementV1,
        dataRoot: URL, evidenceVerifier: ProductionPlanMaterializedEvidenceVerifierV1? = nil) throws -> ReferencePlanV2 {
        guard let evidenceVerifier else { throw ProductionPlanningError.invalid("references.materializationVerifier") }
        guard let shot = projection.shots.first(where: { $0.id == shotID }), let original = shot.generationRequirement else {
            throw ProductionPlanningError.invalid("references.generatedShot")
        }
        let chain = projection.chains.first { $0.shotID == shotID }
        if chain?.kind == .nativeExtension || shot.sourceMode == .aiEnhanced {
            try PlanningValidation.require(materializedRequirement.sourceVideoAssetID != nil
                && materializedRequirement.replacingSourceVideoAssetID(original.sourceVideoAssetID) == original,
                                           "references.onlyDeclaredSourceReification")
        } else {
            try PlanningValidation.require(materializedRequirement == original, "references.requirementSubstitution")
        }
        let prefix = "execution/materialized/" + shotID + "/"
        let suffix = "/asset-graph.v1.json"
        try PlanningValidation.require(graphReference.path.hasPrefix(prefix) && graphReference.path.hasSuffix(suffix), "references.bundleGraphPath")
        let contentID = graphReference.path.dropFirst(prefix.count).dropLast(suffix.count)
        try PlanningValidation.hash(String(contentID), "references.bundleContentID")
        let directory = prefix + String(contentID)
        try PlanningValidation.require(demandReference.path == directory + "/demands.v1.json"
            && routeReference.path == directory + "/route.v1.json"
            && referencePlanReference.path == directory + "/reference-plan.v1.json"
            && materializationReceipt.path == directory + "/receipt.v1.json", "references.bundlePaths")
        var references = try ProductionPlanFilesV1.planningInputs(projection, dataRoot: dataRoot).references
        references += [graphReference, demandReference, routeReference, referencePlanReference, materializationReceipt]
        try ProductionPlanFilesV1.require(references, dataRoot: dataRoot)
        let graph = try JSONDecoder().decode(AssetGraphV1.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(graphReference.path, dataRoot: dataRoot)))
        let demand = try JSONDecoder().decode(ReferenceDemandSetV1.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(demandReference.path, dataRoot: dataRoot)))
        let route = try JSONDecoder().decode(ProductionRouteV1.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(routeReference.path, dataRoot: dataRoot)))
        let plan = try JSONDecoder().decode(ReferencePlanV2.self,
            from: Data(contentsOf: ProjectLocalFile.resolve(referencePlanReference.path, dataRoot: dataRoot)))
        try PlanningValidation.require(graph.projectID == projection.header.projectID && demand.shotID == shotID
            && route.projectID == projection.header.projectID && route.shotID == shotID, "references.bundleIdentity")
        let plannedRoutePath = ShotPlanningPromotionV1.routePath(shotID: shotID, revision: projection.header.revision)
        guard let plannedRouteRef = projection.header.inputs.first(where: { $0.path == plannedRoutePath }) else {
            throw ProductionPlanningError.invalid("references.plannedRoute")
        }
        let plannedRoute = try JSONDecoder().decode(ProductionRouteV1.self,
            from: Data(contentsOf: ProjectLocalFile.requireHash(plannedRouteRef.sha256, at: plannedRouteRef.path, dataRoot: dataRoot)))
        try PlanningValidation.require(route.offering == plannedRoute.offering
            && route.capabilitySnapshot == plannedRoute.capabilitySnapshot
            && route.capabilitiesSHA256 == plannedRoute.capabilitiesSHA256, "references.routeSubstitution")
        let candidate = ProductionPlanFilesV1.candidate(route)
        try PlanningValidation.require(ProductionRequirementResolverV1.revalidate(route, requirement: materializedRequirement,
            demandSet: demand, assetGraph: graph, dataRoot: dataRoot, candidate: candidate, assetGraphPath: graphReference.path),
                                       "references.currentMaterializedRoute")
        try ReferencePlannerV2.validate(plan, dataRoot: dataRoot, route: route, requirement: materializedRequirement,
            demandSet: demand, graph: graph, candidate: candidate, assetGraphPath: graphReference.path, demandSetPath: demandReference.path)
        let continuation = demand.demands.filter {
            ProductionIdentifierNormalizerV1.matches($0.semanticJobID, CoreReferenceSemanticJobIDV1.predecessorLastFrame)
        }
        if chain?.kind == .frameContinuation {
            try PlanningValidation.require(continuation.count == 1 && continuation.first?.expectedSourceShotID == chain?.predecessorShotID,
                                           "references.exactContinuation")
        } else { try PlanningValidation.require(continuation.isEmpty, "references.undeclaredContinuation") }
        if let sourceID = materializedRequirement.sourceVideoAssetID {
            guard let source = graph.assets.first(where: { $0.id == sourceID }), source.modality == .video, source.approval == .approved else {
                throw ProductionPlanningError.invalid("references.realSourceVideo")
            }
            if chain?.kind == .nativeExtension {
                try PlanningValidation.require(source.provenance.sourceShotID == chain?.predecessorShotID,
                                               "references.exactExtensionPredecessor")
            }
        }
        for asset in graph.assets {
            references.append(.init(id: asset.id, role: "core.materialized-input", path: asset.path, sha256: asset.sha256))
            if let path = asset.provenance.sourceProofPath, let hash = asset.provenance.sourceProofSHA256 {
                references.append(.init(id: "proof-" + asset.id, role: "core.materialized-proof", path: path, sha256: hash))
            }
        }
        references = try ProductionPlanFilesV1.unique(references)
        try ProductionPlanFilesV1.require(references, dataRoot: dataRoot)
        try evidenceVerifier(projection, shotID, materializedRequirement, references, dataRoot)
        try ProductionPlanFilesV1.require(references, dataRoot: dataRoot)
        return plan
    }

    @discardableResult
    public static func requireCurrent(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> [String: ReferencePlanV2] {
        let refs = try artifactReferences(projection: projection, dataRoot: dataRoot)
        let context = try ExecutionPlanCanonicalCodec.decodeContext(Data(contentsOf:
            ProjectLocalFile.resolve(projection.executionPlan.creativeContext.path, dataRoot: dataRoot)))
        let graph = try JSONDecoder().decode(AssetGraphV1.self, from: Data(contentsOf:
            ProjectLocalFile.resolve(PipelineLayout.assetGraphFile, dataRoot: dataRoot)))
        try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: dataRoot)
        var demands: [String: ReferenceDemandSetV1] = [:]
        var plans: [String: ReferencePlanV2] = [:]
        for shot in projection.shots {
            guard let requirement = shot.generationRequirement else { continue }
            let demand = try JSONDecoder().decode(ReferenceDemandSetV1.self, from: Data(contentsOf:
                ProjectLocalFile.resolve(PipelineLayout.referenceDemandSetFile(shotID: shot.id), dataRoot: dataRoot)))
            let route = try JSONDecoder().decode(ProductionRouteV1.self, from: Data(contentsOf:
                ProjectLocalFile.resolve(PipelineLayout.productionRouteFile(shotID: shot.id), dataRoot: dataRoot)))
            let plan = try JSONDecoder().decode(ReferencePlanV2.self, from: Data(contentsOf:
                ProjectLocalFile.resolve(PipelineLayout.referencePlanFile(shotID: shot.id), dataRoot: dataRoot)))
            let candidate = ProductionPlanFilesV1.candidate(route)
            try PlanningValidation.require(route.projectID == projection.header.projectID && route.shotID == shot.id,
                                           "references.routeIdentity")
            try PlanningValidation.require(ProductionRequirementResolverV1.revalidate(route, requirement: requirement,
                demandSet: demand, assetGraph: graph, dataRoot: dataRoot, candidate: candidate), "references.currentRoute")
            try ReferencePlannerV2.validate(plan, dataRoot: dataRoot, route: route, requirement: requirement,
                                            demandSet: demand, graph: graph, candidate: candidate)
            try ReferencePlannerV2.validateProjectFiles(plan, dataRoot: dataRoot)
            demands[shot.id] = demand
            plans[shot.id] = plan
        }
        try validateProductionInputs(projection: projection, context: context, graph: graph, demands: demands)
        try ProductionPlanFilesV1.require(refs, dataRoot: dataRoot)
        return plans
    }

    public static func artifactReferences(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        var refs = try ProductionPlanFilesV1.planningInputs(projection, dataRoot: dataRoot).references
        refs.append(try ProductionPlanFilesV1.reference(PipelineLayout.assetGraphFile, dataRoot: dataRoot))
        let graph = try JSONDecoder().decode(AssetGraphV1.self, from: Data(contentsOf:
            ProjectLocalFile.resolve(PipelineLayout.assetGraphFile, dataRoot: dataRoot)))
        try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: dataRoot)
        for asset in graph.assets {
            refs.append(.init(id: asset.id, role: "core.production-asset", path: asset.path, sha256: asset.sha256))
            if let proof = asset.provenance.sourceProofPath, let hash = asset.provenance.sourceProofSHA256 {
                refs.append(.init(id: "proof-" + asset.id, role: "core.asset-proof", path: proof, sha256: hash))
            }
        }
        for shot in projection.shots where shot.generationRequirement != nil {
            for path in [PipelineLayout.referenceDemandSetFile(shotID: shot.id), PipelineLayout.productionRouteFile(shotID: shot.id),
                         PipelineLayout.referencePlanFile(shotID: shot.id)] {
                refs.append(try ProductionPlanFilesV1.reference(path, dataRoot: dataRoot))
            }
            let plan = try JSONDecoder().decode(ReferencePlanV2.self, from: Data(contentsOf:
                ProjectLocalFile.resolve(PipelineLayout.referencePlanFile(shotID: shot.id), dataRoot: dataRoot)))
            for binding in plan.bindings {
                refs.append(.init(id: "reference-" + FileDigest.sha256(of: Data(binding.path.utf8)),
                                  role: "core.conditioning-input", path: binding.path, sha256: binding.sha256))
            }
        }
        let result = try ProductionPlanFilesV1.unique(refs)
        try ProductionPlanFilesV1.require(result, dataRoot: dataRoot)
        return result
    }

    public static func validateProductionInputs(projection: ProductionPlanProjectionV1, context: ProjectCreativeContextV1,
                                                graph: AssetGraphV1, demands: [String: ReferenceDemandSetV1]) throws {
        try ProductionPlanProjectionValidatorV1.validate(projection)
        try ExecutionPlanValidator.validate(projection.executionPlan, against: context,
            creativeContextPath: ShotPlanningPromotionV1.creativeContextPath(revision: projection.header.revision))
        try AssetGraphValidatorV1.validate(graph)
        try PlanningValidation.require(graph.projectID == projection.header.projectID
            && Set(demands.keys) == Set(projection.shots.filter { $0.generationRequirement != nil }.map(\.id)),
                                       "productionInputs.exactDemandCoverage")
        let assets = Dictionary(uniqueKeysWithValues: graph.assets.map { ($0.id, $0) })
        for shot in projection.shots {
            guard let requirement = shot.generationRequirement, let demand = demands[shot.id] else { continue }
            try PlanningValidation.require(demand.shotID == shot.id, "productionInputs.shotIdentity")
            try AssetGraphValidatorV1.validate(demand, against: graph)
            try ProductionRequirementResolverV1.validateBindings(requirement, demandSet: demand)
            let chain = projection.chains.first { $0.shotID == shot.id }
            let continuation = demand.demands.filter {
                ProductionIdentifierNormalizerV1.matches($0.semanticJobID, CoreReferenceSemanticJobIDV1.predecessorLastFrame)
            }
            if chain?.kind == .frameContinuation {
                try PlanningValidation.require(continuation.count == 1
                    && continuation.first?.expectedSourceShotID == chain?.predecessorShotID, "productionInputs.declaredPredecessor")
            } else {
                try PlanningValidation.require(continuation.isEmpty, "productionInputs.undeclaredContinuation")
            }
            for id in requirement.identityLockAssetIDs {
                try PlanningValidation.require(assets[id]?.approval == .approved, "productionInputs.identityLock")
            }
            if let id = requirement.sourceVideoAssetID {
                try PlanningValidation.require(assets[id]?.approval == .approved && assets[id]?.modality == .video,
                                               "productionInputs.sourceVideo")
                if let chain, chain.kind == .nativeExtension {
                    try PlanningValidation.require(assets[id]?.provenance.sourceShotID == chain.predecessorShotID,
                                                   "productionInputs.extensionPredecessor")
                }
            }
        }
    }
}

public extension GenerationRequirementV1 {
    func replacingSourceVideoAssetID(_ assetID: String?) -> Self {
        .init(modalityID: modalityID, modeIDs: modeIDs, visibleEntityCount: visibleEntityCount,
            identityLockAssetIDs: identityLockAssetIDs, referenceDemandIDs: referenceDemandIDs,
            requiresFirstFrame: requiresFirstFrame, requiresLastFrame: requiresLastFrame, sourceVideoAssetID: assetID,
            duration: duration, resolution: resolution, aspectRatio: aspectRatio, requiresOutputAudio: requiresOutputAudio,
            productionProfileRequirementIDs: productionProfileRequirementIDs, qualityTarget: qualityTarget,
            maximumCost: maximumCost, maximumLatencySeconds: maximumLatencySeconds)
    }
}
