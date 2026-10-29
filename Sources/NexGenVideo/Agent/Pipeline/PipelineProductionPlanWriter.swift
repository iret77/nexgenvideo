import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionPlanWriter {
    typealias CandidateProvider = @MainActor @Sendable () -> [CatalogProductionRouteCandidate]

    static func currentCandidates() -> [CatalogProductionRouteCandidate] {
        ModelCatalog.shared.productionRouteCandidates(activation: .current())
    }
    struct ShotProposal: Codable, Sendable, Equatable {
        let execution: ExecutionShotV1
        let nativeDurationTicks: Int64?
        let sourceInTicks: Int64
        let sourceInputRange: ProductionPlanProjectionV1.SourceInputRange?
        let coreInputs: ProductionCoreInputModesV1?
        let referenceDemands: [ReferenceDemandV1]
        let selectedModelID: String?
        let selectedOffering: CapabilityOfferingIdentityV1?
    }

    struct Proposal: Codable, Sendable, Equatable {
        let expectedDraftFingerprint: String
        let expectedAssetGraphFingerprint: String
        let shots: [ShotProposal]
        let musicvideoPlan: MusicvideoProductionPlanDraftV1?

        init(expectedDraftFingerprint: String, expectedAssetGraphFingerprint: String, shots: [ShotProposal],
             musicvideoPlan: MusicvideoProductionPlanDraftV1? = nil) {
            self.expectedDraftFingerprint = expectedDraftFingerprint; self.expectedAssetGraphFingerprint = expectedAssetGraphFingerprint
            self.shots = shots; self.musicvideoPlan = musicvideoPlan
        }
    }

    nonisolated static func planningDirectory(revision: Int) -> String { ShotPlanningPromotionV1.planningDirectory(revision: revision) }
    nonisolated static func predecessorVideoRecipe(shotID: String) -> String { "recipe.predecessor-video." + shotID }

    static func writePrepared(proposal: Proposal, origin: PlanningArtifactHeaderV1.Origin,
                              access: PipelinePlanningWriteAccess,
                              candidateProvider: CandidateProvider = { currentCandidates() },
                              commitValidation: @MainActor () throws -> Void = {}) async throws -> ProductionPlanProjectionV1 {
        let root = access.dataRoot
        let revision = try await Task.detached {
            try PlanningWriterIO.nextRevision(directory: "shotlist", suffix: ".v5.yaml", dataRoot: root)
        }.value
        let musicvideo = try await PipelineMusicvideoProductionWriterV2.prepare(proposal: proposal, revision: revision, access: access)
        let candidates = candidateProvider().map(CandidateInput.init)
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: board)
            let preparation = try PipelineShotPlanningPromotionStore.requirePreparation(dataRoot: root)
            let graph = try PlanningWriterIO.read(AssetGraphV1.self, at: preparation.graph.path, dataRoot: root)
            let newPaths = Set(musicvideo?.files.map(\.path) ?? [])
            let references = board.references + draft.header.inputs + [preparation.graph, preparation.bible, preparation.draft]
                + (musicvideo?.inputs.filter { !newPaths.contains($0.path) } ?? [])
            let files = try NativeFileFence.capture((references.map(\.path) + graph.assets.map(\.path)).map {
                try ProjectLocalFile.resolve($0, dataRoot: root)
            })
            let initial = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root)
            let fence = PipelineSpatialSceneAuthority.SourceFence(paths: initial.paths, canonicalPaths: Array(initial.paths.keys))
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "shotlist")
                return try writeResolved(proposal: proposal, origin: origin, access: writer, musicvideo: musicvideo, candidates: candidates)
            }
            do { try fence.requireUnchanged(); try files.requireUnchanged(); return (transaction, fence, files) }
            catch { transaction.discard(); throw error }
        }
        let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { Task.detached { prepared.0.discard() } }
        try Task.checkCancellation()
        guard candidateProvider().map(CandidateInput.init) == candidates else { throw changed() }
        return try prepared.0.commit { _ in
            try access.revalidate()
            try prepared.1.requireCanonicalRootsUnchanged()
            try prepared.2.requireUnchanged()
            try commitValidation()
        }
    }

    static func write(proposal: Proposal, origin: PlanningArtifactHeaderV1.Origin,
                      access: PipelinePlanningWriteAccess, musicvideo: PipelineMusicvideoProductionWriterV2.Prepared? = nil,
                      candidateProvider: CandidateProvider = { currentCandidates() }) throws -> ProductionPlanProjectionV1 {
        try writeResolved(proposal: proposal, origin: origin, access: access, musicvideo: musicvideo,
            candidates: candidateProvider().map(CandidateInput.init))
    }

    struct CandidateInput: Sendable, Equatable {
        let modelID: String
        let candidate: ProductionRouteCandidateV1
        let target: ResolvedGenerationTarget?
        init(_ value: CatalogProductionRouteCandidate) {
            modelID = value.modelID; candidate = value.candidate; target = value.target
        }
        init(_ value: Candidate) {
            modelID = value.modelID; candidate = value.routeCandidate; target = value.target
        }
    }

    nonisolated static func writeResolved(proposal: Proposal, origin: PlanningArtifactHeaderV1.Origin,
        access: PipelinePlanningWriteAccess, musicvideo: PipelineMusicvideoProductionWriterV2.Prepared?,
        candidates: [CandidateInput]) throws -> ProductionPlanProjectionV1 {
        guard access.phase == "shotlist" else { throw GateBlocked("Production promotion belongs to Shot List.") }
        let root = access.dataRoot
        let storyboard = try PlanningWriterIO.storyboard(dataRoot: root)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: storyboard)
        let preparation = try PipelineShotPlanningPromotionStore.requirePreparation(dataRoot: root)
        guard preparation.draft.sha256 == proposal.expectedDraftFingerprint,
              preparation.graph.sha256 == proposal.expectedAssetGraphFingerprint,
              proposal.shots.map(\.execution.id) == draft.shots.map(\.shotID) else { throw changed() }
        let graph = try PlanningWriterIO.read(AssetGraphV1.self, at: preparation.graph.path, dataRoot: root)
        try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: root)
        let resolutions = try PipelineShotPlanningPromotionStore.resolutions(preparation: preparation,
            workflowID: access.workflow.contractID, dataRoot: root)
        let revision = try PlanningWriterIO.nextRevision(directory: "shotlist", suffix: ".v5.yaml", dataRoot: root)
        let promotionRevision = try PlanningWriterIO.nextRevision(directory: "shot-planning", prefix: "promotion-v", suffix: ".v1.json", dataRoot: root)
        guard revision == promotionRevision else { throw GateBlocked("Production plan and promotion history are incomplete. Restore both before revising.") }
        if access.workflow.packID == "musicvideo" {
            guard let musicvideo, musicvideo.revision == revision, musicvideo.projectID == draft.header.projectID,
                  musicvideo.proposedPlan == proposal.musicvideoPlan else {
                throw GateBlocked("Prepare the current native song performance plan before publishing this Music Video Shot List.")
            }
        } else if musicvideo != nil || proposal.musicvideoPlan != nil { throw changed() }
        let graphPath = ShotPlanningPromotionV1.assetGraphPath(revision: revision)
        let graphBytes = try AssetGraphCanonicalCodecV1.encode(graph)
        let graphRef = PlanningWriterIO.reference(graphPath, id: graph.id, role: AssetGraphV1.artifactRole, bytes: graphBytes)
        let draftRef = preparation.draft
        guard let timingRef = storyboard.references.first(where: { $0.path == StoryboardTimingV1.versionPath(storyboard.timing.header.revision) }) else { throw changed() }
        let steps = Dictionary(uniqueKeysWithValues: storyboard.storyboard.steps.map { ($0.id, $0) })
        let assets = Dictionary(uniqueKeysWithValues: graph.assets.map { ($0.id, $0) })
        var shots: [ExecutionShotV1] = []
        var timings: [ProductionPlanProjectionV1.ShotTiming] = []
        var sources: [CanonicalArtifactReferenceV1] = []
        var sourceInputRanges: [ProductionPlanProjectionV1.SourceInputRange] = []
        var routeBindings: [ShotPlanningPromotionV1.RouteBinding] = []
        var files: [(path: String, bytes: Data)] = [(graphPath, graphBytes)]
        var plannedReferences: [CanonicalArtifactReferenceV1] = [graphRef]
        for ((intent, planned), input) in zip(zip(draft.shots, storyboard.timing.shots), proposal.shots) {
            let source = try sourceAsset(intent: intent, assets: assets, resolutions: resolutions)
            let mode: ExecutionSourceModeV1 = intent.sourceMode == .generated ? .generated : intent.sourceMode == .imported ? .imported : .aiEnhanced
            let proposed = input.execution
            let action = try planned.stepIDs.map { id -> String in
                guard let step = steps[id] else { throw changed() }
                return step.action
            }.joined(separator: "\n")
            guard proposed.sourceMode == mode, proposed.primaryAction == action,
                  proposed.camera.movementID == intent.camera.movement.rawValue,
                  proposed.camera.movementDetail == intent.camera.movementDetail,
                  proposed.sourceAssetID == nil || proposed.sourceAssetID == source?.id else {
                throw GateBlocked("Production details must preserve the exact draft source, camera and Storyboard action.")
            }
            let shot = ExecutionShotV1(id: intent.shotID, sourceMode: mode, sourceAssetID: source?.id,
                startState: proposed.startState, endState: proposed.endState, primaryAction: action,
                camera: .init(movementID: intent.camera.movement.rawValue, movementDetail: intent.camera.movementDetail,
                              framingID: intent.camera.framing.scale, placement: proposed.camera.placement, endpoint: proposed.camera.endpoint),
                blocking: proposed.blocking, timedActionBeats: proposed.timedActionBeats, continuityLocks: proposed.continuityLocks,
                transitionIntent: proposed.transitionIntent, renderability: proposed.renderability, risks: proposed.risks,
                rescue: proposed.rescue, acceptance: proposed.acceptance, generationRequirement: proposed.generationRequirement)
            let selectedRange: SourceFootageRangeV1?
            if let range = intent.sourceInputRange { selectedRange = range }
            else if let obligationID = intent.sourceObligationID {
                selectedRange = try PipelineShotPlanningPromotionStore.resolvedSourceRange(shotID: intent.shotID,
                    obligationID: obligationID, dataRoot: root)
            } else { selectedRange = nil }
            let native: Int64?
            if let source {
                guard let asset = assets[source.id], let duration = asset.durationSeconds else { throw changed() }
                let ticks = duration * Double(storyboard.timing.timebase.ticksPerSecond)
                guard ticks.isFinite, ticks > 0, ticks < Double(Int64.max) else { throw changed() }
                if mode == .imported {
                    native = Int64(ticks.rounded(.down))
                    if let declared = input.nativeDurationTicks, declared != native { throw changed() }
                    guard input.sourceInputRange == nil, let range = selectedRange,
                          range.source.path == source.path, range.source.sha256 == source.sha256,
                          storyboard.timing.timebase.representsSameTime(input.sourceInTicks, as: range.startTicks, timebase: range.timebase),
                          storyboard.timing.timebase.representsSameTime(planned.durationTicks, as: range.durationTicks, timebase: range.timebase) else {
                        throw GateBlocked("The imported source trim must match its explicit native source-range selection.")
                    }
                } else {
                    native = input.nativeDurationTicks
                    guard let range = selectedRange,
                          range.source.path == source.path, range.source.sha256 == source.sha256 else {
                        throw GateBlocked("AI-enhanced footage needs an explicit original source input range, separate from the output trim.")
                    }
                    try range.timebase.validate()
                    let end = range.startTicks.addingReportingOverflow(range.durationTicks)
                    guard !end.overflow, range.startTicks >= 0, range.durationTicks > 0,
                          range.timebase.seconds(for: end.partialValue) <= duration else {
                        throw GateBlocked("The AI input range is outside the actual original video.")
                    }
                    let projectedRange = ProductionPlanProjectionV1.SourceInputRange(shotID: shot.id, source: source,
                        timebase: range.timebase, startTicks: range.startTicks, durationTicks: range.durationTicks)
                    if let proposedRange = input.sourceInputRange, proposedRange != projectedRange { throw changed() }
                    sourceInputRanges.append(projectedRange)
                }
                if !sources.contains(source) { sources.append(source) }
            } else {
                native = input.nativeDurationTicks
                guard input.sourceInputRange == nil else { throw changed() }
            }
            let timing = ProductionPlanProjectionV1.ShotTiming(shotID: shot.id, startTicks: planned.startTicks,
                durationTicks: planned.durationTicks, nativeDurationTicks: native, sourceInTicks: input.sourceInTicks)
            guard input.sourceInTicks >= 0, source != nil || native != nil || input.sourceInTicks == 0 else { throw changed() }
            if let end = native {
                let used = input.sourceInTicks.addingReportingOverflow(planned.durationTicks)
                guard !used.overflow, used.partialValue <= end else { throw GateBlocked("The source range does not cover this shot's canonical duration.") }
            }
            try PipelineShotPlanningPromotionStore.requireSpatialDemands(intent: intent, shot: shot,
                demands: input.referenceDemands, graph: graph, dataRoot: root)
            if let requirement = shot.generationRequirement {
                guard requirement.maximumCost == nil else { throw GateBlocked("Production cost is a display, not a budget limit. Remove maximum_cost from the requirement.") }
                let still = ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill
                let modes: ProductionCoreInputModesV1
                let candidate: CandidateInput?
                if still {
                    modes = input.coreInputs ?? .init()
                    candidate = nil
                    guard modes == ProductionCoreInputModesV1(), input.selectedModelID == nil, input.selectedOffering == nil, input.nativeDurationTicks == nil,
                          input.sourceInTicks == 0, requirement.duration == nil else {
                        throw GateBlocked("Animated-still delivery uses the accepted Frames image. It has no final video route or provider duration.")
                    }
                } else {
                    guard let selectedModes = input.coreInputs, let selectedModel = input.selectedModelID,
                          let offering = input.selectedOffering,
                          let selected = candidates.first(where: { $0.modelID == selectedModel && $0.candidate.capabilities.offering == offering && $0.target != nil }),
                          selected.candidate.providerActivated, selected.candidate.liveAvailable else {
                        throw GateBlocked("Choose an actually available model from an enabled provider for this shot.")
                    }
                    modes = selectedModes
                    candidate = selected
                }
                let template = ProductionInputTemplateV1(id: "input-template-" + shot.id, projectID: draft.header.projectID,
                                                         shotID: shot.id, coreInputs: modes)
                try ProductionInputTemplateValidatorV1.validate(template, requirement: requirement,
                    chainedFromPredecessor: intent.chainKind == .frameContinuation)
                if intent.chainKind == .nativeExtension {
                    guard requirement.sourceVideoAssetID == predecessorVideoRecipe(shotID: shot.id) else {
                        throw GateBlocked("Native extension declares its predecessor-video recipe until the exact predecessor Take exists.")
                    }
                } else if mode == .aiEnhanced {
                    guard requirement.sourceVideoAssetID == source?.id else { throw changed() }
                } else if requirement.sourceVideoAssetID != nil { throw changed() }
                try validateRealDemands(input.referenceDemands, requirement: requirement, graph: graph)
                let demand = ReferenceDemandSetV1(id: "planned-demands-" + shot.id, projectID: draft.header.projectID,
                    shotID: shot.id, assetGraph: graphRef, demands: input.referenceDemands)
                try AssetGraphValidatorV1.validate(demand, against: graph, assetGraphPath: graphPath)
                let sourceDuration: Double?
                if intent.chainKind == .nativeExtension, let predecessor = intent.predecessorShotID,
                   let plannedPredecessor = storyboard.timing.shots.first(where: { $0.id == predecessor }) {
                    let nativeTicks = proposal.shots.first(where: { $0.execution.id == predecessor })?.nativeDurationTicks
                    sourceDuration = storyboard.timing.timebase.seconds(for: nativeTicks ?? plannedPredecessor.durationTicks)
                } else { sourceDuration = selectedRange.map { $0.timebase.seconds(for: $0.durationTicks) } }
                let completeDemands = plannedDemands(real: demand, template: template, intent: intent,
                    timing: timing, timebase: storyboard.timing.timebase, requirement: requirement, sourceDurationSeconds: sourceDuration,
                    audioDurationSeconds: musicvideo?.segments.first(where: { $0.draft.shotIDs.contains(shot.id) }).map {
                        Double($0.draft.sourceEndSample - $0.draft.sourceStartSample) / Double($0.draft.sampleRate)
                    })
                var artifacts: [(String, Data, String, String)] = [
                    (ShotPlanningPromotionV1.inputTemplatePath(shotID: shot.id, revision: revision), try PlanningWriterIO.json(template), template.id, ProductionInputTemplateV1.artifactRole),
                    (ShotPlanningPromotionV1.demandPath(shotID: shot.id, revision: revision), try PlanningWriterIO.json(demand), demand.id, "core.planned-reference-demands")]
                if let candidate {
                    guard let target = candidate.target else { throw changed() }
                    let route = try validatedPlannedRoute(requirement: requirement, demands: completeDemands,
                        graph: graph, candidate: candidate.candidate, target: target, modelID: candidate.modelID,
                        nativeExtension: intent.chainKind == .nativeExtension)
                    artifacts.insert((ShotPlanningPromotionV1.routePath(shotID: shot.id, revision: revision), try PlanningWriterIO.json(route),
                        "route-" + shot.id, "core.production-route"), at: 0)
                }
                for (path, bytes, id, role) in artifacts {
                    let reference = PlanningWriterIO.reference(path, id: id, role: role, bytes: bytes)
                    files.append((path, bytes)); plannedReferences.append(reference)
                    if role == "core.production-route" { routeBindings.append(.init(shotID: shot.id, route: reference)) }
                }
            } else {
                guard mode == .imported, input.coreInputs == nil, input.referenceDemands.isEmpty,
                      input.selectedModelID == nil, input.selectedOffering == nil else { throw changed() }
            }
            shots.append(shot); timings.append(timing)
        }
        var upstream = storyboard.references + draft.header.inputs + [draftRef, preparation.bible]
        for path in try ProductionPlanningLineageV2.artifactPaths(phase: "bible", dataRoot: root,
            evidenceReferences: nil, bibleEvidenceReferences: PipelineProductionAssetEvidence.spatialBibleReferences) {
            upstream.append(try PlanningWriterIO.reference(path, id: "upstream-" + FileDigest.sha256(of: Data(path.utf8)), role: "core.bible-input", dataRoot: root))
        }
        upstream = try unique(upstream)
        var extensions: [PackArtifactExtensionReferenceV1] = []
        var musicReference: CanonicalArtifactReferenceV1?
        if let musicvideo {
            upstream = try unique(upstream + musicvideo.inputs)
            let extensionValue = MusicvideoProductionExtensionV2(header: .init(projectID: draft.header.projectID, revision: revision,
                origin: origin, inputs: try unique(upstream + plannedReferences)), track: musicvideo.track,
                analysis: musicvideo.analysis, treatment: musicvideo.treatment, storyboardTiming: musicvideo.timing,
                performanceSegments: musicvideo.segments, performanceReceipts: musicvideo.receipts,
                finalMix: musicvideo.proposedPlan.finalMix, visualArc: musicvideo.proposedPlan.visualArc, coverage: musicvideo.proposedPlan.coverage)
            let path = MusicvideoProductionExtensionV2.path(revision: revision)
            let bytes = try PlanningWriterIO.json(extensionValue)
            let reference = PlanningWriterIO.reference(path, id: MusicvideoProductionExtensionV2.artifactID,
                role: "musicvideo.production-plan", bytes: bytes)
            musicReference = reference
            extensions = [.init(id: reference.id, schema: MusicvideoProductionExtensionV2.schemaVersion, path: path, sha256: reference.sha256)]
            files += musicvideo.files + [(path, bytes)]
        }
        let media = graph.assets.map { ProjectMediaReferenceV1(id: $0.id, role: "core.project-media", path: $0.path, sha256: $0.sha256) }
        let mediaPaths = Set(media.map(\.path))
        let context = ProjectCreativeContextV1(projectID: draft.header.projectID,
            artifacts: try unique(upstream + plannedReferences).filter { !mediaPaths.contains($0.path) }, media: media, extensions: extensions)
        let contextBytes = try ExecutionPlanCanonicalCodec.encode(context)
        let contextPath = ShotPlanningPromotionV1.creativeContextPath(revision: revision)
        let contextRef = PlanningWriterIO.reference(contextPath, id: ExecutionPlanV1.creativeContextArtifactID,
            role: ExecutionPlanV1.creativeContextArtifactRole, bytes: contextBytes)
        let execution = ExecutionPlanV1(id: "execution-plan-" + UUID().uuidString.lowercased(), projectID: draft.header.projectID,
                                       creativeContext: contextRef, extensionReferences: extensions, shots: shots)
        try ExecutionPlanValidator.validate(execution, against: context, creativeContextPath: contextPath)
        let executionBytes = try ExecutionPlanCanonicalCodec.encode(execution)
        let executionPath = ShotPlanningPromotionV1.executionPlanPath(revision: revision)
        let executionRef = PlanningWriterIO.reference(executionPath, id: execution.id, role: "core.execution-plan", bytes: executionBytes)
        if let musicReference { plannedReferences.append(musicReference) }
        let projection = ProductionPlanProjectionV1(header: .init(projectID: draft.header.projectID, revision: revision, origin: origin,
            inputs: try unique(upstream + plannedReferences + [contextRef, executionRef])), timebase: storyboard.timing.timebase,
            mode: storyboard.timing.mode, executionPlan: execution, timings: timings, sourceBindings: sources,
            draftReference: draftRef, storyboardReference: timingRef,
            editorialBindings: try zip(draft.shots, storyboard.timing.shots).map { intent, planned in
                guard let step = steps[planned.primaryStepID] else { throw changed() }
                return .init(shotID: planned.id, sceneID: step.sceneID, narrativeBeat: intent.narrativeBeat)
            }, chains: draft.shots.compactMap { intent in
                intent.predecessorShotID.map { .init(shotID: intent.shotID, kind: intent.chainKind, predecessorShotID: $0) }
            }, sourceInputRanges: sourceInputRanges)
        try ProductionPlanProjectionValidatorV1.validate(projection, storyboard: storyboard, draft: draft, context: context)
        let projectionPath = ProductionPlanProjectionV1.versionPath(revision)
        let projectionBytes = Data(try YAMLCoding.encode(projection).utf8)
        let projectionRef = PlanningWriterIO.reference(projectionPath, id: "production-plan", role: "core.production-plan", bytes: projectionBytes)
        let promotion = ShotPlanningPromotionV1(header: .init(projectID: draft.header.projectID, revision: revision, origin: origin,
            inputs: try unique(upstream + plannedReferences + [contextRef, executionRef, projectionRef])), draft: draftRef,
            timing: timingRef, bible: preparation.bible, assetGraph: graphRef, projection: projectionRef,
            routes: routeBindings, resolutions: resolutions)
        guard let bible = try loadBible(dataRoot: root) else { throw changed() }
        try ShotPlanningPromotionValidatorV1.validate(promotion, draft: draft, timing: storyboard.timing,
                                                     bible: bible, assetGraph: graph, projection: projection)
        let promotionBytes = try PlanningWriterIO.json(promotion)
        files += [(contextPath, contextBytes), (executionPath, executionBytes), (projectionPath, projectionBytes),
                  (ShotPlanningPromotionV1.versionPath(revision), promotionBytes)]
        for file in files {
            let url = root.appendingPathComponent(file.path).standardizedFileURL
            guard url.resolvingSymlinksInPath() == url, !FileManager.default.fileExists(atPath: url.path),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw changed() }
        }
        files.append((ShotPlanningPromotionV1.currentPath, promotionBytes))
        try access.publish(files) {
            _ = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: root)
            if musicvideo != nil { _ = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: root) }
            guard try PipelineShotPlanningPromotionStore.requirePreparation(dataRoot: root) == preparation else { throw changed() }
        }
        return projection
    }

    nonisolated private static func sourceAsset(intent: ShotPlanningDraftV1.ShotIntent, assets: [String: AssetGraphNodeV1],
                                    resolutions: [ShotPlanningPromotionV1.Resolution]) throws -> CanonicalArtifactReferenceV1? {
        guard intent.sourceMode != .generated else { return nil }
        let selected: AssetGraphNodeV1?
        if let source = intent.source {
            selected = assets.values.first { $0.path == source.path && $0.sha256 == source.sha256 && $0.modality == .video }
        } else if let id = intent.sourceObligationID,
                  let resolution = resolutions.first(where: { $0.shotID == intent.shotID && $0.obligationID == id }),
                  case .asset(let assetID, _) = resolution.outcome { selected = assets[assetID] }
        else { selected = nil }
        guard let selected, selected.modality == .video, selected.approval == .approved else {
            throw GateBlocked("Resolve this shot's exact source-footage obligation before promotion.")
        }
        return .init(id: selected.id, role: "core.source-footage", path: selected.path, sha256: selected.sha256)
    }

    nonisolated static func validateRealDemands(_ demands: [ReferenceDemandV1], requirement: GenerationRequirementV1, graph: AssetGraphV1) throws {
        try PlanningSpatialAssetV1.requireProductionPurpose(requirement, graph: graph)
        let forbidden: Set<String> = [CoreReferenceSemanticJobIDV1.firstFrame, CoreReferenceSemanticJobIDV1.lastFrame,
            CoreReferenceSemanticJobIDV1.predecessorLastFrame, CoreReferenceSemanticJobIDV1.sourceVideo, CoreReferenceSemanticJobIDV1.audioTiming]
        guard demands.allSatisfy({ !forbidden.contains(ProductionIdentifierNormalizerV1.canonical($0.semanticJobID)) }),
              Set(requirement.referenceDemandIDs) == Set(demands.map(\.id)),
              Set(requirement.identityLockAssetIDs).isSubset(of: Set(demands.filter(\.isRequired).map(\.assetID))) else {
            throw GateBlocked("Bind real reference assets here; future Frame, source-video and timing inputs belong to the explicit input template.")
        }
    }

    nonisolated static func plannedDemands(real: ReferenceDemandSetV1, template: ProductionInputTemplateV1,
                               intent: ShotPlanningDraftV1.ShotIntent, timing: ProductionPlanProjectionV1.ShotTiming,
                               timebase: RationalTimebaseV1, requirement: GenerationRequirementV1,
                               sourceDurationSeconds: Double?, audioDurationSeconds: Double? = nil) -> ReferenceDemandSetV1 {
        var demands = real.demands
        let modes = template.coreInputs
        for (job, mode) in [(PipelineProductionInputsWriter.CoreInputJob.firstFrame, modes.firstFrameModeID),
                            (.lastFrame, modes.lastFrameModeID), (.predecessorLastFrame, modes.predecessorLastFrameModeID),
                            (.sourceVideo, modes.sourceVideoModeID), (.audioTiming, modes.audioTimingModeID)] {
            guard let mode else { continue }
            let duration: Double?
            if job == .sourceVideo { duration = sourceDurationSeconds }
            else if job == .audioTiming { duration = audioDurationSeconds ?? timebase.seconds(for: timing.durationTicks) }
            else { duration = nil }
            let assetID = job == .sourceVideo ? (requirement.sourceVideoAssetID ?? "invalid-source-recipe")
                : "recipe." + job.semanticJobID + "." + intent.shotID
            demands.append(PipelineProductionInputsWriter.coreDemand(job, shotID: intent.shotID, assetID: assetID,
                modeID: mode, durationSeconds: duration, expectedSourceShotID: job == .predecessorLastFrame ? intent.predecessorShotID : nil))
        }
        return .init(id: real.id, projectID: real.projectID, shotID: real.shotID, assetGraph: real.assetGraph, demands: demands)
    }

    nonisolated private static func unique(_ references: [CanonicalArtifactReferenceV1]) throws -> [CanonicalArtifactReferenceV1] {
        var byPath: [String: CanonicalArtifactReferenceV1] = [:]
        for reference in references {
            if let old = byPath[reference.path] { guard old.sha256 == reference.sha256 else { throw changed() } }
            else { byPath[reference.path] = reference }
        }
        var ids = Set<String>()
        return try byPath.values.sorted { $0.path < $1.path }.map { reference in
            guard ids.insert(reference.id).inserted else { throw changed() }
            return reference
        }
    }

    nonisolated private static func changed() -> GateBlocked {
        GateBlocked("The approved draft, timing or prepared assets changed. Reload them before promoting the production plan.")
    }
}
