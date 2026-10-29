import AppKit
import Foundation
import NexGenEngine

@MainActor
final class ProductionV2GenerationAcceptance {
    let catalog = ModelCatalog()
    let activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
    let modelID = "bytedance/seedance-2.5/reference-to-video"
    let session: URLSession
    var candidates: [CatalogProductionRouteCandidate] { catalog.productionRouteCandidates(activation: activation).filter { $0.modelID == modelID } }

    init() throws {
        guard WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested else { throw GateBlocked("The HTTP simulator requires explicit native UI acceptance.") }
        catalog.load(entries: ModelCatalog.launchEntries)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MusicvideoGenerationHTTP.self]
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
        guard !candidates.isEmpty else { throw GateBlocked("The actual reference-video catalog route is unavailable.") }
    }

    func close() { session.invalidateAndCancel(); MusicvideoGenerationHTTP.clear() }

    func executor(editor: EditorViewModel) -> ToolExecutor {
        ToolExecutor(editor: editor, providerActivation: { self.activation }, modelCatalog: catalog,
            productionRouteCandidates: { _ in self.candidates }, catalogReadiness: { true }, isModelEnabled: { _ in true })
    }

    func configure(editor: EditorViewModel) {
        editor.generationService.reconciliation = ProviderRunReconciliation(session: session,
            providerKey: { $0 == .fal ? "simulator-only-key" : nil }, falCharge: { _, _, _ in nil })
        editor.generationBatchCoordinator.catalogReadiness = {}
        editor.generationBatchCoordinator.providerActivation = { self.activation }
        editor.generationBatchCoordinator.modelCatalog = catalog
    }

    func proposal(context: ProductionPlanningAcceptanceFixture.Context) async throws -> PipelineProductionPlanWriter.ShotProposal {
        let root = context.dataRoot
        let board = try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root) }.value
        let state = try await Task.detached { try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: root) }.value
        guard let intent = state.draft.shots.first, let planned = board.timing.shots.first,
              intent.shotID == planned.id, intent.sourceMode == .generated,
              let resolution = state.resolutions.first(where: { $0.shotID == intent.shotID && $0.obligationID == "look" }),
              case .asset(let assetID, _) = resolution.outcome,
              let candidate = candidates.first,
              let mode = candidate.candidate.inputSlots.first(where: { $0.id == CoreReferenceInputSlotIDV1.referenceImage })?.modeIDs.first else {
            throw GateBlocked("The generated proposal needs its actual native reference choice and available provider offering.")
        }
        let steps = Dictionary(uniqueKeysWithValues: board.storyboard.steps.map { ($0.id, $0) })
        let action = try planned.stepIDs.map { id in
            guard let step = steps[id] else { throw GateBlocked("The generated proposal lost a canonical story step.") }
            return step.action
        }.joined(separator: "\n")
        let nativeSeconds = 8.0
        guard board.timing.timebase.seconds(for: planned.durationTicks) + 2 <= nativeSeconds else {
            throw GateBlocked("This bounded acceptance source must contain both real handles around the planned cut.")
        }
        let demands = [ReferenceDemandV1(id: "look-" + intent.shotID, assetID: assetID, modality: .image,
            semanticJobID: CoreReferenceSemanticJobIDV1.styleReference, isRequired: true, priority: 0,
            inputSlotID: CoreReferenceInputSlotIDV1.referenceImage, modeID: mode)]
        let shot = ExecutionShotV1(id: intent.shotID, sourceMode: .generated,
            startState: .init(summary: "The pale background is unobstructed."),
            endState: .init(summary: "The approved moving shape reaches its planned composition."),
            primaryAction: action, camera: .init(movementID: intent.camera.movement.rawValue,
                movementDetail: intent.camera.movementDetail, framingID: intent.camera.framing.scale),
            renderability: .green, acceptance: [.init(id: "composition", requirement: "Preserve the approved composition and side lighting.", severity: "error")],
            generationRequirement: .init(modalityID: "video", modeIDs: [mode], visibleEntityCount: 0,
                referenceDemandIDs: demands.map(\.id), duration: .init(preferredSeconds: nativeSeconds,
                    minimumSeconds: nativeSeconds, maximumSeconds: nativeSeconds), resolution: "720p", aspectRatio: "16:9"))
        return .init(execution: shot, nativeDurationTicks: 8 * board.timing.timebase.ticksPerSecond,
            sourceInTicks: board.timing.timebase.ticksPerSecond, sourceInputRange: nil, coreInputs: .init(),
            referenceDemands: demands, selectedModelID: modelID, selectedOffering: candidate.candidate.capabilities.offering)
    }

    func render(context: ProductionPlanningAcceptanceFixture.Context, sourceVideo: URL,
                driver: ProductionVisualSourcesDriver) async throws -> String {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        guard let home = editor.workingRoot, let sessionID = editor.agentService.currentSessionId,
              let model = catalog.video.first(where: { $0.id == modelID }) else { throw GateBlocked("The actual acceptance document has no provider or recording-runtime session.") }
        try await ProductionPlanningAcceptanceFixture.run("run_phase", args: ["phase": "render"], in: context)
        let projection = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
        guard let shot = projection.shots.first, shot.sourceMode == .generated else { throw GateBlocked("The first canonical shot is not generated.") }
        try await ProductionPlanningAcceptanceFixture.run("next_render_shot", args: ["phase": "final", "shot_id": shot.id, "generate": false], in: context)
        let outputBytes = try await Task.detached { try Data(contentsOf: sourceVideo) }.value
        try MusicvideoGenerationHTTP.install(endpoint: modelID, output: outputBytes)
        let executor = executor(editor: editor)
        let selection = try PipelineProductionRouting.resolveAndWrite(shotID: shot.id, dataRoot: root,
            activation: activation, candidateProvider: { _ in self.candidates },
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        let inputs = try await executor.productionVideoInputs(selection: selection, editor: editor, dataRoot: root)
        let compilerShot = try PromptCompiler.currentShotProjection(editor: editor, shotId: shot.id)
        let compiled = try await PromptCompiler.compile(intent: shot.primaryAction, modelId: modelID,
            modality: .video, aspectRatio: "16:9", durationSeconds: 8, editor: editor, shotId: shot.id,
            shot: compilerShot, modelCatalog: catalog)
        let inspected = try await PipelineRenderReviewWriter.capture(editor: editor)
        guard let reviewedShot = inspected.shots.first(where: { $0.shotID == shot.id }),
              reviewedShot.compiledPrompt == compiled.text, reviewedShot.modelID == modelID,
              reviewedShot.review.promptIRSHA256 == compiled.binding.promptIRSHA256 else {
            throw GateBlocked("The actual generation direction differs from the native pre-render inspection.")
        }
        try driver.record("inspected direction bound to submission", fields: ["shotID": shot.id,
            "reviewFingerprint": inspected.fingerprint, "promptSHA256": FileDigest.sha256(of: Data(compiled.text.utf8))])
        var musicArc: MusicArcSectionV1?
        if editor.declaredPluginBinding?.id == "musicvideo" {
            let music = try await Task.detached {
                try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: root)
            }.value
            guard let section = music.visualArc.sections.first(where: { $0.shotIDs.contains(shot.id) }),
                  !section.visualFunction.isEmpty, !section.changeExplanation.isEmpty,
                  compiled.text.contains(section.visualFunction), compiled.text.contains(section.changeExplanation) else {
                throw GateBlocked("The actual compiled Music Video prompt omitted its approved section's visual function or change.")
            }
            musicArc = section
        }
        let request = GenerationRequest(modality: .video, modelId: modelID, intent: compiled.text,
            aspectRatio: "16:9", durationSeconds: 8, outputResolution: "720p", placement: .mediaLibrary(folderId: nil),
            origin: .agentTool, target: selection.target, precompiled: (compiled.text, compiled.token, compiled.binding),
            submission: .video(make: { [modelID] text in
                var input = GenerationInput(prompt: text, model: modelID, duration: 8, aspectRatio: "16:9", resolution: "720p")
                input.videoDuration = .seconds(8)
                input.promptShotId = compiled.binding.shotId; input.promptProjectKey = compiled.binding.projectKey
                input.promptShotFingerprint = compiled.binding.shotFingerprint; input.productionRouting = inputs.routingProof
                return VideoGenerationSubmission.make(genInput: input, model: model,
                    offeringCapabilities: inputs.offeringCapabilities, inputAssets: inputs.assets,
                    placeholderDuration: 8, name: "HTTP simulator · native V2 shot", generateAudio: false)
            }))
        let prepared = try await GenerationController.prepare(request, editor: editor).get()
        let noPrice: GenerationBudgetGuard.QuoteLoader = { _, _ in throw GenerationBackendError.transport("The HTTP simulator has no monetary quote.") }
        let package = try await GenerationController.prepareReviewPackage(prepared, editor: editor, quoteLoader: noPrice)
        guard let references = prepared.references, MusicvideoGenerationHTTP.requests.isEmpty,
              editor.generationLog.spendEvents.isEmpty else { throw GateBlocked("Preparing the candidate dispatched or spent before native approval.") }
        try await GenerationPackageInputs.persist(package: package, snapshot: references, editor: editor)
        let item = GenerationBatch.Item(id: UUID().uuidString, purpose: "Generate the first approved V2 shot", package: package)
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: package.payload.binding.projectKey, phase: "render", items: [item]))
        let coordinator = editor.generationBatchCoordinator
        coordinator.quoteLoader = noPrice
        let option = SpendOption(modelId: modelID, modelName: model.displayName, target: selection.target,
            credits: nil, requiresCatalogAvailability: true, generationPackage: package)
        _ = try editor.agentService.presentGenerationBatch(batch, recoveries: [item.id: GenerationBatchRecovery(options: [option]) { currentEditor, _ in
            try await GenerationController.prepareReviewPackage(prepared, editor: currentEditor, quoteLoader: noPrice)
        }], origin: .inAppChat(sessionID: sessionID), editor: editor)
        try await driver.wait("actual generation package awaits native approval") { driver.state("generation-batch.approve", in: window) == true }
        guard try GenerationBatchStore.all(home: home).isEmpty, MusicvideoGenerationHTTP.requests.isEmpty,
              coordinator.pending?.id == batch.id, coordinator.startsApprovedBatches else { throw GateBlocked("Native batch authority existed before the decision.") }
        try await driver.reveal("generation-batch.approve", in: window)
        try driver.visible(["generation-batch.decline", "generation-batch.approve", "generation-batch.cost"], in: window)
        try driver.capture("generation-unapproved-exact-inputs", target: window)
        try await driver.click("generation-batch.approve", in: window)
        try await driver.wait("native-approved HTTP output completed", seconds: 60) {
            guard let value = try? GenerationBatchStore.load(id: batch.id, home: home), let state = value.journal.executions.first?.state else { return false }
            return [.complete, .blocked, .failed, .canceled].contains(state) && coordinator.activeBatchID == nil && !editor.agentService.isStreaming
        }
        let stored = try GenerationBatchStore.load(id: batch.id, home: home)
        guard stored.journal.executions.first?.state == .complete, let assetID = stored.journal.executions.first?.outputAssetIDs.first,
              let asset = editor.mediaAssets.first(where: { $0.id == assetID }), asset.pendingDownloadURL == nil,
              asset.generationInput?.generationPackageID == package.id, let transaction = asset.generationInput?.spendTransactionId,
              stored.authorityAvailable, stored.batch.payload.items.first?.package == package,
              stored.journal.pricingOverrideItemIDs == [item.id], try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: outputBytes) else {
            throw GateBlocked(stored.journal.executions.first?.detail ?? "The real provider path lost its immutable output package.")
        }
        let events = editor.generationLog.spendEvents.filter { $0.transactionId == transaction }
        guard events.map(\.kind) == [.reserved, .submitted, .settled], events.allSatisfy({ $0.money == nil }),
              events.first(where: { $0.kind == .submitted })?.providerRequestId == MusicvideoGenerationHTTP.requestID,
              MusicvideoGenerationHTTP.submittedPrompt == compiled.text, MusicvideoGenerationHTTP.submittedEnvelopeMatches(duration: 8),
              MusicvideoGenerationHTTP.unexpectedRequests.isEmpty,
              let binding = selection.referencePlan.bindings.first, selection.referencePlan.bindings.count == 1,
              MusicvideoGenerationHTTP.uploadedReference == (try Data(contentsOf: ProjectLocalFile.requireHash(binding.sha256, at: binding.path, dataRoot: root))) else {
            throw GateBlocked("The HTTP path differs from its approved prompt, reference bytes, duration or spend evidence.")
        }
        if let musicArc {
            try driver.record("actual Music Video visual arc compiled", fields: ["sectionID": musicArc.sectionID,
                "visualFunction": musicArc.visualFunction, "changeExplanation": musicArc.changeExplanation,
                "compiledSHA256": FileDigest.sha256(of: Data(compiled.text.utf8)), "providerPromptMatched": true])
        }
        let recorded = await executor.execute(name: "record_render", args: ["phase": "final", "shot_id": shot.id, "output": assetID])
        guard !recorded.isError, recorded.turnDisposition == .continueTurn else {
            let detail = recorded.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
            throw GateBlocked("The V2 writer rejected actual generated output: " + detail)
        }
        let takeID = PipelineRenderTakeStore.identity(eventID: assetID, outputSHA256: FileDigest.sha256(of: outputBytes))
        let take = try await TakeReview.capture(takeID: takeID, home: home)
        guard abs(take.durationSeconds - 8) <= 1 / Double(editor.timeline.fps), take.take.output.sha256 == FileDigest.sha256(of: outputBytes) else {
            throw GateBlocked("The recorded take differs from the submitted complete provider duration and bytes.")
        }
        try driver.record("real HTTP generation approved natively", fields: ["takeID": takeID, "batchID": batch.id,
            "packageSHA256": package.id, "outputSHA256": take.take.output.sha256,
            "promptSHA256": FileDigest.sha256(of: Data(compiled.text.utf8)), "providerRequests": MusicvideoGenerationHTTP.requests.count])
        return takeID
    }
}
