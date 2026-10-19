import Foundation

/// Builds and dispatches AI-tab submissions (Upscale, Rerun) pipeline.
@MainActor
enum EditSubmitter {

    // MARK: - Upscale

    @discardableResult
    static func submitUpscale(
        asset: MediaAsset,
        model: UpscaleModelConfig,
        targetResolution: String? = nil,
        editor: EditorViewModel,
        trimmedSource: TrimmedSource? = nil,
        origin: GenerationRequest.Origin = .panel,
        target: ResolvedGenerationTarget? = nil,
        replacementTarget: GenerationClipReplacement.Snapshot? = nil,
        services: GenerationPanelServices = .live,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) async -> String? {
        do {
            return try await submitReviewedUpscale(asset: asset, model: model, targetResolution: targetResolution,
                editor: editor, trimmedSource: trimmedSource, origin: origin, target: target,
                replacementTarget: replacementTarget, services: services, onComplete: onComplete, onFailure: onFailure)
        } catch {
            editor.mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            return nil
        }
    }

    private static func submitReviewedUpscale(
        asset: MediaAsset, model: UpscaleModelConfig, targetResolution: String?, editor: EditorViewModel,
        trimmedSource: TrimmedSource?, origin: GenerationRequest.Origin, target: ResolvedGenerationTarget?,
        replacementTarget: GenerationClipReplacement.Snapshot?, services: GenerationPanelServices,
        onComplete: (@MainActor (MediaAsset) -> Void)?, onFailure: (@MainActor () -> Void)?
    ) async throws -> String? {
        let failure = FirstOnlyFlag()
        let failed: @MainActor () -> Void = { if failure.fire() { onFailure?() } }
        do {
            try replacementTarget?.requireCurrent(editor: editor)
            let selectedTarget = target ?? services.target(model.id)
            let request = try upscaleRequest(asset: asset, model: model, targetResolution: targetResolution,
                trimmedSource: trimmedSource, origin: origin, target: selectedTarget,
                placement: replacementTarget.map { .replaceClip(id: $0.clipID, resetTrim: $0.resetTrim) })
            let generation = try await GenerationController.prepare(request, editor: editor, preflight: {
                do {
                    try replacementTarget?.requireCurrent(editor: editor)
                    guard services.isCurrent(selectedTarget) else { return "The selected upscaler or provider is unavailable." }
                    return nil
                }
                catch { return error.localizedDescription }
            }).get()
            _ = try await GenerationController.prepareReviewPackage(generation, editor: editor, quoteLoader: services.quoteLoader)
            guard try await GenerationReviewSheet.confirm(generation: generation, title: "Review Upscale", editor: editor, services: services) else {
                return nil
            }
            let outcome = await GenerationController.submitPrepared(generation, editor: editor,
                onSuccess: { value in if let value { onComplete?(value) } }, onFailure: failed, quoteLoader: services.quoteLoader)
            return try outcome.get().placeholderId
        } catch {
            failed()
            throw error
        }
    }

    static func upscaleRequest(asset: MediaAsset, model: UpscaleModelConfig, targetResolution: String? = nil,
                               trimmedSource: TrimmedSource? = nil, origin: GenerationRequest.Origin = .panel,
                               target: ResolvedGenerationTarget? = nil, name: String? = nil,
                               placement: GenerationRequest.Placement? = nil) throws -> GenerationRequest {
        let duration = trimmedSource?.hasTrim == true ? trimmedSource!.durationSeconds : max(1, asset.duration)
        guard duration.isFinite, duration > 0,
              let selection = model.selection(sourceType: asset.type, sourceWidth: asset.sourceWidth,
                sourceHeight: asset.sourceHeight, durationSeconds: duration, targetResolution: targetResolution) else {
            throw RerunError.invalid("\(model.displayName) cannot produce this target from the selected source and range.")
        }
        var input = GenerationInput(prompt: "", model: model.id, duration: max(1, Int(duration.rounded(.up))),
            aspectRatio: "", resolution: selection.targetResolution)
        input.sourceRange = .init(trim: asset.type == .video && trimmedSource?.hasTrim == true ? trimmedSource?.record : nil)
        recordUpscaleProvenance(in: &input, uploadedURLs: [], sourceAssetID: asset.id, sourceType: asset.type)
        let submission = UpscaleGenerationSubmission(genInput: input, source: asset, trimmedSource: trimmedSource,
            placeholderDuration: asset.type == .image ? Defaults.imageDurationSeconds : duration,
            name: name ?? upscaleName(for: asset), folderID: asset.folderId,
            targetResolution: selection.targetResolution, scaleFactor: selection.scaleFactor)
        return GenerationRequest(modality: .upscale, modelId: model.id, intent: "", durationSeconds: duration,
            outputResolution: selection.targetResolution, placement: placement ?? .mediaLibrary(folderId: asset.folderId),
            origin: origin, target: target, submission: .preparedUpscale(submission))
    }

    // MARK: - Rerun

    enum RerunError: LocalizedError {
        case notGenerated
        case unknownModel(String)
        case missingSource
        case missingReference
        case invalid(String)
        case compileBlocked(code: String, message: String)
        case budget(String)

        var errorDescription: String? {
            switch self {
            case .notGenerated: "This asset was not AI-generated"
            case .unknownModel(let id): "Model no longer available: \(id)"
            case .missingSource: "Cannot rerun: source not recorded"
            case .missingReference: "Cannot rerun: a reference image is no longer in the project"
            case .invalid(let msg): msg
            case .compileBlocked(let code, let message): "Prompt lint failed (\(code)): \(message)"
            case .budget(let message): message
            }
        }
    }

    /// The reference record (`imageURLAssetIds`) resolved back to the project's assets, so a rerun can
    /// re-host them for whichever provider services the model now. An id that no longer resolves fails
    /// LOUDLY: rerunning with fewer references than the original is the silent drift this record exists
    /// to prevent.
    private static func referenceAssets(_ ids: [String]?, editor: EditorViewModel) throws -> [MediaAsset] {
        let ids = ids ?? []
        let assets = ids.compactMap { id in editor.mediaAssets.first { $0.id == id } }
        guard assets.count == ids.count else { throw RerunError.missingReference }
        return assets
    }

    static func videoInputAssets(
        _ input: GenerationInput,
        editor: EditorViewModel
    ) throws -> VideoGenerationSubmission.InputAssets {
        let primary = try referenceAssets(input.imageURLAssetIds, editor: editor)
        let source: MediaAsset?
        if let sourceID = input.sourceVideoAssetId {
            guard let resolved = editor.mediaAssets.first(where: { $0.id == sourceID }) else {
                throw RerunError.missingSource
            }
            source = resolved
        } else if primary.first?.type == .video {
            source = primary.first
        } else {
            source = nil
        }

        let explicitFrameIDs = [input.startFrameAssetId, input.endFrameAssetId]
            .compactMap { $0 }
        let frames: [MediaAsset]
        if !explicitFrameIDs.isEmpty {
            frames = try referenceAssets(explicitFrameIDs, editor: editor)
        } else if source == nil {
            frames = primary
        } else {
            frames = []
        }

        var imageRefs = try referenceAssets(
            input.referenceImageAssetIds,
            editor: editor
        )
        if let source,
           input.referenceImageAssetIds == nil {
            imageRefs = primary.filter { $0.id != source.id }
        }
        return VideoGenerationSubmission.InputAssets(
            sourceVideo: source,
            frames: frames,
            imageRefs: imageRefs,
            videoRefs: try referenceAssets(
                input.referenceVideoAssetIds,
                editor: editor
            ),
            audioRefs: try referenceAssets(
                input.referenceAudioAssetIds,
                editor: editor
            )
        )
    }

    @discardableResult
    static func rerun(
        asset: MediaAsset,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil,
        quoteLoader: GenerationBudgetGuard.QuoteLoader = LiveGenerationPricing.quote,
        replacementTarget: GenerationClipReplacement.Snapshot? = nil,
        services: GenerationPanelServices = .live
    ) async throws -> String? {
        guard let stored = asset.generationInput else { throw RerunError.notGenerated }
        var gen = stored
        gen.createdAt = nil
        let modelId = gen.model
        let modelKind = services.catalog.modelKindForRerun(id: modelId)
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

        if case .video(let videoModel)? = modelKind {
            let inputAssets = try videoInputAssets(gen, editor: editor)
            let restoredSource = try GenerationPanelSeed.restore(gen, assets: editor.mediaAssets).sourceTrim
            let primaryDurableIDs = Set(
                (gen.imageURLAssetIds ?? [])
                    + [gen.sourceVideoAssetId, gen.startFrameAssetId, gen.endFrameAssetId]
                        .compactMap { $0 }
            )
            let hasUnprovenRemoteInput = (gen.imageURLs?.count ?? 0)
                    > primaryDurableIDs.count
                || (gen.referenceImageURLs?.count ?? 0)
                    > (gen.referenceImageAssetIds?.count ?? 0)
                || (gen.referenceVideoURLs?.count ?? 0)
                    > (gen.referenceVideoAssetIds?.count ?? 0)
                || (gen.referenceAudioURLs?.count ?? 0)
                    > (gen.referenceAudioAssetIds?.count ?? 0)
            guard !hasUnprovenRemoteInput else {
                throw RerunError.invalid(
                    "Cannot rerun: the original video input roles were not recorded."
                )
            }
            let requiresSourceVideo = inputAssets.sourceVideo != nil
            let videoDuration = gen.videoDuration ?? .seconds(gen.duration)
            let generateAudio = gen.generateAudio ?? false
            let target = GenerationService.dispatchTarget(
                modelId: modelId,
                requiringSourceVideo: requiresSourceVideo,
                matchingVideoCapabilities: { capabilities in
                    capabilities.validate(
                        duration: videoDuration,
                        aspectRatio: gen.aspectRatio,
                        resolution: gen.resolution,
                        generateAudio: generateAudio,
                        displayName: videoModel.displayName
                    ) == nil && inputAssets.validate(
                        for: videoModel,
                        offeringCapabilities: capabilities
                    ) == nil
                }
            )
            guard let offeringCapabilities = target.binding?
                    .resolvedVideoCapabilities else {
                throw RerunError.invalid(
                    "No runnable provider endpoint accepts the recorded video outputs and inputs."
                )
            }
            if let err = offeringCapabilities.validate(
                duration: videoDuration,
                aspectRatio: gen.aspectRatio,
                resolution: gen.resolution,
                generateAudio: generateAudio,
                displayName: videoModel.displayName
            ) ?? inputAssets.validate(
                for: videoModel,
                offeringCapabilities: offeringCapabilities
            ) {
                throw RerunError.invalid(err)
            }
            gen.imageURLs = nil
            gen.referenceImageURLs = nil
            gen.referenceVideoURLs = nil
            gen.referenceAudioURLs = nil
            gen.videoDuration = videoDuration
            let billedSeconds = videoDuration.seconds ?? max(1, gen.duration)
            let authorization = try await authorizeRerun(
                gen: gen,
                modality: .video,
                durationSeconds: Double(max(1, billedSeconds)),
                generateAudio: generateAudio,
                editor: editor,
                quoteLoader: quoteLoader,
                target: target
            )
            let submission = VideoGenerationSubmission.make(
                genInput: gen,
                model: videoModel,
                offeringCapabilities: offeringCapabilities,
                inputAssets: inputAssets,
                placeholderDuration: asset.duration > 0
                    ? asset.duration
                    : Double(max(1, billedSeconds)),
                trimmedSourceOverride: restoredSource,
                name: rerunName(for: asset),
                folderId: asset.folderId,
                generateAudio: generateAudio
            )
            return submission.submit(
                service: editor.generationService,
                projectURL: editor.workingRoot,
                editor: editor,
                authorization: authorization,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if case .image(let imageModel)? = modelKind {
            let count = min(imageModel.maxImages, max(1, gen.numImages ?? 1))
            // A provider that takes its references inline (#212) never persists hosted URLs, so
            // `imageURLs` is empty for it and the durable record is `imageURLAssetIds`. Replaying
            // only `imageURLs` would silently turn an image-to-image rerun into plain text-to-image.
            let hasMask = gen.imageMaskAssetId != nil
            let replayURLs = !hasMask && preUploaded?.isEmpty == false ? preUploaded : nil
            let primaryRefs = replayURLs == nil
                ? try referenceAssets(gen.imageURLAssetIds, editor: editor)
                : []
            let mask = try referenceAssets(
                gen.imageMaskAssetId.map { [$0] },
                editor: editor
            ).first
            let refs = primaryRefs + [mask].compactMap { $0 }
            let refCount = replayURLs?.count ?? primaryRefs.count
            if let err = imageModel.validate(
                aspectRatio: gen.aspectRatio, resolution: gen.resolution, quality: gen.quality,
                imageRefCount: refCount, numImages: count,
                background: gen.imageBackground,
                outputFormat: gen.imageOutputFormat,
                outputCompression: gen.imageOutputCompression,
                hasMask: hasMask
            ) {
                throw RerunError.invalid(err)
            }
            let authorization = try await authorizeRerun(
                gen: gen,
                modality: .image,
                outputCount: count,
                referenceCount: refCount,
                editor: editor,
                quoteLoader: quoteLoader
            )
            return editor.generationService.generate(
                genInput: gen,
                assetType: .image,
                placeholderDuration: Defaults.imageDurationSeconds,
                references: refs,
                preUploadedURLs: replayURLs,
                name: rerunName(for: asset),
                numImages: count,
                folderId: asset.folderId,
                buildParams: { uploaded in
                    let primaryCount = replayURLs?.count ?? primaryRefs.count
                    return .image(ImageGenerationParams(
                        prompt: gen.prompt,
                        aspectRatio: gen.aspectRatio,
                        resolution: gen.resolution,
                        quality: gen.quality,
                        imageURLs: Array(uploaded.prefix(primaryCount)),
                        numImages: count,
                        maskURL: uploaded.count > primaryCount ? uploaded[primaryCount] : nil,
                        background: gen.imageBackground,
                        outputFormat: gen.imageOutputFormat,
                        outputCompression: gen.imageOutputCompression
                    ))
                },
                snapshotRefs: { input, uploaded in
                    let primaryCount = replayURLs?.count ?? primaryRefs.count
                    let primary = Array(uploaded.prefix(primaryCount))
                    input.imageURLs = primary.isEmpty ? nil : primary
                    input.imageMaskURL = uploaded.count > primaryCount
                        ? uploaded[primaryCount]
                        : nil
                },
                fileExtension: gen.imageOutputFormat == "png"
                    ? "png"
                    : (gen.imageOutputFormat == "webp" ? "webp" : "jpg"),
                projectURL: editor.workingRoot,
                editor: editor,
                authorization: authorization,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if case .audio(let audioModel)? = modelKind {
            let sourceVideos = try referenceAssets(gen.referenceVideoAssetIds, editor: editor)
            let expectsVideoSource = audioModel.inputs.contains(.video)
                && (!audioModel.inputs.contains(.text) || !sourceVideos.isEmpty || preUploaded?.isEmpty == false)
            guard !expectsVideoSource || sourceVideos.count == 1 else { throw RerunError.missingSource }
            let restoredSource = expectsVideoSource
                ? try GenerationPanelSeed.restore(gen, assets: editor.mediaAssets).sourceTrim : nil
            gen.imageURLs = nil
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
                videoURL: nil
            )
            if let err = audioModel.validate(params: params) {
                throw RerunError.invalid(err)
            }
            let authorization = try await authorizeRerun(
                gen: gen,
                modality: .audio,
                durationSeconds: params.durationSeconds.map(Double.init),
                editor: editor,
                quoteLoader: quoteLoader
            )
            return editor.generationService.generate(
                genInput: gen,
                assetType: .audio,
                placeholderDuration: placeholderDuration,
                references: sourceVideos,
                trimmedSourceOverride: restoredSource,
                name: rerunName(for: asset),
                folderId: asset.folderId,
                buildParams: { uploaded in
                    var value = params
                    value.videoURL = expectsVideoSource ? uploaded.first : nil
                    return .audio(value)
                },
                fileExtension: "mp3",
                projectURL: editor.workingRoot,
                editor: editor,
                authorization: authorization,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if case .upscale(let model) = modelKind {
            let restored = try GenerationPanelSeed.restore(gen, assets: editor.mediaAssets)
            let sourceID = gen.sourceVideoAssetId ?? gen.imageURLAssetIds?.first
            guard let sourceID, let source = editor.mediaAssets.first(where: { $0.id == sourceID }) else {
                throw RerunError.missingSource
            }
            let target: ResolvedGenerationTarget?
            if let id = gen.generationPackageID, let home = editor.workingRoot {
                let previous = try GenerationPackageV1.load(id: id, home: home).payload.target
                target = services.target(model.id, preferred: previous)
            } else { target = nil }
            return try await submitReviewedUpscale(asset: source, model: model, targetResolution: gen.resolution,
                editor: editor, trimmedSource: restored.sourceTrim, origin: .rerun, target: target,
                replacementTarget: replacementTarget, services: services, onComplete: onComplete, onFailure: onFailure)
        }

        throw RerunError.unknownModel(modelId)
    }

    nonisolated static func recordUpscaleProvenance(
        in input: inout GenerationInput,
        uploadedURLs: [String],
        sourceAssetID: String?,
        sourceType: ClipType
    ) {
        input.imageURLs = uploadedURLs.isEmpty ? nil : uploadedURLs
        if sourceType == .video {
            input.sourceVideoAssetId = sourceAssetID
            input.imageURLAssetIds = nil
        } else {
            input.imageURLAssetIds = sourceAssetID.map { [$0] }
            input.sourceVideoAssetId = nil
        }
    }

    private static func authorizeRerun(
        gen: GenerationInput,
        modality: GenerationRequest.Modality,
        durationSeconds: Double? = nil,
        outputCount: Int = 1,
        generateAudio: Bool? = nil,
        referenceCount: Int = 0,
        editor: EditorViewModel,
        quoteLoader: GenerationBudgetGuard.QuoteLoader,
        target: ResolvedGenerationTarget? = nil
    ) async throws -> GenerationAuthorization {
        do {
            return try await GenerationBudgetGuard.authorize(
                input: GenerationPricingInput(
                    modelId: gen.model,
                    modality: modality,
                    durationSeconds: durationSeconds,
                    outputCount: max(1, outputCount),
                    resolution: gen.resolution,
                    quality: gen.quality,
                    promptCharacterCount: gen.prompt.count,
                    promptUTF8ByteCount: gen.prompt.utf8.count,
                    generateAudio: generateAudio,
                    referenceCount: max(0, referenceCount)
                ),
                target: target ?? GenerationService.dispatchTarget(modelId: gen.model),
                editor: editor,
                quoteLoader: quoteLoader
            )
        } catch {
            throw RerunError.budget(error.localizedDescription)
        }
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
            guard let m = VideoModelConfig.allModels.first(where: {
                GenerationService.dispatchTarget(
                    modelId: $0.id,
                    requiringSourceVideo: true
                ).binding?
                    .resolvedVideoCapabilities?
                    .inputPolicy.requiresSourceVideo == true
            }) else { return nil }
            modelId = m.id
        case .image:
            guard let m = ImageModelConfig.nanoBananaPro else { return nil }
            modelId = m.id
        case .audio, .text, .lottie, .subtitle, .document:
            return nil
        }
        var stored = GenerationInput(prompt: "", model: modelId, duration: 0, aspectRatio: "", resolution: nil)
        if asset.type == .video { stored.sourceVideoAssetId = asset.id }
        stored.imageURLAssetIds = [asset.id]
        return stored
    }

    /// GenerationInput for Create Video — uses the image as a first frame or as a reference.
    static func createVideoSeed(for asset: MediaAsset, asReference: Bool) -> GenerationInput? {
        guard let model = VideoModelConfig.allModels.first(where: {
                let capabilities = GenerationService.dispatchTarget(
                    modelId: $0.id,
                    requiringSourceVideo: false
                ).binding?
                    .resolvedVideoCapabilities
                return capabilities?.inputPolicy.requiresSourceVideo == false
                    && (asReference
                        ? capabilities?.supportsReferences == true
                        : capabilities?.supportsFirstFrame == true)
        }) else { return nil }
        var stored = GenerationInput(prompt: "", model: model.id, duration: 0, aspectRatio: "", resolution: nil)
        if asReference { stored.referenceImageAssetIds = [asset.id] } else { stored.imageURLAssetIds = [asset.id] }
        return stored
    }

    static func videoAudioSeed(for asset: MediaAsset, kind: VideoToAudioEditKind, effectiveDuration: Double? = nil,
                               services: GenerationPanelServices = .live) -> GenerationInput? {
        guard asset.type == .video, let model = kind.model(spanSeconds: effectiveDuration ?? asset.duration, services: services) else { return nil }
        var stored = GenerationInput(
            prompt: "",
            model: model.id,
            duration: max(0, Int((effectiveDuration ?? asset.duration).rounded())),
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
