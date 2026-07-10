import Foundation

/// Builds and dispatches AI-tab submissions (Upscale, Rerun) pipeline.
@MainActor
enum EditSubmitter {

    // MARK: - Upscale

    /// Upscale routes through the shared `GenerationController` like every other generation (#114),
    /// but as the promptless `.upscale` modality — the controller skips the compile stage while
    /// preflight/submit/feedback stay shared. Returns the placeholder id, or nil on a preflight/dispatch
    /// failure.
    @discardableResult
    static func submitUpscale(
        asset: MediaAsset,
        model: UpscaleModelConfig,
        editor: EditorViewModel,
        trimmedSource: TrimmedSource? = nil,
        origin: GenerationRequest.Origin = .panel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) async -> String? {
        let effectiveDuration: Int = {
            if let trim = trimmedSource, trim.hasTrim {
                return max(1, Int(trim.durationSeconds.rounded()))
            }
            return max(1, Int(asset.duration.rounded()))
        }()
        let genInput = GenerationInput(
            prompt: "",
            model: model.id,
            duration: effectiveDuration,
            aspectRatio: "",
            resolution: nil
        )

        let isImage = asset.type == .image
        let placeholderDuration: Double
        if isImage {
            placeholderDuration = Defaults.imageDurationSeconds
        } else if let trim = trimmedSource, trim.hasTrim {
            placeholderDuration = trim.durationSeconds
        } else {
            placeholderDuration = asset.duration > 0 ? asset.duration : Double(effectiveDuration)
        }

        let sourceAssetId = asset.id
        let request = GenerationRequest(
            modality: .upscale, modelId: model.id, intent: "",
            placement: .mediaLibrary(folderId: asset.folderId), origin: origin,
            submission: .upscale(run: { service, projectURL, editor, onComplete, onFailure in
                service.generate(
                    genInput: genInput,
                    assetType: asset.type,
                    placeholderDuration: placeholderDuration,
                    references: [asset],
                    trimmedSourceOverride: trimmedSource,
                    name: upscaleName(for: asset),
                    folderId: asset.folderId,
                    buildParams: { uploaded in
                        .upscale(UpscaleGenerationParams(
                            sourceURL: uploaded.first ?? "",
                            durationSeconds: isImage ? 1 : effectiveDuration
                        ))
                    },
                    snapshotRefs: { input, uploaded in
                        input.imageURLs = uploaded.isEmpty ? nil : uploaded
                        input.imageURLAssetIds = [sourceAssetId]
                    },
                    fileExtension: isImage ? "jpg" : "mp4",
                    projectURL: projectURL,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            }))

        let outcome = await GenerationController.submit(
            request, editor: editor,
            onSuccess: { asset in if let asset { onComplete?(asset) } },
            onFailure: onFailure)
        switch outcome {
        case .success(let o): return o.placeholderId
        case .failure: return nil
        }
    }

    // MARK: - Rerun

    enum RerunError: LocalizedError {
        case notGenerated
        case unknownModel(String)
        case missingSource
        case invalid(String)
        case compileBlocked(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .notGenerated: "This asset was not AI-generated"
            case .unknownModel(let id): "Model no longer available: \(id)"
            case .missingSource: "Cannot rerun: source not recorded"
            case .invalid(let msg): msg
            case .compileBlocked(let code, let message): "Prompt lint failed (\(code)): \(message)"
            }
        }
    }

    @discardableResult
    static func rerun(
        asset: MediaAsset,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) async throws -> String {
        guard let stored = asset.generationInput else { throw RerunError.notGenerated }
        var gen = stored
        gen.createdAt = nil
        let modelId = gen.model
        // Recompile the ORIGINAL intent against the CURRENT ledger — a lock added or changed since the
        // first render now applies. Three cases (#114 gate):
        //   (a) no stored intent (pre-#114 asset, or upscale) → nil → replay the stored compiled prompt
        //       verbatim (documented backward-compat).
        //   (b) intent stored, compose succeeds → use the freshly recompiled prompt.
        //   (c) intent stored, compose throws a lint ERROR → FAIL LOUDLY: recompiledPrompt rethrows a
        //       RerunError.compileBlocked, so no provider call happens and the caller surfaces it.
        if let recompiled = try await recompiledPrompt(gen: gen, editor: editor) {
            gen.prompt = recompiled
        }
        let preUploaded = gen.imageURLs

        if let videoModel = VideoModelConfig.allModels.first(where: { $0.id == modelId }) {
            if let err = videoModel.validate(
                duration: gen.duration, aspectRatio: gen.aspectRatio, resolution: gen.resolution
            ) {
                throw RerunError.invalid(err)
            }
            if videoModel.requiresSourceVideo {
                guard let source = preUploaded?.first else { throw RerunError.missingSource }
                let imageRefs = Array((preUploaded ?? []).dropFirst())
                let params = VideoGenerationParams(
                    prompt: gen.prompt,
                    duration: gen.duration,
                    aspectRatio: gen.aspectRatio,
                    resolution: gen.resolution,
                    sourceVideoURL: source,
                    startFrameURL: nil,
                    endFrameURL: nil,
                    referenceImageURLs: imageRefs,
                    generateAudio: gen.generateAudio ?? true
                )
                return editor.generationService.generate(
                    genInput: gen,
                    assetType: .video,
                    placeholderDuration: asset.duration > 0 ? asset.duration : Double(max(1, gen.duration)),
                    references: [],
                    preUploadedURLs: preUploaded,
                    name: rerunName(for: asset),
                    folderId: asset.folderId,
                    buildParams: { _ in .video(params) },
                    fileExtension: "mp4",
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            }
            let params = VideoGenerationParams(
                prompt: gen.prompt,
                duration: gen.duration,
                aspectRatio: gen.aspectRatio,
                resolution: gen.resolution,
                sourceVideoURL: nil,
                startFrameURL: preUploaded?.first,
                endFrameURL: (preUploaded?.count ?? 0) > 1 ? preUploaded?[1] : nil,
                referenceImageURLs: gen.referenceImageURLs ?? [],
                referenceVideoURLs: gen.referenceVideoURLs ?? [],
                referenceAudioURLs: gen.referenceAudioURLs ?? [],
                generateAudio: gen.generateAudio ?? true
            )
            let bundled = (preUploaded ?? [])
                + (gen.referenceImageURLs ?? [])
                + (gen.referenceVideoURLs ?? [])
                + (gen.referenceAudioURLs ?? [])
            return editor.generationService.generate(
                genInput: gen,
                assetType: .video,
                placeholderDuration: Double(max(1, gen.duration)),
                references: [],
                preUploadedURLs: bundled.isEmpty ? nil : bundled,
                name: rerunName(for: asset),
                folderId: asset.folderId,
                buildParams: { _ in .video(params) },
                snapshotRefs: { _, _ in },
                fileExtension: "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let imageModel = ImageModelConfig.allModels.first(where: { $0.id == modelId }) {
            let count = min(imageModel.maxImages, max(1, gen.numImages ?? 1))
            let refCount = (preUploaded ?? []).count
            if let err = imageModel.validate(
                aspectRatio: gen.aspectRatio, resolution: gen.resolution, quality: gen.quality,
                imageRefCount: refCount, numImages: count
            ) {
                throw RerunError.invalid(err)
            }
            return editor.generationService.generate(
                genInput: gen,
                assetType: .image,
                placeholderDuration: Defaults.imageDurationSeconds,
                references: [],
                preUploadedURLs: preUploaded,
                name: rerunName(for: asset),
                numImages: count,
                folderId: asset.folderId,
                buildParams: { uploaded in
                    .image(ImageGenerationParams(
                        prompt: gen.prompt,
                        aspectRatio: gen.aspectRatio,
                        resolution: gen.resolution,
                        quality: gen.quality,
                        imageURLs: uploaded,
                        numImages: count
                    ))
                },
                fileExtension: "jpg",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let audioModel = AudioModelConfig.allModels.first(where: { $0.id == modelId }) {
            let sourceVideoURL = audioModel.inputs.contains(.video) ? preUploaded?.first : nil
            let expectsVideoSource = audioModel.inputs.contains(.video)
                && (!audioModel.inputs.contains(.text)
                    || (gen.referenceVideoAssetIds?.isEmpty == false)
                    || sourceVideoURL != nil)
            if expectsVideoSource, sourceVideoURL == nil {
                throw RerunError.missingSource
            }
            let placeholderDuration: Double = asset.duration > 0
                ? asset.duration
                : (audioModel.category == .music
                    ? Defaults.audioMusicDurationSeconds
                    : Defaults.audioTTSDurationSeconds)
            let params = AudioGenerationParams(
                prompt: gen.prompt,
                voice: gen.voice,
                lyrics: gen.lyrics,
                styleInstructions: gen.styleInstructions,
                instrumental: gen.instrumental ?? false,
                durationSeconds: (audioModel.durations != nil || expectsVideoSource) && gen.duration > 0 ? gen.duration : nil,
                videoURL: sourceVideoURL
            )
            if let err = audioModel.validate(params: params) {
                throw RerunError.invalid(err)
            }
            return editor.generationService.generate(
                genInput: gen,
                assetType: .audio,
                placeholderDuration: placeholderDuration,
                references: [],
                preUploadedURLs: preUploaded,
                name: rerunName(for: asset),
                folderId: asset.folderId,
                buildParams: { _ in .audio(params) },
                fileExtension: "mp3",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if UpscaleModelConfig.allModels.contains(where: { $0.id == modelId }) {
            guard let source = preUploaded?.first else { throw RerunError.missingSource }
            let isImage = asset.type == .image
            return editor.generationService.generate(
                genInput: gen,
                assetType: asset.type,
                placeholderDuration: isImage
                    ? Defaults.imageDurationSeconds
                    : (asset.duration > 0 ? asset.duration : Double(gen.duration)),
                references: [],
                preUploadedURLs: preUploaded,
                name: rerunName(for: asset),
                folderId: asset.folderId,
                buildParams: { _ in
                    .upscale(UpscaleGenerationParams(
                        sourceURL: source,
                        durationSeconds: isImage ? 1 : gen.duration
                    ))
                },
                fileExtension: isImage ? "jpg" : "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        throw RerunError.unknownModel(modelId)
    }

    /// Recompose a rerun's stored intent against the current ledger. Returns the fresh compiled prompt,
    /// or nil to keep the stored one when there's nothing to recompose (no intent recorded, or a
    /// promptless upscale). A compile lint ERROR is NOT swallowed — it rethrows as
    /// `RerunError.compileBlocked` so the rerun fails loudly before any provider call, enforcing the
    /// pre-generation gate against the CURRENT ledger (#114).
    private static func recompiledPrompt(gen: GenerationInput, editor: EditorViewModel) async throws -> String? {
        guard let intent = gen.intent?.trimmingCharacters(in: .whitespacesAndNewlines), !intent.isEmpty
        else { return nil }
        let modality: PromptComposer.Modality
        if VideoModelConfig.allModels.contains(where: { $0.id == gen.model }) { modality = .video }
        else if ImageModelConfig.allModels.contains(where: { $0.id == gen.model }) { modality = .image }
        else if AudioModelConfig.allModels.contains(where: { $0.id == gen.model }) { modality = .audio }
        else { return nil }  // upscale has no prompt
        do {
            return try await PromptComposer.compose(
                intent: intent, modality: modality, modelId: gen.model,
                aspectRatio: gen.aspectRatio, durationSeconds: gen.duration > 0 ? Double(gen.duration) : nil,
                projectDir: editor.workingRoot).text
        } catch let e as PromptComposer.ComposeError {
            if case .lintBlocked(let code, let message) = e {
                throw RerunError.compileBlocked(code: code, message: message)
            }
            // Non-lint compose failures (empty intent, too-long) also block the rerun with their copy.
            throw RerunError.invalid(e.errorDescription ?? "Prompt compilation failed.")
        }
    }

    // MARK: - Panel seeds

    /// GenerationInput for an Edit action — opens the generation panel pre-filled with the asset as source.
    static func editSeed(for asset: MediaAsset) -> GenerationInput? {
        let modelId: String
        switch asset.type {
        case .video:
            guard let m = VideoModelConfig.allModels.first(where: { $0.requiresSourceVideo }) else { return nil }
            modelId = m.id
        case .image:
            guard let m = ImageModelConfig.nanoBananaPro else { return nil }
            modelId = m.id
        case .audio, .text, .lottie:
            return nil
        }
        var stored = GenerationInput(prompt: "", model: modelId, duration: 0, aspectRatio: "", resolution: nil)
        stored.imageURLAssetIds = [asset.id]
        return stored
    }

    /// GenerationInput for Create Video — uses the image as a first frame or as a reference.
    static func createVideoSeed(for asset: MediaAsset, asReference: Bool) -> GenerationInput? {
        guard let model = VideoModelConfig.allModels.first(where: {
            !$0.requiresSourceVideo && (asReference ? $0.supportsReferences : $0.supportsFirstFrame)
        }) else { return nil }
        var stored = GenerationInput(prompt: "", model: model.id, duration: 0, aspectRatio: "", resolution: nil)
        if asReference { stored.referenceImageAssetIds = [asset.id] } else { stored.imageURLAssetIds = [asset.id] }
        return stored
    }

    static func videoAudioSeed(for asset: MediaAsset, kind: VideoToAudioEditKind) -> GenerationInput? {
        guard asset.type == .video, let model = kind.model else { return nil }
        var stored = GenerationInput(
            prompt: "",
            model: model.id,
            duration: max(0, Int(asset.duration.rounded())),
            aspectRatio: "",
            resolution: nil
        )
        stored.referenceVideoAssetIds = [asset.id]
        return stored
    }

    // MARK: - Names

    private static func upscaleName(for asset: MediaAsset) -> String {
        "Upscaled \(stripPrefix(asset.name))"
    }

    private static func rerunName(for asset: MediaAsset) -> String {
        "Rerun \(stripPrefix(asset.name))"
    }

    private static func stripPrefix(_ name: String) -> String {
        for prefix in ["Upscaled ", "Edited ", "Rerun "] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }
}
