import Foundation

// MARK: - Canonical request

/// The ONE request every generation surface builds (issue #114). Panel, music tab, agent tools,
/// dialogs, and rerun all describe *what to generate* as a `GenerationRequest` and hand it to
/// `GenerationController.submit` — which runs the same preflight → compile → submit → feedback
/// sequence for all of them. The provider stack (Video/Image/Audio/MusicGenerationSubmission) is
/// untouched; this is the funnel above it.
struct GenerationRequest {
    typealias UpscaleSubmission = @MainActor (
        GenerationService, URL?, EditorViewModel, GenerationAuthorization,
        (@MainActor (MediaAsset) -> Void)?, (@MainActor () -> Void)?
    ) -> String
    /// `.upscale` is promptless — its controller path skips the compile stage but shares the same
    /// preflight → submit → feedback sequence as the rest.
    enum Modality: Sendable, Equatable { case video, image, audio, music, upscale }

    /// Where the result lands once generation finishes.
    enum Placement {
        case mediaLibrary(folderId: String?)
        case timelineAt(startFrame: Int, spanSeconds: Double, actionName: String?)
        case replaceClip(id: String, resetTrim: Bool)
    }

    /// Which surface built the request — drives the raw-prompt escape and shapes feedback copy.
    enum Origin { case panel, agentTool, dialog, rerun }

    /// A prebuilt provider submission. The controller stays out of the provider-specific assembly
    /// (references, params, folder resolution) — each adapter constructs its submission the way it
    /// already did and hands the controller a thunk that submits it with the compiled prompt folded
    /// in. This keeps every existing behavior intact while unifying the surrounding sequence.
    enum Submission {
        case video(make: @MainActor (_ compiledPrompt: String) -> VideoGenerationSubmission)
        case image(make: @MainActor (_ compiledPrompt: String) -> ImageGenerationSubmission)
        case audio(make: @MainActor (_ compiledPrompt: String) -> AudioGenerationSubmission)
        case music(make: @MainActor (_ compiledPrompt: String) -> MusicGenerationSubmission)
        /// Upscale is promptless — no submission struct to compose a prompt into. The thunk performs
        /// the `service.generate` (source asset uploaded as its reference) and returns the placeholder
        /// id, so the controller's compile stage is skipped while placement/feedback stay shared.
        case upscale(run: UpscaleSubmission)
    }

    let modality: Modality
    let modelId: String
    /// User/agent text. May be empty (e.g. a music dialog with only chips, or a video-to-audio job
    /// scored purely from a source). An empty intent skips compilation.
    let intent: String
    let aspectRatio: String
    let durationSeconds: Double?
    let placement: Placement
    let origin: Origin
    /// Exact user-approved provider target. Nil lets NGV resolve its normal default.
    let target: ResolvedGenerationTarget?

    /// A precompiled prompt + token from the agent's `compile_prompt` tool. When present the
    /// controller validates it through the gate instead of composing (the token proves it came from
    /// the engine composer this run).
    let precompiled: (
        text: String,
        token: String,
        binding: PromptBinding
    )?
    /// Pro raw-prompt escape (origin `.agentTool` only) — bypasses compilation exactly as
    /// `PromptCompiler.enforceGate` allows today.
    let rawPrompt: Bool
    /// The provider submission thunk (compiled prompt injected at submit time).
    let submission: Submission

    init(
        modality: Modality,
        modelId: String,
        intent: String,
        aspectRatio: String = "",
        durationSeconds: Double? = nil,
        placement: Placement,
        origin: Origin,
        target: ResolvedGenerationTarget? = nil,
        precompiled: (
            text: String,
            token: String,
            binding: PromptBinding
        )? = nil,
        rawPrompt: Bool = false,
        submission: Submission
    ) {
        self.modality = modality
        self.modelId = modelId
        self.intent = intent
        self.aspectRatio = aspectRatio
        self.durationSeconds = durationSeconds
        self.placement = placement
        self.origin = origin
        self.target = target
        self.precompiled = precompiled
        self.rawPrompt = rawPrompt
        self.submission = submission
    }

    /// Upscale is promptless but still receives an image-safe project binding before submission.
    var composerModality: PromptComposer.Modality {
        switch modality {
        case .video: return .video
        case .image: return .image
        case .audio: return .audio
        case .music: return .music
        case .upscale: return .image
        }
    }
}

// MARK: - Errors

enum GenerationRequestError: LocalizedError {
    case unknownModel(String)
    case optionsInvalid(String)
    case compile(String)
    case gate(String)
    case storage(String)
    case budget(String)

    var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Unknown model '\(id)'."
        case .optionsInvalid(let m): return m
        case .compile(let m): return m
        case .gate(let m): return m
        case .storage(let m): return m
        case .budget(let m): return m
        }
    }
}

// MARK: - Outcome

/// The controller's uniform feedback. Surfaces render this however they already do — the music tab
/// as its Banner, the panel/agent as a MediaPanelToast, the agent tool as a text result. Notes are
/// the lint warnings the compile step passed through.
struct GenerationOutcome: Sendable {
    let placeholderId: String
    let notes: [String]
}

// MARK: - Controller

/// The ONE generation controller. Every surface routes through `submit`, which runs the identical
/// sequence: PREFLIGHT (model + options) → COMPILE (engine-composed prompt, lint blocks on ERROR) →
/// SUBMIT (existing provider submission) → FEEDBACK (placeholder placed + selected, uniform outcome).
@MainActor
enum GenerationController {
    @MainActor
    final class PreparedGeneration {
        let request: GenerationRequest
        let submission: PreparedSubmission
        let target: ResolvedGenerationTarget
        let compiledPrompt: String
        let notes: [String]
        let home: URL?
        let scope: GenerationProjectMutationScope?
        let binding: PromptBinding
        let compilerInputsSHA256: String
        let destination: GenerationPackageV1.Destination
        let recipe: GenerationCompileRecipe?
        let repairPlanID: String?
        let references: GenerationReferenceSnapshot?
        let preflight: Preflight?
        private(set) var reviewedPackage: GenerationPackageV1?
        private(set) var batchItem: GenerationBatchAuthorization?
        private var submitted = false

        init(request: GenerationRequest, submission: PreparedSubmission, target: ResolvedGenerationTarget,
             compiledPrompt: String, notes: [String], home: URL?, scope: GenerationProjectMutationScope?,
             binding: PromptBinding, compilerInputsSHA256: String, destination: GenerationPackageV1.Destination, recipe: GenerationCompileRecipe?, repairPlanID: String?,
             references: GenerationReferenceSnapshot?, preflight: Preflight?) {
            self.request = request; self.submission = submission; self.target = target
            self.compiledPrompt = compiledPrompt; self.notes = notes; self.home = home; self.scope = scope
            self.binding = binding; self.recipe = recipe; self.repairPlanID = repairPlanID
            self.compilerInputsSHA256 = compilerInputsSHA256
            self.destination = destination
            self.references = references; self.preflight = preflight
        }

        func claimSubmission() throws {
            guard !submitted else { throw GenerationRequestError.gate("This prepared generation was already submitted. Join its existing job or explicitly prepare a new attempt.") }
            submitted = true
        }

        func attachReview(_ package: GenerationPackageV1) throws {
            guard !submitted, reviewedPackage == nil else { throw GenerationRequestError.gate("This generation already has a review package.") }
            try package.validate()
            reviewedPackage = package
        }

        func attachBatch(_ item: GenerationBatchAuthorization, editor: EditorViewModel) throws {
            guard !submitted, batchItem == nil, let reviewedPackage else {
                throw GenerationRequestError.gate("Only an unsubmitted reviewed request can join an approved batch.")
            }
            try item.requireQueued(package: reviewedPackage, editor: editor)
            batchItem = item
        }
    }

    @MainActor
    enum PreparedSubmission {
        case video(VideoGenerationSubmission, PreparedProviderParameters)
        case image(ImageGenerationSubmission, PreparedProviderParameters)
        case audio(AudioGenerationSubmission)
        case music(MusicGenerationSubmission)
        case upscale(GenerationRequest.UpscaleSubmission)

        init(_ submission: GenerationRequest.Submission, compiledPrompt: String) throws {
            switch submission {
            case .video(let make):
                let value = make(compiledPrompt)
                let parameters = try PreparedProviderParameters(referenceCount: value.references.count, build: value.buildParams)
                guard case .video(let video) = parameters.parameters, video.prompt == compiledPrompt,
                      value.genInput.prompt == compiledPrompt else { throw GenerationRequestError.optionsInvalid("The video request does not contain the compiled prompt.") }
                self = .video(value, parameters)
            case .image(let make):
                let value = make(compiledPrompt)
                let count = value.preUploadedURLs.flatMap { $0.isEmpty ? nil : $0.count } ?? value.references.count
                let parameters = try PreparedProviderParameters(referenceCount: count, build: value.buildParams)
                guard case .image(let image) = parameters.parameters, image.prompt == compiledPrompt,
                      value.genInput.prompt == compiledPrompt, image.numImages == value.numImages,
                      (1...4).contains(image.numImages) else {
                    throw GenerationRequestError.optionsInvalid("The image output count does not match the prepared request.")
                }
                self = .image(value, parameters)
            case .audio(let make): self = .audio(make(compiledPrompt))
            case .music(let make): self = .music(make(compiledPrompt))
            case .upscale(let run): self = .upscale(run)
            }
        }
    }

    /// Optional preflight validation the adapter supplies — it already knows the model config and
    /// its reference/option rules (see `VideoGenerationSubmission.InputAssets.validate`). Returning a
    /// message blocks the request before compile.
    typealias Preflight = @MainActor () -> String?

    /// Music-only progress passthroughs — the music submission is a self-contained async run with
    /// phase reporting that drives the music tab's spinner label. Other modalities ignore these.
    struct MusicProgress {
        var onPhase: (@MainActor (MusicGenerationSubmission.Phase) -> Void)?
        var onFinished: (@MainActor () -> Void)?
    }

    static func prepareReviewPackage(_ generation: PreparedGeneration, editor: EditorViewModel,
                                    quoteLoader: GenerationBudgetGuard.QuoteLoader = LiveGenerationPricing.quote) async throws -> GenerationPackageV1 {
        let estimate = try? await quoteLoader(generation.target,
            pricingInput(generation.request, prepared: generation.submission, compiledPrompt: generation.compiledPrompt))
        try generation.scope?.requireCurrent(editor: editor)
        try await generation.references?.requireUnchanged()
        guard editor.workingRoot == generation.home else { throw GenerationRequestError.gate("The project changed during request preparation.") }
        try generation.destination.requireCurrent(editor: editor)
        guard let package = try makePackage(generation, estimate: estimate) else {
            throw GenerationRequestError.optionsInvalid("This operation does not support a visual generation package.")
        }
        try await package.requireCurrentContext(editor: editor)
        try generation.attachReview(package)
        return package
    }

    private static func makePackage(_ generation: PreparedGeneration, estimate: GenerationMoney?) throws -> GenerationPackageV1? {
        var input: GenerationInput
        let parameters: PreparedProviderParameters
        let modality: String
        let count: Int
        switch generation.submission {
        case .video(let video, let prepared):
            input = video.genInput; parameters = prepared; modality = "video"; count = 1
        case .image(let image, let prepared):
            input = image.genInput; parameters = prepared; modality = "image"; count = image.numImages
        default: return nil
        }
        let references = generation.references?.receipts ?? []
        input.referenceReceipts = references; input.compileRecipe = generation.recipe; input.takeRepairPlanID = generation.repairPlanID
        return try GenerationPackageV1(payload: .init(target: generation.target, modality: modality,
            operation: input.productionRouting?.offeringCapabilities.inputPolicy.sourceOperation?.rawValue ?? "generate_\(modality)",
            intent: generation.request.intent, prompt: generation.compiledPrompt,
            promptRevisionID: PipelineRenderTakeStore.promptRevision(input), generationInput: GenerationPackageV1.normalized(input),
            binding: generation.binding, compilerInputsSHA256: generation.compilerInputsSHA256,
            recipe: generation.recipe, repairPlanID: generation.repairPlanID,
            destination: generation.destination, outputCount: count, references: references,
            referenceRoles: GenerationPackageV1.referenceRoles(parameters: parameters),
            requestParametersJSON: GenerationPackageV1.requestJSON(parameters: parameters, references: references),
            routing: input.productionRouting,
            routeReceipt: .init(target: generation.target, checks: ModelCatalog.shared.routeChecks,
                capabilitySnapshot: input.productionRouting?.route.capabilitySnapshot), estimate: estimate))
    }

    @discardableResult
    static func submit(
        _ request: GenerationRequest,
        editor: EditorViewModel,
        preflight: Preflight? = nil,
        musicProgress: MusicProgress? = nil,
        onSuccess: (@MainActor (MediaAsset?) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil,
        quoteLoader: GenerationBudgetGuard.QuoteLoader = LiveGenerationPricing.quote
    ) async -> Result<GenerationOutcome, GenerationRequestError> {
        switch await prepare(request, editor: editor, preflight: preflight) {
        case .failure(let error): return .failure(error)
        case .success(let generation):
            return await submitPrepared(generation, editor: editor, musicProgress: musicProgress,
                onSuccess: onSuccess, onFailure: onFailure, quoteLoader: quoteLoader)
        }
    }

    static func prepare(
        _ request: GenerationRequest, editor: EditorViewModel, preflight: Preflight? = nil
    ) async -> Result<PreparedGeneration, GenerationRequestError> {
        let requestHome = editor.workingRoot
        if let message = preflight?() { return .failure(.optionsInvalid(message)) }
        let scope: GenerationProjectMutationScope?
        let binding: PromptBinding
        let compilerInputsSHA256: String
        let destination: GenerationPackageV1.Destination
        do {
            destination = try .init(request.placement, editor: editor)
            scope = try requestHome.map { try GenerationProjectMutationScope(projectHome: $0, editor: editor) }
            let currentBinding = try await PromptCompiler.currentBinding(editor: editor,
                shotId: request.precompiled?.binding.shotId ?? "none",
                modality: request.composerModality,
                modelId: request.modelId)
            if let compiledBinding = request.precompiled?.binding {
                guard currentBinding.matchesCurrentState(of: compiledBinding) else {
                    throw GenerationRequestError.gate(
                        "The compiled prompt no longer matches the current project direction."
                    )
                }
                binding = compiledBinding
            } else {
                binding = currentBinding
            }
            compilerInputsSHA256 = try await PromptComposer.inputFingerprint(projectDir: requestHome)
        } catch { return .failure(.gate(error.localizedDescription)) }
        // (b) COMPILE — engine-composed prompt; a lint ERROR blocks with a clear message. An empty
        // intent skips compilation (nothing to compose); the raw escape and precompiled token are the
        // agent's two ways past the composer, mirroring PromptCompiler.enforceGate. Upscale is
        // promptless and skips this stage entirely.
        let compiled: String
        let notes: [String]
        do {
            let result = try await compilePrompt(request, editor: editor)
            compiled = result.text
            notes = result.notes
        } catch let error as GenerationRequestError {
            return .failure(error)
        } catch {
            return .failure(.compile(error.localizedDescription))
        }

        let target = request.target ?? GenerationService.dispatchTarget(modelId: request.modelId)
        guard target.modelId == request.modelId else { return .failure(.optionsInvalid("The selected route and compiled model do not match.")) }
        guard editor.workingRoot == requestHome else { return .failure(.gate("The active project changed during prompt compilation. Prepare the request again.")) }
        let prepared: PreparedSubmission
        do { prepared = try PreparedSubmission(request.submission, compiledPrompt: compiled) }
        catch { return .failure(.optionsInvalid(error.localizedDescription)) }
        let referenceSnapshot: GenerationReferenceSnapshot?
        do {
            switch prepared {
            case .video(let video, let parameters):
                guard video.genInput.model == target.modelId else { throw GenerationRequestError.optionsInvalid("The video request changed its approved model.") }
                if video.genInput.productionRouting != nil,
                   video.trimmedSourceOverride?.hasTrim == true || video.preprocessRef != nil {
                    throw GenerationRequestError.optionsInvalid("A routed request must preserve its exact planned input bytes.")
                }
                referenceSnapshot = try await GenerationReferenceSnapshot.prepare(references: video.references,
                    trim: video.trimmedSourceOverride, preprocess: video.preprocessRef)
                try PipelineProductionRouting.validateProviderEnvelope(genInput: video.genInput, target: target,
                    params: parameters.parameters, uploadedReferences: parameters.referenceSlots)
                if let routing = video.genInput.productionRouting, let referenceSnapshot {
                    guard routing.orderedBindings.count == referenceSnapshot.receipts.count,
                          zip(routing.orderedBindings, referenceSnapshot.receipts).allSatisfy({ pair in
                              pair.0.mediaAssetID == pair.1.assetID && pair.0.sha256 == pair.1.sourceSHA256
                                  && pair.0.sha256 == pair.1.submittedSHA256
                          }) else { throw GenerationRequestError.optionsInvalid("The prepared reference bytes differ from the approved ReferencePlan.") }
                }
            case .image(let image, _):
                guard image.genInput.model == target.modelId else { throw GenerationRequestError.optionsInvalid("The image request changed its approved model.") }
                referenceSnapshot = try await GenerationReferenceSnapshot.prepare(references: image.references,
                    preUploadedURLs: image.preUploadedURLs)
                if let plan = image.genInput.frameReferencePlan {
                    guard plan.isExecutable,
                          let referenceSnapshot,
                          plan.bindings.count == referenceSnapshot.receipts.count,
                          zip(plan.bindings, referenceSnapshot.receipts).allSatisfy({ pair in
                              pair.0.sha256 == pair.1.sourceSHA256
                                  && pair.0.sha256 == pair.1.submittedSHA256
                          }) else {
                        throw GenerationRequestError.optionsInvalid(
                            "The prepared image references differ from the semantic frame plan."
                        )
                    }
                }
            default: referenceSnapshot = nil
            }
        } catch { return .failure(.optionsInvalid(error.localizedDescription)) }
        do {
            let recipe = request.precompiled.flatMap {
                PromptCompiler.rememberedRecipe(token: $0.token, text: compiled, modelId: request.modelId)
            }
            let repairPlanID: String?
            if case .video(let video, _) = prepared {
                var input = video.genInput
                input.compileRecipe = recipe
                input.referenceReceipts = referenceSnapshot?.receipts
                repairPlanID = try await TakeRepairPlan.requireForGeneration(input: input, home: requestHome)
            } else { repairPlanID = nil }
            guard editor.workingRoot == requestHome,
                  try await PromptCompiler.currentBinding(editor: editor, shotId: binding.shotId,
                    modality: request.composerModality, modelId: request.modelId)
                    .matchesCurrentState(of: binding),
                  try await PromptComposer.inputFingerprint(projectDir: requestHome) == compilerInputsSHA256 else {
                return .failure(.gate("The project or approved direction changed during preparation. Prepare the request again."))
            }
            try scope?.requireCurrent(editor: editor)
            try destination.requireCurrent(editor: editor)
            return .success(PreparedGeneration(request: request, submission: prepared, target: target,
                compiledPrompt: compiled, notes: notes, home: requestHome, scope: scope, binding: binding,
                compilerInputsSHA256: compilerInputsSHA256, destination: destination,
                recipe: recipe, repairPlanID: repairPlanID, references: referenceSnapshot, preflight: preflight))
        } catch { return .failure(.gate(error.localizedDescription)) }
    }

    @discardableResult
    static func submitPrepared(
        _ generation: PreparedGeneration,
        editor: EditorViewModel,
        musicProgress: MusicProgress? = nil,
        onSuccess: (@MainActor (MediaAsset?) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil,
        quoteLoader: GenerationBudgetGuard.QuoteLoader = LiveGenerationPricing.quote
    ) async -> Result<GenerationOutcome, GenerationRequestError> {
        let request = generation.request, prepared = generation.submission
        let target = generation.target, referenceSnapshot = generation.references
        let requestHome = generation.home
        do {
            try generation.claimSubmission()
            if let item = generation.batchItem, let package = generation.reviewedPackage {
                try item.requireQueued(package: package, editor: editor)
            }
            if let error = generation.preflight?() { return .failure(.optionsInvalid(error)) }
            guard editor.workingRoot == requestHome else { return .failure(.gate("The prepared request belongs to another project.")) }
            try generation.scope?.requireCurrent(editor: editor)
            try generation.destination.requireCurrent(editor: editor)
            guard try await PromptCompiler.currentBinding(editor: editor, shotId: generation.binding.shotId,
                modality: request.composerModality, modelId: request.modelId)
                .matchesCurrentState(of: generation.binding),
                  try await PromptComposer.inputFingerprint(projectDir: requestHome) == generation.compilerInputsSHA256 else {
                return .failure(.gate("The approved direction changed. Prepare and review the generation again."))
            }
            try await referenceSnapshot?.requireUnchanged()
            if case .video(let video, _) = prepared {
                try referenceSnapshot?.requireIdentity(video.references)
                var input = video.genInput
                input.compileRecipe = generation.recipe
                input.referenceReceipts = referenceSnapshot?.receipts
                guard try await TakeRepairPlan.requireForGeneration(input: input, home: requestHome) == generation.repairPlanID else {
                    return .failure(.gate("The iteration decision changed. Review the generation again."))
                }
            } else if case .image(let image, _) = prepared {
                try referenceSnapshot?.requireIdentity(image.references)
            }
            try generation.scope?.requireCurrent(editor: editor)
        } catch { return .failure(.gate(error.localizedDescription)) }
        let authorization: GenerationAuthorization
        do {
            let priced = try await GenerationBudgetGuard.authorize(
                input: pricingInput(request, prepared: prepared, compiledPrompt: generation.compiledPrompt),
                target: target, editor: editor, approvedPackage: generation.reviewedPackage, quoteLoader: quoteLoader)
            do {
                let package = try generation.reviewedPackage ?? makePackage(generation, estimate: priced.estimate)
                try package?.persist(editor: editor)
                authorization = GenerationAuthorization(transactionId: priced.transactionId, target: priced.target, estimate: priced.estimate,
                    projectMutationScope: priced.projectMutationScope, takeRepairPlanID: generation.repairPlanID,
                    compileRecipe: generation.recipe, referenceSnapshot: referenceSnapshot, generationPackage: package,
                    batchItem: generation.batchItem)
            } catch {
                try? editor.recordSpendEvent(authorization: priced, kind: .released, note: error.localizedDescription)
                throw error
            }
        } catch { return .failure(.budget(error.localizedDescription)) }
        do {
            try await referenceSnapshot?.requireUnchanged()
            guard editor.workingRoot == requestHome else { throw GenerationRequestError.gate("The active project changed during reference validation.") }
            try authorization.projectMutationScope?.requireCurrent(editor: editor)
            try generation.destination.requireCurrent(editor: editor)
        }
        catch {
            try? editor.recordSpendEvent(authorization: authorization, kind: .released, note: error.localizedDescription)
            return .failure(.optionsInvalid(error.localizedDescription))
        }

        if editor.workingRoot != nil {
            do {
                _ = try editor.prepareWorkingMediaDirectory()
            } catch {
                try? editor.recordSpendEvent(
                    authorization: authorization,
                    kind: .released,
                    note: error.localizedDescription
                )
                return .failure(.storage(error.localizedDescription))
            }
        }

        // (c) SUBMIT — the adapter's existing provider submission, with the compiled prompt injected.
        // (d) FEEDBACK — placeholder auto-selected where placed; the outcome is returned uniformly.
        let placeholderId = dispatch(
            request, prepared: prepared, editor: editor,
            authorization: authorization,
            musicProgress: musicProgress, onSuccess: onSuccess, onFailure: onFailure)
        return .success(GenerationOutcome(placeholderId: placeholderId, notes: generation.notes))
    }

    // MARK: - Compile

    private static func compilePrompt(
        _ request: GenerationRequest, editor: EditorViewModel
    ) async throws -> (text: String, notes: [String]) {
        // Upscale carries no prompt — nothing to compose or gate.
        if request.modality == .upscale { return ("", []) }

        let intent = request.intent.trimmingCharacters(in: .whitespacesAndNewlines)

        // Raw escape (agent pro toggle) or an agent-precompiled token: validate through the gate
        // exactly as generate_* does today, and pass the text straight through — no recompile. An
        // empty prompt (audio scored purely from a video) skips the gate, as the tool did before.
        if request.origin == .agentTool {
            if request.rawPrompt {
                do {
                    try await PromptCompiler.enforceGate(
                        args: [
                            "rawPrompt": true,
                            "shotId": "none",
                        ],
                        prompt: intent,
                        modelId: request.modelId,
                        editor: editor)
                } catch let e as ToolError {
                    throw GenerationRequestError.gate(e.message)
                }
                return (intent, [])
            }
            if let precompiled = request.precompiled {
                do {
                    try await PromptCompiler.enforceGate(
                        args: [
                            "compileToken": precompiled.token,
                            "shotId": precompiled.binding.shotId,
                        ],
                        prompt: precompiled.text,
                        modelId: request.modelId,
                        editor: editor)
                } catch let e as ToolError {
                    throw GenerationRequestError.gate(e.message)
                }
                return (precompiled.text, [])
            }
            guard intent.isEmpty else {
                throw GenerationRequestError.gate(
                    "Agent generation requires a validated compile_prompt result."
                )
            }
            return ("", [])
        }

        // Empty intent: nothing to compose (a chip-only music dialog, or audio scored from a video).
        guard !intent.isEmpty else { return ("", []) }

        do {
            let composition = try await PromptComposer.compose(
                intent: intent,
                modality: request.composerModality,
                modelId: request.modelId,
                aspectRatio: request.aspectRatio,
                durationSeconds: request.durationSeconds,
                projectDir: editor.workingRoot,
                preserveComposition: request.target?.binding?
                    .resolvedVideoCapabilities?
                    .inputPolicy.preservesSourceComposition == true)
            return (composition.text, composition.notes)
        } catch let e as PromptComposer.ComposeError {
            throw GenerationRequestError.compile(e.errorDescription ?? "Prompt compilation failed.")
        }
    }

    // MARK: - Submit + placement

    private static func dispatch(
        _ request: GenerationRequest,
        prepared: PreparedSubmission,
        editor: EditorViewModel,
        authorization: GenerationAuthorization,
        musicProgress: MusicProgress?,
        onSuccess: (@MainActor (MediaAsset?) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) -> String {
        let service = editor.generationService
        let projectURL = editor.workingRoot

        switch prepared {
        case .video(let submission, let parameters):
            let onComplete = replacementOnComplete(request, editor: editor, destination: authorization.generationPackage?.payload.destination, then: onSuccess)
            let id = submission.submit(
                service: service, projectURL: projectURL, editor: editor,
                authorization: authorization, preparedParameters: parameters,
                onComplete: onComplete, onFailure: failureHandler(request, editor: editor, then: onFailure))
            place(request, placeholderId: id, editor: editor)
            return id
        case .image(let submission, let parameters):
            let onComplete = replacementOnComplete(request, editor: editor, destination: authorization.generationPackage?.payload.destination, then: onSuccess)
            let id = submission.submit(
                service: service, projectURL: projectURL, editor: editor,
                authorization: authorization, preparedParameters: parameters,
                onComplete: onComplete, onFailure: failureHandler(request, editor: editor, then: onFailure))
            place(request, placeholderId: id, editor: editor)
            return id
        case .audio(let submission):
            let id = submission.submit(
                service: service, projectURL: projectURL, editor: editor,
                authorization: authorization,
                onComplete: audioOnComplete(request, editor: editor, then: onSuccess),
                onFailure: failureHandler(request, editor: editor, then: onFailure))
            place(request, placeholderId: id, editor: editor)
            return id
        case .music(let submission):
            // MusicGenerationSubmission owns its own async run + placement; the outcome flows through
            // the success/failure callbacks (the music tab renders them as its Banner). No library
            // placeholder id to return, so the outcome carries an empty id for this path.
            runMusic(
                submission, editor: editor,
                authorization: authorization,
                progress: musicProgress, onSuccess: onSuccess, onFailure: onFailure)
            return ""
        case .upscale(let run):
            let onComplete = replacementOnComplete(request, editor: editor, destination: authorization.generationPackage?.payload.destination, then: onSuccess)
            let id = run(
                service, projectURL, editor,
                authorization,
                onComplete, failureHandler(request, editor: editor, then: onFailure))
            place(request, placeholderId: id, editor: editor)
            return id
        }
    }

    private static func pricingInput(
        _ request: GenerationRequest,
        prepared: PreparedSubmission,
        compiledPrompt: String
    ) -> GenerationPricingInput {
        var duration = request.durationSeconds
        var outputCount = 1
        var resolution: String?
        var quality: String?
        var generateAudio: Bool?

        switch prepared {
        case .video(let submission, let parameters):
            duration = submission.placeholderDuration
            if case .video(let params) = parameters.parameters {
                duration = params.duration.seconds.map(Double.init) ?? duration
                resolution = params.resolution
                generateAudio = params.generateAudio
            }
        case .image(let submission, let parameters):
            outputCount = max(1, submission.numImages)
            if case .image(let params) = parameters.parameters {
                resolution = params.resolution
                quality = params.quality
            }
        case .audio(let submission):
            let params = submission.params
            duration = params.durationSeconds.map(Double.init) ?? duration
        case .music(let submission):
            duration = submission.spanSeconds
        case .upscale:
            break
        }

        return GenerationPricingInput(
            modelId: request.modelId,
            modality: request.modality,
            durationSeconds: duration,
            outputCount: outputCount,
            resolution: resolution,
            quality: quality,
            promptCharacterCount: compiledPrompt.count,
            generateAudio: generateAudio
        )
    }

    /// Placeholder placement + selection. Library placements select in the media panel; timeline
    /// placements drop a generating clip at the span and select it. Replace-clip placement is handled
    /// in the submission's onComplete (the asset id isn't known until it lands).
    private static func place(_ request: GenerationRequest, placeholderId: String, editor: EditorViewModel) {
        switch request.placement {
        case .mediaLibrary:
            if request.origin != .agentTool {
                // The agent places via add_clips itself; UI surfaces reveal the placeholder.
                editor.selectMediaPanelItem(placeholderId)
            }
        case .timelineAt(let startFrame, let spanSeconds, let actionName):
            editor.placeGeneratingAudioClip(
                placeholderId: placeholderId, startFrame: startFrame, spanSeconds: spanSeconds,
                actionName: actionName ?? "Add \(actionLabel(request))")
            editor.selectedClipIds = [placeholderId]
        case .replaceClip(let id, _):
            editor.markPendingReplacement(clipId: id)
        }
    }

    private static func replacementOnComplete(
        _ request: GenerationRequest, editor: EditorViewModel,
        destination: GenerationPackageV1.Destination? = nil,
        then onSuccess: (@MainActor (MediaAsset?) -> Void)?
    ) -> (@MainActor (MediaAsset) -> Void)? {
        guard case .replaceClip(let clipId, let resetTrim) = request.placement else {
            guard let onSuccess else { return nil }
            return { asset in onSuccess(asset) }
        }
        let firstOnly = FirstOnlyFlag()
        return { [weak editor] newAsset in
            guard firstOnly.fire() else { return }
            if let editor, let destination {
                do { try destination.requireCurrent(editor: editor) }
                catch {
                    editor.clearPendingReplacement(clipId: clipId)
                    editor.mediaPanelToast = MediaPanelToast(message: "The generated media is saved in Media. The clip changed during generation and was not replaced.")
                    onSuccess?(newAsset)
                    return
                }
            }
            editor?.replaceClipMediaRef(clipId: clipId, newAssetId: newAsset.id, resetTrim: resetTrim)
            editor?.clearPendingReplacement(clipId: clipId)
            onSuccess?(newAsset)
        }
    }

    private static func audioOnComplete(
        _ request: GenerationRequest, editor: EditorViewModel,
        then onSuccess: (@MainActor (MediaAsset?) -> Void)?
    ) -> (@MainActor (MediaAsset) -> Void)? {
        guard case .timelineAt = request.placement else {
            // Library and replace-clip placements share the video/image completion path.
            return replacementOnComplete(request, editor: editor, then: onSuccess)
        }
        return { [weak editor] asset in
            editor?.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
            onSuccess?(asset)
        }
    }

    private static func failureHandler(
        _ request: GenerationRequest, editor: EditorViewModel,
        then onFailure: (@MainActor () -> Void)?
    ) -> (@MainActor () -> Void)? {
        switch request.placement {
        case .replaceClip(let clipId, _):
            return { [weak editor] in
                editor?.clearPendingReplacement(clipId: clipId)
                onFailure?()
            }
        case .mediaLibrary where request.origin != .agentTool:
            // Uniform failure surface for library placements: the failed tile can sit below the
            // fold, so name the failure where the user is looking. Agent failures return through
            // the tool result instead.
            return { [weak editor] in
                editor?.mediaPanelToast = "Generation failed — open the item for details."
                onFailure?()
            }
        default:
            return onFailure
        }
    }

    /// Drive a `MusicGenerationSubmission` through its own async run. It creates + places its
    /// placeholder on the timeline internally; phase/finish drive the music tab's spinner, and
    /// success/failure flow through the callbacks.
    private static func runMusic(
        _ submission: MusicGenerationSubmission, editor: EditorViewModel,
        authorization: GenerationAuthorization,
        progress: MusicProgress?,
        onSuccess: (@MainActor (MediaAsset?) -> Void)?, onFailure: (@MainActor () -> Void)?
    ) {
        Task { @MainActor in
            do {
                try await submission.run(
                    service: editor.generationService,
                    projectURL: editor.workingRoot,
                    editor: editor,
                    authorization: authorization,
                    onPhase: { progress?.onPhase?($0) },
                    onFinished: { progress?.onFinished?() },
                    onSucceeded: { onSuccess?(nil) })
            } catch {
                try? editor.recordSpendEvent(
                    authorization: authorization,
                    kind: .released,
                    note: error.localizedDescription
                )
                progress?.onFinished?()
                onFailure?()
            }
        }
    }

    private static func actionLabel(_ request: GenerationRequest) -> String {
        switch request.modality {
        case .music: return "Music"
        case .audio: return "Audio"
        case .video: return "Video"
        case .image: return "Image"
        case .upscale: return "Upscale"
        }
    }
}
