import Foundation

// MARK: - Canonical request

/// The ONE request every generation surface builds (issue #114). Panel, music tab, agent tools,
/// dialogs, and rerun all describe *what to generate* as a `GenerationRequest` and hand it to
/// `GenerationController.submit` — which runs the same preflight → compile → submit → feedback
/// sequence for all of them. The provider stack (Video/Image/Audio/MusicGenerationSubmission) is
/// untouched; this is the funnel above it.
struct GenerationRequest {
    /// `.upscale` is promptless — its controller path skips the compile stage but shares the same
    /// preflight → submit → feedback sequence as the rest.
    enum Modality { case video, image, audio, music, upscale }

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
        case upscale(run: @MainActor (
            _ service: GenerationService, _ projectURL: URL?, _ editor: EditorViewModel,
            _ onComplete: (@MainActor (MediaAsset) -> Void)?, _ onFailure: (@MainActor () -> Void)?
        ) -> String)
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

    /// A precompiled prompt + token from the agent's `compile_prompt` tool. When present the
    /// controller validates it through the gate instead of composing (the token proves it came from
    /// the engine composer this run).
    let precompiled: (text: String, token: String)?
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
        precompiled: (text: String, token: String)? = nil,
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
        self.precompiled = precompiled
        self.rawPrompt = rawPrompt
        self.submission = submission
    }

    /// Only meaningful for compiled modalities. Upscale never composes (the controller skips its
    /// compile stage), so it maps arbitrarily to `.video` and is never consulted.
    var composerModality: PromptComposer.Modality {
        switch modality {
        case .video: return .video
        case .image: return .image
        case .audio: return .audio
        case .music: return .music
        case .upscale: return .video
        }
    }
}

// MARK: - Errors

enum GenerationRequestError: LocalizedError {
    case unknownModel(String)
    case optionsInvalid(String)
    case compile(String)
    case gate(String)

    var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Unknown model '\(id)'."
        case .optionsInvalid(let m): return m
        case .compile(let m): return m
        case .gate(let m): return m
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

    @discardableResult
    static func submit(
        _ request: GenerationRequest,
        editor: EditorViewModel,
        preflight: Preflight? = nil,
        musicProgress: MusicProgress? = nil,
        onSuccess: (@MainActor (MediaAsset?) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) async -> Result<GenerationOutcome, GenerationRequestError> {
        // (a) PREFLIGHT — model exists + options validate (adapter's model.validate lives here).
        if let message = preflight?() {
            return .failure(.optionsInvalid(message))
        }

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

        // (c) SUBMIT — the adapter's existing provider submission, with the compiled prompt injected.
        // (d) FEEDBACK — placeholder auto-selected where placed; the outcome is returned uniformly.
        let placeholderId = dispatch(
            request, compiledPrompt: compiled, editor: editor,
            musicProgress: musicProgress, onSuccess: onSuccess, onFailure: onFailure)
        return .success(GenerationOutcome(placeholderId: placeholderId, notes: notes))
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
                    try PromptCompiler.enforceGate(
                        args: ["rawPrompt": true], prompt: intent, modelId: request.modelId)
                } catch let e as ToolError {
                    throw GenerationRequestError.gate(e.message)
                }
                return (intent, [])
            }
            guard !intent.isEmpty else { return ("", []) }
            if let precompiled = request.precompiled {
                do {
                    try PromptCompiler.enforceGate(
                        args: ["compileToken": precompiled.token],
                        prompt: precompiled.text, modelId: request.modelId)
                } catch let e as ToolError {
                    throw GenerationRequestError.gate(e.message)
                }
                return (precompiled.text, [])
            }
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
                projectDir: editor.workingRoot)
            return (composition.text, composition.notes)
        } catch let e as PromptComposer.ComposeError {
            throw GenerationRequestError.compile(e.errorDescription ?? "Prompt compilation failed.")
        }
    }

    // MARK: - Submit + placement

    private static func dispatch(
        _ request: GenerationRequest,
        compiledPrompt: String,
        editor: EditorViewModel,
        musicProgress: MusicProgress?,
        onSuccess: (@MainActor (MediaAsset?) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) -> String {
        let service = editor.generationService
        let projectURL = editor.projectURL

        switch request.submission {
        case .video(let make):
            let onComplete = replacementOnComplete(request, editor: editor, then: onSuccess)
            let id = make(compiledPrompt).submit(
                service: service, projectURL: projectURL, editor: editor,
                onComplete: onComplete, onFailure: failureHandler(request, editor: editor, then: onFailure))
            place(request, placeholderId: id, editor: editor)
            return id
        case .image(let make):
            let onComplete = replacementOnComplete(request, editor: editor, then: onSuccess)
            let id = make(compiledPrompt).submit(
                service: service, projectURL: projectURL, editor: editor,
                onComplete: onComplete, onFailure: failureHandler(request, editor: editor, then: onFailure))
            place(request, placeholderId: id, editor: editor)
            return id
        case .audio(let make):
            let id = make(compiledPrompt).submit(
                service: service, projectURL: projectURL, editor: editor,
                onComplete: audioOnComplete(request, editor: editor, then: onSuccess),
                onFailure: failureHandler(request, editor: editor, then: onFailure))
            place(request, placeholderId: id, editor: editor)
            return id
        case .music(let make):
            // MusicGenerationSubmission owns its own async run + placement; the outcome flows through
            // the success/failure callbacks (the music tab renders them as its Banner). No library
            // placeholder id to return, so the outcome carries an empty id for this path.
            runMusic(
                make(compiledPrompt), editor: editor,
                progress: musicProgress, onSuccess: onSuccess, onFailure: onFailure)
            return ""
        case .upscale(let run):
            let onComplete = replacementOnComplete(request, editor: editor, then: onSuccess)
            let id = run(
                service, projectURL, editor,
                onComplete, failureHandler(request, editor: editor, then: onFailure))
            place(request, placeholderId: id, editor: editor)
            return id
        }
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
        then onSuccess: (@MainActor (MediaAsset?) -> Void)?
    ) -> (@MainActor (MediaAsset) -> Void)? {
        guard case .replaceClip(let clipId, let resetTrim) = request.placement else {
            guard let onSuccess else { return nil }
            return { asset in onSuccess(asset) }
        }
        let firstOnly = FirstOnlyFlag()
        return { [weak editor] newAsset in
            guard firstOnly.fire() else { return }
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
        progress: MusicProgress?,
        onSuccess: (@MainActor (MediaAsset?) -> Void)?, onFailure: (@MainActor () -> Void)?
    ) {
        Task { @MainActor in
            do {
                try await submission.run(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onPhase: { progress?.onPhase?($0) },
                    onFinished: { progress?.onFinished?() },
                    onSucceeded: { onSuccess?(nil) })
            } catch {
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
