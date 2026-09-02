import Foundation
import ImageIO
import NexGenEngine

@MainActor
final class AgentGenerationAwaiter {
    enum Completion {
        case succeeded(MediaAsset?)
        case failed(String?)
    }

    private var completion: Completion?
    private var continuation: CheckedContinuation<Completion, Never>?
    private(set) var isResolved = false
    private var cancellationRequested = false
    private var cancellationDispatched = false
    private var cancelOperation: (@MainActor () -> Bool)?

    static func waitForSubmission(
        start: @escaping @MainActor (AgentGenerationAwaiter) async throws -> String,
        cancel: @escaping @MainActor (String) -> Bool
    ) async throws -> (placeholderId: String, completion: Completion) {
        let awaiter = AgentGenerationAwaiter()
        return try await withTaskCancellationHandler {
            let placeholderId = try await start(awaiter)
            awaiter.installCancellation { cancel(placeholderId) }
            if Task.isCancelled { awaiter.cancel() }
            let completion = await awaiter.value()
            if Task.isCancelled { awaiter.cancel() }
            return (placeholderId, awaiter.terminal(completion))
        } onCancel: {
            Task { @MainActor [weak awaiter] in awaiter?.cancel() }
        }
    }

    func resolve(_ completion: Completion) {
        guard !isResolved else { return }
        isResolved = true
        let completion = terminal(completion)
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: completion)
        } else {
            self.completion = completion
        }
    }

    func value() async -> Completion {
        if let completion { return completion }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func installCancellation(_ action: @escaping @MainActor () -> Bool) {
        guard !isResolved else { return }
        cancelOperation = action
        dispatchCancellationIfNeeded()
    }

    func cancel() {
        cancellationRequested = true
        guard !isResolved else { return }
        dispatchCancellationIfNeeded()
    }

    private func dispatchCancellationIfNeeded() {
        guard cancellationRequested,
              !cancellationDispatched,
              let cancelOperation else { return }
        cancellationDispatched = true
        self.cancelOperation = nil
        _ = cancelOperation()
    }

    private func terminal(_ completion: Completion) -> Completion {
        guard cancellationRequested else { return completion }
        switch completion {
        case .succeeded:
            return .failed("Generation cancelled.")
        case .failed:
            return completion
        }
    }
}

struct ProductionDesignReferenceSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let path: String
        let sha256: String
    }

    let entries: [Entry]

    var paths: [String] { entries.map(\.path) }
}

@MainActor
final class ProductionDesignReferenceStaging {
    let directory: URL
    let references: [MediaAsset]

    init(directory: URL, references: [MediaAsset]) {
        self.directory = directory
        self.references = references
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try FileManager.default.removeItem(at: directory)
        } catch {
            Log.generation.error(
                "failed to clean Production Design reference staging: \(error.localizedDescription)"
            )
        }
    }
}

private struct ProductionVideoGenerationInputs {
    let assets: VideoGenerationSubmission.InputAssets
    let routingProof: ProductionGenerationRoutingProofV1
    let offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1
}

extension ToolExecutor {
    private func currentProductionRouting(
        editor: EditorViewModel,
        args: [String: Any]
    ) throws -> (selection: PipelineProductionRouteSelection, dataRoot: URL)? {
        let shotID = try args.requireString("shotId")
        guard shotID != "none" else { return nil }
        guard let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot) else {
            throw ToolError(
                "Shot-bound generation requires an open project with a pipeline data root."
            )
        }
        do {
            return (
                try PipelineProductionRouting.requireCurrent(
                    shotID: shotID,
                    dataRoot: dataRoot,
                    activation: providerActivation(),
                    candidateProvider: productionRouteCandidates
                ),
                dataRoot
            )
        } catch {
            throw ToolError(
                "The production route for shot '\(shotID)' is missing or stale. "
                    + "Call next_render_shot again before compiling or generating: \(error)."
            )
        }
    }

    private func productionVideoInputs(
        selection: PipelineProductionRouteSelection,
        editor: EditorViewModel,
        dataRoot: URL
    ) async throws -> ProductionVideoGenerationInputs {
        guard let offeringCapabilities = selection.target.binding?
            .resolvedVideoCapabilities else {
            throw ToolError(
                "The selected provider endpoint has no versioned video capability contract."
            )
        }
        let inputPolicy = offeringCapabilities.inputPolicy
        var sourceVideo: MediaAsset?
        var startFrame: MediaAsset?
        var endFrame: MediaAsset?
        var imageReferences: [MediaAsset] = []
        var videoReferences: [MediaAsset] = []
        var audioReferences: [MediaAsset] = []
        var proofs: [ProductionGenerationRoutingBindingV1] = []

        for binding in selection.referencePlan.bindings {
            guard let asset = await resolveRenderedAsset(
                binding.path,
                editor: editor,
                dataRoot: dataRoot
            ) else {
                throw ToolError(
                    "Planned input '\(binding.demandID)' is no longer available as project media."
                )
            }
            let plannedURL = try ProjectLocalFile.requireHash(
                binding.sha256,
                at: binding.path,
                dataRoot: dataRoot
            ).standardizedFileURL.resolvingSymlinksInPath()
            let actualURL = asset.url.standardizedFileURL.resolvingSymlinksInPath()
            guard actualURL == plannedURL else {
                throw ToolError(
                    "Planned input '\(binding.demandID)' resolves to different media bytes."
                )
            }
            let expectedType: ClipType
            switch binding.modality {
            case .image: expectedType = .image
            case .video: expectedType = .video
            case .audio: expectedType = .audio
            case .geometry:
                throw ToolError(
                    "The selected provider submission does not implement geometry input slot "
                        + "'\(binding.inputSlotID)'."
                )
            }
            guard asset.type == expectedType else {
                throw ToolError(
                    "Planned input '\(binding.demandID)' must be \(expectedType.rawValue) media."
                )
            }
            proofs.append(ProductionGenerationRoutingBindingV1(
                demandID: binding.demandID,
                graphAssetID: binding.assetID,
                graphAssetVersion: binding.assetVersion,
                mediaAssetID: asset.id,
                path: binding.path,
                sha256: binding.sha256,
                modalityID: binding.modality.rawValue,
                semanticJobID: binding.semanticJobID,
                inputSlotID: binding.inputSlotID,
                modeID: binding.modeID
            ))
            switch binding.semanticJobID {
            case CoreReferenceSemanticJobIDV1.sourceVideo:
                guard sourceVideo == nil else {
                    throw ToolError("The reference plan contains more than one source video.")
                }
                sourceVideo = asset
            case CoreReferenceSemanticJobIDV1.firstFrame,
                 CoreReferenceSemanticJobIDV1.predecessorLastFrame:
                guard startFrame == nil else {
                    throw ToolError("The reference plan contains more than one start frame.")
                }
                startFrame = asset
            case CoreReferenceSemanticJobIDV1.lastFrame:
                guard endFrame == nil else {
                    throw ToolError("The reference plan contains more than one end frame.")
                }
                endFrame = asset
            default:
                switch binding.modality {
                case .image: imageReferences.append(asset)
                case .video: videoReferences.append(asset)
                case .audio: audioReferences.append(asset)
                case .geometry: break
                }
            }
        }
        if endFrame != nil, startFrame == nil {
            throw ToolError("The reference plan has an end frame without a start frame.")
        }
        let frames = [startFrame, endFrame].compactMap { $0 }
        let assets = VideoGenerationSubmission.InputAssets(
            sourceVideo: sourceVideo,
            frames: frames,
            imageRefs: imageReferences,
            videoRefs: videoReferences,
            audioRefs: audioReferences
        )
        guard (sourceVideo != nil) == inputPolicy.requiresSourceVideo else {
            throw ToolError(
                "The provider source-video policy does not match the ReferencePlan."
            )
        }
        let submittedOrder = inputPolicy.requiresSourceVideo
            ? assets.editReferences.map(\.id)
            : assets.textToVideoReferences.map(\.id)
        guard submittedOrder == proofs.map(\.mediaAssetID) else {
            throw ToolError(
                "The provider submission cannot preserve the ReferencePlan's exact input order."
            )
        }
        let historicalInputs = try PipelineProductionInputsWriter.load(
            shotID: selection.route.shotID,
            dataRoot: dataRoot
        )
        let (historicalAssetGraph, historicalDemandSet, _) = historicalInputs
        let demandData = try AssetGraphCanonicalCodecV1.encode(
            historicalDemandSet
        )
        let assetsByID = Dictionary(
            uniqueKeysWithValues: historicalAssetGraph.assets.map { ($0.id, $0) }
        )
        let demandsByID = Dictionary(
            uniqueKeysWithValues: historicalDemandSet.demands.map { ($0.id, $0) }
        )
        guard historicalAssetGraph.projectID == selection.route.projectID,
              historicalDemandSet.projectID == selection.route.projectID,
              historicalDemandSet.shotID == selection.route.shotID,
              selection.referencePlan.demandSet.id == historicalDemandSet.id,
              selection.referencePlan.demandSet.sha256
                == FileDigest.sha256(of: demandData),
              selection.referencePlan.bindings.allSatisfy({ binding in
                  guard let demand = demandsByID[binding.demandID],
                        let asset = assetsByID[binding.assetID] else { return false }
                  return binding == ReferenceBindingV2(demand: demand, asset: asset)
              }) else {
            throw ToolError(
                "The production inputs changed after the ReferencePlan was selected."
            )
        }
        let offeringCapabilitiesData = try ReferencePlanCanonicalCodecV2.encode(
            offeringCapabilities
        )
        let proof = ProductionGenerationRoutingProofV1(
            projectID: selection.route.projectID,
            shotID: selection.route.shotID,
            modelID: selection.modelID,
            providerID: selection.target.provider.rawValue,
            transportID: selection.target.transport.rawValue,
            endpointID: selection.target.endpoint,
            modelParam: selection.target.binding?.modelParam,
            offeringID: selection.route.offering.offeringID,
            requirement: selection.requirement,
            route: selection.route,
            referencePlan: selection.referencePlan,
            routeArtifactSHA256: selection.routeArtifactSHA256,
            requirementSHA256: selection.route.requirementSHA256,
            capabilitiesSHA256: selection.route.capabilitiesSHA256,
            routeSHA256: selection.route.routeSHA256,
            referencePlanSHA256: selection.referencePlanSHA256,
            orderedBindingsSHA256: selection.orderedBindingsSHA256,
            orderedBindings: proofs,
            offeringCapabilities: offeringCapabilities,
            offeringCapabilitiesSHA256: FileDigest.sha256(
                of: offeringCapabilitiesData
            ),
            historicalAssetGraph: historicalAssetGraph,
            historicalDemandSet: historicalDemandSet
        )
        return ProductionVideoGenerationInputs(
            assets: assets,
            routingProof: proof,
            offeringCapabilities: offeringCapabilities
        )
    }

    private static func validateProductionArguments(
        _ args: [String: Any],
        against inputAssets: VideoGenerationSubmission.InputAssets
    ) throws {
        guard args.string("sourceVideoMediaRef") == inputAssets.sourceVideo?.id,
              args.string("startFrameMediaRef") == inputAssets.frames.first?.id,
              args.string("endFrameMediaRef") == inputAssets.frames.dropFirst().first?.id,
              args.stringArray("referenceImageMediaRefs") == inputAssets.imageRefs.map(\.id),
              args.stringArray("referenceVideoMediaRefs") == inputAssets.videoRefs.map(\.id),
              args.stringArray("referenceAudioMediaRefs") == inputAssets.audioRefs.map(\.id) else {
            throw ToolError(
                "The submitted generation inputs do not exactly match next_render_shot's "
                    + "ordered ReferencePlan. Use its media_ref values without adding, removing, "
                    + "substituting, or reordering them."
            )
        }
    }

    private static func validateProductionOutput(
        duration: VideoDuration,
        aspectRatio: String,
        resolution: String?,
        requirement: ProductionRequirementV1
    ) throws {
        if let requested = requirement.duration {
            switch duration {
            case .automatic:
                guard requested.allowsAutomatic else {
                    throw ToolError(
                        "The ProductionRequirement does not allow automatic duration."
                    )
                }
            case .seconds(let seconds):
                let value = Double(seconds)
                guard requested.preferredSeconds.map({ $0 == value }) ?? true,
                      requested.minimumSeconds.map({ value >= $0 }) ?? true,
                      requested.maximumSeconds.map({ value <= $0 }) ?? true else {
                    throw ToolError(
                        "The submitted duration does not match the ProductionRequirement."
                    )
                }
            }
        }
        if let expected = requirement.aspectRatio,
           expected.caseInsensitiveCompare(aspectRatio) != .orderedSame {
            throw ToolError(
                "The submitted aspect ratio '\(aspectRatio)' does not match the "
                    + "ProductionRequirement '\(expected)'."
            )
        }
        if let expected = requirement.resolution,
           expected.caseInsensitiveCompare(resolution ?? "") != .orderedSame {
            throw ToolError(
                "The submitted resolution '\(resolution ?? "none")' does not match the "
                    + "ProductionRequirement '\(expected)'."
            )
        }
    }

    private func productionSpendOptions(
        shotID: String,
        dataRoot: URL,
        durationSeconds: Int,
        resolution: String?
    ) -> [SpendOption] {
        guard let selections = try? PipelineProductionRouting.resolveOptions(
            shotID: shotID,
            dataRoot: dataRoot,
            activation: providerActivation(),
            candidateProvider: productionRouteCandidates
        ) else { return [] }
        return selections.compactMap { selection in
            guard let offeringCapabilities = selection.target.binding?
                    .resolvedVideoCapabilities,
                  let model = VideoModelConfig.allModels.first(where: {
                $0.id == selection.modelID
            }) else { return nil }
            let requirementDuration: VideoDuration = selection.requirement.duration?
                .preferredSeconds.map { .seconds(Int($0)) }
                ?? .seconds(durationSeconds)
            guard offeringCapabilities.validate(
                duration: requirementDuration,
                aspectRatio: selection.requirement.aspectRatio ?? "",
                resolution: selection.requirement.resolution,
                generateAudio: selection.requirement.requiresOutputAudio,
                displayName: model.displayName
            ) == nil else { return nil }
            return SpendOption(
                modelId: model.id,
                modelName: model.displayName,
                target: selection.target,
                credits: CostEstimator.videoCost(
                    model: model,
                    durationSeconds: durationSeconds,
                    resolution: resolution,
                    generateAudio: selection.requirement.requiresOutputAudio
                ),
                requiresCatalogAvailability: true
            )
        }
    }

    func generate(
        _ editor: EditorViewModel,
        _ args: [String: Any],
        type: ClipType,
        origin: ToolCallOrigin
    ) async throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        switch type {
        case .video:
            let productionRouting = try currentProductionRouting(
                editor: editor,
                args: args
            )
            let requestedModelID = args.string("model").map {
                ModelCatalog.shared.internalId(forLogical: $0)
            }
            if let productionRouting,
               let requestedModelID,
               requestedModelID != productionRouting.selection.modelID {
                throw ToolError(
                    "Pipeline shot generation must start with next_render_shot's exact "
                        + "generation_model '\(productionRouting.selection.modelID)'."
                )
            }
            guard let modelId = productionRouting?.selection.modelID
                ?? requestedModelID
                ?? VideoModelConfig.allModels.first?.id else {
                throw ToolError("Model catalog not loaded yet. Try again in a moment.")
            }
            guard let model = VideoModelConfig.allModels.first(where: { $0.id == modelId }) else {
                throw ToolError("Unknown model '\(modelId)'. Available: \(VideoModelConfig.allModels.map(\.id).joined(separator: ", "))")
            }
            let initialTarget = productionRouting?.selection.target
                ?? GenerationService.dispatchTarget(
                    modelId: model.id,
                    requiringSourceVideo: args.string("sourceVideoMediaRef") != nil
                )
            guard let offeringCapabilities = initialTarget.binding?
                    .resolvedVideoCapabilities else {
                throw ToolError(
                    "The selected provider endpoint has no versioned video capability contract."
                )
            }
            let inputPolicy = offeringCapabilities.inputPolicy
            try await enforceVideoShotSourceContract(
                editor: editor,
                args: args,
                requiresSourceVideo: inputPolicy.requiresSourceVideo
            )
            return inputPolicy.requiresSourceVideo
                ? try await generateVideoEdit(
                    editor, args, prompt: prompt, model: model,
                    offeringCapabilities: offeringCapabilities,
                    initialTarget: initialTarget,
                    productionRouting: productionRouting,
                    origin: origin
                )
                : try await generateVideoText(
                    editor, args, prompt: prompt, model: model,
                    offeringCapabilities: offeringCapabilities,
                    initialTarget: initialTarget,
                    productionRouting: productionRouting,
                    origin: origin
                )
        case .image:
            try enforceImageShotSourceContract(editor: editor, args: args)
            return try await generateImage(editor, args, prompt: prompt, origin: origin)
        case .audio:
            throw ToolError("internal: audio generation is dispatched via the async path")
        case .text:
            throw ToolError("Text generation is not wired through the generate tool.")
        case .lottie:
            throw ToolError("Lottie animations aren't generated through this tool.")
        case .document:
            throw ToolError("Documents are source material you import, not something this tool generates.")
        }
    }

    private func enforceImageShotSourceContract(
        editor: EditorViewModel,
        args: [String: Any]
    ) throws {
        let shotId = try args.requireString("shotId")
        guard shotId != "none" else { return }
        guard let root = editor.workingRoot.flatMap({
            DataRootResolver.dataRoot(of: $0)
        }), let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil,
              let shot = shotlist.shots.first(where: { $0.id == shotId }) else {
            throw ToolError(
                "Shot-bound generation requires the current project shotlist."
            )
        }
        try PromptCompiler.validateImageShotSourceContract(
            sourceMode: shot.sourceMode
        )
    }

    private func enforceVideoShotSourceContract(
        editor: EditorViewModel,
        args: [String: Any],
        requiresSourceVideo: Bool
    ) async throws {
        let shotId = try args.requireString("shotId")
        guard shotId != "none" else { return }
        guard let root = editor.workingRoot.flatMap({
            DataRootResolver.dataRoot(of: $0)
        }), let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil,
              let shot = shotlist.shots.first(where: { $0.id == shotId }) else {
            throw ToolError(
                "Shot-bound generation requires the current project shotlist."
            )
        }
        let submittedSourceId = args.string("sourceVideoMediaRef")
        let expectedSourceId: String?
        if shot.sourceMode == .aiEnhanced {
            guard let sourcePath = shot.sourcePath,
                  let source = await resolveRenderedAsset(
                      sourcePath,
                      editor: editor,
                      dataRoot: root
                  ) else {
                throw ToolError(
                    "Shot '\(shotId)' has no current project-local source_path."
                )
            }
            expectedSourceId = source.id
        } else {
            expectedSourceId = nil
        }
        try Self.validateVideoShotSourceContract(
            sourceMode: shot.sourceMode,
            modelRequiresSourceVideo: requiresSourceVideo,
            submittedSourceId: submittedSourceId,
            expectedSourceId: expectedSourceId
        )
    }

    nonisolated static func validateVideoShotSourceContract(
        sourceMode: SourceMode,
        modelRequiresSourceVideo: Bool,
        submittedSourceId: String?,
        expectedSourceId: String?
    ) throws {
        switch sourceMode {
        case .aiEnhanced:
            guard modelRequiresSourceVideo,
                  let expectedSourceId,
                  submittedSourceId == expectedSourceId else {
                throw ToolError(
                    "AI-enhanced generation must use the exact source_path media "
                        + "returned by next_render_shot with a source-video model."
                )
            }
        case .generated:
            guard !modelRequiresSourceVideo, submittedSourceId == nil else {
                throw ToolError(
                    "Generated shots cannot select source footage. Declare an "
                        + "AI-enhanced shot with source_path instead."
                )
            }
        case .imported:
            throw ToolError(
                "Imported shots use their existing footage and cannot run generate_video."
            )
        }
    }

    /// Turn a `GenerationController` result into the tool's `.ok`/error surface, reusing the same
    /// error copy the surfaces used before (the gate/compile messages come straight through).
    private func routeThroughController(
        _ request: GenerationRequest, editor: EditorViewModel,
        preflight: GenerationController.Preflight? = nil,
        success: @escaping (String) -> String
    ) async throws -> ToolResult {
        let result = try await AgentGenerationAwaiter.waitForSubmission(
            start: { awaiter in
                let submission = await GenerationController.submit(
                    request,
                    editor: editor,
                    preflight: preflight,
                    onSuccess: { asset in awaiter.resolve(.succeeded(asset)) },
                    onFailure: { awaiter.resolve(.failed(nil)) }
                )
                switch submission {
                case .failure(let error):
                    throw ToolError(error.errorDescription ?? "Generation failed.")
                case .success(let outcome):
                    return outcome.placeholderId
                }
            }, cancel: { placeholderId in
                editor.generationService.cancelGeneration(placeholderId: placeholderId)
            }
        )
        switch result.completion {
        case .failed(let explicitMessage):
            let message = explicitMessage ?? editor.mediaAssets.first(where: {
                $0.id == result.placeholderId
            }).flatMap { asset -> String? in
                guard case .failed(let message) = asset.generationStatus else { return nil }
                return message
            } ?? "The provider did not return a usable result."
            throw ToolError(message)
        case .succeeded(let asset):
            return try await Self.completedGenerationResult(
                text: success(result.placeholderId),
                asset: request.modality == .image ? asset : nil
            )
        }
    }

    private static func completedGenerationResult(
        text: String,
        asset: MediaAsset?
    ) async throws -> ToolResult {
        var content: [ToolResult.Block] = [.text(text)]
        if let asset {
            let url = asset.url
            let encodedResult = await Task.detached(priority: .utility) {
                ImageEncoder.encode(url: url)
            }.value
            guard let encoded = encodedResult else {
                throw ToolError(
                    "The image was generated and saved as '\(asset.name)', but NexGenVideo could not decode it for the agent transcript. Open it from Media before continuing."
                )
            }
            content.append(.image(
                base64: encoded.data.base64EncodedString(),
                mediaType: encoded.mime
            ))
        }
        return ToolResult(content: content, isError: false)
    }

    /// The agent's precompiled prompt (from compile_prompt) + token, or nil for the raw-prompt escape.
    private static func agentPrompt(
        _ args: [String: Any],
        prompt: String,
        modality: PromptComposer.Modality,
        editor: EditorViewModel
    ) throws -> (
        precompiled: (text: String, token: String, binding: PromptBinding)?,
        raw: Bool
    ) {
        let shotId = try args.requireString("shotId")
        if args.bool("rawPrompt") == true {
            guard shotId == "none" else {
                throw ToolError(
                    "Raw prompts cannot render a pipeline shot. Compile the current shot first."
                )
            }
            return (nil, true)
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard shotId == "none" else {
                throw ToolError(
                    "A shot-bound generation requires a compiled prompt."
                )
            }
            return (nil, false)
        }
        let binding = try PromptCompiler.currentBinding(
            editor: editor,
            shotId: shotId,
            modality: modality
        )
        return ((
            text: prompt,
            token: args.string("compileToken") ?? "",
            binding: binding
        ), false)
    }

    // MARK: - Cost-Guard (M7) — the user's final word on paid agent renders

    @MainActor
    private func withSpendApproval(
        _ editor: EditorViewModel, currentModelId: String, currentModelName: String,
        credits: Int?, actionLabel: String,
        pipelineTool: ToolName,
        origin: ToolCallOrigin,
        currentIsCompatible: Bool = true,
        noCompatibleModelReason: String? = nil,
        alternatives: @escaping @MainActor () -> [SpendModelCandidate],
        exactOptions: (@MainActor () -> [SpendOption])? = nil,
        recommendedTarget: ResolvedGenerationTarget? = nil,
        targetIsCompatible: @escaping @MainActor (ResolvedGenerationTarget) -> Bool = { _ in true },
        diagnosticProviderScope: @escaping @MainActor () -> [GenerationProvider] = { [] },
        cancel: @escaping @MainActor (EditorViewModel) -> Void = { _ in },
        execute: @escaping @MainActor (EditorViewModel, SpendOption) async throws -> ToolResult
    ) async throws -> ToolResult {
        func currentOptions() -> [SpendOption] {
            if let exactOptions {
                return exactOptions().filter { targetIsCompatible($0.target) }
            }
            let current = currentIsCompatible ? [SpendModelCandidate(
                modelId: currentModelId, modelName: currentModelName, credits: credits
            )] : []
            return SpendOptionBuilder.options(
                candidates: current + alternatives(),
                isModelAvailable: {
                    ModelRegistry.exists(id: $0) && ModelPreferences.shared.isEnabled($0)
                },
                runnableBindings: { modelID in
                    ProviderManifest.runnableBindingsByProvider(
                        forModelId: modelID,
                        matching: { binding in
                            targetIsCompatible(ResolvedGenerationTarget(
                                modelId: modelID,
                                provider: binding.provider,
                                endpoint: binding.providerRef,
                                binding: binding
                            ))
                        }
                    )
                }
            ).filter { targetIsCompatible($0.target) }
        }
        let options = currentOptions()
        let defaultTarget = recommendedTarget
            ?? GenerationService.dispatchTarget(modelId: currentModelId)
        guard let recommended = SpendOptionBuilder.recommended(
            from: options,
            currentModelId: currentModelId,
            defaultTarget: defaultTarget
        ) else {
            throw ToolError(
                noCompatibleModelReason
                    ?? "No enabled model is available through an active provider for this request. Choose a runnable model from list_models."
            )
        }
        guard CostGuard.needsApproval(credits: recommended.credits) else {
            do {
                return try await execute(editor, recommended)
            } catch {
                cancel(editor)
                throw error
            }
        }
        let approvalID = UUID().uuidString
        var providerScope = Set(options.map(\.target.provider))
        providerScope.formUnion(diagnosticProviderScope())
        func makeApproval() -> SpendApproval {
            let latest = currentOptions()
            providerScope.formUnion(latest.map(\.target.provider))
            providerScope.formUnion(diagnosticProviderScope())
            let latestRecommended = SpendOptionBuilder.recommended(
                from: latest,
                currentModelId: currentModelId,
                defaultTarget: recommendedTarget
                    ?? GenerationService.dispatchTarget(modelId: currentModelId)
            )
            let ordered = latestRecommended.map { option in
                [option] + latest.filter { $0.id != option.id }
            } ?? []
            return SpendApproval(
                id: approvalID,
                recommendedOptionId: latestRecommended?.id ?? "",
                options: ordered,
                actionLabel: actionLabel,
                providerScope: GenerationProvider.allCases.filter {
                    providerScope.contains($0)
                }
            )
        }
        return try editor.agentService.requestSpendApproval(
            makeApproval(),
            origin: origin,
            editor: editor,
            pipelineScope: try spendPipelineScope(
                tool: pipelineTool,
                editor: editor
            ),
            refresh: makeApproval,
            cancel: cancel,
            execute: execute
        )
    }

    @MainActor
    private func activeImageProviderScope() -> [GenerationProvider] {
        ModelCatalog.shared.activeImageProviderScope()
    }

    @MainActor
    private func cheaperVideoAlternatives(
        than modelId: String,
        currentCredits: Int?,
        duration: Int,
        resolution: String?,
        requiresSource: Bool,
        generateAudio: Bool,
        isCompatible: (VideoModelConfig) -> Bool
    ) -> [SpendModelCandidate] {
        guard let current = currentCredits else { return [] }
        return VideoModelConfig.allModels
            .filter {
                $0.id != modelId
                    && ModelPreferences.shared.isEnabled($0.id)
                    && GenerationProvider.canRun(modelId: $0.id)
                    && ProviderManifest.runnableBindingsByProvider(
                        forModelId: $0.id,
                        matching: { binding in
                            guard let capabilities = binding.resolvedVideoCapabilities else {
                                return false
                            }
                            return capabilities.inputPolicy.requiresSourceVideo == requiresSource
                                && (!generateAudio || capabilities.supportsNativeAudio)
                        }
                    ).isEmpty == false
                    && isCompatible($0)
            }
            .compactMap { m -> SpendModelCandidate? in
                guard let c = CostEstimator.videoCost(
                    model: m, durationSeconds: duration,
                    resolution: resolution ?? m.resolutions?.first,
                    generateAudio: generateAudio),
                    c < current else { return nil }
                return SpendModelCandidate(
                    modelId: m.id,
                    modelName: m.displayName,
                    credits: c
                )
            }
            .sorted { ($0.credits ?? 0) < ($1.credits ?? 0) }
            .prefix(3).map { $0 }
    }

    @MainActor
    private func availableImageOfferings(
        preferredModelID: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        referenceCount: Int
    ) -> [CatalogImageOfferingCandidate] {
        ModelCatalog.shared.compatibleImageOfferings(
            preferredModelID: preferredModelID,
            aspectRatio: aspectRatio,
            resolution: resolution,
            quality: quality,
            referenceCount: referenceCount
        )
    }

    private func availableImageSpendOptions(
        preferredModelID: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        referenceCount: Int
    ) -> [SpendOption] {
        availableImageOfferings(
            preferredModelID: preferredModelID,
            aspectRatio: aspectRatio,
            resolution: resolution,
            quality: quality,
            referenceCount: referenceCount
        ).map { candidate in
            SpendOption(
                modelId: candidate.model.id,
                modelName: candidate.model.displayName,
                target: candidate.target,
                credits: CostEstimator.imageCost(
                    model: candidate.model,
                    resolution: candidate.resolution,
                    quality: candidate.quality,
                    numImages: 1
                ),
                requiresCatalogAvailability: true
            )
        }
    }

    private static func sameImageOffering(
        _ candidate: CatalogImageOfferingCandidate,
        as target: ResolvedGenerationTarget
    ) -> Bool {
        guard let candidateBinding = candidate.target.binding,
              let targetBinding = target.binding else { return false }
        return candidate.model.id == target.modelId
            && candidateBinding.provider == targetBinding.provider
            && candidateBinding.transport == targetBinding.transport
            && candidateBinding.kind == targetBinding.kind
            && candidateBinding.providerRef == targetBinding.providerRef
            && candidateBinding.modelParam == targetBinding.modelParam
            && candidateBinding.mcpMediaRoles == targetBinding.mcpMediaRoles
    }

    @MainActor
    private func promptForApprovedModel(
        _ precompiled: (text: String, token: String, binding: PromptBinding)?,
        originalModelId: String,
        approvedModelId: String,
        approvedTarget: ResolvedGenerationTarget? = nil,
        editor: EditorViewModel
    ) async throws -> (text: String, token: String, binding: PromptBinding)? {
        guard let precompiled else { return nil }
        let currentBinding = try PromptCompiler.currentBinding(
            editor: editor,
            shotId: precompiled.binding.shotId,
            modality: PromptCompiler.modalityForModel(approvedModelId)
        )
        let preserveComposition = approvedTarget?.binding?
            .resolvedVideoCapabilities?.inputPolicy.requiresSourceVideo
        let compositionModeMatches = preserveComposition.map {
            PromptCompiler.rememberedCompositionModeMatches(
                token: precompiled.token,
                text: precompiled.text,
                modelId: approvedModelId,
                preserveComposition: $0
            )
        } ?? true
        guard approvedModelId != originalModelId
                || currentBinding != precompiled.binding
                || !compositionModeMatches else {
            return precompiled
        }
        let compiled = try await PromptCompiler.recompile(
            token: precompiled.token,
            text: precompiled.text,
            for: approvedModelId,
            editor: editor,
            allowCurrentRoutingChange: true,
            preserveCompositionOverride: preserveComposition
        )
        return (compiled.text, compiled.token, compiled.binding)
    }

    private func generateVideoEdit(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model modelIn: VideoModelConfig,
        offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1,
        initialTarget: ResolvedGenerationTarget,
        productionRouting: (
            selection: PipelineProductionRouteSelection,
            dataRoot: URL
        )?,
        origin: ToolCallOrigin
    ) async throws -> ToolResult {
        let model = modelIn
        guard let sourceRef = args.string("sourceVideoMediaRef") else {
            throw ToolError("Model '\(model.id)' requires 'sourceVideoMediaRef' pointing to a video asset.")
        }
        let sourceAsset = try asset(sourceRef, editor: editor, label: "Source video")
        let trimmed = try trimmedSource(args, editor: editor, source: sourceAsset)
        if productionRouting != nil, trimmed != nil {
            throw ToolError(
                "Pipeline source-video routing requires the exact source asset; a clip trim "
                    + "is not part of the ProductionRequirement."
            )
        }
        let (precompiled, raw) = try Self.agentPrompt(
            args,
            prompt: prompt,
            modality: .video,
            editor: editor
        )

        var imageRefs: [MediaAsset] = []
        for id in args.stringArray("referenceImageMediaRefs") {
            imageRefs.append(try asset(id, editor: editor, label: "Reference image"))
        }

        let submittedInputAssets = VideoGenerationSubmission.InputAssets(
            sourceVideo: sourceAsset,
            imageRefs: imageRefs
        )
        let routedInputs: ProductionVideoGenerationInputs?
        if let productionRouting {
            let resolvedInputs = try await productionVideoInputs(
                selection: productionRouting.selection,
                editor: editor,
                dataRoot: productionRouting.dataRoot
            )
            try Self.validateProductionArguments(
                args,
                against: resolvedInputs.assets
            )
            routedInputs = resolvedInputs
        } else {
            routedInputs = nil
        }
        let inputAssets = routedInputs?.assets ?? submittedInputAssets
        let editSeconds = Int((trimmed?.durationSeconds ?? sourceAsset.duration).rounded())
        let editDuration = VideoDuration.seconds(editSeconds)
        let editAspectRatio = productionRouting?.selection.requirement.aspectRatio
            ?? args.string("aspectRatio") ?? ""
        let editResolution = productionRouting?.selection.requirement.resolution
            ?? args.string("resolution")
        if let productionRouting {
            try Self.validateProductionOutput(
                duration: editDuration,
                aspectRatio: editAspectRatio,
                resolution: editResolution,
                requirement: productionRouting.selection.requirement
            )
        }
        let initialCapabilities = routedInputs?.offeringCapabilities
            ?? offeringCapabilities
        let requestedGenerateAudio = productionRouting?.selection.requirement
            .requiresOutputAudio ?? initialCapabilities.supportsNativeAudio
        if let error = initialCapabilities.validate(
            duration: editDuration,
            aspectRatio: editAspectRatio,
            resolution: editResolution,
            generateAudio: requestedGenerateAudio,
            displayName: model.displayName
        ) ?? inputAssets.validate(
            for: model,
            offeringCapabilities: initialCapabilities
        ) {
            throw ToolError(error)
        }
        let editCredits = CostEstimator.videoCost(
            model: model,
            durationSeconds: editSeconds,
            resolution: editResolution,
            generateAudio: requestedGenerateAudio
        )
        let originalModelId = model.id
        let exactOptions: (@MainActor () -> [SpendOption])?
        if let productionRouting {
            exactOptions = {
                self.productionSpendOptions(
                    shotID: productionRouting.selection.route.shotID,
                    dataRoot: productionRouting.dataRoot,
                    durationSeconds: editSeconds,
                    resolution: editResolution
                )
            }
        } else {
            exactOptions = nil
        }
        return try await withSpendApproval(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: editCredits, actionLabel: "Generate edit",
            pipelineTool: .generateVideo,
            origin: origin,
            alternatives: { self.cheaperVideoAlternatives(
                than: model.id,
                currentCredits: editCredits,
                duration: editSeconds,
                resolution: editResolution,
                requiresSource: true,
                generateAudio: requestedGenerateAudio,
                isCompatible: { _ in true }
            ) },
            exactOptions: exactOptions,
            recommendedTarget: initialTarget,
            targetIsCompatible: { target in
                guard let capabilities = target.binding?.resolvedVideoCapabilities,
                      capabilities.inputPolicy.requiresSourceVideo else { return false }
                guard let candidate = VideoModelConfig.allModels.first(where: {
                    $0.id == target.modelId
                }) else { return false }
                return inputAssets.validate(
                    for: candidate,
                    offeringCapabilities: capabilities
                ) == nil && capabilities.validate(
                    duration: editDuration,
                    aspectRatio: editAspectRatio,
                    resolution: editResolution,
                    generateAudio: requestedGenerateAudio,
                    displayName: candidate.displayName
                ) == nil
            },
            execute: { editor, approved in
                let selectedRouting: PipelineProductionRouteSelection?
                let selectedInputs: ProductionVideoGenerationInputs?
                if let productionRouting {
                    let declaration = try self.mutationPackDeclaration(
                        editor,
                        dataRoot: productionRouting.dataRoot
                    )
                    let resolvedRouting = try PipelineProductionRouting.resolveAndWrite(
                        shotID: productionRouting.selection.route.shotID,
                        dataRoot: productionRouting.dataRoot,
                        target: approved.target,
                        activation: self.providerActivation(),
                        candidateProvider: self.productionRouteCandidates,
                        declaredPack: declaration.packName,
                        declaredBinding: declaration.binding
                    )
                    selectedRouting = resolvedRouting
                    selectedInputs = try await self.productionVideoInputs(
                        selection: resolvedRouting,
                        editor: editor,
                        dataRoot: productionRouting.dataRoot
                    )
                } else {
                    selectedRouting = nil
                    selectedInputs = nil
                }
                guard let finalModel = VideoModelConfig.allModels.first(where: {
                    $0.id == approved.modelId
                }) else {
                    throw ToolError("The approved video model is no longer available.")
                }
                guard let finalCapabilities = approved.target.binding?
                        .resolvedVideoCapabilities,
                      finalCapabilities.inputPolicy.requiresSourceVideo,
                      selectedInputs.map({
                          $0.offeringCapabilities == finalCapabilities
                      }) ?? true else {
                    throw ToolError(
                        "The approved provider endpoint no longer matches the source-video request."
                    )
                }
                let finalInputAssets = selectedInputs?.assets ?? inputAssets
                guard let finalSourceAsset = finalInputAssets.sourceVideo else {
                    throw ToolError("The approved route no longer has its required source video.")
                }
                let approvedPrompt = try await self.promptForApprovedModel(
                    precompiled,
                    originalModelId: originalModelId,
                    approvedModelId: finalModel.id,
                    approvedTarget: approved.target,
                    editor: editor
                )
                let name = args.string("name")
                let folderId = finalSourceAsset.folderId
                let finalTrimmed = selectedRouting == nil ? trimmed : nil
                let placeholderDuration = finalTrimmed?.durationSeconds
                    ?? (finalSourceAsset.duration > 0 ? finalSourceAsset.duration : 5)
                let finalDuration = VideoDuration.seconds(
                    Int((finalTrimmed?.durationSeconds ?? finalSourceAsset.duration).rounded())
                )
                let finalSeconds = finalDuration.seconds ?? 0
                let finalAspectRatio = selectedRouting?.requirement.aspectRatio
                    ?? editAspectRatio
                let finalResolution = selectedRouting?.requirement.resolution
                    ?? editResolution
                if let selectedRouting {
                    try Self.validateProductionOutput(
                        duration: finalDuration,
                        aspectRatio: finalAspectRatio,
                        resolution: finalResolution,
                        requirement: selectedRouting.requirement
                    )
                }
                let request = GenerationRequest(
                    modality: .video, modelId: finalModel.id, intent: prompt,
                    aspectRatio: finalAspectRatio,
                    durationSeconds: Double(finalSeconds),
                    placement: .mediaLibrary(folderId: folderId), origin: .agentTool,
                    target: approved.target,
                    precompiled: approvedPrompt, rawPrompt: raw,
                    submission: .video(make: { compiled in
                        var genInput = GenerationInput(
                            prompt: compiled, model: finalModel.id,
                            duration: finalSeconds,
                            aspectRatio: finalAspectRatio,
                            resolution: finalResolution)
                        genInput.videoDuration = finalDuration
                        genInput.promptShotId = approvedPrompt?.binding.shotId
                        genInput.promptProjectKey = approvedPrompt?.binding.projectKey
                        genInput.promptShotFingerprint = approvedPrompt?.binding.shotFingerprint
                        genInput.productionRouting = selectedInputs?.routingProof
                        return VideoGenerationSubmission.make(
                            genInput: genInput, model: finalModel,
                            offeringCapabilities: finalCapabilities,
                            inputAssets: finalInputAssets,
                            placeholderDuration: placeholderDuration,
                            trimmedSourceOverride: finalTrimmed,
                            name: name, folderId: folderId,
                            generateAudio: requestedGenerateAudio)
                    }))
                return try await self.routeThroughController(
                    request, editor: editor,
                    preflight: {
                        if let err = finalCapabilities.validate(
                            duration: finalDuration,
                            aspectRatio: finalAspectRatio,
                            resolution: finalResolution,
                            generateAudio: requestedGenerateAudio,
                            displayName: finalModel.displayName
                        ) { return err }
                        return finalInputAssets.validate(
                            for: finalModel,
                            offeringCapabilities: finalCapabilities
                        )
                    },
                    success: {
                        "Edit completed. Asset ID: \($0). Model: \(finalModel.displayName), source: \(finalSourceAsset.name)"
                    })
            }
        )
    }

    private func generateVideoText(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model modelIn: VideoModelConfig,
        offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1,
        initialTarget: ResolvedGenerationTarget,
        productionRouting: (
            selection: PipelineProductionRouteSelection,
            dataRoot: URL
        )?,
        origin: ToolCallOrigin
    ) async throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }

        let model = modelIn
        var duration: VideoDuration
        if let raw = args["duration"] as? String {
            guard raw.lowercased() == "auto" else {
                throw ToolError("duration must be an integer number of seconds or 'auto'")
            }
            duration = .automatic
        } else if let seconds = args.int("duration") {
            duration = .seconds(seconds)
        } else {
            duration = offeringCapabilities.durationCapabilities.defaultValue
        }
        let billedDuration = duration.seconds
            ?? offeringCapabilities.durationCapabilities.maximumSeconds ?? 0
        let aspectRatio = args.string("aspectRatio")
            ?? offeringCapabilities.aspectRatios.first ?? ""
        let resolution = args.string("resolution")
            ?? offeringCapabilities.resolutions?.first
        let (precompiled, raw) = try Self.agentPrompt(
            args,
            prompt: prompt,
            modality: .video,
            editor: editor
        )

        var frameSlots: [MediaAsset] = []
        if let startRef = args.string("startFrameMediaRef") {
            frameSlots.append(try asset(startRef, editor: editor, label: "Start frame"))
        }
        if let endRef = args.string("endFrameMediaRef") {
            frameSlots.append(try asset(endRef, editor: editor, label: "End frame"))
        }

        func refs(_ argName: String, label: String) throws -> [MediaAsset] {
            try args.stringArray(argName).map { id in
                try asset(id, editor: editor, label: label)
            }
        }
        let imageRefs = try refs("referenceImageMediaRefs", label: "Image reference")
        let videoRefs = try refs("referenceVideoMediaRefs", label: "Video reference")
        let audioRefs = try refs("referenceAudioMediaRefs", label: "Audio reference")
        let submittedInputAssets = VideoGenerationSubmission.InputAssets(
            frames: frameSlots,
            imageRefs: imageRefs,
            videoRefs: videoRefs,
            audioRefs: audioRefs
        )
        let routedInputs: ProductionVideoGenerationInputs?
        if let productionRouting {
            try Self.validateProductionOutput(
                duration: duration,
                aspectRatio: aspectRatio,
                resolution: resolution,
                requirement: productionRouting.selection.requirement
            )
            let resolvedInputs = try await productionVideoInputs(
                selection: productionRouting.selection,
                editor: editor,
                dataRoot: productionRouting.dataRoot
            )
            try Self.validateProductionArguments(
                args,
                against: resolvedInputs.assets
            )
            routedInputs = resolvedInputs
        } else {
            routedInputs = nil
        }
        let inputAssets = routedInputs?.assets ?? submittedInputAssets
        let initialCapabilities = routedInputs?.offeringCapabilities
            ?? offeringCapabilities
        let requestedGenerateAudio = productionRouting?.selection.requirement
            .requiresOutputAudio ?? initialCapabilities.supportsNativeAudio
        if let error = initialCapabilities.validate(
            duration: duration,
            aspectRatio: aspectRatio,
            resolution: resolution,
            generateAudio: requestedGenerateAudio,
            displayName: model.displayName
        ) ?? inputAssets.validate(
            for: model,
            offeringCapabilities: initialCapabilities
        ) {
            throw ToolError(error)
        }

        let credits = CostEstimator.videoCost(
            model: model,
            durationSeconds: billedDuration,
            resolution: resolution,
            generateAudio: requestedGenerateAudio
        )
        let originalModelId = model.id
        let exactOptions: (@MainActor () -> [SpendOption])?
        if let productionRouting {
            exactOptions = {
                self.productionSpendOptions(
                    shotID: productionRouting.selection.route.shotID,
                    dataRoot: productionRouting.dataRoot,
                    durationSeconds: billedDuration,
                    resolution: resolution
                )
            }
        } else {
            exactOptions = nil
        }
        return try await withSpendApproval(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: credits, actionLabel: "Generate video",
            pipelineTool: .generateVideo,
            origin: origin,
            alternatives: { self.cheaperVideoAlternatives(
                than: model.id,
                currentCredits: credits,
                duration: billedDuration,
                resolution: resolution,
                requiresSource: false,
                generateAudio: requestedGenerateAudio,
                isCompatible: { _ in true }
            ) },
            exactOptions: exactOptions,
            recommendedTarget: initialTarget,
            targetIsCompatible: { target in
                guard let capabilities = target.binding?.resolvedVideoCapabilities,
                      !capabilities.inputPolicy.requiresSourceVideo else { return false }
                guard productionRouting == nil else { return true }
                guard let candidate = VideoModelConfig.allModels.first(where: {
                    $0.id == target.modelId
                }) else { return false }
                let candidateDuration = capabilities.durationCapabilities.accepts(duration)
                    ? duration
                    : capabilities.durationCapabilities.defaultValue
                let candidateAspect = capabilities.aspectRatios.contains(aspectRatio)
                    ? aspectRatio
                    : (capabilities.aspectRatios.first ?? aspectRatio)
                let candidateResolution = capabilities.resolutions.map { allowed in
                    resolution.flatMap { allowed.contains($0) ? $0 : nil }
                        ?? allowed.first
                } ?? resolution
                return inputAssets.validate(
                    for: candidate,
                    offeringCapabilities: capabilities
                ) == nil && capabilities.validate(
                    duration: candidateDuration,
                    aspectRatio: candidateAspect,
                    resolution: candidateResolution,
                    generateAudio: requestedGenerateAudio,
                    displayName: candidate.displayName
                ) == nil
            },
            execute: { editor, approved in
                let selectedRouting: PipelineProductionRouteSelection?
                let selectedInputs: ProductionVideoGenerationInputs?
                if let productionRouting {
                    let declaration = try self.mutationPackDeclaration(
                        editor,
                        dataRoot: productionRouting.dataRoot
                    )
                    let resolvedRouting = try PipelineProductionRouting.resolveAndWrite(
                        shotID: productionRouting.selection.route.shotID,
                        dataRoot: productionRouting.dataRoot,
                        target: approved.target,
                        activation: self.providerActivation(),
                        candidateProvider: self.productionRouteCandidates,
                        declaredPack: declaration.packName,
                        declaredBinding: declaration.binding
                    )
                    selectedRouting = resolvedRouting
                    selectedInputs = try await self.productionVideoInputs(
                        selection: resolvedRouting,
                        editor: editor,
                        dataRoot: productionRouting.dataRoot
                    )
                } else {
                    selectedRouting = nil
                    selectedInputs = nil
                }
                guard let selectedModel = VideoModelConfig.allModels.first(where: {
                    $0.id == approved.modelId
                }) else {
                    throw ToolError("The approved video model is no longer available.")
                }
                guard let finalCapabilities = approved.target.binding?
                        .resolvedVideoCapabilities,
                      !finalCapabilities.inputPolicy.requiresSourceVideo,
                      selectedInputs.map({
                          $0.offeringCapabilities == finalCapabilities
                      }) ?? true else {
                    throw ToolError(
                        "The approved provider endpoint no longer matches the video input request."
                    )
                }
                var selectedDuration = duration
                var selectedBilledDuration = billedDuration
                var selectedAspectRatio = aspectRatio
                var selectedResolution = resolution
                if selectedRouting == nil {
                    if !finalCapabilities.durationCapabilities.accepts(selectedDuration) {
                        selectedDuration = finalCapabilities.durationCapabilities.defaultValue
                        selectedBilledDuration = selectedDuration.seconds
                            ?? finalCapabilities.durationCapabilities.maximumSeconds ?? 0
                    }
                    if !finalCapabilities.aspectRatios.contains(selectedAspectRatio) {
                        selectedAspectRatio = finalCapabilities.aspectRatios.first
                            ?? selectedAspectRatio
                    }
                    if let allowed = finalCapabilities.resolutions,
                       let selected = selectedResolution,
                       !allowed.contains(selected) {
                        selectedResolution = allowed.first
                    }
                }
                if let selectedRouting {
                    try Self.validateProductionOutput(
                        duration: selectedDuration,
                        aspectRatio: selectedAspectRatio,
                        resolution: selectedResolution,
                        requirement: selectedRouting.requirement
                    )
                }
                let finalInputAssets = selectedInputs?.assets ?? inputAssets
                let approvedPrompt = try await self.promptForApprovedModel(
                    precompiled,
                    originalModelId: originalModelId,
                    approvedModelId: selectedModel.id,
                    approvedTarget: approved.target,
                    editor: editor
                )
                let folderId = try self.resolveFolderId(
                    args,
                    editor: editor,
                    fallbackReferences: finalInputAssets.textToVideoReferences
                )
                let name = args.string("name")
                let finalModel = selectedModel
                let finalDuration = selectedDuration
                let finalBilledDuration = selectedBilledDuration
                let finalAspectRatio = selectedAspectRatio
                let finalResolution = selectedResolution
                let request = GenerationRequest(
                    modality: .video, modelId: finalModel.id, intent: prompt,
                    aspectRatio: finalAspectRatio,
                    durationSeconds: Double(finalBilledDuration),
                    placement: .mediaLibrary(folderId: folderId), origin: .agentTool,
                    target: approved.target,
                    precompiled: approvedPrompt, rawPrompt: raw,
                    submission: .video(make: { compiled in
                        var genInput = GenerationInput(
                            prompt: compiled, model: finalModel.id,
                            duration: finalBilledDuration,
                            aspectRatio: finalAspectRatio, resolution: finalResolution)
                        genInput.videoDuration = finalDuration
                        genInput.promptShotId = approvedPrompt?.binding.shotId
                        genInput.promptProjectKey = approvedPrompt?.binding.projectKey
                        genInput.promptShotFingerprint = approvedPrompt?.binding.shotFingerprint
                        genInput.productionRouting = selectedInputs?.routingProof
                        return VideoGenerationSubmission.make(
                            genInput: genInput, model: finalModel,
                            offeringCapabilities: finalCapabilities,
                            inputAssets: finalInputAssets,
                            placeholderDuration: Double(max(1, finalBilledDuration)),
                            name: name, folderId: folderId,
                            generateAudio: requestedGenerateAudio)
                    }))
                let refSummary = finalInputAssets.totalRefCount > 0
                    ? ", refs: \(finalInputAssets.imageRefs.count)img/"
                        + "\(finalInputAssets.videoRefs.count)vid/"
                        + "\(finalInputAssets.audioRefs.count)aud"
                    : ""
                return try await self.routeThroughController(
                    request, editor: editor,
                    preflight: {
                        if let err = finalCapabilities.validate(
                            duration: finalDuration,
                            aspectRatio: finalAspectRatio,
                            resolution: finalResolution,
                            generateAudio: requestedGenerateAudio,
                            displayName: finalModel.displayName
                        ) { return err }
                        return finalInputAssets.validate(
                            for: finalModel,
                            offeringCapabilities: finalCapabilities
                        )
                    },
                    success: {
                        "Generation completed. Asset ID: \($0). Model: \(finalModel.displayName), duration: \(finalDuration.displayLabel), aspect: \(finalAspectRatio)\(refSummary)"
                    })
            }
        )
    }

    private func generateImage(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String,
        origin: ToolCallOrigin
    ) async throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }
        await CatalogDiscovery.ensureCurrent()
        guard let modelId = args.string("model").map({ ModelCatalog.shared.internalId(forLogical: $0) }) ?? ImageModelConfig.allModels.first?.id else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let model = ImageModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(ImageModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        let resolution = args.string("resolution") ?? model.resolutions?.first
        let quality = args.string("quality") ?? model.qualities?.last
        let (precompiled, raw) = try Self.agentPrompt(
            args,
            prompt: prompt,
            modality: .image,
            editor: editor
        )
        let refIds = args.stringArray("referenceMediaRefs")
        let libraryRefs: [MediaAsset] = try refIds.map { id in
            let a = try asset(id, editor: editor, label: "Reference image")
            guard a.type == .image else {
                throw ToolError("referenceMediaRefs entry '\(id)' must be an image asset (got \(a.type.rawValue))")
            }
            return a
        }
        let requestedProjectPaths = args.stringArray("referenceProjectPaths")
        let productionDesignSnapshot: ProductionDesignReferenceSnapshot?
        let productionDesignDataRoot: URL?
        if let workingRoot = editor.workingRoot,
           let dataRoot = DataRootResolver.dataRoot(of: workingRoot),
           try currentPhaseIfEnforced(
               tool: .generateImage,
               editor: editor,
               dataRoot: dataRoot
           ) == "production_design" {
            productionDesignSnapshot = try Self.productionDesignReferenceSnapshot(
                dataRoot: dataRoot
            )
            productionDesignDataRoot = dataRoot.standardizedFileURL
                .resolvingSymlinksInPath()
        } else {
            productionDesignSnapshot = nil
            productionDesignDataRoot = nil
        }
        let projectPaths = productionDesignSnapshot?.paths ?? requestedProjectPaths
        let projectRefs = try projectImageReferences(projectPaths, editor: editor)
        let effectiveLibraryRefs = productionDesignSnapshot == nil ? libraryRefs : []
        let refs = effectiveLibraryRefs + projectRefs
        let currentValidation = model.validate(
            aspectRatio: aspectRatio,
            resolution: resolution,
            quality: quality,
            imageRefCount: refs.count,
            numImages: 1
        )
        let isMarble = MarbleModelRegistry.isMarbleModel(model.id)
        if isMarble, refs.isEmpty {
            throw ToolError(
                "\(model.displayName) requires a reference image via 'referenceMediaRefs'."
            )
        }
        let credits = CostEstimator.imageCost(
            model: model, resolution: resolution, quality: quality, numImages: 1)
        let originalModelId = model.id
        let exactImageOptions: (@MainActor () -> [SpendOption])?
        if isMarble {
            exactImageOptions = nil
        } else {
            exactImageOptions = {
                self.availableImageSpendOptions(
                    preferredModelID: model.id,
                    aspectRatio: aspectRatio,
                    resolution: resolution,
                    quality: quality,
                    referenceCount: refs.count
                )
            }
        }
        return try await withSpendApproval(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: credits, actionLabel: "Generate image",
            pipelineTool: .generateImage,
            origin: origin,
            currentIsCompatible: currentValidation == nil,
            noCompatibleModelReason: currentValidation,
            alternatives: { [] },
            exactOptions: exactImageOptions,
            diagnosticProviderScope: { self.activeImageProviderScope() },
            execute: { editor, approved in
                var verifiedProductionDesignRoot: URL?
                if let productionDesignSnapshot {
                    guard let approvedDataRoot = productionDesignDataRoot,
                          let workingRoot = editor.workingRoot,
                          let resolvedDataRoot = DataRootResolver.dataRoot(of: workingRoot) else {
                        throw ToolError(
                            "The Production Design project changed while approval was open. Review the references and generate again."
                        )
                    }
                    let currentDataRoot = resolvedDataRoot.standardizedFileURL
                        .resolvingSymlinksInPath()
                    guard currentDataRoot == approvedDataRoot else {
                        throw ToolError(
                            "The Production Design project changed while approval was open. Review the references and generate again."
                        )
                    }
                    guard try Self.productionDesignReferenceSnapshot(
                        dataRoot: currentDataRoot
                    ) == productionDesignSnapshot else {
                        throw ToolError(
                            "The staged Production Design references changed while approval was open. Review the updated set and generate again."
                        )
                    }
                    verifiedProductionDesignRoot = currentDataRoot
                }

                let submit: @MainActor ([MediaAsset]) async throws -> ToolResult = {
                    generationReferences in
                    let selectedOffering: CatalogImageOfferingCandidate?
                    if isMarble {
                        selectedOffering = nil
                    } else {
                        selectedOffering = self.availableImageOfferings(
                            preferredModelID: model.id,
                            aspectRatio: aspectRatio,
                            resolution: resolution,
                            quality: quality,
                            referenceCount: generationReferences.count
                        ).first {
                            Self.sameImageOffering($0, as: approved.target)
                        }
                        guard selectedOffering != nil else {
                            throw ToolError(
                                "The approved image offering is no longer live or compatible. Review the refreshed provider and model choices."
                            )
                        }
                    }
                    let selectedModel = selectedOffering?.model ?? model
                    let selectedModelID = selectedModel.id
                    let selectedAspectRatio = selectedOffering?.aspectRatio ?? aspectRatio
                    let selectedResolution = selectedOffering?.resolution ?? resolution
                    let selectedQuality = selectedOffering?.quality ?? quality
                    let approvedPrompt = try await self.promptForApprovedModel(
                        precompiled,
                        originalModelId: originalModelId,
                        approvedModelId: selectedModel.id,
                        editor: editor
                    )
                    let folderId = try self.resolveFolderId(
                        args, editor: editor, fallbackReferences: generationReferences
                    )
                    let name = args.string("name")
                    let finalModel = selectedModel
                    let finalModelID = selectedModelID
                    let finalAspectRatio = selectedAspectRatio
                    let finalResolution = selectedResolution
                    let finalQuality = selectedQuality
                    func genInput(_ compiled: String) -> GenerationInput {
                        var input = GenerationInput(
                            prompt: compiled, model: finalModelID, duration: 0,
                            aspectRatio: finalAspectRatio,
                            resolution: finalResolution,
                            quality: finalQuality)
                        input.promptShotId = approvedPrompt?.binding.shotId
                        input.promptProjectKey = approvedPrompt?.binding.projectKey
                        input.promptShotFingerprint = approvedPrompt?.binding.shotFingerprint
                        return input
                    }
                    let preflight: GenerationController.Preflight = {
                        finalModel.validate(
                            aspectRatio: finalAspectRatio,
                            resolution: finalResolution,
                            quality: finalQuality,
                            imageRefCount: generationReferences.count,
                            numImages: 1)
                    }
                    if MarbleModelRegistry.isMarbleModel(finalModelID) {
                        guard let reference = generationReferences.first else {
                            throw ToolError(
                                "\(finalModel.displayName) requires a reference image via 'referenceMediaRefs' (the world is generated from it)."
                            )
                        }
                        let request = GenerationRequest(
                            modality: .image, modelId: finalModelID, intent: prompt,
                            aspectRatio: finalAspectRatio,
                            placement: .mediaLibrary(folderId: folderId), origin: .agentTool,
                            target: approved.target,
                            precompiled: approvedPrompt, rawPrompt: raw,
                            submission: .image(make: { compiled in
                                ImageGenerationSubmission.makeMarble(
                                    genInput: genInput(compiled), model: finalModel,
                                    reference: reference, name: name, folderId: folderId)
                            }))
                        return try await self.routeThroughController(
                            request, editor: editor, preflight: preflight,
                            success: {
                                "Marble world generation completed. Asset ID: \($0). Model: \(finalModel.displayName). Result: equirectangular panorama image."
                            })
                    }
                    let request = GenerationRequest(
                        modality: .image, modelId: finalModelID, intent: prompt,
                        aspectRatio: finalAspectRatio,
                        placement: .mediaLibrary(folderId: folderId), origin: .agentTool,
                        target: approved.target,
                        precompiled: approvedPrompt, rawPrompt: raw,
                        submission: .image(make: { compiled in
                            ImageGenerationSubmission.make(
                                genInput: genInput(compiled), model: finalModel,
                                references: generationReferences,
                                referenceAssetIDs: effectiveLibraryRefs.map(\.id),
                                name: name, folderId: folderId)
                        }))
                    return try await self.routeThroughController(
                        request, editor: editor, preflight: preflight,
                        success: {
                            "Generation completed. Asset ID: \($0). Model: \(finalModel.displayName), aspect: \(finalAspectRatio)"
                        })
                }

                guard let productionDesignSnapshot else {
                    return try await submit(refs)
                }
                guard let verifiedProductionDesignRoot else {
                    throw ToolError(
                        "The Production Design references could not be verified. Review them and generate again."
                    )
                }
                return try await Self.withStagedProductionDesignReferences(
                    snapshot: productionDesignSnapshot,
                    projectReferences: projectRefs,
                    dataRoot: verifiedProductionDesignRoot,
                    operation: submit
                )
            }
        )
    }

    nonisolated static func productionDesignReferencePaths(
        dataRoot: URL
    ) throws -> [String] {
        try productionDesignReferenceSnapshot(dataRoot: dataRoot).paths
    }

    nonisolated static func productionDesignReferenceSnapshot(
        dataRoot: URL
    ) throws -> ProductionDesignReferenceSnapshot {
        let canonicalDataRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        let refsRoot = canonicalDataRoot
            .appendingPathComponent("production_design/refs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: refsRoot.path) else {
            return ProductionDesignReferenceSnapshot(entries: [])
        }
        let rootValues = try refsRoot.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ToolError(
                "Production Design references must be a project-local directory, not a symbolic link."
            )
        }
        var entries: [ProductionDesignReferenceSnapshot.Entry] = []
        var seenPaths = Set<String>()

        func collect(_ directory: URL) throws {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            for child in children {
                let stagedPath = child.standardizedFileURL.path
                let relativeStagedPath = stagedPath.hasPrefix(canonicalDataRoot.path + "/")
                    ? String(stagedPath.dropFirst(canonicalDataRoot.path.count + 1))
                    : child.lastPathComponent
                let values = try child.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                if values.isSymbolicLink == true {
                    throw ToolError(
                        "Production Design reference '\(relativeStagedPath)' is a symbolic link. Use a project-local image file."
                    )
                }
                if values.isDirectory == true {
                    try collect(child)
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let canonical = child.standardizedFileURL.resolvingSymlinksInPath()
                guard canonical.path.hasPrefix(canonicalDataRoot.path + "/") else {
                    throw ToolError(
                        "Production Design references must remain inside the project pipeline."
                    )
                }
                let relativePath = String(
                    canonical.path.dropFirst(canonicalDataRoot.path.count + 1)
                )
                let source = CGImageSourceCreateWithURL(
                    canonical as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                )
                let declaredType = ClipType(
                    fileExtension: child.pathExtension.lowercased()
                )
                let declaredImage = declaredType == .image
                let containsImage = source.flatMap {
                    CGImageSourceCopyPropertiesAtIndex($0, 0, nil)
                } != nil
                guard declaredImage || containsImage else {
                    if declaredType != nil || child.lastPathComponent.hasPrefix(".") {
                        continue
                    }
                    throw ToolError(
                        "Production Design reference '\(relativePath)' uses an unsupported image format."
                    )
                }
                guard declaredImage else {
                    throw ToolError(
                        "Production Design reference '\(relativePath)' uses an unsupported image format."
                    )
                }
                if let reason = projectImageValidationFailure(canonical, source: source) {
                    throw ToolError(
                        "Production Design reference '\(relativePath)' \(reason)."
                    )
                }
                if seenPaths.insert(relativePath).inserted {
                    entries.append(.init(
                        path: relativePath,
                        sha256: try FileDigest.sha256(of: canonical)
                    ))
                }
            }
        }

        try collect(refsRoot)
        return ProductionDesignReferenceSnapshot(
            entries: entries.sorted { $0.path < $1.path }
        )
    }

    static func withStagedProductionDesignReferences<Result>(
        snapshot: ProductionDesignReferenceSnapshot,
        projectReferences: [MediaAsset],
        dataRoot: URL,
        stagingParent: URL? = nil,
        operation: @MainActor ([MediaAsset]) async throws -> Result
    ) async throws -> Result {
        let staging = try stageProductionDesignReferences(
            snapshot: snapshot,
            projectReferences: projectReferences,
            dataRoot: dataRoot,
            stagingParent: stagingParent
        )
        defer { staging.cleanup() }
        return try await operation(staging.references)
    }

    static func stageProductionDesignReferences(
        snapshot: ProductionDesignReferenceSnapshot,
        projectReferences: [MediaAsset],
        dataRoot: URL,
        stagingParent suppliedParent: URL? = nil
    ) throws -> ProductionDesignReferenceStaging {
        guard snapshot.entries.count == projectReferences.count else {
            throw ToolError(
                "The Production Design reference set no longer matches the approved snapshot. Review it and generate again."
            )
        }

        let fileManager = FileManager.default
        let canonicalDataRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        let parent = (suppliedParent ?? AppPaths.caches.appendingPathComponent(
            "generation-references",
            isDirectory: true
        )).standardizedFileURL
        let canonicalParent = parent.resolvingSymlinksInPath()
        guard canonicalParent.path != canonicalDataRoot.path,
              !canonicalParent.path.hasPrefix(canonicalDataRoot.path + "/") else {
            throw ToolError(
                "Production Design generation references must be staged outside the project pipeline."
            )
        }

        do {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ToolError(
                "Production Design references could not be staged: \(error.localizedDescription)"
            )
        }

        let directory = parent.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ToolError(
                "Production Design references could not be staged: \(error.localizedDescription)"
            )
        }

        do {
            var stagedReferences: [MediaAsset] = []
            stagedReferences.reserveCapacity(snapshot.entries.count)
            for (index, pair) in zip(snapshot.entries, projectReferences).enumerated() {
                let entry = pair.0
                let reference = pair.1
                let expectedID = "pipeline-reference:\(entry.path)"
                guard reference.id == expectedID, reference.type == .image else {
                    throw ToolError(
                        "Production Design reference '\(entry.path)' no longer matches its approved identity. Review it and generate again."
                    )
                }

                let source = canonicalDataRoot.appendingPathComponent(entry.path)
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard source.path.hasPrefix(canonicalDataRoot.path + "/"),
                      source == reference.url.standardizedFileURL.resolvingSymlinksInPath(),
                      (try? source.resourceValues(forKeys: [.isRegularFileKey])
                        .isRegularFile) == true else {
                    throw ToolError(
                        "Production Design reference '\(entry.path)' is no longer a project-local image. Review it and generate again."
                    )
                }

                let destination = directory.appendingPathComponent(
                    String(format: "%03d", index) + "-" + source.lastPathComponent
                )
                try fileManager.copyItem(at: source, to: destination)
                guard try FileDigest.sha256(of: destination) == entry.sha256 else {
                    throw ToolError(
                        "Production Design reference '\(entry.path)' changed while it was being staged. Review it and generate again."
                    )
                }
                try fileManager.setAttributes(
                    [.posixPermissions: 0o400],
                    ofItemAtPath: destination.path
                )
                stagedReferences.append(MediaAsset(
                    id: reference.id,
                    url: destination,
                    type: reference.type,
                    name: reference.name,
                    originalFilename: reference.originalFilename
                ))
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: directory.path
            )
            return ProductionDesignReferenceStaging(
                directory: directory,
                references: stagedReferences
            )
        } catch {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? fileManager.removeItem(at: directory)
            if let error = error as? ToolError { throw error }
            throw ToolError(
                "Production Design references could not be staged: \(error.localizedDescription)"
            )
        }
    }

    private func projectImageReferences(
        _ paths: [String],
        editor: EditorViewModel
    ) throws -> [MediaAsset] {
        guard !paths.isEmpty else { return [] }
        guard let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot) else {
            throw ToolError("referenceProjectPaths requires an open pipeline project.")
        }
        let canonicalRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        var seen = Set<URL>()
        return try paths.compactMap { path in
            guard path == path.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty,
                  !NSString(string: path).isAbsolutePath,
                  !path.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw ToolError("referenceProjectPaths must contain normalized pipeline-relative paths.")
            }
            let url = dataRoot.appendingPathComponent(path)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(canonicalRoot.path + "/"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  ClipType(fileExtension: url.pathExtension.lowercased()) == .image,
                  Self.projectImageValidationFailure(url) == nil else {
                throw ToolError("Project reference '\(path)' must be a real image inside pipeline/.")
            }
            guard seen.insert(url).inserted else { return nil }
            return MediaAsset(
                id: "pipeline-reference:\(path)",
                url: url,
                type: .image,
                name: url.deletingPathExtension().lastPathComponent,
                originalFilename: url.lastPathComponent
            )
        }
    }

    nonisolated private static func projectImageValidationFailure(
        _ url: URL,
        source existingSource: CGImageSource? = nil
    ) -> String? {
        if let dimensions = encodedPNGDimensions(url),
           let reason = projectImageDimensionValidationFailure(
               width: dimensions.width,
               height: dimensions.height
           ) {
            return reason
        }
        guard let source = existingSource ?? CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return "cannot be decoded as an image"
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else {
            return "cannot be decoded as an image"
        }
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return "has invalid image dimensions"
        }
        if let reason = projectImageDimensionValidationFailure(
            width: width,
            height: height
        ) {
            return reason
        }
        guard CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) != nil else {
            return "cannot be decoded as an image"
        }
        return nil
    }

    nonisolated private static func encodedPNGDimensions(
        _ url: URL
    ) -> (width: Int, height: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let header: Data
        do {
            header = try handle.read(upToCount: 24) ?? Data()
        } catch {
            return nil
        }
        guard header.count >= 24,
              Array(header[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(header[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else {
            return nil
        }
        func integer(at offset: Int) -> Int {
            (0..<4).reduce(0) {
                ($0 << 8) | Int(header[offset + $1])
            }
        }
        return (integer(at: 16), integer(at: 20))
    }

    nonisolated private static func projectImageDimensionValidationFailure(
        width: Int,
        height: Int
    ) -> String? {
        guard width > 0, height > 0 else {
            return "has invalid image dimensions"
        }
        guard width <= 16_384, height <= 16_384,
              width <= 64_000_000 / height else {
            return "exceeds the 16,384-pixel or 64-megapixel safety limit"
        }
        return nil
    }

    func showDialog(
        _ editor: EditorViewModel,
        _ args: [String: Any],
        origin: ToolCallOrigin
    ) throws -> ToolResult {
        if case .externalMCP = origin {
            throw ToolError(
                "External MCP sessions cannot own an in-app dialog. Ask in the MCP client or start the request from an in-app chat."
            )
        }
        let dialog = try AgentDialog.parse(args)
        try editor.pipelineAgentHarness.guardAgentDecision(dialog, editor: editor)
        try editor.agentService.presentDialog(dialog, origin: origin)
        // Canvas projection (A3, #124): reveal the Review gallery at the shot so its candidates are
        // where the user decides. Timeline-range projection needs no reveal — the timeline is always
        // on. v1: picking a frame candidate in Review while the dialog is pending is the follow-up.
        if let shot = dialog.projection.reviewShot {
            editor.revealCockpit(.review)
            editor.inspectedObject = .shot(shot)
        }
        return .suspended("Dialog \u{201C}\(dialog.title)\u{201D} is presented in the composer. STOP — the user's structured answer arrives as the next semantic user turn; do not act on this step until then.")
    }

    /// Validation IS the execution: a strict parse failure returns the exact violation for the
    /// model to correct against. Rendering happens straight from the transcript's tool-use block
    /// (AgentBlocksView) — nothing to store.
    func showBlocks(_ args: [String: Any]) throws -> ToolResult {
        let blocks = try AgentBlocks.parse(args)
        return .ok("Rendered \(blocks.count) block(s) natively in the transcript. Don't repeat their content in prose.")
    }

    func compilePrompt(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let intent = try args.requireString("intent")
        let modelId = ModelCatalog.shared.internalId(forLogical: try args.requireString("model"))
        let shotId = try args.requireString("shotId")
        // #231: `shotId` is REQUIRED and has no default — "none" is the explicit free-intent choice. It
        // used to be optional, so forgetting it degraded the compile silently: no camera projection from
        // the spec, no drift lint, no error. The contract now forces the decision instead of asking the
        // agent to remember it; an unknown id is refused rather than quietly treated as free intent.
        let projection = try PromptCompiler.currentShotProjection(
            editor: editor,
            shotId: shotId
        )
        // Composition runs the engine path (ledger directives + provider builder + PromptLinter) instead of
        // the old local ledger text-append, then the gate mints the token over the result.
        let compiled = try await PromptCompiler.compile(
            intent: intent, modelId: modelId,
            modality: PromptCompiler.modalityForModel(modelId), editor: editor,
            setting: args.string("setting") ?? "",
            lighting: args.string("lighting") ?? "",
            style: args.string("style") ?? "",
            shotId: shotId, shot: projection)
        let body: [String: Any] = [
            "compiledPrompt": compiled.text,
            "compileToken": compiled.token,
            "shotId": compiled.binding.shotId,
            "notes": compiled.notes,
        ]
        guard let json = Self.jsonString(body) else { return .error("Failed to encode compiled prompt") }
        return .ok(json)
    }

    func generateAudio(
        _ editor: EditorViewModel,
        _ args: [String: Any],
        origin: ToolCallOrigin
    ) async throws -> ToolResult {
        guard let modelId = args.string("model").map({ ModelCatalog.shared.internalId(forLogical: $0) }) ?? AudioModelConfig.allModels.first?.id else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let model = AudioModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(AudioModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }

        let prompt = (args.string("prompt") ?? "").trimmingCharacters(in: .whitespaces)
        let acceptsVideo = model.inputs.contains(.video)
        var videoReference: MediaAsset?
        var persistedVideoReferenceID: String?
        var preprocessReference: (@Sendable (Int, MediaAsset) async throws -> URL?)?
        var temporaryReferenceURLs: [URL] = []
        var spanSeconds: Double?
        var placementStartFrame: Int?   // set when a timeline span is given -> auto-place on the timeline
        if let ref = args.string("videoSourceMediaRef") {
            guard acceptsVideo else {
                throw ToolError("Model '\(model.id)' does not accept a video input (see list_models 'inputs').")
            }
            let videoAsset = try asset(ref, editor: editor, label: "Video source")
            guard videoAsset.type == .video else {
                throw ToolError("videoSourceMediaRef must be a video asset (got \(videoAsset.type.rawValue)).")
            }
            guard editor.mediaResolver.resolveURL(for: videoAsset.id) != nil else {
                throw ToolError("Could not read the video source file.")
            }
            spanSeconds = videoAsset.duration
            if let error = model.validate(spanSeconds: videoAsset.duration) {
                throw ToolError(error)
            }
            videoReference = videoAsset
            persistedVideoReferenceID = videoAsset.id
        } else if let start = args.int("videoSourceStartFrame"), let end = args.int("videoSourceEndFrame") {
            guard acceptsVideo else {
                throw ToolError("Model '\(model.id)' does not accept a video input (see list_models 'inputs').")
            }
            guard start >= 0, end > start else {
                throw ToolError("videoSourceEndFrame must be greater than videoSourceStartFrame (>= 0).")
            }
            let seconds = Double(end - start) / Double(max(1, editor.timeline.fps))
            if let error = model.validate(spanSeconds: seconds) {
                throw ToolError(error)
            }
            let mp4 = try await TimelineRenderer.render(
                timeline: editor.timeline, resolver: editor.mediaResolver,
                startFrame: start, frameCount: end - start,
                shortSide: 360, includeAudio: false
            )
            spanSeconds = seconds
            placementStartFrame = start
            temporaryReferenceURLs = [mp4]
            videoReference = MediaAsset(
                id: UUID().uuidString,
                url: mp4,
                type: .video,
                name: "Timeline source",
                duration: seconds
            )
            preprocessReference = { @Sendable _, asset in
                await MainActor.run { asset.url }
            }
        }

        // A video-only model (no text input, e.g. Mirelo) needs a source.
        if acceptsVideo && !model.inputs.contains(.text) && videoReference == nil {
            throw ToolError("Model '\(model.id)' generates audio from video. Provide videoSourceStartFrame + videoSourceEndFrame (a timeline span) or videoSourceMediaRef.")
        }

        let instrumental = args.bool("instrumental") ?? false
        let durationSeconds = args.int("duration") ?? spanSeconds.map { max(1, Int($0.rounded())) }
        let voice = model.voices != nil ? (args.string("voice") ?? model.defaultVoice) : nil
        let lyrics = model.supportsLyrics ? args.string("lyrics") : nil
        let styleInstructions = model.supportsStyleInstructions ? args.string("styleInstructions") : nil
        let name = args.string("name")
        let folderId = try resolveFolderId(args, editor: editor)
        let (precompiled, raw) = try Self.agentPrompt(
            args,
            prompt: prompt,
            modality: .audio,
            editor: editor
        )

        // Build the submission from the CONTROLLER-compiled prompt so the audio params + genInput
        // carry the same text the gate validated.
        func makeSubmission(_ compiled: String) -> AudioGenerationSubmission {
            let params = AudioGenerationParams(
                prompt: compiled, voice: voice, lyrics: lyrics,
                styleInstructions: styleInstructions,
                instrumental: model.supportsInstrumental ? instrumental : false,
                durationSeconds: durationSeconds)
            var genInput = GenerationInput(
                prompt: compiled, model: model.id, duration: durationSeconds ?? 0,
                aspectRatio: "", resolution: nil, voice: params.voice, lyrics: params.lyrics,
                styleInstructions: params.styleInstructions,
                instrumental: model.supportsInstrumental ? instrumental : nil)
            genInput.promptShotId = precompiled?.binding.shotId
            genInput.promptProjectKey = precompiled?.binding.projectKey
            genInput.promptShotFingerprint = precompiled?.binding.shotFingerprint
            genInput.referenceVideoAssetIds = persistedVideoReferenceID.map { [$0] }
            return AudioGenerationSubmission.make(
                genInput: genInput,
                model: model,
                params: params,
                name: name,
                folderId: folderId,
                references: videoReference.map { [$0] } ?? [],
                preprocessRef: preprocessReference
            )
        }
        // Preflight validates the params; build them once with the raw prompt for validation (the
        // compiled text only differs by ledger merge and never invalidates model.validate).
        let preflight: GenerationController.Preflight = {
            model.validate(params: makeSubmission(prompt).params)
        }
        if let error = preflight() { throw ToolError(error) }
        let audioCredits = CostEstimator.audioCost(
            model: model,
            prompt: prompt,
            durationSeconds: durationSeconds
        )
        let placement: GenerationRequest.Placement
        let successCopy: (String) -> String
        if let startFrame = placementStartFrame, let span = spanSeconds {
            placement = .timelineAt(startFrame: startFrame, spanSeconds: span, actionName: "Add \(model.category.label)")
            successCopy = { "Generation completed and was placed on the timeline at frame \(startFrame). Asset ID: \($0). Model: \(model.displayName), \(model.category.label) (scored from video)." }
        } else {
            placement = .mediaLibrary(folderId: folderId)
            let scored = videoReference != nil ? " (scored from video)" : ""
            successCopy = { "Generation completed. Asset ID: \($0). Model: \(model.displayName), \(model.category.label)\(scored). Place it with add_clips." }
        }
        let cleanupURLs = temporaryReferenceURLs
        return try await withSpendApproval(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: audioCredits, actionLabel: "Generate \(model.category.label)",
            pipelineTool: .generateAudio,
            origin: origin,
            alternatives: { [] },
            cancel: { _ in
                for url in cleanupURLs { try? FileManager.default.removeItem(at: url) }
            },
            execute: { editor, approved in
                let request = GenerationRequest(
                    modality: .audio, modelId: model.id, intent: prompt,
                    durationSeconds: durationSeconds.map(Double.init),
                    placement: placement, origin: .agentTool,
                    target: approved.target,
                    precompiled: precompiled, rawPrompt: raw,
                    submission: .audio(make: { makeSubmission($0) }))
                return try await self.routeThroughController(
                    request,
                    editor: editor,
                    preflight: preflight,
                    success: successCopy
                )
            }
        )
    }

    func upscaleMedia(
        _ editor: EditorViewModel,
        _ args: [String: Any],
        origin: ToolCallOrigin
    ) async throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video || asset.type == .image else {
            throw ToolError("Upscale supports video and image assets only (got \(asset.type.rawValue))")
        }

        let available = UpscaleModelConfig.models(for: asset.type)
        let model: UpscaleModelConfig
        if let requested = args.string("model").map({ ModelCatalog.shared.internalId(forLogical: $0) }) {
            guard let match = available.first(where: { $0.id == requested }) else {
                let ids = available.map(\.id).joined(separator: ", ")
                throw ToolError("Model '\(requested)' does not support \(asset.type.rawValue). Available: \(ids)")
            }
            model = match
        } else {
            guard let first = available.first else {
                throw ToolError("No upscaler available for \(asset.type.rawValue)")
            }
            model = first
        }

        let trimmed = try trimmedSource(args, editor: editor, source: asset)

        // Cost-Guard (M7): approval before this paid upscale. Upscalers are type-specific, so no swap.
        let upSeconds = Int((trimmed?.durationSeconds ?? (asset.duration > 0 ? asset.duration : 1)).rounded())
        return try await withSpendApproval(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: CostEstimator.upscaleCost(model: model, durationSeconds: upSeconds),
            actionLabel: "Upscale",
            pipelineTool: .upscaleMedia,
            origin: origin,
            alternatives: { [] },
            execute: { editor, approved in
                let result = try await AgentGenerationAwaiter.waitForSubmission(
                    start: { awaiter in
                        guard let placeholderId = await EditSubmitter.submitUpscale(
                            asset: asset,
                            model: model,
                            editor: editor,
                            trimmedSource: trimmed,
                            origin: .agentTool,
                            target: approved.target,
                            onComplete: { awaiter.resolve(.succeeded($0)) },
                            onFailure: { awaiter.resolve(.failed(nil)) }
                        ) else {
                            throw ToolError("Failed to start upscale")
                        }
                        return placeholderId
                    }, cancel: { placeholderId in
                        editor.generationService.cancelGeneration(
                            placeholderId: placeholderId
                        )
                    }
                )
                switch result.completion {
                case .failed(let explicitMessage):
                    let message = editor.mediaAssets.first(where: {
                        $0.id == result.placeholderId
                    }).flatMap { placeholder -> String? in
                        guard case .failed(let message) = placeholder.generationStatus else {
                            return nil
                        }
                        return message
                    } ?? explicitMessage ?? "The provider did not return a usable upscale result."
                    throw ToolError(message)
                case .succeeded(let completed):
                    return try await Self.completedGenerationResult(
                        text: "Upscale completed. Asset ID: \(result.placeholderId). Model: \(model.displayName), source: \(asset.name)\(trimmed != nil ? " (trimmed range)" : "")",
                        asset: asset.type == .image ? completed : nil
                    )
                }
            }
        )
    }

    private func trimmedSource(
        _ args: [String: Any], editor: EditorViewModel, source: MediaAsset
    ) throws -> TrimmedSource? {
        guard let clipId = args.string("sourceClipId") else { return nil }
        guard let clip = editor.clipFor(id: clipId) else {
            throw ToolError("sourceClipId not found: \(clipId)")
        }
        guard clip.mediaRef == source.id else {
            throw ToolError("sourceClipId \(clipId) references a different asset than the source")
        }
        guard source.type == .video else {
            throw ToolError("sourceClipId only applies to video sources")
        }
        guard clip.trimStartFrame > 0 || clip.trimEndFrame > 0 else { return nil }
        return TrimmedSource(
            sourceURL: source.url,
            trimStartFrame: clip.trimStartFrame,
            trimEndFrame: clip.trimEndFrame,
            sourceFramesConsumed: clip.sourceFramesConsumed,
            fps: editor.timeline.fps
        )
    }

    func listModels(_ args: [String: Any]) -> ToolResult {
        let filter = args.string("type")
        var out: [[String: Any]] = []
        if filter == nil || filter == "video" {
            out += VideoModelConfig.allModels.map { Self.videoModelInfo($0, includeType: true) }
        }
        if filter == nil || filter == "image" {
            out += ImageModelConfig.allModels.map { Self.imageModelInfo($0, includeType: true) }
        }
        if filter == nil || filter == "audio" {
            out += AudioModelConfig.allModels.map { Self.audioModelInfo($0) }
        }
        if filter == nil || filter == "upscale" {
            out += UpscaleModelConfig.allModels.map { Self.upscaleModelInfo($0) }
        }
        // Usable-only (LLM → NGV → Provider; docs concept #159 + the user's final say): the agent
        // sees ONLY models it can actually run — an activated provider services the model AND the
        // user hasn't disabled it in Settings → Models. Never surface a model that would fail at
        // request time (no key) or one the user turned off; the resolver, not the LLM, owns which
        // provider runs it.
        let prefs = ModelPreferences.shared
        out = out.filter { info in
            guard let id = info["id"] as? String else { return false }
            return prefs.isEnabled(id) && GenerationProvider.canRun(modelId: id)
        }
        // Attach each model's curated card (strengths/weaknesses/best-for/rank) so the agent
        // recommends from the CURRENT truth NGV feeds it, not stale training knowledge. Cards are
        // hosted + refreshed without an app release; absent card = no `card` key (still usable).
        let cards = ModelCatalog.shared.cardsById
        out = out.map { info in
            guard let id = info["id"] as? String, let card = cards[id] else { return info }
            var info = info
            var c: [String: Any] = [:]
            if let v = card.strengths { c["strengths"] = v }
            if let v = card.weaknesses { c["weaknesses"] = v }
            if let v = card.bestFor { c["bestFor"] = v }
            if let v = card.rank { c["rank"] = v }
            if let v = card.tags { c["tags"] = v }
            if !c.isEmpty { info["card"] = c }
            return info
        }
        // Present provider-neutral LOGICAL ids to the agent (NGV maps back to the internal id +
        // resolves the provider on generate). The agent names a model, never a provider.
        out = out.map { info in
            guard let id = info["id"] as? String else { return info }
            var info = info
            info["id"] = ModelCatalog.deriveLogicalId(id)
            return info
        }
        var body: [String: Any] = [
            "models": out,
            "loaded": ModelCatalog.shared.isLoaded,
        ]
        if out.isEmpty {
            body["note"] = "No usable models yet — activate a provider in Settings → Providers "
                + "(or re-enable models in Settings → Models). Recommend the user do this rather than guessing."
        }
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(body, toPlaces: 3)) else {
            return .error("Failed to encode model list")
        }
        return .ok(json)
    }

    static func videoModelInfo(
        _ m: VideoModelConfig,
        includeType: Bool = false
    ) -> [String: Any] {
        let activation = ProviderActivation.current()
        let bindings = ProviderManifest.bindings(forModelId: m.id)
            .filter { binding in
                guard activation.isActive(binding.provider, binding.transport),
                      binding.kind == .generation,
                      let capabilities = binding.resolvedVideoCapabilities,
                      capabilities.contractViolation == nil else {
                    return false
                }
                return binding.productionInputPolicy == capabilities.inputPolicy
            }
            .sorted {
                ($0.provider.rawValue, $0.transport.rawValue, $0.providerRef,
                 $0.modelParam ?? "")
                    < ($1.provider.rawValue, $1.transport.rawValue, $1.providerRef,
                       $1.modelParam ?? "")
            }
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "offerings": bindings.compactMap(videoOfferingInfo),
        ]
        if includeType { info["type"] = "video" }
        return info
    }

    private static func videoOfferingInfo(
        _ binding: ProviderBinding
    ) -> [String: Any]? {
        guard let capabilities = binding.resolvedVideoCapabilities else {
            return nil
        }
        guard capabilities.contractViolation == nil else { return nil }
        var duration: [String: Any] = [
            "discrete": capabilities.durationValues,
            "supportsAuto": capabilities.supportsAutomaticDuration,
        ]
        if let minimum = capabilities.durationMinimum,
           let maximum = capabilities.durationMaximum {
            duration["range"] = ["min": minimum, "max": maximum]
        }
        var info: [String: Any] = [
            "provider": binding.provider.rawValue,
            "transport": binding.transport.rawValue,
            "endpoint": binding.providerRef,
            "requiresSourceVideo": capabilities.inputPolicy.requiresSourceVideo,
            "duration": duration,
            "aspectRatios": capabilities.aspectRatios,
            "supportsNativeAudio": capabilities.supportsNativeAudio,
            "supportsFirstFrame": capabilities.supportsFirstFrame,
            "supportsLastFrame": capabilities.supportsLastFrame,
            "supportsReferences": capabilities.supportsReferences,
            "maxReferenceImages": capabilities.maxReferenceImages,
            "maxReferenceVideos": capabilities.maxReferenceVideos,
            "maxReferenceAudios": capabilities.maxReferenceAudios,
            "framesCountTowardImageReferenceLimit": capabilities.inputPolicy
                .framesCountTowardImageReferenceLimit,
            "framesCountTowardTotalReferenceLimit": capabilities.inputPolicy
                .framesCountTowardTotalReferenceLimit,
            "framesAndReferencesExclusive": capabilities.framesAndReferencesExclusive,
            "requiresReferenceImage": capabilities.requiresReferenceImage,
        ]
        if let modelParam = binding.modelParam { info["providerModel"] = modelParam }
        if let resolutions = capabilities.resolutions {
            info["resolutions"] = resolutions
        }
        if let maximum = capabilities.maxTotalReferences {
            info["maxTotalReferences"] = maximum
        }
        if let maximum = capabilities.maxReferenceImagesWhenVideoPresent {
            info["maxReferenceImagesWhenVideoPresent"] = maximum
        }
        if let seconds = capabilities.maxCombinedVideoReferenceSeconds {
            info["maxCombinedVideoRefSeconds"] = seconds
        }
        if let seconds = capabilities.maxCombinedAudioReferenceSeconds {
            info["maxCombinedAudioRefSeconds"] = seconds
        }
        return info
    }

    nonisolated static func imageModelInfo(_ m: ImageModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "aspectRatios": m.aspectRatios,
            "supportsImageReference": m.supportsImageReference,
            "requiresImageReference": m.requiresImageReference,
            "minReferenceImages": m.minReferenceImages,
            "maxImages": m.maxImages,
        ]
        switch m.referenceImageLimit {
        case .bounded(let maximum):
            info["maxReferenceImages"] = maximum
        case .capabilityProfile(let maximum):
            info["referenceImageLimit"] = "capability-profile"
            info["maxReferenceImages"] = maximum
        case .unknown:
            info["referenceImageLimit"] = "unknown"
        }
        if includeType { info["type"] = "image" }
        if let r = m.resolutions { info["resolutions"] = r }
        if let q = m.qualities { info["qualities"] = q }
        return info
    }

    nonisolated static func audioModelInfo(_ m: AudioModelConfig) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "type": "audio",
            "category": m.category == .music ? "music" : (m.category == .sfx ? "sfx" : "tts"),
            "inputs": m.inputs.map(\.rawValue),
            "minPromptLength": m.minPromptLength,
            "supportsLyrics": m.supportsLyrics,
            "supportsInstrumental": m.supportsInstrumental,
            "supportsStyleInstructions": m.supportsStyleInstructions,
        ]
        if let voices = m.voices {
            info["voicesSample"] = Array(voices.prefix(3))
            info["voiceCount"] = voices.count
        }
        if let defaultVoice = m.defaultVoice { info["defaultVoice"] = defaultVoice }
        if let durations = m.durations { info["durations"] = durations }
        return info
    }

    nonisolated static func upscaleModelInfo(_ m: UpscaleModelConfig) -> [String: Any] {
        [
            "id": m.id, "displayName": m.displayName,
            "type": "upscale",
            "speed": m.speed,
            "supportedTypes": m.supportedTypes.map(\.rawValue).sorted(),
        ]
    }
}
