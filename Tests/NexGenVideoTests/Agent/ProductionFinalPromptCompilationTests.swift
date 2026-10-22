import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Final production tool preserves the approved shot compilation", .serialized)
struct ProductionFinalPromptCompilationTests {
    @Test func nextFinalShotReturnsTheExactApprovedPromptAndBinding() async throws {
        let original = try await ProductionPlanningAcceptanceFixture.makePromotion(withLookObligation: true, presentation: .editorSession)
        defer { original.document.close() }
        #expect(original.document.windowControllers.isEmpty)
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries)
        let activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
        let modelID = "bytedance/seedance-2.5/reference-to-video"
        let candidates = catalog.productionRouteCandidates(activation: activation).filter { $0.modelID == modelID }
        let candidate = try #require(candidates.first)
        let mode = try #require(candidate.candidate.inputSlots.first {
            $0.id == CoreReferenceInputSlotIDV1.referenceImage
        }?.modeIDs.first)
        let editor = original.editor, root = original.dataRoot
        editor.generationBatchCoordinator.modelCatalog = catalog
        editor.generationBatchCoordinator.providerActivation = { activation }
        let executor = ToolExecutor(editor: editor, providerActivation: { activation }, modelCatalog: catalog,
            productionRouteCandidates: { _ in candidates }, catalogReadiness: { true }, isModelEnabled: { _ in true })
        let context = ProductionPlanningAcceptanceFixture.Context(document: original.document,
            packageURL: original.packageURL, dataRoot: root, executor: executor, presentation: .editorSession)
        let inputs = try await Task.detached { try PipelineProductionPlanWriter.nativeInputs(dataRoot: root) }.value
        let shots = try inputs.proposal.shots.map { input -> PipelineProductionPlanWriter.ShotProposal in
            let old = input.execution
            let reference = try #require(input.referenceDemands.first)
            let demand = ReferenceDemandV1(id: reference.id, assetID: reference.assetID, modality: .image,
                semanticJobID: CoreReferenceSemanticJobIDV1.styleReference, isRequired: true, priority: 0,
                inputSlotID: CoreReferenceInputSlotIDV1.referenceImage, modeID: mode)
            let shot = ExecutionShotV1(id: old.id, sourceMode: .generated,
                startState: old.startState, endState: old.endState, primaryAction: old.primaryAction,
                camera: old.camera, renderability: .green, acceptance: old.acceptance,
                generationRequirement: .init(modalityID: "video", modeIDs: [mode], visibleEntityCount: 0,
                    referenceDemandIDs: [demand.id], duration: .init(preferredSeconds: 8,
                        minimumSeconds: 8, maximumSeconds: 8), resolution: "720p", aspectRatio: "16:9"))
            return .init(execution: shot, nativeDurationTicks: 8 * inputs.projection.timebase.ticksPerSecond,
                sourceInTicks: inputs.projection.timebase.ticksPerSecond, sourceInputRange: nil,
                coreInputs: .init(), referenceDemands: [demand], selectedModelID: modelID,
                selectedOffering: candidate.candidate.capabilities.offering)
        }
        let proposal = PipelineProductionPlanWriter.Proposal(
            expectedDraftFingerprint: inputs.proposal.expectedDraftFingerprint,
            expectedAssetGraphFingerprint: inputs.proposal.expectedAssetGraphFingerprint, shots: shots)
        try await ProductionPlanningAcceptanceFixture.run("write_shotlist", args: [
            "origin": "agentRevision", "proposal": try ProductionPlanningAcceptanceFixture.object(proposal),
        ], in: context)
        try await ProductionPlanningAcceptanceFixture.approve("shotlist", in: context)
        try await ProductionPlanningAcceptanceFixture.prepareImportedSanity(in: context)
        try await ProductionPlanningAcceptanceFixture.approve("sanity", in: context)
        try await ProductionPlanningAcceptanceFixture.prepareEmptyFrames(in: context)
        try await ProductionPlanningAcceptanceFixture.approve("frames", in: context)
        let document = context.document, home = context.packageURL
        try await withPromptCompilerTimeLimit {
            let context = ProductionPlanningAcceptanceFixture.Context(document: document,
                packageURL: home, dataRoot: root, executor: executor, presentation: .editorSession)
            let inspected = try await ProductionPlanningAcceptanceFixture.captureReview(in: context)
            #expect(context.document.windowControllers.isEmpty)
            #expect(Set(inspected.references.map(\.id)).count == inspected.references.count)
            for shot in shots {
                let bundle = try PipelineProductionInputMaterializer.requireCurrent(shotID: shot.execution.id, dataRoot: root)
                let planned = bundle.receipt.plannedRoute
                #expect(planned.id == bundle.receipt.route.id && planned.path != bundle.receipt.route.path)
                #expect(inspected.shots.first { $0.shotID == shot.execution.id }?.review.route == bundle.receipt.route)
                for reference in [planned, bundle.receipt.graph, bundle.receipt.route] {
                    #expect(inspected.references.contains {
                        $0.path == reference.path && $0.sha256 == reference.sha256 && $0.role == reference.role
                    })
                }
            }
            _ = try await PipelineRenderReviewWriter.recordNativeReview(snapshot: inspected, findings: [], editor: editor)
            try await ProductionPlanningAcceptanceFixture.approve("render_review", in: context)
            let first = try #require(shots.first)
            let reviewed = try #require(inspected.shots.first { $0.shotID == first.execution.id })
            let reference = try #require(reviewed.review.compiledPrompt)
            let approved = try ProductionCompiledPromptStore.load(reference, dataRoot: root)
            let promptBytes = try Data(contentsOf: root.appendingPathComponent(reference.path))
            let reviewBytes = try Data(contentsOf: root.appendingPathComponent(RenderReviewV1.currentPath))
            #expect(approved.shotID == first.execution.id)
            #expect(approved.modality == "video")
            #expect(approved.modelID == modelID)
            #expect(!reviewed.review.conditioning.isEmpty)

            for _ in 0..<2 {
                let result = await executor.execute(name: "next_render_shot", args: ["phase": "final"])
                try #require(!result.isError, Comment(rawValue: ToolHarness.textOf(result)))
                let value = try #require(JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any])
                let text = try #require(value["compiled_prompt"] as? String)
                let token = try #require(value["compileToken"] as? String)
                #expect(value["shot_id"] as? String == first.execution.id)
                #expect(value["generation_model"] as? String == modelID)
                #expect(value["video_generation_required"] as? Bool == true)
                #expect(value["done"] as? Bool == false)
                #expect(Data(text.utf8) == Data(approved.text.utf8))
                #expect(PromptCompiler.validate(token: token, text: text, modelId: modelID, binding: approved.binding))
                let actual = try await PromptCompiler.currentBinding(editor: editor, shotId: first.execution.id,
                    modality: .video, modelId: modelID, modelCatalog: catalog)
                #expect(actual.withPromptIRSHA256(FileDigest.sha256(of: approved.sourceIR)) == approved.binding)
                #expect(try Data(contentsOf: root.appendingPathComponent(reference.path)) == promptBytes)
                #expect(try Data(contentsOf: root.appendingPathComponent(RenderReviewV1.currentPath)) == reviewBytes)
                #expect(editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil)
            }
            do {
                _ = try await PromptCompiler.compile(intent: first.execution.primaryAction, modelId: modelID,
                    modality: .video, editor: editor, shotId: first.execution.id, modelCatalog: catalog)
                Issue.record("A shot-bound compile accepted a missing current shot projection.")
            } catch let error as ToolError {
                #expect(error.message == "Shot-bound compilation requires the current shot projection.")
            }
            #expect(try Data(contentsOf: root.appendingPathComponent(reference.path)) == promptBytes)
        }
    }
}
