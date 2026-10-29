import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionInputMaterializer {
    struct Bundle: Sendable {
        let receipt: Receipt
        let reference: CanonicalArtifactReferenceV1
        let graph: AssetGraphV1
        let demands: ReferenceDemandSetV1
        let route: ProductionRouteV1
        let plan: ReferencePlanV2
    }

    struct Receipt: Codable, Sendable, Equatable {
        let schema: String
        let workflow: HostWorkflowKey
        let projectKey: String
        let shotID: String
        let projection: CanonicalArtifactReferenceV1
        let promotion: CanonicalArtifactReferenceV1
        let plannedRoute: CanonicalArtifactReferenceV1
        let graph: CanonicalArtifactReferenceV1
        let demands: CanonicalArtifactReferenceV1
        let route: CanonicalArtifactReferenceV1
        let referencePlan: CanonicalArtifactReferenceV1
        let requirement: GenerationRequirementV1
        let sourceMedia: [CanonicalArtifactReferenceV1]
        let inputs: [CanonicalArtifactReferenceV1]
        let predecessor: RenderSubmissionBindingV1.SelectedPredecessor?
    }

    nonisolated static func currentPath(shotID: String) -> String { "execution/materialized/\(shotID)/current.v1.json" }

    static func prepare(shotID: String, editor: EditorViewModel, catalog: ModelCatalog) async throws -> Bundle {
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
              let workflow = try PipelineProductionPromptCompiler.workflow(editor: editor), workflow.isProductionV2 else { throw changed() }
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: root, order: PhaseContractRuntime.order(workflow: workflow))
        guard let phase = state.nextPhase, ["render_review", "render"].contains(phase) else { throw changed() }
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: .init(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract), phase: phase)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
        try GateGuard.requirePriorApproved(gates, order: PhaseContractRuntime.order(workflow: workflow), phase: phase)
        _ = try ProductionPlanFramesV1.requireCurrent(projection: projection, dataRoot: root)
        try PipelineProductionFramesWriter.requireCurrent(projection: projection, dataRoot: root)
        guard let shot = projection.shots.first(where: { $0.id == shotID }), let requirement = shot.generationRequirement,
              ShotDeliveryModeResolverV1.resolve(shot) != .timelineAnimatedStill else { throw changed() }
        let chain = projection.chains.first(where: { $0.shotID == shotID })
        if chain != nil, phase != "render" { throw changed() }
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: root)
        let template = try PipelineShotPlanningPromotionStore.inputTemplate(for: shotID, promotion: promotion, dataRoot: root)
        let originalGraph = try PipelineShotPlanningPromotionStore.plannedGraph(promotion: promotion, dataRoot: root)
        let originalDemand = try PipelineShotPlanningPromotionStore.plannedDemands(for: shotID, promotion: promotion, dataRoot: root)
        let plannedRoute = try PipelineShotPlanningPromotionStore.route(for: shotID, promotion: promotion, dataRoot: root)
        guard let routeRef = promotion.routes.first(where: { $0.shotID == shotID })?.route,
              let candidate = catalog.productionRouteCandidates(activation: editor.generationBatchCoordinator.providerActivation()).first(where: {
                  $0.candidate.providerActivated && $0.candidate.liveAvailable && $0.target != nil
                    && $0.candidate.capabilities.offering == plannedRoute.offering
                    && (try? ProductionRequirementResolverV1.fingerprints(requirement: requirement, candidate: $0.candidate).capabilitiesSHA256) == plannedRoute.capabilitiesSHA256
              }) else { throw changed() }
        var assets = Dictionary(uniqueKeysWithValues: originalGraph.assets.map { ($0.path, $0) })
        var demands = originalDemand.demands
        var inputs: [CanonicalArtifactReferenceV1] = []
        var preparedMedia: [CanonicalArtifactReferenceV1] = []
        var predecessor: RenderSubmissionBindingV1.SelectedPredecessor?
        if let chain {
            let selected = try PipelineProductionRenderWriter.requireSelected(shotID: chain.predecessorShotID, dataRoot: root)
            let sourceRange = try PipelineProductionRenderWriter.sourceRange(record: selected.record, selection: selected.selection, dataRoot: root)
            guard sourceRange.endTicks == sourceRange.fullDurationTicks else {
                throw GateBlocked("A chained shot requires an explicitly reviewed predecessor range ending at the actual video end.")
            }
            let proof = try PipelineRenderRecordWriter.requireCurrentShotProvenance(dataRoot: root, phase: "final", shotID: chain.predecessorShotID)
            var preparedTail: CanonicalArtifactReferenceV1?
            let path: String, hash: String, job: PipelineProductionInputsWriter.CoreInputJob, mode: String
            let modality: AssetPhysicalModalityV1
            if chain.kind == .frameContinuation {
                guard let frame = selected.selection.lastFrame, let selectedMode = template.coreInputs.predecessorLastFrameModeID,
                      template.coreInputs.sourceVideoModeID == nil, originalDemand.demands.isEmpty,
                      template.coreInputs.audioTimingModeID == nil else { throw changed() }
                path = frame.path; hash = frame.sha256; job = .predecessorLastFrame; mode = selectedMode; modality = .image
            } else {
                guard let selectedMode = template.coreInputs.sourceVideoModeID,
                      template.coreInputs.predecessorLastFrameModeID == nil else { throw changed() }
                job = .sourceVideo; mode = selectedMode; modality = .video
                if sourceRange.startTicks > 0 {
                    let clock = RationalTimebaseV1(ticksPerSecond: sourceRange.timebase.ticksPerSecond,
                        fpsNumerator: projection.timebase.fpsNumerator, fpsDenominator: projection.timebase.fpsDenominator)
                    let prepared = try await PipelineProductionInputMedia.prepare(.init(source: selected.record.output,
                        timebase: clock, startTicks: sourceRange.startTicks,
                        durationTicks: sourceRange.endTicks - sourceRange.startTicks, modality: .video), access: access)
                    let media = try PlanningWriterIO.read(PipelineProductionInputMedia.Receipt.self, at: prepared.path, dataRoot: root)
                    path = media.output.path; hash = media.output.sha256; preparedTail = prepared
                    preparedMedia.append(prepared); inputs += [selected.record.output, media.output]
                } else { path = selected.record.output.path; hash = selected.record.output.sha256 }
            }
            _ = try ProjectLocalFile.requireHash(hash, at: path, dataRoot: root)
            let asset = try PipelineProductionInputsWriter.upsertingAsset(path: path, modality: modality, semanticJobID: job.semanticJobID,
                provenance: .init(kindID: preparedTail == nil ? CoreAssetProvenanceKindIDV1.renderFrame : "core.selected-predecessor-range",
                    sourceShotID: chain.predecessorShotID,
                    sourceRoleID: chain.kind == .frameContinuation ? CoreReferenceSemanticJobIDV1.lastFrame : CoreReferenceSemanticJobIDV1.sourceVideo,
                    sourceProofPath: preparedTail?.path ?? proof.artifact.path, sourceProofSHA256: preparedTail?.sha256 ?? proof.artifact.sha256,
                    recordedAt: proof.proof.renderEntry.updatedAt ?? ""),
                durationSeconds: modality == .video ? sourceRange.timebase.seconds(for: sourceRange.endTicks - sourceRange.startTicks) : nil,
                assetsByPath: &assets, dataRoot: root)
            demands.append(PipelineProductionInputsWriter.coreDemand(job, shotID: shotID, assetID: asset.id, modeID: mode,
                durationSeconds: asset.durationSeconds, expectedSourceShotID: chain.kind == .frameContinuation ? chain.predecessorShotID : nil))
            let alias = CanonicalArtifactReferenceV1(id: asset.id, role: job.semanticJobID, path: asset.path, sha256: asset.sha256)
            predecessor = .init(shotID: chain.predecessorShotID, takeID: selected.record.takeID, selectionReceipt: selected.reference,
                outputVideo: chain.kind == .nativeExtension ? alias : selected.record.output,
                lastFrame: chain.kind == .frameContinuation ? alias : nil,
                fullDurationTicks: sourceRange.fullDurationTicks, selectedStartTicks: sourceRange.startTicks, selectedEndTicks: sourceRange.endTicks,
                sourceTimebase: sourceRange.timebase)
            inputs += [selected.reference, selected.selection.record, selected.selection.review, selected.record.output,
                selected.record.generation, selected.record.submission,
                .init(id: "predecessor-proof", role: "core.render-proof", path: proof.artifact.path, sha256: proof.artifact.sha256)]
            if let frame = predecessor?.lastFrame { inputs.append(frame) }
        }
        for (role, job, mode) in [("start", PipelineProductionInputsWriter.CoreInputJob.firstFrame, template.coreInputs.firstFrameModeID),
                                  ("end", .lastFrame, template.coreInputs.lastFrameModeID)] {
            guard let mode else { continue }
            let proof = try PipelineRenderRecordWriter.requireCurrentShotProvenance(dataRoot: root, phase: "frames", shotID: shotID)
            guard let frame = proof.proof.frames?.frames.first(where: { $0.role == role }),
                  let recordedAt = proof.proof.renderEntry.updatedAt else { throw changed() }
            _ = try FrameRasterizer.loadImage(at: ProjectLocalFile.resolve(frame.path, dataRoot: root))
            let asset = try PipelineProductionInputsWriter.upsertingAsset(path: frame.path, modality: .image,
                semanticJobID: job.semanticJobID, provenance: .init(kindID: CoreAssetProvenanceKindIDV1.approvedFrame,
                    sourceShotID: shotID, sourceRoleID: job.semanticJobID,
                    sourceProofPath: proof.artifact.path, sourceProofSHA256: proof.artifact.sha256, recordedAt: recordedAt),
                assetsByPath: &assets, dataRoot: root)
            demands.append(PipelineProductionInputsWriter.coreDemand(job, shotID: shotID, assetID: asset.id, modeID: mode))
            inputs.append(.init(id: "frame-proof-" + shotID, role: "core.frame-proof", path: proof.artifact.path, sha256: proof.artifact.sha256))
        }
        var materializedRequirement = requirement
        if chain?.kind == .nativeExtension, let predecessor {
            materializedRequirement = replacingSource(requirement, with: predecessor.outputVideo.id)
        }
        if chain == nil, let mode = template.coreInputs.sourceVideoModeID {
            guard let selected = projection.sourceInputRanges.first(where: { $0.shotID == shotID }), shot.sourceMode == .aiEnhanced else { throw changed() }
            let mediaRef = try await PipelineProductionInputMedia.prepare(.init(source: selected.source, timebase: selected.timebase,
                startTicks: selected.startTicks, durationTicks: selected.durationTicks, modality: .video), access: access)
            let media = try PlanningWriterIO.read(PipelineProductionInputMedia.Receipt.self, at: mediaRef.path, dataRoot: root)
            let asset = try PipelineProductionInputsWriter.upsertingAsset(path: media.output.path, modality: .video,
                semanticJobID: CoreReferenceSemanticJobIDV1.sourceVideo,
                provenance: .init(kindID: "core.selected-source-range", sourceAssetID: selected.source.id, recordedAt: media.recordedAt),
                durationSeconds: Double(media.durationValue) / Double(media.durationTimescale), assetsByPath: &assets, dataRoot: root)
            demands.append(PipelineProductionInputsWriter.coreDemand(.sourceVideo, shotID: shotID, assetID: asset.id, modeID: mode,
                durationSeconds: asset.durationSeconds))
            preparedMedia.append(mediaRef)
            inputs += [selected.source, media.output]
            materializedRequirement = replacingSource(requirement, with: asset.id)
        }
        if let mode = template.coreInputs.audioTimingModeID {
            let known = try await PipelineProductionKnownAudio.prepare(shotID: shotID, projection: projection, modeID: mode, access: access)
            assets[known.asset.path] = known.asset
            demands.append(known.demand)
            inputs += known.references
            if let media = known.preparedMedia { preparedMedia.append(media) }
        }
        try access.revalidate()
        let retainedIDs = Set(originalDemand.demands.map(\.assetID) + requirement.identityLockAssetIDs
            + demands.filter { ProductionReferenceDemandSemanticsV1.isDedicated(semanticJobID: $0.semanticJobID) }.map(\.assetID))
        let nodes = assets.values.filter { retainedIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let graph = AssetGraphV1(id: try AssetGraphContentAddressV1.graphID(projectID: originalGraph.projectID, assets: nodes),
            projectID: originalGraph.projectID, assets: nodes)
        let graphBytes = try AssetGraphCanonicalCodecV1.encode(graph)
        let planRef = try PlanningWriterIO.reference(ProductionPlanProjectionV1.versionPath(projection.header.revision),
            id: "production-plan", role: "core.production-plan", dataRoot: root)
        let promotionRef = try PlanningWriterIO.reference(ShotPlanningPromotionV1.versionPath(promotion.header.revision),
            id: "production-promotion", role: "core.production-promotion", dataRoot: root)
        struct Identity: Encodable {
            let plan: CanonicalArtifactReferenceV1
            let promotion: CanonicalArtifactReferenceV1
            let graphSHA256: String
            let media: [CanonicalArtifactReferenceV1]
            let demands: [ReferenceDemandV1]
            let predecessor: RenderSubmissionBindingV1.SelectedPredecessor?
        }
        let identity = FileDigest.sha256(of: try PlanningWriterIO.json(Identity(plan: planRef, promotion: promotionRef,
            graphSHA256: FileDigest.sha256(of: graphBytes), media: preparedMedia, demands: demands, predecessor: predecessor)))
        let directory = "execution/materialized/\(shotID)/\(identity)"
        let graphRef = PlanningWriterIO.reference(directory + "/asset-graph.v1.json", id: graph.id, role: AssetGraphV1.artifactRole, bytes: graphBytes)
        let demand = ReferenceDemandSetV1(id: "materialized-demands-" + shotID, projectID: projection.header.projectID,
            shotID: shotID, assetGraph: graphRef, demands: demands)
        let demandBytes = try AssetGraphCanonicalCodecV1.encode(demand)
        let demandRef = PlanningWriterIO.reference(directory + "/demands.v1.json", id: demand.id, role: ReferenceDemandSetV1.artifactRole, bytes: demandBytes)
        guard case .matched(let route, _) = try ProductionRequirementResolverV1.resolve(requirement: materializedRequirement,
            demandSet: demand, assetGraph: graph, dataRoot: root, candidates: [candidate.candidate], assetGraphPath: graphRef.path),
              case .plan(let referencePlan) = try ReferencePlannerV2.plan(id: "materialized-plan-" + shotID,
                dataRoot: root, route: route, requirement: materializedRequirement, demandSet: demand, graph: graph,
                candidate: candidate.candidate, assetGraphPath: graphRef.path, demandSetPath: demandRef.path),
              PipelineProductionRouting.providerAdapterSupports(referencePlan: referencePlan, route: route,
                target: candidate.target!, modelID: candidate.modelID, requirement: materializedRequirement) else { throw changed() }
        let routeBytes = try PlanningWriterIO.json(route)
        let materializedRoute = PlanningWriterIO.reference(directory + "/route.v1.json", id: route.id, role: "core.production-route", bytes: routeBytes)
        let referenceBytes = try ReferencePlanCanonicalCodecV2.encode(referencePlan)
        let referenceRef = PlanningWriterIO.reference(directory + "/reference-plan.v1.json", id: referencePlan.id, role: "core.reference-plan", bytes: referenceBytes)
        guard let projectKey = ProjectIdentity.existingUUID(for: FrameInventory.projectHome(of: root)), editor.projectId == projectKey else { throw changed() }
        let receipt = Receipt(schema: "production-input-materialization/v1", workflow: workflow, projectKey: projectKey, shotID: shotID,
            projection: planRef, promotion: promotionRef, plannedRoute: routeRef, graph: graphRef, demands: demandRef,
            route: materializedRoute, referencePlan: referenceRef, requirement: materializedRequirement,
            sourceMedia: preparedMedia, inputs: inputs, predecessor: predecessor)
        let receiptBytes = try PlanningWriterIO.json(receipt)
        let receiptRef = PlanningWriterIO.reference(directory + "/receipt.v1.json", id: identity,
            role: "host.production-input-materialization", bytes: receiptBytes)
        let proposed = [(graphRef.path, graphBytes), (demandRef.path, demandBytes), (materializedRoute.path, routeBytes),
            (referenceRef.path, referenceBytes), (receiptRef.path, receiptBytes)]
        var files: [(path: String, bytes: Data)] = []
        for (path, bytes) in proposed {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                guard try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root)) == bytes else { throw changed() }
            } else { files.append((path, bytes)) }
        }
        let pointer = currentPath(shotID: shotID)
        if (try? Data(contentsOf: ProjectLocalFile.resolve(pointer, dataRoot: root))) != receiptBytes { files.append((pointer, receiptBytes)) }
        if !files.isEmpty {
            try access.publish(files, captureLineage: false) { _ = try requireCurrent(shotID: shotID, dataRoot: root) }
        }
        return try requireCurrent(shotID: shotID, dataRoot: root)
    }

    nonisolated static func requireCurrent(shotID: String, dataRoot: URL) throws -> Bundle {
        let receipt = try PlanningWriterIO.read(Receipt.self, at: currentPath(shotID: shotID), dataRoot: dataRoot)
        let directory = (receipt.referencePlan.path as NSString).deletingLastPathComponent
        let receiptRef = try PlanningWriterIO.reference(directory + "/receipt.v1.json", id: (directory as NSString).lastPathComponent,
            role: "host.production-input-materialization", dataRoot: dataRoot)
        guard try PlanningWriterIO.read(Receipt.self, at: receiptRef.path, dataRoot: dataRoot) == receipt else { throw changed() }
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let plan = try ProductionPlanReferencesV1.requireCurrent(projection: projection, shotID: shotID,
            graphReference: receipt.graph, demandReference: receipt.demands, routeReference: receipt.route,
            referencePlanReference: receipt.referencePlan, materializationReceipt: receiptRef,
            materializedRequirement: receipt.requirement, dataRoot: dataRoot, evidenceVerifier: verify)
        return Bundle(receipt: receipt, reference: receiptRef,
            graph: try PlanningWriterIO.read(AssetGraphV1.self, at: receipt.graph.path, dataRoot: dataRoot),
            demands: try PlanningWriterIO.read(ReferenceDemandSetV1.self, at: receipt.demands.path, dataRoot: dataRoot),
            route: try PlanningWriterIO.read(ProductionRouteV1.self, at: receipt.route.path, dataRoot: dataRoot), plan: plan)
    }

    nonisolated static func verify(_ projection: ProductionPlanProjectionV1, _ shotID: String,
        _ requirement: GenerationRequirementV1, _ references: [CanonicalArtifactReferenceV1], _ root: URL) throws {
        guard let reference = references.first(where: { $0.role == "host.production-input-materialization" }) else { throw changed() }
        let receipt = try PlanningWriterIO.read(Receipt.self, at: reference.path, dataRoot: root)
        guard receipt.schema == "production-input-materialization/v1", receipt.shotID == shotID, receipt.requirement == requirement,
              receipt.projectKey == ProjectIdentity.existingUUID(for: FrameInventory.projectHome(of: root)),
              receipt.projection.path == ProductionPlanProjectionV1.versionPath(projection.header.revision) else { throw changed() }
        let chain = projection.chains.first(where: { $0.shotID == shotID })
        if let chain {
            guard let predecessor = receipt.predecessor, predecessor.shotID == chain.predecessorShotID else { throw changed() }
            let selected = try PipelineProductionRenderWriter.requireSelected(shotID: chain.predecessorShotID, dataRoot: root)
            let sourceRange = try PipelineProductionRenderWriter.sourceRange(record: selected.record, selection: selected.selection, dataRoot: root)
            guard predecessor.takeID == selected.record.takeID, predecessor.selectionReceipt == selected.reference,
                  predecessor.fullDurationTicks == sourceRange.fullDurationTicks, predecessor.selectedStartTicks == sourceRange.startTicks,
                  predecessor.selectedEndTicks == sourceRange.endTicks, sourceRange.endTicks == sourceRange.fullDurationTicks,
                  predecessor.sourceTimebase == sourceRange.timebase else { throw changed() }
            if chain.kind == .frameContinuation || sourceRange.startTicks == 0 {
                guard predecessor.outputVideo.path == selected.record.output.path,
                      predecessor.outputVideo.sha256 == selected.record.output.sha256 else { throw changed() }
            }
            if chain.kind == .frameContinuation {
                guard let frame = selected.selection.lastFrame, let actual = predecessor.lastFrame,
                      actual.path == frame.path, actual.sha256 == frame.sha256 else { throw changed() }
            } else if predecessor.lastFrame != nil { throw changed() }
        } else if receipt.predecessor != nil { throw changed() }
        let declaration = try ProjectPackGate.captureMutationDeclaration(projectURL: FrameInventory.projectHome(of: root))
        guard try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: declaration.binding,
            expectedProductionContract: declaration.productionContract) == receipt.workflow else { throw changed() }
        guard [receipt.graph, receipt.demands, receipt.route, receipt.referencePlan].allSatisfy({ references.contains($0) }) else { throw changed() }
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: root)
        guard promotion.routes.first(where: { $0.shotID == shotID })?.route == receipt.plannedRoute,
              receipt.promotion.path == ShotPlanningPromotionV1.versionPath(promotion.header.revision) else { throw changed() }
        for ref in [receipt.projection, receipt.promotion, receipt.plannedRoute] + receipt.inputs + receipt.sourceMedia {
            _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: root)
        }
        for ref in receipt.sourceMedia {
            let media = try PlanningWriterIO.read(PipelineProductionInputMedia.Receipt.self, at: ref.path, dataRoot: root)
            try PipelineProductionInputMedia.require(media, selection: media.selection, dataRoot: root)
            if media.selection.modality == .video {
                if let chain, chain.kind == .nativeExtension {
                    let selected = try PipelineProductionRenderWriter.requireSelected(shotID: chain.predecessorShotID, dataRoot: root)
                    let range = try PipelineProductionRenderWriter.sourceRange(record: selected.record, selection: selected.selection, dataRoot: root)
                    let clock = RationalTimebaseV1(ticksPerSecond: range.timebase.ticksPerSecond,
                        fpsNumerator: projection.timebase.fpsNumerator, fpsDenominator: projection.timebase.fpsDenominator)
                    guard media.selection.source == selected.record.output, media.selection.timebase == clock,
                          media.selection.startTicks == range.startTicks, media.selection.durationTicks == range.endTicks - range.startTicks,
                          media.output.path == receipt.predecessor?.outputVideo.path,
                          media.output.sha256 == receipt.predecessor?.outputVideo.sha256 else { throw changed() }
                } else {
                    guard let selected = projection.sourceInputRanges.first(where: { $0.shotID == shotID }),
                          media.selection.source == selected.source, media.selection.timebase == selected.timebase,
                          media.selection.startTicks == selected.startTicks, media.selection.durationTicks == selected.durationTicks else { throw changed() }
                }
            } else {
                let board = try PlanningWriterIO.storyboard(dataRoot: root)
                guard let audio = board.timing.audio, let timing = projection.timing(for: shotID) else { throw changed() }
                guard let start = audio.sourceTick(atTimelineTick: timing.startTicks),
                      media.selection.source == audio.source, media.selection.timebase == projection.timebase,
                      media.selection.startTicks == start,
                      media.selection.durationTicks == timing.durationTicks else { throw changed() }
            }
        }
        if let chain, chain.kind == .nativeExtension, let predecessor = receipt.predecessor, predecessor.selectedStartTicks > 0 {
            guard try receipt.sourceMedia.contains(where: { reference in
                let media = try PlanningWriterIO.read(PipelineProductionInputMedia.Receipt.self, at: reference.path, dataRoot: root)
                return media.selection.modality == .video && media.output.path == predecessor.outputVideo.path && media.output.sha256 == predecessor.outputVideo.sha256
            }) else { throw changed() }
        }
        let graph = try PlanningWriterIO.read(AssetGraphV1.self, at: receipt.graph.path, dataRoot: root)
        let template = try PipelineShotPlanningPromotionStore.inputTemplate(for: shotID, promotion: promotion, dataRoot: root)
        if let mode = template.coreInputs.audioTimingModeID {
            let known = try PipelineProductionKnownAudio.requirePrepared(shotID: shotID, projection: projection, modeID: mode, dataRoot: root)
            let demands = try PlanningWriterIO.read(ReferenceDemandSetV1.self, at: receipt.demands.path, dataRoot: root)
            guard graph.assets.contains(known.asset), demands.demands.contains(known.demand),
                  known.references.allSatisfy({ reference in receipt.inputs.contains { $0.path == reference.path && $0.sha256 == reference.sha256 } }) else { throw changed() }
        }
        try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: root)
        for asset in graph.assets where asset.provenance.kindID == CoreAssetProvenanceKindIDV1.approvedFrame {
            guard let proofPath = asset.provenance.sourceProofPath, let proofSHA = asset.provenance.sourceProofSHA256 else { throw changed() }
            let publication = try PlanningWriterIO.read(RenderShotProvenancePublicationV1.self,
                at: RenderShotProvenancePublicationV1.artifactPath(phase: "frames"), dataRoot: root)
            guard publication.proofs[shotID] == .init(path: proofPath, sha256: proofSHA) else { throw changed() }
        }
    }

    nonisolated private static func replacingSource(_ value: GenerationRequirementV1, with sourceID: String) -> GenerationRequirementV1 {
        .init(modalityID: value.modalityID, modeIDs: value.modeIDs, visibleEntityCount: value.visibleEntityCount,
            identityLockAssetIDs: value.identityLockAssetIDs, referenceDemandIDs: value.referenceDemandIDs,
            requiresFirstFrame: value.requiresFirstFrame, requiresLastFrame: value.requiresLastFrame, sourceVideoAssetID: sourceID,
            duration: value.duration, resolution: value.resolution, aspectRatio: value.aspectRatio,
            requiresOutputAudio: value.requiresOutputAudio, productionProfileRequirementIDs: value.productionProfileRequirementIDs,
            qualityTarget: value.qualityTarget, maximumCost: value.maximumCost, maximumLatencySeconds: value.maximumLatencySeconds)
    }

    nonisolated private static func changed() -> GateBlocked { GateBlocked("The actual production inputs are missing or changed. Prepare and review the current source ranges, approved Frames and active provider route.") }
}
