import Foundation

extension ToolExecutor {
    func generate(_ editor: EditorViewModel, _ args: [String: Any], type: ClipType) async throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        switch type {
        case .video:
            guard let modelId = args.string("model") ?? VideoModelConfig.allModels.first?.id else {
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

    private func generateVideoEdit(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model: VideoModelConfig
    ) async throws -> ToolResult {
        guard let sourceRef = args.string("sourceVideoMediaRef") else {
            throw ToolError("Model '\(model.id)' requires 'sourceVideoMediaRef' pointing to a video asset.")
        }
        let sourceAsset = try asset(sourceRef, editor: editor, label: "Source video")
        let trimmed = try trimmedSource(args, editor: editor, source: sourceAsset)

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
        prompt: String, model: VideoModelConfig
    ) async throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }

        let duration = args.int("duration") ?? model.durations.first ?? 0
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        let resolution = args.string("resolution") ?? model.resolutions?.first

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
        guard let modelId = args.string("model") ?? ImageModelConfig.allModels.first?.id else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let model = ImageModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(ImageModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        let resolution = args.string("resolution") ?? model.resolutions?.first
        let quality = args.string("quality") ?? model.qualities?.last
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
        let modelId = try args.requireString("model")
        // Same contract as before ({ compiledPrompt, compileToken, notes }); composition now runs the
        // ENGINE path (PromptComposer: ledger directives + provider builder + PromptLinter) instead of
        // the old local ledger text-append, then the gate mints the token over the result.
        let compiled = try await PromptCompiler.compile(
            intent: intent, modelId: modelId,
            modality: PromptCompiler.modalityForModel(modelId), editor: editor)
        let body: [String: Any] = [
            "compiledPrompt": compiled.text,
            "compileToken": compiled.token,
            "notes": compiled.notes,
        ]
        guard let json = Self.jsonString(body) else { return .error("Failed to encode compiled prompt") }
        return .ok(json)
    }

    func generateAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        guard let modelId = args.string("model") ?? AudioModelConfig.allModels.first?.id else {
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
        if let requested = args.string("model") {
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
        // A model whose backing provider has no API key is accepted but fails at request time.
        // Surface that here so the agent doesn't pick an unusable model and misread the failure.
        out = out.map { info in
            guard let id = info["id"] as? String else { return info }
            var info = info
            let provider = GenerationProvider.servicing(modelId: id)
            let available = provider.hasKey
            info["available"] = available
            if !available {
                info["unavailableReason"] = "No \(provider.displayName) API key — add one in Settings → Providers to use this model."
            }
            return info
        }
        let body: [String: Any] = [
            "models": out,
            "loaded": ModelCatalog.shared.isLoaded,
        ]
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
