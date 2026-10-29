import AppKit
import NexGenEngine

@MainActor
final class ProductionSourceModeGenerationAcceptance {
    let kind: ProductionSourceModesOwnerAcceptance.Kind
    let catalog = ModelCatalog()
    let first: ProductionV2GenerationAcceptance
    let activation: ProviderActivation
    let session: URLSession
    let modelID: String

    var candidates: [CatalogProductionRouteCandidate] {
        catalog.productionRouteCandidates(activation: activation).filter { $0.modelID == modelID || $0.modelID == first.modelID }
    }

    init(kind: ProductionSourceModesOwnerAcceptance.Kind, driver: ProductionVisualSourcesDriver) async throws {
        guard WorkspaceUIAcceptance.isRequested, kind != .animatedStill else { throw GateBlocked("Source generation is confined to isolated native video acceptance.") }
        self.kind = kind
        first = try ProductionV2GenerationAcceptance()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        switch kind {
        case .aiEnhanced:
            modelID = "runway/aleph2"
            activation = ProviderActivation(active: [.init(provider: .fal, transport: .api), .init(provider: .runway, transport: .api)])
            configuration.protocolClasses = [ProductionRunwaySourceHTTP.self]
            ProductionRunwaySourceHTTP.install(operation: .transform, output: Data())
        case .nativeExtension:
            modelID = "runway/seedance2_5"
            activation = ProviderActivation(active: [.init(provider: .fal, transport: .api), .init(provider: .runway, transport: .api)])
            configuration.protocolClasses = [ProductionRunwaySourceHTTP.self]
            ProductionRunwaySourceHTTP.install(operation: .extend, output: Data())
        case .frameContinuation:
            modelID = "bytedance/seedance-2.5/image-to-video"
            activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
            configuration.protocolClasses = [ManualVideoModesHTTP.self]
        case .animatedStill:
            throw GateBlocked("Animated still uses its actual Frames image and has no final video-generation helper.")
        }
        session = URLSession(configuration: configuration)
        var initialized = false
        defer { if !initialized { session.invalidateAndCancel(); first.close() } }
        catalog.load(entries: ModelCatalog.launchEntries)
        if kind != .frameContinuation {
            let offered = try await RunwayClient(apiKey: "simulator-only-key", session: session).availableModelIds()
            let discovered = RunwayModelRegistry.discoveredEntries(availableModelIds: offered)
            catalog.applyDiscovered(discovered, for: .runway)
            catalog.setProviderDiscoveryState(.ready(modelCount: discovered.count), for: .runway)
            guard ProductionRunwaySourceHTTP.unexpectedRequests.isEmpty,
                  ProductionRunwaySourceHTTP.requests.count == 1,
                  ProductionRunwaySourceHTTP.requests.first?.url == "https://api.dev.runwayml.com/v1/organization" else {
                throw GateBlocked("The isolated account model response bypassed the actual Runway client.")
            }
            try driver.record("actual source-video catalog through isolated HTTP", fields: ["accountModelIDs": offered.sorted(),
                "registeredModelIDs": discovered.map(\.id), "operation": kind.rawValue, "liveProvider": false,
                "actualAccountEntitlementClaim": false])
        }
        guard candidates.contains(where: { $0.modelID == modelID && $0.target != nil && $0.candidate.providerActivated && $0.candidate.liveAvailable }) else {
            throw GateBlocked("The actual native catalog cannot execute this source-video recipe.")
        }
        initialized = true
    }

    func close() {
        session.invalidateAndCancel(); first.close(); ProductionRunwaySourceHTTP.clear(); ManualVideoModesHTTP.clear()
    }

    func executor(editor: EditorViewModel) -> ToolExecutor {
        ToolExecutor(editor: editor, providerActivation: { self.activation }, modelCatalog: catalog,
            productionRouteCandidates: { _ in self.candidates }, catalogReadiness: { true }, isModelEnabled: { _ in true },
            generationQuoteLoader: { _, _ in throw GenerationBackendError.transport("The isolated provider has no live monetary quote.") })
    }

    func configure(editor: EditorViewModel) {
        editor.generationService.reconciliation = ProviderRunReconciliation(session: session,
            providerKey: { $0 == .fal || $0 == .runway ? "simulator-only-key" : nil }, falCharge: { _, _, _ in nil })
        editor.generationBatchCoordinator.catalogReadiness = {}
        editor.generationBatchCoordinator.providerActivation = { self.activation }
        editor.generationBatchCoordinator.modelCatalog = catalog
        editor.generationBatchCoordinator.quoteLoader = { _, _ in throw GenerationBackendError.transport("The isolated provider has no live monetary quote.") }
    }

    func proposal(shotID: String, context: ProductionPlanningAcceptanceFixture.Context) async throws -> PipelineProductionPlanWriter.ShotProposal {
        let root = context.dataRoot
        let (board, snapshot) = try await Task.detached {
            (try PlanningWriterIO.storyboard(dataRoot: root), try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: root))
        }.value
        guard let intent = snapshot.draft.shots.first(where: { $0.shotID == shotID }),
              let planned = board.timing.shots.first(where: { $0.id == shotID }),
              let candidate = candidates.first(where: { $0.modelID == modelID }),
              let target = candidate.target else { throw GateBlocked("The selected native source recipe has no actual plan or provider offering.") }
        let slot = kind == .frameContinuation ? CoreReferenceInputSlotIDV1.firstFrame : CoreReferenceInputSlotIDV1.sourceVideo
        guard let mode = candidate.candidate.inputSlots.first(where: { $0.id == slot })?.modeIDs.first else {
            throw GateBlocked("The actual offering has no executable native source input slot.")
        }
        let sourceAssetID: String?
        let nativeTicks: Int64
        let inputs: ProductionCoreInputModesV1
        switch kind {
        case .aiEnhanced:
            guard intent.sourceMode == .aiEnhanced, let source = intent.source, let range = intent.sourceInputRange,
                  range.timebase == board.timing.timebase,
                  let asset = snapshot.assets.first(where: { $0.path == source.path && $0.sha256 == source.sha256 }) else {
                throw GateBlocked("AI-enhanced output needs the exact natively selected original source and range.")
            }
            sourceAssetID = asset.id
            nativeTicks = range.durationTicks
            inputs = .init(sourceVideoModeID: mode)
        case .nativeExtension:
            guard intent.chainKind == .nativeExtension, intent.sourceMode == .generated else { throw GateBlocked("The draft did not natively choose video extension.") }
            sourceAssetID = PipelineProductionPlanWriter.predecessorVideoRecipe(shotID: shotID)
            nativeTicks = 8 * board.timing.timebase.ticksPerSecond
            inputs = .init(sourceVideoModeID: mode)
            guard target.binding?.resolvedVideoCapabilities?.inputPolicy.sourceOperation == .extendForward else { throw GateBlocked("Transform is not executable forward extension.") }
        case .frameContinuation:
            guard intent.chainKind == .frameContinuation, intent.sourceMode == .generated else { throw GateBlocked("The draft did not natively choose frame continuation.") }
            sourceAssetID = nil
            nativeTicks = 8 * board.timing.timebase.ticksPerSecond
            inputs = .init(predecessorLastFrameModeID: mode)
        case .animatedStill: throw GateBlocked("Still has no final video-generation requirement.")
        }
        let steps = Dictionary(uniqueKeysWithValues: board.storyboard.steps.map { ($0.id, $0) })
        let action = try planned.stepIDs.map { id in
            guard let step = steps[id] else { throw GateBlocked("The native source recipe lost its canonical action.") }
            return step.action
        }.joined(separator: "\n")
        let sourceIn = board.timing.timebase.ticksPerSecond
        guard nativeTicks >= planned.durationTicks + 2 * sourceIn else { throw GateBlocked("This actual provider output must contain both explicit review handles around its planned cut.") }
        let duration = board.timing.timebase.seconds(for: nativeTicks)
        let shot = ExecutionShotV1(id: shotID, sourceMode: kind == .aiEnhanced ? .aiEnhanced : .generated,
            startState: .init(summary: "The approved source movement begins."),
            endState: .init(summary: "The source movement reaches its planned final composition."), primaryAction: action,
            camera: .init(movementID: intent.camera.movement.rawValue, movementDetail: intent.camera.movementDetail,
                framingID: intent.camera.framing.scale), renderability: .green,
            acceptance: [.init(id: "exact-source", requirement: "Use the exact approved native source recipe without substituting another asset.", severity: "error")],
            generationRequirement: .init(modalityID: "video", modeIDs: [mode], visibleEntityCount: 0,
                requiresFirstFrame: kind == .frameContinuation, sourceVideoAssetID: sourceAssetID,
                duration: .init(preferredSeconds: duration, minimumSeconds: duration, maximumSeconds: duration),
                resolution: kind == .frameContinuation ? "720p" : nil, aspectRatio: "16:9"))
        return .init(execution: shot, nativeDurationTicks: nativeTicks, sourceInTicks: sourceIn, sourceInputRange: nil,
            coreInputs: inputs, referenceDemands: [], selectedModelID: modelID, selectedOffering: candidate.candidate.capabilities.offering)
    }

    func render(shotID: String, context: ProductionPlanningAcceptanceFixture.Context, outputVideo: URL,
                driver: ProductionVisualSourcesDriver, output: URL) async throws -> String {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        guard let home = editor.workingRoot, let sessionID = editor.agentService.currentSessionId,
              let model = catalog.video.first(where: { $0.id == modelID }) else {
            throw GateBlocked("The native source-video run has no actual provider or recording session.")
        }
        configure(editor: editor)
        let executor = executor(editor: editor)
        let active = ProductionPlanningAcceptanceFixture.Context(document: context.document, packageURL: context.packageURL,
            dataRoot: root, executor: executor)
        try await ProductionPlanningAcceptanceFixture.run("run_phase", args: ["phase": "render"], in: active)
        let projection = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
        guard let shot = projection.shots.first(where: { $0.id == shotID }),
              let timing = projection.timings.first(where: { $0.shotID == shotID }),
              let nativeTicks = timing.nativeDurationTicks,
              nativeTicks % projection.timebase.ticksPerSecond == 0 else {
            throw GateBlocked("The chosen source recipe has no exact integer provider output duration.")
        }
        let seconds = Int(nativeTicks / projection.timebase.ticksPerSecond)
        let resolution = shot.generationRequirement?.resolution
        let bytes = try await Task.detached { try Data(contentsOf: outputVideo) }.value
        let spendBefore = editor.generationLog.spendEvents
        if kind == .frameContinuation { ManualVideoModesHTTP.install(endpoint: modelID, output: bytes) }
        else { ProductionRunwaySourceHTTP.install(operation: kind == .aiEnhanced ? .transform : .extend, output: bytes) }
        try await ProductionPlanningAcceptanceFixture.run("next_render_shot", args: ["phase": "final", "shot_id": shotID, "generate": false], in: active)
        let selection = try PipelineProductionRouting.resolveAndWrite(shotID: shotID, dataRoot: root,
            activation: activation, candidateProvider: { _ in self.candidates },
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        let inputs = try await executor.productionVideoInputs(selection: selection, editor: editor, dataRoot: root)
        let compilerShot = try PromptCompiler.currentShotProjection(editor: editor, shotId: shotID)
        let compiled = try await PromptCompiler.compile(intent: shot.primaryAction, modelId: modelID,
            modality: .video, aspectRatio: "16:9", durationSeconds: Double(seconds), editor: editor, shotId: shotID,
            shot: compilerShot, modelCatalog: catalog)
        let inspected = try await PipelineRenderReviewWriter.capture(editor: editor)
        guard let reviewed = inspected.shots.first(where: { $0.shotID == shotID }),
              reviewed.compiledPrompt == compiled.text, reviewed.modelID == modelID,
              reviewed.review.promptIRSHA256 == compiled.binding.promptIRSHA256 else {
            throw GateBlocked("The actual source-video direction differs from the native pre-render inspection.")
        }
        let request = GenerationRequest(modality: .video, modelId: modelID, intent: compiled.text,
            aspectRatio: "16:9", durationSeconds: Double(seconds), outputResolution: resolution,
            placement: .mediaLibrary(folderId: nil), origin: .agentTool, target: selection.target,
            precompiled: (compiled.text, compiled.token, compiled.binding), submission: .video(make: { [modelID] text in
                var input = GenerationInput(prompt: text, model: modelID, duration: seconds, aspectRatio: "16:9", resolution: resolution)
                input.videoDuration = .seconds(seconds)
                input.promptShotId = compiled.binding.shotId; input.promptProjectKey = compiled.binding.projectKey
                input.promptShotFingerprint = compiled.binding.shotFingerprint; input.productionRouting = inputs.routingProof
                return VideoGenerationSubmission.make(genInput: input, model: model,
                    offeringCapabilities: inputs.offeringCapabilities, inputAssets: inputs.assets,
                    placeholderDuration: Double(seconds), name: "HTTP simulator · native source recipe", generateAudio: false)
            }))
        let prepared = try await GenerationController.prepare(request, editor: editor).get()
        let noPrice: GenerationBudgetGuard.QuoteLoader = { _, _ in throw GenerationBackendError.transport("The isolated source provider has no monetary quote.") }
        let package = try await GenerationController.prepareReviewPackage(prepared, editor: editor, quoteLoader: noPrice)
        guard let references = prepared.references, requestsAreEmpty,
              editor.generationLog.spendEvents == spendBefore else {
            throw GateBlocked("Preparing exact source-video inputs submitted or spent before native approval.")
        }
        try await GenerationPackageInputs.persist(package: package, snapshot: references, editor: editor)
        let item = GenerationBatch.Item(id: UUID().uuidString, purpose: "Generate the approved native source recipe", package: package)
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: package.payload.binding.projectKey, phase: "render", items: [item]))
        let option = SpendOption(modelId: modelID, modelName: model.displayName, target: selection.target,
            credits: nil, requiresCatalogAvailability: true, generationPackage: package)
        _ = try editor.agentService.presentGenerationBatch(batch, recoveries: [item.id: GenerationBatchRecovery(options: [option]) { current, _ in
            try await GenerationController.prepareReviewPackage(prepared, editor: current, quoteLoader: noPrice)
        }], origin: .inAppChat(sessionID: sessionID), editor: editor)
        try await driver.wait("native source package awaits approval") { driver.state("generation-batch.approve", in: window) == true }
        guard requestsAreEmpty, editor.generationLog.spendEvents == spendBefore,
              editor.generationBatchCoordinator.pending?.id == batch.id else {
            throw GateBlocked("The source recipe ran before its actual native decision.")
        }
        try await driver.reveal("generation-batch.approve", in: window)
        try driver.visible(["generation-batch.decline", "generation-batch.approve", "generation-batch.cost"], in: window)
        try driver.capture("source-recipe-unapproved-inputs", target: window)
        try await driver.click("generation-batch.approve", in: window)
        try await driver.wait("actual source recipe HTTP output completed", seconds: 90) {
            guard let value = try? GenerationBatchStore.load(id: batch.id, home: home), let state = value.journal.executions.first?.state else { return false }
            return [.complete, .blocked, .failed, .canceled].contains(state)
                && editor.generationBatchCoordinator.activeBatchID == nil && !editor.agentService.isStreaming
        }
        let stored = try GenerationBatchStore.load(id: batch.id, home: home)
        guard stored.journal.executions.first?.state == .complete,
              let assetID = stored.journal.executions.first?.outputAssetIDs.first,
              let asset = editor.mediaAssets.first(where: { $0.id == assetID }), asset.pendingDownloadURL == nil,
              asset.generationInput?.generationPackageID == package.id,
              let transaction = asset.generationInput?.spendTransactionId,
              stored.authorityAvailable, stored.batch.payload.items.first?.package == package,
              stored.journal.pricingOverrideItemIDs == [item.id],
              try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: bytes) else {
            throw GateBlocked(stored.journal.executions.first?.detail ?? "The actual source recipe lost its approved output package.")
        }
        let events = editor.generationLog.spendEvents.filter { $0.transactionId == transaction }
        guard events.map(\.kind) == [.reserved, .submitted, .settled], events.allSatisfy({ $0.money == nil }),
              selection.referencePlan.bindings.count == 1, let binding = selection.referencePlan.bindings.first else {
            throw GateBlocked("The source recipe has unexpected spend evidence or mixed conditioning inputs.")
        }
        let expected = try await Task.detached {
            try Data(contentsOf: ProjectLocalFile.requireHash(binding.sha256, at: binding.path, dataRoot: root))
        }.value
        let envelope: [String: Any]
        let requestID: String
        let uploadedBytes: Data
        if kind == .frameContinuation {
            let transport = ManualVideoModesHTTP.snapshot
            guard transport.unexpected.isEmpty,
                  let post = transport.requests.first(where: { $0.method == "POST" && $0.url == "https://queue.fal.run/" + modelID }),
                  let body = try JSONSerialization.jsonObject(with: post.body) as? [String: Any],
                  let image = body["image_url"] as? String, transport.uploads[image] == expected,
                  binding.modality == .image, body["prompt"] as? String == compiled.text,
                  body["duration"] as? String == String(seconds), body["resolution"] as? String == resolution,
                  body["end_image_url"] == nil, body["image_urls"] == nil, body["video_urls"] == nil,
                  body["audio_urls"] == nil, transport.uploads.count == 1 else {
                throw GateBlocked("Frame continuation did not upload its exact sole predecessor last frame.")
            }
            envelope = body; requestID = transport.requestID
            uploadedBytes = try requireUpload(transport.uploads[image])
        } else {
            guard ProductionRunwaySourceHTTP.unexpectedRequests.isEmpty,
                  ProductionRunwaySourceHTTP.uploadedBytes == expected, binding.modality == .video,
                  let body = ProductionRunwaySourceHTTP.submittedBody,
                  body["promptText"] as? String == compiled.text,
                  (kind != .nativeExtension || body["duration"] as? Int == seconds),
                  body[kind == .aiEnhanced ? "videoUri" : "promptVideo"] as? String == ProductionRunwaySourceHTTP.sourceURI else {
                throw GateBlocked("The Runway source request did not upload the exact materialized conditioning video.")
            }
            envelope = body; requestID = ProductionRunwaySourceHTTP.requestID
            uploadedBytes = try requireUpload(ProductionRunwaySourceHTTP.uploadedBytes)
        }
        guard events.first(where: { $0.kind == .submitted })?.providerRequestId == requestID else {
            throw GateBlocked("The submitted source request ID differs from its real provider receipt.")
        }
        let recorded = await executor.execute(name: "record_render", args: ["phase": "final", "shot_id": shotID, "output": assetID])
        guard !recorded.isError, recorded.turnDisposition == .continueTurn else {
            throw GateBlocked("The canonical writer refused the actual source-mode output.")
        }
        let takeID = PipelineRenderTakeStore.identity(eventID: assetID, outputSHA256: FileDigest.sha256(of: bytes))
        let take = try await TakeReview.capture(takeID: takeID, home: home)
        guard abs(take.durationSeconds - Double(seconds)) <= 1 / Double(editor.timeline.fps),
              take.take.output.sha256 == FileDigest.sha256(of: bytes) else {
            throw GateBlocked("The source-mode Take differs from its actual provider output.")
        }
        let evidence = ["kind": kind.rawValue, "shotID": shotID, "takeID": takeID, "batchID": batch.id,
            "modelID": modelID, "providerID": selection.target.provider.rawValue,
            "endpoint": selection.target.endpoint,
            "packageSHA256": package.id, "inputPath": binding.path, "inputSHA256": binding.sha256,
            "inputModality": binding.modality.rawValue, "outputSHA256": take.take.output.sha256,
            "compiledSHA256": FileDigest.sha256(of: Data(compiled.text.utf8)), "durationSeconds": seconds,
            "providerRequestID": requestID, "submittedEnvelope": envelope, "nativeBatchApproved": true,
            "liveProvider": false, "semanticGenerationQualityClaim": false] as [String: Any]
        try driver.record("actual source-mode provider request", fields: evidence)
        try await Task.detached { try uploadedBytes.write(to: output.appendingPathComponent("source-provider-upload.bin")) }.value
        try await Task.detached {
            try JSONEncoder().encode(stored).write(to: output.appendingPathComponent("source-approved-batch.json"))
        }.value
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("source-provider.json"))
        return takeID
    }

    private var requestsAreEmpty: Bool {
        kind == .frameContinuation ? ManualVideoModesHTTP.snapshot.requests.isEmpty : ProductionRunwaySourceHTTP.requests.isEmpty
    }

    private func requireUpload(_ data: Data?) throws -> Data {
        guard let data, !data.isEmpty else { throw GateBlocked("The actual provider transport captured no uploaded source bytes.") }
        return data
    }

}
