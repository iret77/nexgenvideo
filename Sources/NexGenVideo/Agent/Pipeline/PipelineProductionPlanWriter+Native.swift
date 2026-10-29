import Darwin
import Foundation
import NexGenEngine

extension PipelineProductionPlanWriter {
    enum Conditioning: String, CaseIterable, Codable, Sendable {
        case none, start, startEnd, predecessorFrame, nativeExtension, sourceVideo
    }

    struct TechnicalChange: Sendable, Equatable {
        let delivery: ShotDeliveryModeV1
        let candidateID: String?
        let modeID: String?
        let conditioning: Conditioning
        let nativeDurationTicks: Int64?
        let sourceInTicks: Int64
        let resolution: String?
    }

    struct Candidate: Identifiable, Codable, Sendable {
        let id: String
        let modelID: String
        let displayName: String
        let offering: CapabilityOfferingIdentityV1
        let modeIDs: [String]
        let durationValues: [Int]
        let durationMinimum: Int?
        let durationMaximum: Int?
        let resolutions: [String]
        let routeCandidate: ProductionRouteCandidateV1
        let target: ResolvedGenerationTarget
    }

    struct CandidateSnapshot: Sendable {
        let projection: ProductionPlanProjectionV1
        let shot: ExecutionShotV1
        let proposal: Proposal
        let candidates: [Candidate]
        let fingerprint: String
        let currentChange: TechnicalChange
        let draft: ShotPlanningDraftV1
        let timing: StoryboardTimingV1
        let assets: AssetGraphV1
        let promotion: ShotPlanningPromotionV1
        let preparationFingerprint: String
    }

    struct Evaluation: Sendable {
        let proposal: Proposal?
        let deficits: [String]
        var canApply: Bool { proposal != nil && deficits.isEmpty }
    }

    struct NativeInputs: Sendable {
        let projection: ProductionPlanProjectionV1
        let proposal: Proposal
        let draft: ShotPlanningDraftV1
        let timing: StoryboardTimingV1
        let assets: AssetGraphV1
        let promotion: ShotPlanningPromotionV1
        let preparationFingerprint: String
        let fingerprint: String
    }

    struct NativeRevision: Sendable {
        let home: URL
        let key: String
        let input: NativeInputs
    }

    @MainActor private final class NativeSession {
        weak var editor: EditorViewModel?
        let home: URL?
        let key: String?
        let history: PipelineNativeRevisionHistory<NativeRevision>

        init(editor: EditorViewModel, manager: UndoManager, candidateProvider: CandidateProvider?) {
            self.editor = editor; home = editor.workingRoot; key = editor.openWorkingCopyKey
            history = PipelineNativeRevisionHistory(manager: manager, equivalent: {
                $0.home == $1.home && $0.key == $1.key && $0.input.proposal == $1.input.proposal
            }, restore: { [weak editor] desired, expected in
                guard let editor else { throw nativeChanged() }
                return try await restoreNative(desired, expected: expected, editor: editor, candidateProvider: candidateProvider)
            }, failure: { [weak editor] error in editor?.mediaPanelToast = MediaPanelToast(message: error.localizedDescription) })
        }
    }

    private static var nativeSessions: [ObjectIdentifier: NativeSession] = [:]

    static func resetNativeHistory(editor: EditorViewModel) {
        nativeSessions.removeValue(forKey: ObjectIdentifier(editor))?.history.clear()
    }

    static func waitForPendingNativeRestore(editor: EditorViewModel) async throws -> ProductionPlanProjectionV1 {
        guard let history = nativeSessions[ObjectIdentifier(editor)]?.history else { throw nativeChanged() }
        return try await history.waitForRestore().input.projection
    }

    private static func nativeSession(editor: EditorViewModel, candidateProvider: CandidateProvider?) throws -> NativeSession {
        guard let manager = editor.undoManager else { throw GateBlocked("This editor window has no Undo manager for technical Shot List changes.") }
        nativeSessions = nativeSessions.filter { $0.value.editor != nil }
        let id = ObjectIdentifier(editor)
        if let session = nativeSessions[id], session.home == editor.workingRoot, session.key == editor.openWorkingCopyKey,
           session.history.manager === manager { return session }
        nativeSessions[id]?.history.clear()
        let session = NativeSession(editor: editor, manager: manager, candidateProvider: candidateProvider)
        nativeSessions[id] = session
        return session
    }

    static func readCandidateSnapshot(shotID: String, editor: EditorViewModel,
                                      candidateProvider: CandidateProvider? = nil) async throws -> CandidateSnapshot {
        let candidatesProvider: CandidateProvider = candidateProvider ?? { editor.generationBatchCoordinator.modelCatalog.productionRouteCandidates(activation: editor.generationBatchCoordinator.providerActivation()) }
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else { throw nativeChanged() }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "shotlist")
        let inputs = try await Task.detached(priority: .userInitiated) { try nativeInputs(dataRoot: root) }.value
        guard editor.workingRoot == home else { throw nativeChanged() }
        _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "shotlist")
        let candidates = try nativeCandidates(candidateProvider: candidatesProvider)
        guard let shot = inputs.projection.shots.first(where: { $0.id == shotID }), shot.sourceMode != .imported,
              let proposed = inputs.proposal.shots.first(where: { $0.execution.id == shotID }) else {
            throw GateBlocked("Imported shots use their native source range. Select a generated or AI-enhanced shot to edit its production route.")
        }
        let current = technicalChange(proposed, candidates: candidates)
        let fingerprint = FileDigest.sha256(of: Data((inputs.fingerprint + (try catalogFingerprint(candidates))).utf8))
        let preliminary = CandidateSnapshot(projection: inputs.projection, shot: shot, proposal: inputs.proposal,
            candidates: candidates, fingerprint: fingerprint, currentChange: current, draft: inputs.draft,
            timing: inputs.timing, assets: inputs.assets, promotion: inputs.promotion,
            preparationFingerprint: inputs.preparationFingerprint)
        return preliminary
    }

    nonisolated static func evaluateNative(_ change: TechnicalChange, snapshot: CandidateSnapshot) -> Evaluation {
        do {
            let proposal = try replacingTechnical(change, snapshot: snapshot)
            try validateNativeProjection(proposal, snapshot: snapshot)
            try validateNativeRoutes(proposal, snapshot: snapshot)
            return Evaluation(proposal: proposal, deficits: [])
        } catch let error as GateBlocked {
            return Evaluation(proposal: nil, deficits: [error.localizedDescription])
        } catch let error as ProductionPlanningError {
            let message: String
            switch error {
            case .invalid("productionPlan.chainPredecessorVideo"):
                message = "A chained shot needs a selected video Take from its predecessor. Keep that predecessor in video delivery or revise the chain in Shot Planning."
            case .invalid("productionPlan.soleContinuationFrame"):
                message = "Frame continuation uses only the predecessor's exact last frame. Remove independent image references or revise the chain in Shot Planning."
            default:
                message = "The change conflicts with the approved timing, source selection or Shot Planning recipe. Revise that phase before changing these constraints."
            }
            return Evaluation(proposal: nil, deficits: [message])
        } catch {
            return Evaluation(proposal: nil, deficits: ["The proposed inputs do not satisfy this shot's production contract."])
        }
    }

    static func applyNative(_ change: TechnicalChange, snapshot: CandidateSnapshot,
                            editor: EditorViewModel, candidateProvider: CandidateProvider? = nil) async throws -> ProductionPlanProjectionV1 {
        let session = try nativeSession(editor: editor, candidateProvider: candidateProvider)
        guard !session.history.isBusy else { throw GateBlocked("Wait for the current technical revision to finish restoring.") }
        try session.history.beginPublication()
        var ownsPublication = true
        defer { if ownsPublication { session.history.endPublication() } }
        let provider = nativeCandidateProvider(editor: editor, override: candidateProvider)
        let access = try PipelineNativeEditAccess(editor: editor, label: "Edit Shot List")
        var ownsLease = true
        defer { if ownsLease { access.end(editor: editor) } }
        let current = try await readCandidateSnapshot(shotID: snapshot.shot.id, editor: editor, candidateProvider: provider)
        guard current.fingerprint == snapshot.fingerprint else { throw nativeChanged() }
        let evaluation = evaluateNative(change, snapshot: current)
        guard evaluation.deficits.isEmpty, let proposal = evaluation.proposal else { throw GateBlocked(evaluation.deficits.joined(separator: "\n")) }
        if proposal == current.proposal { return current.projection }
        let actual = try await nativeBackground { try nativeInputs(dataRoot: access.root) }
        guard FileDigest.sha256(of: Data((actual.fingerprint + (try catalogFingerprint(current.candidates))).utf8)) == current.fingerprint else { throw nativeChanged() }
        let written = try await publishNative(proposal: proposal, expected: actual, access: access,
            candidates: current.candidates, editor: editor, candidateProvider: provider,
            commitValidation: { try session.history.requireNoPendingRestore() })
        access.end(editor: editor); ownsLease = false
        session.history.record(before: .init(home: access.home, key: access.key, input: actual),
            after: written, name: "Edit Shot List")
        session.history.endPublication()
        ownsPublication = false
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return written.input.projection
    }

    private static func restoreNative(_ desired: NativeRevision, expected: NativeRevision,
        editor: EditorViewModel, candidateProvider: CandidateProvider?) async throws -> NativeRevision {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Restore Shot List")
        var ownsLease = true
        defer { if ownsLease { access.end(editor: editor) } }
        guard desired.home == access.home, desired.key == access.key,
              expected.home == access.home, expected.key == access.key else { throw nativeChanged() }
        let provider = nativeCandidateProvider(editor: editor, override: candidateProvider)
        let candidates = try nativeCandidates(candidateProvider: provider)
        let written = try await publishNative(proposal: desired.input.proposal, expected: expected.input,
            access: access, candidates: candidates, editor: editor, candidateProvider: provider)
        access.end(editor: editor); ownsLease = false
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return written
    }

    private static func nativeCandidateProvider(editor: EditorViewModel, override: CandidateProvider?) -> CandidateProvider {
        override ?? { editor.generationBatchCoordinator.modelCatalog.productionRouteCandidates(activation: editor.generationBatchCoordinator.providerActivation()) }
    }

    private static func publishNative(proposal: Proposal, expected: NativeInputs, access: PipelineNativeEditAccess,
        candidates: [Candidate], editor: EditorViewModel, candidateProvider: CandidateProvider,
        commitValidation: @MainActor () throws -> Void = {}) async throws -> NativeRevision {
        let writer = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "shotlist")
        let nextRevision = try await nativeBackground {
            try PlanningWriterIO.nextRevision(directory: "shotlist", suffix: ".v5.yaml", dataRoot: access.root)
        }
        let musicvideo = try await PipelineMusicvideoProductionWriterV2.prepare(proposal: proposal, revision: nextRevision, access: writer)
        let prepared = try await nativeBackground {
            try prepareNativePublication(proposal: proposal, expectedFingerprint: expected.fingerprint,
                access: access, candidates: candidates, musicvideo: musicvideo)
        }
        defer { Task.detached { prepared.discard() } }
        try Task.checkCancellation()
        return try prepared.commit(editor: editor, candidateProvider: candidateProvider, commitValidation: commitValidation)
    }

    struct NativeFileFence: Sendable {
        let paths: [URL: [Int64]]
        static func capture(_ urls: [URL]) throws -> Self {
            var result: [URL: [Int64]] = [:]
            for url in Set(urls) {
                var value = stat()
                guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw nativeChanged() }
                result[url] = [Int64(value.st_dev), Int64(bitPattern: value.st_ino), value.st_size, Int64(value.st_mode),
                    Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec), Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
            }
            return .init(paths: result)
        }
        func requireUnchanged() throws { guard try Self.capture(Array(paths.keys)).paths == paths else { throw nativeChanged() } }
    }

    struct PreparedNativePublication: Sendable {
        private let transaction: ProjectWorkingCopy.PreparedPipelineTransaction<NativeRevision>
        private let fence: PipelineSpatialSceneAuthority.SourceFence
        private let access: PipelineNativeEditAccess
        private let candidates: [Candidate]
        private let files: NativeFileFence
        var projection: ProductionPlanProjectionV1 { transaction.output.input.projection }

        fileprivate init(transaction: ProjectWorkingCopy.PreparedPipelineTransaction<NativeRevision>,
            fence: PipelineSpatialSceneAuthority.SourceFence, access: PipelineNativeEditAccess, candidates: [Candidate], files: NativeFileFence) {
            self.transaction = transaction; self.fence = fence; self.access = access; self.candidates = candidates; self.files = files
        }

        func discard() { transaction.discard() }

        @MainActor
        func commit(editor: EditorViewModel, candidateProvider: CandidateProvider,
                    commitValidation: @MainActor () throws -> Void = {}) throws -> NativeRevision {
            try Task.checkCancellation()
            let currentCatalog = try nativeCandidates(candidateProvider: candidateProvider)
            guard try catalogFingerprint(currentCatalog) == catalogFingerprint(candidates) else { throw nativeChanged() }
            return try transaction.commit { _ in
                try commitValidation()
                try access.requireCurrent(editor: editor)
                try fence.requireCanonicalRootsUnchanged()
                try files.requireUnchanged()
                try ProjectWorkingCopy.markDirty(key: access.key)
            }
        }
    }

    nonisolated static func prepareNativePublication(proposal: Proposal, expectedFingerprint: String,
        access: PipelineNativeEditAccess, candidates: [Candidate], musicvideo: PipelineMusicvideoProductionWriterV2.Prepared? = nil) throws -> PreparedNativePublication {
        let current = try nativeInputs(dataRoot: access.root)
        guard current.fingerprint == expectedFingerprint else { throw nativeChanged() }
        let references = current.projection.header.inputs + current.promotion.header.inputs
        let urls = try (references.map(\.path) + current.assets.assets.map(\.path)).map { try ProjectLocalFile.resolve($0, dataRoot: access.root) }
        let files = try NativeFileFence.capture(urls)
        let original = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root)
        let fence = PipelineSpatialSceneAuthority.SourceFence(paths: original.paths, canonicalPaths: Array(original.paths.keys))
        let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
            let staged = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "shotlist")
            guard try nativeInputs(dataRoot: staging).fingerprint == expectedFingerprint else { throw nativeChanged() }
            _ = try writeResolved(proposal: proposal, origin: .userRevision, access: staged,
                musicvideo: musicvideo, candidates: candidates.map(CandidateInput.init))
            return NativeRevision(home: access.home, key: access.key, input: try nativeInputs(dataRoot: staging))
        }
        do {
            try fence.requireUnchanged(); try files.requireUnchanged()
            return PreparedNativePublication(transaction: transaction, fence: fence, access: access, candidates: candidates, files: files)
        } catch { transaction.discard(); throw error }
    }

    nonisolated private static func nativeBackground<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private nonisolated static func validateNativeProjection(_ proposal: Proposal, snapshot: CandidateSnapshot) throws {
        let current = snapshot.projection
        let execution = ExecutionPlanV1(id: current.executionPlan.id, projectID: current.executionPlan.projectID,
            creativeContext: current.executionPlan.creativeContext, extensionReferences: current.executionPlan.extensionReferences,
            completeness: current.executionPlan.completeness, incompleteReasons: current.executionPlan.incompleteReasons,
            shots: proposal.shots.map(\.execution))
        let timings = try proposal.shots.map { input -> ProductionPlanProjectionV1.ShotTiming in
            guard let old = current.timing(for: input.execution.id) else { throw nativeChanged() }
            return .init(shotID: old.shotID, startTicks: old.startTicks, durationTicks: old.durationTicks,
                nativeDurationTicks: input.nativeDurationTicks, sourceInTicks: input.sourceInTicks)
        }
        let preview = ProductionPlanProjectionV1(header: current.header, timebase: current.timebase, mode: current.mode,
            executionPlan: execution, timings: timings, sourceBindings: current.sourceBindings, draftReference: current.draftReference,
            storyboardReference: current.storyboardReference, editorialBindings: current.editorialBindings,
            chains: current.chains, sourceInputRanges: current.sourceInputRanges)
        try ProductionPlanProjectionValidatorV1.validate(preview, timing: snapshot.timing, draft: snapshot.draft)
    }

    private nonisolated static func validateNativeRoutes(_ proposal: Proposal, snapshot: CandidateSnapshot) throws {
        for input in proposal.shots {
            guard let requirement = input.execution.generationRequirement,
                  ShotDeliveryModeResolverV1.resolve(input.execution) == .providerVideo else { continue }
            guard let intent = snapshot.draft.shots.first(where: { $0.shotID == input.execution.id }),
                  let timing = snapshot.projection.timing(for: input.execution.id),
                  let candidate = snapshot.candidates.first(where: { $0.modelID == input.selectedModelID && $0.offering == input.selectedOffering }),
                  let modes = input.coreInputs else {
                throw GateBlocked("Choose a currently available production route for every video shot before applying the edit.")
            }
            let template = ProductionInputTemplateV1(id: "input-template-" + input.execution.id,
                projectID: snapshot.projection.header.projectID, shotID: input.execution.id, coreInputs: modes)
            try ProductionInputTemplateValidatorV1.validate(template, requirement: requirement,
                chainedFromPredecessor: intent.chainKind == .frameContinuation)
            try validateRealDemands(input.referenceDemands, requirement: requirement, graph: snapshot.assets)
            let real = ReferenceDemandSetV1(id: "planned-demands-" + input.execution.id,
                projectID: snapshot.projection.header.projectID, shotID: input.execution.id,
                assetGraph: snapshot.promotion.assetGraph, demands: input.referenceDemands)
            try AssetGraphValidatorV1.validate(real, against: snapshot.assets, assetGraphPath: snapshot.promotion.assetGraph.path)
            let sourceDuration: Double?
            if intent.chainKind == .nativeExtension, let predecessorID = intent.predecessorShotID,
               let predecessor = proposal.shots.first(where: { $0.execution.id == predecessorID }),
               let predecessorTiming = snapshot.projection.timing(for: predecessorID) {
                sourceDuration = snapshot.projection.timebase.seconds(for: predecessor.nativeDurationTicks ?? predecessorTiming.durationTicks)
            } else { sourceDuration = input.sourceInputRange.map { $0.timebase.seconds(for: $0.durationTicks) } }
            let complete = plannedDemands(real: real, template: template, intent: intent, timing: timing,
                timebase: snapshot.projection.timebase, requirement: requirement, sourceDurationSeconds: sourceDuration,
                audioDurationSeconds: proposal.musicvideoPlan?.performanceSegments.first(where: { $0.shotIDs.contains(input.execution.id) }).map {
                    Double($0.sourceEndSample - $0.sourceStartSample) / Double($0.sampleRate)
                })
            _ = try validatedPlannedRoute(requirement: requirement, demands: complete, graph: snapshot.assets,
                candidate: candidate.routeCandidate, target: candidate.target, modelID: candidate.modelID,
                nativeExtension: intent.chainKind == .nativeExtension)
        }
    }

    nonisolated static func validatedPlannedRoute(requirement: GenerationRequirementV1, demands: ReferenceDemandSetV1,
        graph: AssetGraphV1, candidate: ProductionRouteCandidateV1, target: ResolvedGenerationTarget,
        modelID: String, nativeExtension: Bool) throws -> ProductionRouteV1 {
        if nativeExtension {
            guard target.binding?.resolvedVideoCapabilities?.inputPolicy.sourceOperation == .extendForward else {
                throw GateBlocked("The chosen endpoint must execute a forward extension of the predecessor video.")
            }
        }
        let result = try ProductionRequirementResolverV1.plannedRoute(requirement: requirement,
            demandSet: demands, assetGraph: graph, candidate: candidate)
        switch result {
        case .matched(let route, _):
            try requirePlannedAdapter(target, requirement: requirement, demands: demands.demands, route: route, modelID: modelID)
            return route
        case .noMatch(let noMatch):
            let problems = noMatch.evaluations.flatMap(\.deficits).map {
                "\($0.code.rawValue): requires \($0.requiredValue); available \($0.availableValue ?? "unverified")"
            }
            throw GateBlocked(problems.isEmpty ? "The model cannot satisfy this shot." : problems.joined(separator: "\n"))
        }
    }

    nonisolated static func nativeInputs(dataRoot: URL) throws -> NativeInputs {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: dataRoot)
        let storyboard = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: storyboard)
        let preparation = try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: dataRoot)
        let graph = try PipelineShotPlanningPromotionStore.plannedGraph(promotion: promotion, dataRoot: dataRoot)
        guard preparation.preparation.graph.sha256 == promotion.assetGraph.sha256,
              preparation.preparation.draft == promotion.draft, preparation.preparation.bible == promotion.bible else {
            throw GateBlocked("The prepared assets changed after this Shot List was written. Update the production plan before editing its technical settings.")
        }
        let proposals = try projection.shots.map { shot -> ShotProposal in
            guard let timing = projection.timings.first(where: { $0.shotID == shot.id }) else { throw nativeChanged() }
            let generated = shot.generationRequirement != nil
            let route = ShotDeliveryModeResolverV1.resolve(shot) == .providerVideo
                ? try PipelineShotPlanningPromotionStore.route(for: shot.id, promotion: promotion, dataRoot: dataRoot) : nil
            let template = generated ? try PipelineShotPlanningPromotionStore.inputTemplate(for: shot.id, promotion: promotion, dataRoot: dataRoot) : nil
            let demands = generated ? try PipelineShotPlanningPromotionStore.plannedDemands(for: shot.id, promotion: promotion, dataRoot: dataRoot).demands : []
            return ShotProposal(execution: shot, nativeDurationTicks: timing.nativeDurationTicks, sourceInTicks: timing.sourceInTicks,
                sourceInputRange: projection.sourceInputRanges.first(where: { $0.shotID == shot.id }),
                coreInputs: template?.coreInputs, referenceDemands: demands,
                selectedModelID: route?.offering.catalogModelID, selectedOffering: route?.offering)
        }
        let musicvideo = projection.executionPlan.extensionReferences.contains { $0.id == MusicvideoProductionExtensionV2.artifactID }
            ? try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot).draft : nil
        let proposal = Proposal(expectedDraftFingerprint: preparation.preparation.draft.sha256,
            expectedAssetGraphFingerprint: preparation.preparation.graph.sha256, shots: proposals, musicvideoPlan: musicvideo)
        let refs = projection.header.inputs + promotion.header.inputs
        let hashes = try refs.sorted { $0.path < $1.path }.map { reference -> String in
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
            return reference.path + ":" + reference.sha256
        }
        let projectionBytes = try Data(contentsOf: ProjectLocalFile.resolve(ProductionPlanProjectionV1.versionPath(projection.header.revision), dataRoot: dataRoot))
        let promotionBytes = try Data(contentsOf: ProjectLocalFile.resolve(ShotPlanningPromotionV1.currentPath, dataRoot: dataRoot))
        let fingerprint = FileDigest.sha256(of: Data((hashes.joined(separator: "\n") + preparation.fingerprint
            + FileDigest.sha256(of: projectionBytes) + FileDigest.sha256(of: promotionBytes)).utf8))
        return NativeInputs(projection: projection, proposal: proposal, draft: draft, timing: storyboard.timing,
            assets: graph, promotion: promotion, preparationFingerprint: preparation.fingerprint, fingerprint: fingerprint)
    }

    private static func nativeCandidates(candidateProvider: CandidateProvider) throws -> [Candidate] {
        try candidateProvider().compactMap { value in
            guard value.candidate.providerActivated, value.candidate.liveAvailable,
                  value.candidate.capabilities.offering.modality == .video,
                  value.modelID == value.candidate.capabilities.offering.catalogModelID, let target = value.target,
                  let capabilities = target.binding?.resolvedVideoCapabilities else { return nil }
            let identity = try PlanningWriterIO.json(CandidateIdentity(modelID: value.modelID, candidate: value.candidate, target: target))
            return Candidate(id: FileDigest.sha256(of: identity), modelID: value.candidate.capabilities.offering.catalogModelID,
                displayName: ModelRegistry.displayName(for: value.candidate.capabilities.offering.catalogModelID), offering: value.candidate.capabilities.offering,
                modeIDs: value.candidate.capabilities.effective.fields.strings[CapabilityFieldIDV1.modes]?.value ?? [],
                durationValues: capabilities.durationValues, durationMinimum: capabilities.durationMinimum,
                durationMaximum: capabilities.durationMaximum, resolutions: capabilities.resolutions ?? [],
                routeCandidate: value.candidate, target: target)
        }.sorted { $0.id < $1.id }
    }

    private struct CandidateIdentity: Encodable {
        let modelID: String
        let candidate: ProductionRouteCandidateV1
        let target: ResolvedGenerationTarget
    }

    private nonisolated static func catalogFingerprint(_ candidates: [Candidate]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let values = candidates.sorted { $0.id < $1.id }.map { CandidateIdentity(modelID: $0.modelID, candidate: $0.routeCandidate, target: $0.target) }
        return FileDigest.sha256(of: try encoder.encode(values))
    }

    private nonisolated static func technicalChange(_ input: ShotProposal, candidates: [Candidate]) -> TechnicalChange {
        let modes = input.coreInputs ?? .init()
        let conditioning: Conditioning = modes.predecessorLastFrameModeID != nil ? .predecessorFrame
            : modes.sourceVideoModeID != nil ? (input.execution.sourceMode == .aiEnhanced ? .sourceVideo : .nativeExtension)
            : modes.lastFrameModeID != nil ? .startEnd : modes.firstFrameModeID != nil ? .start : .none
        return TechnicalChange(delivery: ShotDeliveryModeResolverV1.resolve(input.execution) ?? .providerVideo,
            candidateID: candidates.first { $0.modelID == input.selectedModelID && $0.offering == input.selectedOffering }?.id,
            modeID: ShotDeliveryModeResolverV1.resolve(input.execution) == .timelineAnimatedStill ? nil : input.execution.generationRequirement?.modeIDs.first, conditioning: conditioning,
            nativeDurationTicks: input.nativeDurationTicks, sourceInTicks: input.sourceInTicks,
            resolution: input.execution.generationRequirement?.resolution)
    }

    private nonisolated static func replacingTechnical(_ change: TechnicalChange, snapshot: CandidateSnapshot) throws -> Proposal {
        guard let original = snapshot.proposal.shots.first(where: { $0.execution.id == snapshot.shot.id }),
              let old = original.execution.generationRequirement,
              let intent = snapshot.draft.shots.first(where: { $0.shotID == snapshot.shot.id }),
              let timing = snapshot.projection.timings.first(where: { $0.shotID == snapshot.shot.id }) else { throw nativeChanged() }
        let candidate: Candidate?
        let modes: ProductionCoreInputModesV1
        let requirement: GenerationRequirementV1
        var demands = original.referenceDemands
        if change.delivery == .timelineAnimatedStill {
            guard original.execution.sourceMode == .generated, intent.chainKind == .none,
                  change.conditioning == .none, change.candidateID == nil, change.nativeDurationTicks == nil,
                  change.sourceInTicks == 0, change.modeID == nil else {
                throw GateBlocked("Animated stills require an independent generated shot, no video route, no conditioning and no provider trim.")
            }
            guard !old.requiresOutputAudio, original.coreInputs?.audioTimingModeID == nil else {
                throw GateBlocked("This shot requires generated audio or audio conditioning. Revise those explicit requirements before choosing an animated still.")
            }
            candidate = nil; modes = .init()
            demands = demands.map { remap($0, slotID: $0.inputSlotID, modeID: ShotDeliveryModeResolverV1.timelineAnimatedStillModeID) }
            requirement = replacingRequirement(old, modality: "image", modes: [ShotDeliveryModeResolverV1.timelineAnimatedStillModeID],
                conditioning: .none, sourceVideoID: nil, duration: nil, resolution: change.resolution, outputAudio: false)
        } else {
            guard let selected = snapshot.candidates.first(where: { $0.id == change.candidateID }),
                  let mode = change.modeID, selected.modeIDs.contains(mode) else {
                throw GateBlocked("Choose a live model and one of its actual production modes.")
            }
            candidate = selected
            switch intent.chainKind {
            case .frameContinuation:
                guard change.conditioning == .predecessorFrame else { throw GateBlocked("This draft chain requires the predecessor's exact last frame. Revise Shot Planning to change the chain.") }
            case .nativeExtension:
                guard change.conditioning == .nativeExtension else { throw GateBlocked("This draft chain requires a native video extension. Revise Shot Planning to change the chain.") }
            case .none:
                if intent.sourceMode == .aiEnhanced {
                    guard change.conditioning == .sourceVideo else { throw GateBlocked("AI-enhanced shots must condition on their exact native source range.") }
                } else {
                    guard [.none, .start, .startEnd].contains(change.conditioning) else { throw GateBlocked("Choose independent generation or start/end frames for this unchained shot.") }
                }
            }
            guard let duration = change.nativeDurationTicks, duration > 0, change.sourceInTicks >= 0 else {
                throw GateBlocked("Set the provider duration and a nonnegative output trim.")
            }
            let used = change.sourceInTicks.addingReportingOverflow(timing.durationTicks)
            guard !used.overflow, used.partialValue <= duration else { throw GateBlocked("The provider output must cover the complete shot after its output trim.") }
            let first = change.conditioning == .start || change.conditioning == .startEnd
            modes = .init(firstFrameModeID: first ? mode : nil, lastFrameModeID: change.conditioning == .startEnd ? mode : nil,
                predecessorLastFrameModeID: change.conditioning == .predecessorFrame ? mode : nil,
                sourceVideoModeID: [.sourceVideo, .nativeExtension].contains(change.conditioning) ? mode : nil,
                audioTimingModeID: original.coreInputs?.audioTimingModeID == nil ? nil : mode)
            demands = try demands.map { demand in
                let slots = selected.routeCandidate.inputSlots.filter {
                    $0.modality == demand.modality && $0.modeIDs.map(ProductionIdentifierNormalizerV1.canonical).contains(ProductionIdentifierNormalizerV1.canonical(mode))
                }
                let matching = slots.filter { ProductionIdentifierNormalizerV1.canonical($0.id) == ProductionIdentifierNormalizerV1.canonical(demand.inputSlotID) }
                guard let slot = matching.first ?? (slots.count == 1 ? slots.first : nil) else {
                    throw GateBlocked("The model has no unambiguous input slot for the existing \(demand.semanticJobID) reference. Its required reference cannot be discarded.")
                }
                return remap(demand, slotID: slot.id, modeID: mode)
            }
            let sourceID = change.conditioning == .nativeExtension ? predecessorVideoRecipe(shotID: snapshot.shot.id)
                : change.conditioning == .sourceVideo ? snapshot.shot.sourceAssetID : nil
            requirement = replacingRequirement(old, modality: "video", modes: [mode], conditioning: change.conditioning,
                sourceVideoID: sourceID, duration: .init(preferredSeconds: snapshot.projection.timebase.seconds(for: duration)),
                resolution: change.resolution, outputAudio: old.requiresOutputAudio)
        }
        let shot = replacingShot(original.execution, requirement: requirement)
        let replacement = ShotProposal(execution: shot, nativeDurationTicks: change.nativeDurationTicks,
            sourceInTicks: change.sourceInTicks, sourceInputRange: original.sourceInputRange, coreInputs: modes,
            referenceDemands: demands, selectedModelID: candidate?.modelID, selectedOffering: candidate?.offering)
        return Proposal(expectedDraftFingerprint: snapshot.proposal.expectedDraftFingerprint,
            expectedAssetGraphFingerprint: snapshot.proposal.expectedAssetGraphFingerprint,
            shots: snapshot.proposal.shots.map { $0.execution.id == shot.id ? replacement : $0 }, musicvideoPlan: snapshot.proposal.musicvideoPlan)
    }

    nonisolated static func requirePlannedAdapter(_ target: ResolvedGenerationTarget, requirement: GenerationRequirementV1,
        demands: [ReferenceDemandV1], route: ProductionRouteV1, modelID: String) throws {
        guard PipelineProductionRouting.plannedProviderAdapterSupports(demands: demands, route: route, target: target,
            modelID: modelID, requirement: requirement) else {
            throw GateBlocked("The provider's executable adapter cannot deliver this combination of mode, duration, output settings and conditioning inputs.")
        }
    }

    private nonisolated static func replacingRequirement(_ old: GenerationRequirementV1, modality: String, modes: [String],
        conditioning: Conditioning, sourceVideoID: String?, duration: RequestedDurationV1?, resolution: String?, outputAudio: Bool) -> GenerationRequirementV1 {
        .init(modalityID: modality, modeIDs: modes, visibleEntityCount: old.visibleEntityCount,
            identityLockAssetIDs: old.identityLockAssetIDs, referenceDemandIDs: old.referenceDemandIDs,
            requiresFirstFrame: [.start, .startEnd, .predecessorFrame].contains(conditioning), requiresLastFrame: conditioning == .startEnd,
            sourceVideoAssetID: sourceVideoID, duration: duration, resolution: resolution, aspectRatio: old.aspectRatio,
            requiresOutputAudio: outputAudio, productionProfileRequirementIDs: old.productionProfileRequirementIDs,
            qualityTarget: old.qualityTarget, maximumCost: nil, maximumLatencySeconds: old.maximumLatencySeconds)
    }

    private nonisolated static func replacingShot(_ shot: ExecutionShotV1, requirement: GenerationRequirementV1) -> ExecutionShotV1 {
        .init(id: shot.id, sourceMode: shot.sourceMode, sourceAssetID: shot.sourceAssetID, startState: shot.startState,
            endState: shot.endState, primaryAction: shot.primaryAction, camera: shot.camera, blocking: shot.blocking,
            timedActionBeats: shot.timedActionBeats, continuityLocks: shot.continuityLocks, transitionIntent: shot.transitionIntent,
            renderability: shot.renderability, risks: shot.risks, rescue: shot.rescue, acceptance: shot.acceptance,
            generationRequirement: requirement)
    }

    private nonisolated static func remap(_ demand: ReferenceDemandV1, slotID: String, modeID: String) -> ReferenceDemandV1 {
        .init(id: demand.id, assetID: demand.assetID, modality: demand.modality, semanticJobID: demand.semanticJobID,
            isRequired: demand.isRequired, priority: demand.priority, preservationScopeIDs: demand.preservationScopeIDs,
            exclusionDemandIDs: demand.exclusionDemandIDs, inputSlotID: slotID, modeID: modeID,
            durationSeconds: demand.durationSeconds, expectedSourceShotID: demand.expectedSourceShotID)
    }

    private nonisolated static func nativeChanged() -> GateBlocked {
        GateBlocked("The Shot List, reference assignments or live model capabilities changed. Reload before applying the edit.")
    }
}
