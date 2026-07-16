import Foundation
import NexGenEngine

extension ToolExecutor {
    func generate(_ editor: EditorViewModel, _ args: [String: Any], type: ClipType) async throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        switch type {
        case .video:
            guard let modelId = args.string("model").map { ModelCatalog.shared.internalId(forLogical: $0) } ?? VideoModelConfig.allModels.first?.id else {
                throw ToolError("Model catalog not loaded yet. Try again in a moment.")
            }
            guard let model = VideoModelConfig.allModels.first(where: { $0.id == modelId }) else {
                throw ToolError("Unknown model '\(modelId)'. Available: \(VideoModelConfig.allModels.map(\.id).joined(separator: ", "))")
            }
            return model.requiresSourceVideo
                ? try await generateVideoEdit(editor, args, prompt: prompt, model: model)
                : try await generateVideoText(editor, args, prompt: prompt, model: model)
        case .image:
            return try await generateImage(editor, args, prompt: prompt)
        case .audio:
            throw ToolError("internal: audio generation is dispatched via the async path")
        case .text:
            throw ToolError("Text generation is not wired through the generate tool.")
        case .lottie:
            throw ToolError("Lottie animations aren't generated through this tool.")
        }
    }

    /// Turn a `GenerationController` result into the tool's `.ok`/error surface, reusing the same
    /// error copy the surfaces used before (the gate/compile messages come straight through).
    private func routeThroughController(
        _ request: GenerationRequest, editor: EditorViewModel,
        preflight: GenerationController.Preflight? = nil,
        success: (String) -> String
    ) async throws -> ToolResult {
        switch await GenerationController.submit(request, editor: editor, preflight: preflight) {
        case .success(let outcome):
            return .ok(success(outcome.placeholderId))
        case .failure(let error):
            throw ToolError(error.errorDescription ?? "Generation failed.")
        }
    }

    /// The agent's precompiled prompt (from compile_prompt) + token, or nil for the raw-prompt escape.
    private static func agentPrompt(_ args: [String: Any], prompt: String) -> (precompiled: (text: String, token: String)?, raw: Bool) {
        if args.bool("rawPrompt") == true { return (nil, true) }
        return ((text: prompt, token: args.string("compileToken") ?? ""), false)
    }

    // MARK: - Cost-Guard (M7) — the user's final word on paid agent renders

    /// Gate a paid render on the user's approval. Returns the model id to actually run — the same one
    /// when kept or under the auto-approve ceiling, a cheaper one when the user swaps. Throws when the
    /// user declines, so the agent stops and asks rather than spending anyway. This is the one place an
    /// agent render waits for a human tap; it is never agent-self-asserted.
    @MainActor
    private func confirmSpend(
        _ editor: EditorViewModel, currentModelId: String, currentModelName: String,
        credits: Int?, actionLabel: String, alternatives: [SpendAlternative]
    ) async throws -> String {
        guard CostGuard.needsApproval(credits: credits) else { return currentModelId }
        let approval = SpendApproval(
            id: UUID().uuidString,
            modelId: currentModelId, modelName: currentModelName,
            providerLabel: GenerationProvider.servicing(modelId: currentModelId).displayName,
            credits: credits, alternatives: alternatives, actionLabel: actionLabel)
        switch await editor.agentService.requestSpendApproval(approval) {
        case .approved(let modelId):
            // The turn may have been cancelled (tab switch/new chat) while the card was up — never
            // spend on a cancelled turn even if an approval slipped through.
            try Task.checkCancellation()
            return modelId
        case .declined:
            throw ToolError("Render declined — the user did not approve the spend. Ask what they'd prefer: a cheaper model, different settings, or skip this render.")
        }
    }

    /// Cheaper runnable video models than the current pick, cost-ascending (≤ 3). `requiresSource`
    /// keeps text-to-video and video-edit swaps within their own kind so a swap stays valid.
    @MainActor
    private func cheaperVideoAlternatives(
        than modelId: String, currentCredits: Int?, duration: Int, resolution: String?, requiresSource: Bool
    ) -> [SpendAlternative] {
        guard let current = currentCredits else { return [] }
        return VideoModelConfig.allModels
            .filter { $0.id != modelId && $0.requiresSourceVideo == requiresSource && GenerationProvider.canRun(modelId: $0.id) }
            .compactMap { m -> SpendAlternative? in
                guard let c = CostEstimator.videoCost(
                    model: m, durationSeconds: duration,
                    resolution: resolution ?? m.resolutions?.first, generateAudio: true),
                    c < current else { return nil }
                return SpendAlternative(
                    modelId: m.id, name: m.displayName,
                    providerLabel: GenerationProvider.servicing(modelId: m.id).displayName, credits: c)
            }
            .sorted { ($0.credits ?? 0) < ($1.credits ?? 0) }
            .prefix(3).map { $0 }
    }

    @MainActor
    private func cheaperImageAlternatives(
        than modelId: String, currentCredits: Int?, resolution: String?, quality: String?
    ) -> [SpendAlternative] {
        guard let current = currentCredits else { return [] }
        return ImageModelConfig.allModels
            .filter { $0.id != modelId && !MarbleModelRegistry.isMarbleModel($0.id) && GenerationProvider.canRun(modelId: $0.id) }
            .compactMap { m -> SpendAlternative? in
                guard let c = CostEstimator.imageCost(
                    model: m, resolution: resolution ?? m.resolutions?.first,
                    quality: quality ?? m.qualities?.last, numImages: 1),
                    c < current else { return nil }
                return SpendAlternative(
                    modelId: m.id, name: m.displayName,
                    providerLabel: GenerationProvider.servicing(modelId: m.id).displayName, credits: c)
            }
            .sorted { ($0.credits ?? 0) < ($1.credits ?? 0) }
            .prefix(3).map { $0 }
    }

    private func generateVideoEdit(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model modelIn: VideoModelConfig
    ) async throws -> ToolResult {
        var model = modelIn
        guard let sourceRef = args.string("sourceVideoMediaRef") else {
            throw ToolError("Model '\(model.id)' requires 'sourceVideoMediaRef' pointing to a video asset.")
        }
        let sourceAsset = try asset(sourceRef, editor: editor, label: "Source video")
        let trimmed = try trimmedSource(args, editor: editor, source: sourceAsset)

        // Cost-Guard (M7): approval before spend. Edit is source-driven, so a swap stays within the
        // other source-requiring video models (a text-to-video model can't service an edit).
        let editSeconds = Int((trimmed?.durationSeconds ?? sourceAsset.duration).rounded())
        let editCredits = CostEstimator.videoCost(
            model: model, durationSeconds: editSeconds, resolution: nil, generateAudio: true)
        let editFinalId = try await confirmSpend(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: editCredits, actionLabel: "Generate edit",
            alternatives: cheaperVideoAlternatives(
                than: model.id, currentCredits: editCredits, duration: editSeconds,
                resolution: nil, requiresSource: true))
        if editFinalId != model.id, let swapped = VideoModelConfig.allModels.first(where: { $0.id == editFinalId }) {
            model = swapped
        }

        var imageRefs: [MediaAsset] = []
        for id in args.stringArray("referenceImageMediaRefs") {
            imageRefs.append(try asset(id, editor: editor, label: "Reference image"))
        }

        let inputAssets = VideoGenerationSubmission.InputAssets(sourceVideo: sourceAsset, imageRefs: imageRefs)
        let name = args.string("name")
        let folderId = sourceAsset.folderId
        let placeholderDuration = trimmed?.durationSeconds ?? (sourceAsset.duration > 0 ? sourceAsset.duration : 5)
        let (precompiled, raw) = Self.agentPrompt(args, prompt: prompt)

        let request = GenerationRequest(
            modality: .video, modelId: model.id, intent: prompt,
            placement: .mediaLibrary(folderId: folderId), origin: .agentTool,
            precompiled: precompiled, rawPrompt: raw,
            submission: .video(make: { compiled in
                let genInput = GenerationInput(
                    prompt: compiled, model: model.id, duration: Int(sourceAsset.duration.rounded()),
                    aspectRatio: "", resolution: nil)
                return VideoGenerationSubmission.make(
                    genInput: genInput, model: model, inputAssets: inputAssets,
                    placeholderDuration: placeholderDuration, trimmedSourceOverride: trimmed,
                    name: name, folderId: folderId, generateAudio: true)
            }))
        return try await routeThroughController(
            request, editor: editor,
            preflight: {
                if let err = model.validate(duration: 0, aspectRatio: "", resolution: nil) { return err }
                return inputAssets.validate(for: model)
            },
            success: { "Edit started. Placeholder asset ID: \($0). Model: \(model.displayName), source: \(sourceAsset.name)" })
    }

    private func generateVideoText(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model modelIn: VideoModelConfig
    ) async throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }

        var model = modelIn
        var duration = args.int("duration") ?? model.durations.first ?? 0
        var aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        var resolution = args.string("resolution") ?? model.resolutions?.first

        // Cost-Guard (M7): the user's final word before this render spends money. Over the
        // auto-approve ceiling → wait for a tap; a swap re-derives options against the chosen model.
        let credits = CostEstimator.videoCost(
            model: model, durationSeconds: duration, resolution: resolution, generateAudio: true)
        let finalModelId = try await confirmSpend(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: credits, actionLabel: "Generate video",
            alternatives: cheaperVideoAlternatives(
                than: model.id, currentCredits: credits, duration: duration,
                resolution: resolution, requiresSource: false))
        if finalModelId != model.id, let swapped = VideoModelConfig.allModels.first(where: { $0.id == finalModelId }) {
            model = swapped
            if !swapped.durations.contains(duration) { duration = swapped.durations.first ?? duration }
            if !swapped.aspectRatios.contains(aspectRatio) { aspectRatio = swapped.aspectRatios.first ?? aspectRatio }
            if let allowed = swapped.resolutions, let r = resolution, !allowed.contains(r) { resolution = allowed.first }
        }

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
        let inputAssets = VideoGenerationSubmission.InputAssets(
            frames: frameSlots,
            imageRefs: imageRefs,
            videoRefs: videoRefs,
            audioRefs: audioRefs
        )
        let imageRefCount = imageRefs.count
        let videoRefCount = videoRefs.count
        let audioRefCount = audioRefs.count
        let totalRefs = inputAssets.totalRefCount

        let folderId = try resolveFolderId(
            args, editor: editor, fallbackReferences: inputAssets.textToVideoReferences
        )
        let name = args.string("name")
        let (precompiled, raw) = Self.agentPrompt(args, prompt: prompt)

        let request = GenerationRequest(
            modality: .video, modelId: model.id, intent: prompt,
            aspectRatio: aspectRatio, durationSeconds: Double(duration),
            placement: .mediaLibrary(folderId: folderId), origin: .agentTool,
            precompiled: precompiled, rawPrompt: raw,
            submission: .video(make: { compiled in
                let genInput = GenerationInput(
                    prompt: compiled, model: model.id, duration: duration,
                    aspectRatio: aspectRatio, resolution: resolution)
                return VideoGenerationSubmission.make(
                    genInput: genInput, model: model, inputAssets: inputAssets,
                    placeholderDuration: Double(max(1, duration)),
                    name: name, folderId: folderId, generateAudio: true)
            }))
        let refSummary = totalRefs > 0
            ? ", refs: \(imageRefCount)img/\(videoRefCount)vid/\(audioRefCount)aud"
            : ""
        return try await routeThroughController(
            request, editor: editor,
            preflight: {
                if let err = model.validate(duration: duration, aspectRatio: aspectRatio, resolution: resolution) { return err }
                return inputAssets.validate(for: model)
            },
            success: { "Generation started. Placeholder asset ID: \($0). Model: \(model.displayName), duration: \(duration)s, aspect: \(aspectRatio)\(refSummary)" })
    }

    private func generateImage(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) async throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }
        guard var modelId = args.string("model").map({ ModelCatalog.shared.internalId(forLogical: $0) }) ?? ImageModelConfig.allModels.first?.id else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard var model = ImageModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(ImageModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }
        var aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        var resolution = args.string("resolution") ?? model.resolutions?.first
        var quality = args.string("quality") ?? model.qualities?.last

        // Cost-Guard (M7): approval before spend. Marble is excluded as a swap target — it is a
        // reference-driven world generator, not a drop-in cheaper image model.
        let credits = CostEstimator.imageCost(
            model: model, resolution: resolution, quality: quality, numImages: 1)
        let finalModelId = try await confirmSpend(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: credits, actionLabel: "Generate image",
            alternatives: cheaperImageAlternatives(
                than: model.id, currentCredits: credits, resolution: resolution, quality: quality))
        if finalModelId != model.id, let swapped = ImageModelConfig.allModels.first(where: { $0.id == finalModelId }) {
            model = swapped
            modelId = swapped.id
            if !swapped.aspectRatios.contains(aspectRatio) { aspectRatio = swapped.aspectRatios.first ?? aspectRatio }
            if let allowed = swapped.resolutions, let r = resolution, !allowed.contains(r) { resolution = allowed.first }
            if let allowed = swapped.qualities, let q = quality, !allowed.contains(q) { quality = allowed.last }
        }

        let refIds = args.stringArray("referenceMediaRefs")
        let refs: [MediaAsset] = try refIds.map { id in
            let a = try asset(id, editor: editor, label: "Reference image")
            guard a.type == .image else {
                throw ToolError("referenceMediaRefs entry '\(id)' must be an image asset (got \(a.type.rawValue))")
            }
            return a
        }
        let folderId = try resolveFolderId(args, editor: editor, fallbackReferences: refs)
        let name = args.string("name")
        let (precompiled, raw) = Self.agentPrompt(args, prompt: prompt)

        func genInput(_ compiled: String) -> GenerationInput {
            GenerationInput(
                prompt: compiled, model: modelId, duration: 0,
                aspectRatio: aspectRatio, resolution: resolution, quality: quality)
        }
        let preflight: GenerationController.Preflight = {
            model.validate(
                aspectRatio: aspectRatio, resolution: resolution, quality: quality,
                imageRefCount: refIds.count, numImages: 1)
        }

        if MarbleModelRegistry.isMarbleModel(modelId) {
            guard let reference = refs.first else {
                throw ToolError("\(model.displayName) requires a reference image via 'referenceMediaRefs' (the world is generated from it).")
            }
            let request = GenerationRequest(
                modality: .image, modelId: modelId, intent: prompt, aspectRatio: aspectRatio,
                placement: .mediaLibrary(folderId: folderId), origin: .agentTool,
                precompiled: precompiled, rawPrompt: raw,
                submission: .image(make: { compiled in
                    ImageGenerationSubmission.makeMarble(
                        genInput: genInput(compiled), model: model, reference: reference,
                        name: name, folderId: folderId)
                }))
            return try await routeThroughController(
                request, editor: editor, preflight: preflight,
                success: { "Marble world generation started (this can take several minutes). Placeholder asset ID: \($0). Model: \(model.displayName). Result: equirectangular panorama image." })
        }

        let request = GenerationRequest(
            modality: .image, modelId: modelId, intent: prompt, aspectRatio: aspectRatio,
            placement: .mediaLibrary(folderId: folderId), origin: .agentTool,
            precompiled: precompiled, rawPrompt: raw,
            submission: .image(make: { compiled in
                ImageGenerationSubmission.make(
                    genInput: genInput(compiled), model: model, references: refs,
                    name: name, folderId: folderId)
            }))
        return try await routeThroughController(
            request, editor: editor, preflight: preflight,
            success: { "Generation started. Placeholder asset ID: \($0). Model: \(model.displayName), aspect: \(aspectRatio)" })
    }

    func showDialog(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let dialog = try AgentDialog.parse(args)
        editor.agentService.pendingDialog = dialog
        editor.agentPanelVisible = true
        // Canvas projection (A3, #124): reveal the Review gallery at the shot so its candidates are
        // where the user decides. Timeline-range projection needs no reveal — the timeline is always
        // on. v1: picking a frame candidate in Review while the dialog is pending is the follow-up.
        if let shot = dialog.projection.reviewShot {
            editor.revealCockpit(.review)
            editor.inspectedObject = .shot(shot)
        }
        return .ok("Dialog \u{201C}\(dialog.title)\u{201D} is presented in the composer. STOP \u{2014} the user's structured answer arrives as the next user message; do not act on this step until then.")
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
        // #231: `shotId` is REQUIRED and has no default — "none" is the explicit free-intent choice. It
        // used to be optional, so forgetting it degraded the compile silently: no camera projection from
        // the spec, no drift lint, no error. The contract now forces the decision instead of asking the
        // agent to remember it; an unknown id is refused rather than quietly treated as free intent.
        let projection = try shotProjection(try args.requireString("shotId"), editor: editor)
        // Same contract as before ({ compiledPrompt, compileToken, notes }); composition now runs the
        // ENGINE path (PromptComposer: ledger directives + provider builder + PromptLinter) instead of
        // the old local ledger text-append, then the gate mints the token over the result.
        let compiled = try await PromptCompiler.compile(
            intent: intent, modelId: modelId,
            modality: PromptCompiler.modalityForModel(modelId), editor: editor, shot: projection)
        let body: [String: Any] = [
            "compiledPrompt": compiled.text,
            "compileToken": compiled.token,
            "notes": compiled.notes,
        ]
        guard let json = Self.jsonString(body) else { return .error("Failed to encode compiled prompt") }
        return .ok(json)
    }

    /// Build a per-shot projection for `compile_prompt`'s required `shotId` — loads the shot from the
    /// open project's shotlist and derives the deterministic camera/framing projection plus the
    /// compliance read-surface (#197). `"none"` is the explicit free-intent choice → nil.
    ///
    /// An id that names no shot THROWS (#231). It would otherwise be indistinguishable from free intent,
    /// which is the silent degradation this contract exists to prevent: a typo'd id would drop the
    /// camera projection and the drift lint without a word. A project that has no shotlist yet is a
    /// normal state, not a violation — only a real miss against a real shotlist is an error.
    private func shotProjection(_ shotId: String, editor: EditorViewModel) throws -> PromptComposer.ShotProjection? {
        guard shotId != "none" else { return nil }
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
              let shotlist = (try? loadShotlist(dataRoot: root)) ?? nil else { return nil }
        guard let shot = shotlist.shots.first(where: { $0.id == shotId }) else {
            throw ToolError(
                "No shot '\(shotId)' in the shotlist. Pass a real shot id from next_render_shot, or "
                + "\"none\" if this prompt belongs to no shot — but note that \"none\" compiles without "
                + "the shot's camera projection and without the drift check.")
        }
        return PromptComposer.ShotProjection(shot)
    }

    func generateAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        guard let modelId = args.string("model").map { ModelCatalog.shared.internalId(forLogical: $0) } ?? AudioModelConfig.allModels.first?.id else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let model = AudioModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(AudioModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }

        let prompt = (args.string("prompt") ?? "").trimmingCharacters(in: .whitespaces)
        let acceptsVideo = model.inputs.contains(.video)
        var videoURL: String?
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
            throw GenerationBackendError.notConfigured
        } else if let start = args.int("videoSourceStartFrame"), let end = args.int("videoSourceEndFrame") {
            guard acceptsVideo else {
                throw ToolError("Model '\(model.id)' does not accept a video input (see list_models 'inputs').")
            }
            guard start >= 0, end > start else {
                throw ToolError("videoSourceEndFrame must be greater than videoSourceStartFrame (>= 0).")
            }
            let mp4 = try await TimelineRenderer.render(
                timeline: editor.timeline, resolver: editor.mediaResolver,
                startFrame: start, frameCount: end - start,
                shortSide: 360, includeAudio: false
            )
            try? FileManager.default.removeItem(at: mp4)
            throw GenerationBackendError.notConfigured
        }

        // A video-only model (no text input, e.g. Mirelo) needs a source.
        if acceptsVideo && !model.inputs.contains(.text) && videoURL == nil {
            throw ToolError("Model '\(model.id)' generates audio from video. Provide videoSourceStartFrame + videoSourceEndFrame (a timeline span) or videoSourceMediaRef.")
        }

        let instrumental = args.bool("instrumental") ?? false
        let durationSeconds = args.int("duration") ?? spanSeconds.map { max(1, Int($0.rounded())) }
        let voice = model.voices != nil ? (args.string("voice") ?? model.defaultVoice) : nil
        let lyrics = model.supportsLyrics ? args.string("lyrics") : nil
        let styleInstructions = model.supportsStyleInstructions ? args.string("styleInstructions") : nil
        let name = args.string("name")
        let folderId = try resolveFolderId(args, editor: editor)
        let (precompiled, raw) = Self.agentPrompt(args, prompt: prompt)

        // Cost-Guard (M7): the user's final word before this paid audio render. No swap — audio models
        // vary by category/voice/inputs, so an alternative isn't a drop-in; approval only.
        let audioCredits = CostEstimator.audioCost(model: model, prompt: prompt, durationSeconds: durationSeconds)
        _ = try await confirmSpend(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: audioCredits, actionLabel: "Generate \(model.category.label)", alternatives: [])

        // Build the submission from the CONTROLLER-compiled prompt so the audio params + genInput
        // carry the same text the gate validated.
        func makeSubmission(_ compiled: String) -> AudioGenerationSubmission {
            let params = AudioGenerationParams(
                prompt: compiled, voice: voice, lyrics: lyrics,
                styleInstructions: styleInstructions,
                instrumental: model.supportsInstrumental ? instrumental : false,
                durationSeconds: durationSeconds, videoURL: videoURL)
            let genInput = GenerationInput(
                prompt: compiled, model: model.id, duration: durationSeconds ?? 0,
                aspectRatio: "", resolution: nil, voice: params.voice, lyrics: params.lyrics,
                styleInstructions: params.styleInstructions,
                instrumental: model.supportsInstrumental ? instrumental : nil)
            return AudioGenerationSubmission.make(
                genInput: genInput, model: model, params: params, name: name, folderId: folderId)
        }
        // Preflight validates the params; build them once with the raw prompt for validation (the
        // compiled text only differs by ledger merge and never invalidates model.validate).
        let preflight: GenerationController.Preflight = {
            model.validate(params: makeSubmission(prompt).params)
        }

        let placement: GenerationRequest.Placement
        let successCopy: (String) -> String
        if let startFrame = placementStartFrame, let span = spanSeconds {
            placement = .timelineAt(startFrame: startFrame, spanSeconds: span, actionName: "Add \(model.category.label)")
            successCopy = { "Generation started and placed on the timeline at frame \(startFrame). Placeholder asset ID: \($0). Model: \(model.displayName), \(model.category.label) (scored from video)." }
        } else {
            placement = .mediaLibrary(folderId: folderId)
            let scored = videoURL != nil ? " (scored from video)" : ""
            successCopy = { "Generation started. Placeholder asset ID: \($0). Model: \(model.displayName), \(model.category.label)\(scored). Place it with add_clips." }
        }

        let request = GenerationRequest(
            modality: .audio, modelId: model.id, intent: prompt,
            durationSeconds: durationSeconds.map(Double.init),
            placement: placement, origin: .agentTool,
            precompiled: precompiled, rawPrompt: raw,
            submission: .audio(make: { makeSubmission($0) }))
        return try await routeThroughController(
            request, editor: editor, preflight: preflight, success: successCopy)
    }

    func upscaleMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video || asset.type == .image else {
            throw ToolError("Upscale supports video and image assets only (got \(asset.type.rawValue))")
        }

        let available = UpscaleModelConfig.models(for: asset.type)
        let model: UpscaleModelConfig
        if let requested = args.string("model").map { ModelCatalog.shared.internalId(forLogical: $0) } {
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
        _ = try await confirmSpend(
            editor, currentModelId: model.id, currentModelName: model.displayName,
            credits: CostEstimator.upscaleCost(model: model, durationSeconds: upSeconds),
            actionLabel: "Upscale", alternatives: [])

        guard let placeholderId = await EditSubmitter.submitUpscale(
            asset: asset, model: model, editor: editor, trimmedSource: trimmed, origin: .agentTool
        ) else {
            throw ToolError("Failed to start upscale")
        }
        return .ok("Upscale started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), source: \(asset.name)\(trimmed != nil ? " (trimmed range)" : "")")
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

    nonisolated static func videoModelInfo(_ m: VideoModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "durations": m.durations, "aspectRatios": m.aspectRatios,
            "supportsFirstFrame": m.supportsFirstFrame,
            "supportsLastFrame": m.supportsLastFrame,
            "supportsReferences": m.supportsReferences,
        ]
        if includeType { info["type"] = "video" }
        if let r = m.resolutions { info["resolutions"] = r }
        if m.supportsReferences {
            if m.maxReferenceImages > 0 { info["maxReferenceImages"] = m.maxReferenceImages }
            if m.maxReferenceVideos > 0 { info["maxReferenceVideos"] = m.maxReferenceVideos }
            if m.maxReferenceAudios > 0 { info["maxReferenceAudios"] = m.maxReferenceAudios }
            if let total = m.maxTotalReferences { info["maxTotalReferences"] = total }
            if let s = m.maxCombinedVideoRefSeconds { info["maxCombinedVideoRefSeconds"] = Int(s) }
            if let s = m.maxCombinedAudioRefSeconds { info["maxCombinedAudioRefSeconds"] = Int(s) }
            if m.framesAndReferencesExclusive { info["framesAndReferencesExclusive"] = true }
            info["referenceTagNoun"] = m.referenceTagNoun
        }
        return info
    }

    nonisolated static func imageModelInfo(_ m: ImageModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "aspectRatios": m.aspectRatios,
            "supportsImageReference": m.supportsImageReference,
        ]
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
