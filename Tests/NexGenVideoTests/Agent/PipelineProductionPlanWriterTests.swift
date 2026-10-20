import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Native normalized Shot List revisions")
struct PipelineProductionPlanWriterTests {
    @Test func stillPromotionUsesRealPhaseChainWithoutAFinalProviderRoute() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion()
        defer { fixture.document.close() }
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: fixture.dataRoot)
        #expect(promotion.routes.isEmpty)
        #expect(projection.shots.allSatisfy { ShotDeliveryModeResolverV1.resolve($0) == .timelineAnimatedStill })
        let inventory = try PipelineProductionPlanReadStore.inventory(dataRoot: fixture.dataRoot)
        #expect(inventory.problems.isEmpty)
        #expect(inventory.shots.allSatisfy { $0.route == nil && $0.inputTemplate != nil })
        #expect(projection.shots.map(\.id) == (try PlanningWriterIO.storyboard(dataRoot: fixture.dataRoot)).timing.shots.map(\.id))
        for shot in projection.shots {
            let template = try PipelineShotPlanningPromotionStore.inputTemplate(for: shot.id, promotion: promotion, dataRoot: fixture.dataRoot)
            #expect(template.coreInputs == ProductionCoreInputModesV1())
        }
        try await ProductionPlanningAcceptanceFixture.approve("shotlist", in: fixture)
        #expect(fixture.editor.projectState?.nextPhaseName == "sanity")
    }

    @Test func promotedAssignmentsRemainReadOnlyUntilAnExplicitBibleRewind() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion(withLookObligation: true)
        defer { fixture.document.close() }
        let shown = try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: fixture.dataRoot)
        #expect(!shown.canAssign)
        #expect(shown.assignmentMessage != nil)
        #expect(shown.resolutions.count == shown.draft.shots.count)
        let shot = try #require(shown.draft.shots.first)
        let asset = try #require(shown.eligibleAssets(shotID: shot.shotID, obligationID: "look").first)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: fixture.dataRoot)
        let before = try Data(contentsOf: fixture.dataRoot.appendingPathComponent(ShotPlanningPromotionV1.currentPath))
        await #expect(throws: (any Error).self) {
            try await PipelineShotPlanningPromotionStore.recordResolution(shotID: shot.shotID, obligationID: "look",
                assetID: asset.id, skipReason: nil, expectedDraftFingerprint: shown.preparation.draft.sha256,
                expectedPreparationFingerprint: shown.fingerprint, editor: fixture.editor)
        }
        #expect(try Data(contentsOf: fixture.dataRoot.appendingPathComponent(ShotPlanningPromotionV1.currentPath)) == before)
        #expect(try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: fixture.dataRoot) == promotion)
        let preparationBytes = try Data(contentsOf: fixture.dataRoot.appendingPathComponent(PipelineShotPlanningPromotionStore.preparationPath))
        let originalGraph = try PipelineShotPlanningPromotionStore.plannedGraph(promotion: promotion, dataRoot: fixture.dataRoot)
        let changedGraph = AssetGraphV1(id: originalGraph.id + "-changed", projectID: originalGraph.projectID, assets: originalGraph.assets)
        let access = try PipelinePlanningWriteAccess(dataRoot: fixture.dataRoot,
            declaration: .init(packName: nil, binding: nil, productionContract: .current), phase: "shotlist")
        await #expect(throws: (any Error).self) {
            try await PipelineShotPlanningPromotionStore.prepareAssets(graph: changedGraph, access: access)
        }
        #expect(try Data(contentsOf: fixture.dataRoot.appendingPathComponent(PipelineShotPlanningPromotionStore.preparationPath)) == preparationBytes)
        #expect(try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: fixture.dataRoot).resolutions == shown.resolutions)
        #expect(try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: fixture.dataRoot) == promotion)
        let home = try #require(fixture.editor.workingRoot)
        try NativeGateWriter.rewind(projectDir: home, targetPhase: "bible", declaredPack: nil,
            declaredProductionContract: .current, executionCoordinator: fixture.editor.pipelinePhaseRunCoordinator)
        await fixture.editor.refreshEngineState()
        let revised = try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: fixture.dataRoot)
        #expect(revised.canAssign)
        try await PipelineShotPlanningPromotionStore.recordResolution(shotID: shot.shotID, obligationID: "look",
            assetID: asset.id, skipReason: nil, expectedDraftFingerprint: revised.preparation.draft.sha256,
            expectedPreparationFingerprint: revised.fingerprint, editor: fixture.editor)
        let confirmed = try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: fixture.dataRoot)
        #expect(confirmed.resolutions != shown.resolutions)
        #expect(confirmed.sourceRanges == shown.sourceRanges)
    }

    @Test func actualNativeBibleVariantUsesItsBaseIdentityAndDistinctStateID() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeStateVariantBible()
        defer { fixture.document.close() }
        let shown = try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: fixture.dataRoot)
        #expect(shown.canAssign)
        let shot = try #require(shown.draft.shots.first)
        let asset = try #require(shown.eligibleAssets(shotID: shot.shotID, obligationID: "blue-state").first)
        #expect(asset.entityID == "shape")
        #expect(asset.stateID == "shape_blue")
        #expect(asset.entityID != asset.stateID)
        try await PipelineShotPlanningPromotionStore.recordResolution(shotID: shot.shotID, obligationID: "blue-state",
            assetID: asset.id, skipReason: nil, expectedDraftFingerprint: shown.preparation.draft.sha256,
            expectedPreparationFingerprint: shown.fingerprint, editor: fixture.editor)
        let confirmed = try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: fixture.dataRoot)
        #expect(confirmed.resolutions.count == 1)
        let receipt = try #require(confirmed.resolutions.first?.confirmationReceipt)
        #expect(try FileDigest.sha256(of: fixture.dataRoot.appendingPathComponent(receipt.path)) == receipt.sha256)
        let originalPreparation = try Data(contentsOf: fixture.dataRoot.appendingPathComponent(PipelineShotPlanningPromotionStore.preparationPath))
        await #expect(throws: (any Error).self) {
            try await ProductionPlanningAcceptanceFixture.run("prepare_production_assets", args: ["assets": [[
                "path": asset.path, "modality": "image", "entity_id": "shape", "state_id": "shape",
                "allowed_use_ids": [CoreReferenceSemanticJobIDV1.referenceAnchor]]]], in: fixture)
        }
        #expect(try Data(contentsOf: fixture.dataRoot.appendingPathComponent(PipelineShotPlanningPromotionStore.preparationPath)) == originalPreparation)
    }

    @Test func nativeRevisionPreservesCanonicalActionTimingAndImmutableHistory() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion()
        defer { fixture.document.close() }
        let original = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let shot = try #require(original.shots.first)
        let archive = fixture.dataRoot.appendingPathComponent(ProductionPlanProjectionV1.versionPath(original.header.revision))
        let originalBytes = try Data(contentsOf: archive)
        let snapshot = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: shot.id, editor: fixture.editor)
        #expect(snapshot.candidates.allSatisfy { $0.routeCandidate.providerActivated && $0.routeCandidate.liveAvailable })
        #expect(PipelineProductionPlanWriter.evaluateNative(snapshot.currentChange, snapshot: snapshot).canApply)
        let change = PipelineProductionPlanWriter.TechnicalChange(delivery: .timelineAnimatedStill,
            candidateID: nil, modeID: nil, conditioning: .none, nativeDurationTicks: nil, sourceInTicks: 0, resolution: "1080p")
        let result = try await PipelineProductionPlanWriter.applyNative(change, snapshot: snapshot, editor: fixture.editor)
        #expect(result.header.revision == original.header.revision + 1)
        #expect(result.header.origin == .userRevision)
        #expect(result.timings == original.timings)
        #expect(result.shots.map(\.primaryAction) == original.shots.map(\.primaryAction))
        #expect(result.shots.map(\.id) == original.shots.map(\.id))
        #expect(try Data(contentsOf: archive) == originalBytes)
        let committed = try Data(contentsOf: fixture.dataRoot.appendingPathComponent(ProductionPlanProjectionV1.versionPath(result.header.revision)))
        await #expect(throws: (any Error).self) {
            try await PipelineProductionPlanWriter.applyNative(change, snapshot: snapshot, editor: fixture.editor)
        }
        #expect(try Data(contentsOf: fixture.dataRoot.appendingPathComponent(ProductionPlanProjectionV1.versionPath(result.header.revision))) == committed)
        try await ProductionPlanningAcceptanceFixture.approve("shotlist", in: fixture)
    }

    @Test func stillDoesNotAcceptProviderHandlesOrAnInventedVideoCandidate() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion()
        defer { fixture.document.close() }
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let shot = try #require(projection.shots.first)
        let snapshot = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: shot.id, editor: fixture.editor)
        let stillWithHandles = PipelineProductionPlanWriter.TechnicalChange(delivery: .timelineAnimatedStill,
            candidateID: nil, modeID: nil, conditioning: .none, nativeDurationTicks: 4_800, sourceInTicks: 600, resolution: nil)
        #expect(!PipelineProductionPlanWriter.evaluateNative(stillWithHandles, snapshot: snapshot).canApply)
        let fakeCandidate = PipelineProductionPlanWriter.TechnicalChange(delivery: .providerVideo,
            candidateID: "invented-provider-choice", modeID: "invented-mode", conditioning: .none,
            nativeDurationTicks: 2_400, sourceInTicks: 0, resolution: nil)
        #expect(!PipelineProductionPlanWriter.evaluateNative(fakeCandidate, snapshot: snapshot).canApply)
        let before = try Data(contentsOf: fixture.dataRoot.appendingPathComponent(ShotPlanningPromotionV1.currentPath))
        await #expect(throws: (any Error).self) {
            try await PipelineProductionPlanWriter.applyNative(fakeCandidate, snapshot: snapshot, editor: fixture.editor)
        }
        #expect(try Data(contentsOf: fixture.dataRoot.appendingPathComponent(ShotPlanningPromotionV1.currentPath)) == before)
    }

    @Test func stillPreviewCannotSilentlyDiscardEitherAudioRequirement() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion()
        defer { fixture.document.close() }
        let current = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let id = try #require(current.shots.first?.id)
        let original = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: id, editor: fixture.editor)
        for outputAudio in [true, false] {
            let inputs = original.proposal.shots.map { input -> PipelineProductionPlanWriter.ShotProposal in
                guard input.execution.id == id else { return input }
                return replacing(input, requirement: .init(modalityID: "video", modeIDs: ["keyframe"], visibleEntityCount: 0,
                    requiresOutputAudio: outputAudio), modes: .init(audioTimingModeID: outputAudio ? nil : "keyframe"))
            }
            let snapshot = replacing(original, inputs: inputs)
            let change = PipelineProductionPlanWriter.TechnicalChange(delivery: .timelineAnimatedStill,
                candidateID: nil, modeID: nil, conditioning: .none, nativeDurationTicks: nil, sourceInTicks: 0, resolution: nil)
            let result = PipelineProductionPlanWriter.evaluateNative(change, snapshot: snapshot)
            #expect(!result.canApply)
            #expect(result.deficits.contains { $0.contains("audio") })
        }
        #expect(try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot) == current)
    }

    @Test func predecessorStillPreviewChecksTheDependentShotRecipe() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion()
        defer { fixture.document.close() }
        let current = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let id = try #require(current.shots.first?.id), follower = try #require(current.shots.last?.id)
        let original = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: id, editor: fixture.editor)
        let inputs = original.proposal.shots.map { input in
            replacing(input, requirement: .init(modalityID: "video", modeIDs: ["keyframe"], visibleEntityCount: 0,
                requiresFirstFrame: input.execution.id == follower),
                modes: .init(predecessorLastFrameModeID: input.execution.id == follower ? "keyframe" : nil))
        }
        let intents = original.draft.shots.map { intent in
            ShotPlanningDraftV1.ShotIntent(shotID: intent.shotID, sourceMode: intent.sourceMode,
                source: intent.source, sourceObligationID: intent.sourceObligationID, camera: intent.camera,
                obligations: intent.obligations, chainKind: intent.shotID == follower ? .frameContinuation : intent.chainKind,
                predecessorShotID: intent.shotID == follower ? id : intent.predecessorShotID,
                narrativeBeat: intent.narrativeBeat, sourceInputRange: intent.sourceInputRange)
        }
        let snapshot = replacing(original, inputs: inputs, intents: intents,
            chains: [.init(shotID: follower, kind: .frameContinuation, predecessorShotID: id)])
        let change = PipelineProductionPlanWriter.TechnicalChange(delivery: .timelineAnimatedStill,
            candidateID: nil, modeID: nil, conditioning: .none, nativeDurationTicks: nil, sourceInTicks: 0, resolution: nil)
        let result = PipelineProductionPlanWriter.evaluateNative(change, snapshot: snapshot)
        #expect(!result.canApply)
        #expect(result.deficits.contains { $0.contains("predecessor") })
        #expect(try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot) == current)
    }

    @Test func nativeApplyCannotEnterAnotherPhaseMutation() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion()
        defer { fixture.document.close() }
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let shot = try #require(projection.shots.first)
        let snapshot = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: shot.id, editor: fixture.editor)
        let lease = try #require(fixture.editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: fixture.dataRoot, label: "Existing job"))
        defer { fixture.editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: fixture.dataRoot, id: lease) }
        await #expect(throws: (any Error).self) {
            try await PipelineProductionPlanWriter.applyNative(snapshot.currentChange, snapshot: snapshot, editor: fixture.editor)
        }
        #expect(try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot).header.revision == projection.header.revision)
        #expect(fixture.editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: fixture.dataRoot, id: lease))
    }
    @Test func unchangedTechnicalApplyDoesNotInventARevision() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion()
        defer { fixture.document.close() }
        let plan = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let snapshot = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: try #require(plan.shots.first?.id), editor: fixture.editor)
        let result = try await PipelineProductionPlanWriter.applyNative(snapshot.currentChange, snapshot: snapshot, editor: fixture.editor)
        #expect(result == plan)
        #expect(!FileManager.default.fileExists(atPath: fixture.dataRoot.appendingPathComponent(ProductionPlanProjectionV1.versionPath(plan.header.revision + 1)).path))
    }

    @Test func rapidNativeTechnicalUndoRedoCreatesCanonicalRevisionsWithoutReusingHistoricalHeads() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion()
        defer { fixture.document.close() }
        let original = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let id = try #require(original.shots.first?.id)
        for resolution in ["1080p", "720p"] {
            let snapshot = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: id, editor: fixture.editor)
            let change = PipelineProductionPlanWriter.TechnicalChange(delivery: .timelineAnimatedStill, candidateID: nil,
                modeID: nil, conditioning: .none, nativeDurationTicks: nil, sourceInTicks: 0, resolution: resolution)
            _ = try await PipelineProductionPlanWriter.applyNative(change, snapshot: snapshot, editor: fixture.editor)
            #expect(fixture.editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: fixture.dataRoot) == nil)
        }
        let manager = try #require(fixture.editor.undoManager)
        manager.undo(); manager.undo()
        let restored = try await PipelineProductionPlanWriter.waitForPendingNativeRestore(editor: fixture.editor)
        #expect(restored.shots.first?.generationRequirement?.resolution == original.shots.first?.generationRequirement?.resolution)
        #expect(restored.header.revision >= original.header.revision + 4)
        manager.redo(); manager.redo()
        let redone = try await PipelineProductionPlanWriter.waitForPendingNativeRestore(editor: fixture.editor)
        #expect(redone.shots.first?.generationRequirement?.resolution == "720p")
        #expect(redone.timings == original.timings)
        #expect(redone.shots.map(\.id) == original.shots.map(\.id))
        #expect(redone.header.revision >= restored.header.revision + 2)
    }

    @Test func preparedTechnicalCommitRejectsChangedPlanAndRealReferenceBytes() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion(withLookObligation: true)
        defer { fixture.document.close() }
        let dataRoot = fixture.dataRoot
        let initial = try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot)
        let head = try await Task.detached { try PipelineProductionPlanWriter.nativeInputs(dataRoot: dataRoot) }.value
        let reference = try #require(head.assets.assets.first?.path)
        for path in [ProductionPlanProjectionV1.versionPath(initial.header.revision), reference] {
            let access = try PipelineNativeEditAccess(editor: fixture.editor, label: "Prepared technical regression")
            defer { access.end(editor: fixture.editor) }
            let prepared = try await Task.detached {
                try PipelineProductionPlanWriter.prepareNativePublication(proposal: head.proposal,
                    expectedFingerprint: head.fingerprint, access: access, candidates: [])
            }.value
            defer { prepared.discard() }
            #expect(prepared.projection.header.revision == initial.header.revision + 1)
            let url = try ProjectLocalFile.resolve(path, dataRoot: fixture.dataRoot)
            let bytes = try Data(contentsOf: url)
            try (bytes + Data("external byte change".utf8)).write(to: url)
            #expect(throws: (any Error).self) { _ = try prepared.commit(editor: fixture.editor, candidateProvider: { [] }) }
            try bytes.write(to: url)
            #expect(!FileManager.default.fileExists(atPath: fixture.dataRoot.appendingPathComponent(ProductionPlanProjectionV1.versionPath(initial.header.revision + 1)).path))
        }
        #expect(try ProductionPlanningLineageV2.projection(dataRoot: fixture.dataRoot) == initial)
    }

    @Test func unchangedPreparedPublicationCommitsExactCanonicalBytesAndChangedSessionCannotCommit() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makePromotion()
        defer { fixture.document.close() }
        let root = fixture.dataRoot
        let head = try await Task.detached { try PipelineProductionPlanWriter.nativeInputs(dataRoot: root) }.value
        let access = try PipelineNativeEditAccess(editor: fixture.editor, label: "Prepare exact publication")
        let prepared = try await Task.detached {
            try PipelineProductionPlanWriter.prepareNativePublication(proposal: head.proposal,
                expectedFingerprint: head.fingerprint, access: access, candidates: [])
        }.value
        defer { prepared.discard() }
        let output = try prepared.commit(editor: fixture.editor, candidateProvider: { [] })
        access.end(editor: fixture.editor)
        #expect(output.input.projection == prepared.projection)
        #expect(try ProductionPlanningLineageV2.projection(dataRoot: root) == prepared.projection)
        #expect(output.input.projection.timings == head.projection.timings)
        let nextAccess = try PipelineNativeEditAccess(editor: fixture.editor, label: "Prepare stale session")
        defer { nextAccess.end(editor: fixture.editor) }
        let next = try await Task.detached {
            try PipelineProductionPlanWriter.prepareNativePublication(proposal: output.input.proposal,
                expectedFingerprint: output.input.fingerprint, access: nextAccess, candidates: [])
        }.value
        defer { next.discard() }
        fixture.editor.projectURL = nil
        #expect(throws: (any Error).self) { _ = try next.commit(editor: fixture.editor, candidateProvider: { [] }) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(ProductionPlanProjectionV1.versionPath(next.projection.header.revision)).path))
    }

    @Test func preparedPublicationRejectsActualReferencedSourceVideoChange() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly()
        defer { fixture.document.close() }
        let root = fixture.dataRoot
        try NativeGateWriter.rewind(projectDir: try #require(fixture.editor.workingRoot), targetPhase: "shotlist",
            declaredPack: nil, declaredProductionContract: .current, executionCoordinator: fixture.editor.pipelinePhaseRunCoordinator)
        let head = try await Task.detached { try PipelineProductionPlanWriter.nativeInputs(dataRoot: root) }.value
        let access = try PipelineNativeEditAccess(editor: fixture.editor, label: "Prepare source-byte regression")
        defer { access.end(editor: fixture.editor) }
        let prepared = try await Task.detached {
            try PipelineProductionPlanWriter.prepareNativePublication(proposal: head.proposal,
                expectedFingerprint: head.fingerprint, access: access, candidates: [])
        }.value
        defer { prepared.discard() }
        let source = try #require(head.assets.assets.first(where: { $0.modality == .video }))
        let url = try ProjectLocalFile.resolve(source.path, dataRoot: root)
        let original = try Data(contentsOf: url)
        defer { try? original.write(to: url) }
        try (original + Data("changed actual source video".utf8)).write(to: url)
        #expect(throws: (any Error).self) { _ = try prepared.commit(editor: fixture.editor, candidateProvider: { [] }) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(ProductionPlanProjectionV1.versionPath(prepared.projection.header.revision)).path))
    }

    private func replacing(_ input: PipelineProductionPlanWriter.ShotProposal, requirement: GenerationRequirementV1,
        modes: ProductionCoreInputModesV1) -> PipelineProductionPlanWriter.ShotProposal {
        let old = input.execution
        let shot = ExecutionShotV1(id: old.id, sourceMode: old.sourceMode, sourceAssetID: old.sourceAssetID,
            startState: old.startState, endState: old.endState, primaryAction: old.primaryAction, camera: old.camera,
            blocking: old.blocking, timedActionBeats: old.timedActionBeats, continuityLocks: old.continuityLocks,
            transitionIntent: old.transitionIntent, renderability: old.renderability, risks: old.risks,
            rescue: old.rescue, acceptance: old.acceptance, generationRequirement: requirement)
        return .init(execution: shot, nativeDurationTicks: input.nativeDurationTicks, sourceInTicks: input.sourceInTicks,
            sourceInputRange: input.sourceInputRange, coreInputs: modes, referenceDemands: input.referenceDemands,
            selectedModelID: input.selectedModelID, selectedOffering: input.selectedOffering, endFrameBoundary: input.endFrameBoundary)
    }

    private func replacing(_ original: PipelineProductionPlanWriter.CandidateSnapshot,
        inputs: [PipelineProductionPlanWriter.ShotProposal], intents: [ShotPlanningDraftV1.ShotIntent]? = nil,
        chains: [ProductionPlanProjectionV1.ChainBinding]? = nil) -> PipelineProductionPlanWriter.CandidateSnapshot {
        let old = original.projection
        let plan = ProductionPlanProjectionV1(header: old.header, timebase: old.timebase, mode: old.mode,
            executionPlan: .init(id: old.executionPlan.id, projectID: old.header.projectID,
                creativeContext: old.executionPlan.creativeContext, shots: inputs.map(\.execution)),
            timings: old.timings, sourceBindings: old.sourceBindings, draftReference: old.draftReference,
            storyboardReference: old.storyboardReference, editorialBindings: old.editorialBindings,
            chains: chains ?? old.chains, sourceInputRanges: old.sourceInputRanges,
            endFrameBoundaries: Dictionary(uniqueKeysWithValues: inputs.compactMap { input in
                input.endFrameBoundary.map { (input.execution.id, $0) }
            }))
        let draft = ShotPlanningDraftV1(header: original.draft.header, storyboardRevision: original.draft.storyboardRevision,
            shots: intents ?? original.draft.shots)
        return .init(projection: plan, shot: inputs.first { $0.execution.id == original.shot.id }!.execution,
            proposal: .init(expectedDraftFingerprint: original.proposal.expectedDraftFingerprint,
                expectedAssetGraphFingerprint: original.proposal.expectedAssetGraphFingerprint, shots: inputs),
            candidates: original.candidates, fingerprint: original.fingerprint, currentChange: original.currentChange,
            draft: draft, timing: original.timing, assets: original.assets, promotion: original.promotion,
            preparationFingerprint: original.preparationFingerprint)
    }

}
