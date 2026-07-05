import Foundation

/// Used by replace-clip callbacks so only the
/// first successful asset of an N-image generation swaps the clip
@MainActor
final class FirstOnlyFlag {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

@MainActor
final class GenerationService {

    private static let uploadCacheTTL: TimeInterval = 6 * 24 * 60 * 60

    @discardableResult
    func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        placeholderDuration: Double,
        references: [MediaAsset] = [],
        trimmedSourceOverride: TrimmedSource? = nil,
        preUploadedURLs: [String]? = nil,
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil,
        buildParams: @escaping ([String]) -> BackendGenerationParams,
        snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)? = nil,
        preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)? = nil,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let count = max(1, min(4, numImages))
        let baseName = name ?? String(genInput.prompt.prefix(30))

        let resolvedFolderId = folderId.flatMap { id in
            editor.folder(id: id) != nil ? id : nil
        }
        var placeholders: [MediaAsset] = []
        let destDir = Self.destinationDirectory(for: projectURL)

        for _ in 0..<count {
            let placeholder = createPlaceholder(
                type: assetType,
                name: baseName,
                duration: placeholderDuration,
                genInput: genInput,
                folderId: resolvedFolderId,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            placeholders.append(placeholder)
        }
        let primaryId = placeholders[0].id
        let refURLs = references.map(\.url)

        Task { @MainActor in
            var tempToCleanup: [URL] = []
            defer { Self.cleanupTempFiles(tempToCleanup) }
            do {
                let uploaded: [String]
                if let preUploadedURLs, !preUploadedURLs.isEmpty {
                    uploaded = preUploadedURLs
                } else {
                    var urlsToUpload = refURLs
                    let refTypes = references.map(\.type)
                    if let trim = trimmedSourceOverride, trim.hasTrim, !urlsToUpload.isEmpty {
                        Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[0].lastPathComponent)")
                        let extracted = try await VideoTrimExtractor.extract(trim)
                        urlsToUpload[0] = extracted
                        tempToCleanup.append(extracted)
                    }
                    if let preprocessRef, !references.isEmpty {
                        let snapshot = references
                        let rewrites: [(Int, URL?)] = try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
                            for (i, asset) in snapshot.enumerated() {
                                group.addTask { (i, try await preprocessRef(i, asset)) }
                            }
                            var results: [(Int, URL?)] = []
                            for try await r in group { results.append(r) }
                            return results
                        }
                        for (i, rewritten) in rewrites {
                            if let rewritten {
                                urlsToUpload[i] = rewritten
                                tempToCleanup.append(rewritten)
                            }
                        }
                    }
                    // Cache against the MediaAsset only when asset bytes are pristine (not trimmed, not preprocessed)
                    let trimmedFirst = trimmedSourceOverride?.hasTrim == true
                    let cacheKeys: [MediaAsset?] = references.enumerated().map { (i, asset) in
                        if preprocessRef != nil { return nil }
                        if i == 0 && trimmedFirst { return nil }
                        return asset
                    }
                    uploaded = try await uploadReferences(
                        at: urlsToUpload,
                        types: refTypes,
                        cacheKeys: cacheKeys,
                    )
                }

                var finalGenInput = genInput
                if let snapshotRefs {
                    snapshotRefs(&finalGenInput, uploaded)
                } else {
                    finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
                }
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                for placeholder in placeholders {
                    placeholder.generationInput = finalGenInput
                }

                let params = buildParams(uploaded)

                await self.runJob(
                    placeholders: placeholders,
                    params: params,
                    genInput: finalGenInput,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            } catch {
                let message = error.localizedDescription
                Log.generation.error("upload failed model=\(genInput.model) error=\(message)")
                for placeholder in placeholders {
                    placeholder.generationStatus = .failed("Upload failed: \(message)")
                }
                onFailure?()
            }
        }

        return primaryId
    }

    private static func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Shared

    private func createPlaceholder(
        type: ClipType,
        name: String,
        duration: Double,
        genInput: GenerationInput,
        folderId: String?,
        destDir: URL,
        fileExtension: String,
        editor: EditorViewModel
    ) -> MediaAsset {
        let id = UUID().uuidString
        let destURL = destDir.appendingPathComponent("gen-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(
            id: id,
            url: destURL,
            type: type,
            name: name,
            duration: duration,
            generationInput: genInput
        )
        placeholder.generationStatus = .generating
        placeholder.folderId = folderId
        editor.mediaAssets.append(placeholder)
        return placeholder
    }

    private static func destinationDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            let dir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return FileManager.default.temporaryDirectory
    }

    @discardableResult
    private func downloadAndFinalize(asset: MediaAsset, remoteURL: URL, editor: EditorViewModel) async -> Bool {
        asset.generationStatus = .downloading
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
            let realExt = remoteURL.pathExtension.lowercased()
            if !realExt.isEmpty, realExt != asset.url.pathExtension.lowercased(),
               ClipType(fileExtension: realExt) != nil {
                asset.url = asset.url.deletingPathExtension().appendingPathExtension(realExt)
            }
            try? FileManager.default.removeItem(at: asset.url)
            try FileManager.default.moveItem(at: tempURL, to: asset.url)

            asset.pendingDownloadURL = nil
            asset.generationStatus = .none
            editor.importMediaAsset(asset, skipAppend: true)
            editor.appendGenerationLog(for: asset)
            await editor.finalizeImportedAsset(asset)
            return true
        } catch {
            let message = error.localizedDescription
            Log.generation.error("download failed url=\(remoteURL.absoluteString) error=\(message)")
            asset.pendingDownloadURL = remoteURL
            asset.generationStatus = .failed(message)
            return false
        }
    }

    func retryDownload(asset: MediaAsset, editor: EditorViewModel) {
        guard let remoteURL = asset.pendingDownloadURL else { return }
        Task { @MainActor in
            await downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
        }
    }

    /// Uploads each reference and returns the hosted URLs.
    private func uploadReferences(
        at urls: [URL],
        types: [ClipType],
        cacheKeys: [MediaAsset?],
    ) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        guard let apiKey = ProviderKeychain.load(.fal) else {
            throw GenerationBackendError.transport("Add a fal.ai API key in Settings to use references.")
        }

        let uploaded = try await withThrowingTaskGroup(of: (Int, String, Bool).self) { group in
            for (i, url) in urls.enumerated() {
                let type = types.indices.contains(i) ? types[i] : .image
                let cacheKey = cacheKeys.indices.contains(i) ? cacheKeys[i] : nil
                if let cacheKey, let hit = cacheKey.freshRemoteURL {
                    group.addTask { (i, hit, false) }
                    continue
                }
                let contentType = Self.contentType(for: url, fallback: type)
                group.addTask {
                    let hosted = try await FalStorage.upload(fileURL: url, contentType: contentType, apiKey: apiKey)
                    return (i, hosted, true)
                }
            }
            var results = [(Int, String, Bool)]()
            for try await r in group { results.append(r) }
            return results
        }

        // Record cache for freshly-uploaded references (on the main actor).
        for (i, hosted, fresh) in uploaded where fresh {
            if let cacheKey = cacheKeys.indices.contains(i) ? cacheKeys[i] : nil {
                Self.recordUploadCache(asset: cacheKey, url: hosted)
            }
        }
        return uploaded.sorted(by: { $0.0 < $1.0 }).map(\.1)
    }

    @MainActor
    private static func recordUploadCache(asset: MediaAsset, url: String) {
        asset.cachedRemoteURL = url
        asset.cachedRemoteURLExpiresAt = Date().addingTimeInterval(uploadCacheTTL)
    }

    private static func contentType(for url: URL, fallback: ClipType) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aiff", "aif", "aifc": return "audio/aiff"
        case "flac": return "audio/flac"
        default:
            switch fallback {
            case .image: return "image/jpeg"
            case .video: return "video/mp4"
            case .audio: return "audio/mpeg"
            case .text: return "application/octet-stream"
            case .lottie: return "application/json"
            }
        }
    }

    // MARK: - Job execution

    private func runJob(
        placeholders: [MediaAsset],
        params: BackendGenerationParams,
        genInput: GenerationInput,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        let runId = String(UUID().uuidString.prefix(8))
        Log.generation.notice("run \(runId) start model=\(genInput.model) placeholders=\(placeholders.count)")
        defer { Log.generation.notice("run \(runId) settled") }

        let endpoint = genInput.model

        if MarbleModelRegistry.isMarbleModel(endpoint) {
            guard case .image(let p) = params, let marbleModel = MarbleModelRegistry.model(for: endpoint) else {
                return failJob(placeholders, "Unsupported Marble request for model: \(endpoint)", onFailure)
            }
            await runMarbleJob(
                model: marbleModel,
                prompt: p.prompt,
                referencePath: p.imageURLs.first,
                name: genInput.prompt,
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
            return
        }

        if HiggsfieldModelRegistry.isHiggsfieldModel(endpoint) {
            await runHiggsfieldJob(
                endpoint: endpoint, params: params,
                placeholders: placeholders, editor: editor,
                onComplete: onComplete, onFailure: onFailure
            )
            return
        }

        if RunwayModelRegistry.isRunwayModel(endpoint) {
            await runRunwayJob(
                endpoint: endpoint, params: params,
                placeholders: placeholders, editor: editor,
                onComplete: onComplete, onFailure: onFailure
            )
            return
        }

        // ElevenLabs-family models run directly against the user's ElevenLabs key when present
        // (their account, no fal middleman); without one they fall through to fal's hosted endpoints.
        if endpoint.hasPrefix("fal-ai/elevenlabs"), ProviderKeychain.load(.elevenlabs) != nil,
           case .audio(let audioParams) = params {
            await runElevenLabsJob(
                endpoint: endpoint, params: audioParams,
                placeholders: placeholders, editor: editor,
                onComplete: onComplete, onFailure: onFailure
            )
            return
        }

        let falModel = FalModelRegistry.model(for: endpoint)
        let input: [String: Any]
        let shape: CatalogEntry.ResponseShape

        switch params {
        case .image(let p):
            input = FalInputBuilder.imageInput(p, sizeMode: falModel?.imageSize ?? .imageSizeEnum, refField: falModel?.imageRef ?? .none, count: placeholders.count)
            shape = .images
        case .video(let p):
            guard let falModel else { return failJob(placeholders, "Unknown video model: \(endpoint)", onFailure) }
            input = FalInputBuilder.videoInput(p, model: falModel)
            shape = .video
        case .audio(let p):
            guard let falModel else { return failJob(placeholders, "Unknown audio model: \(endpoint)", onFailure) }
            input = FalInputBuilder.audioInput(p, model: falModel)
            shape = .audio
        case .upscale(let p):
            guard let falModel else { return failJob(placeholders, "Unknown upscale model: \(endpoint)", onFailure) }
            input = FalInputBuilder.upscaleInput(p, model: falModel)
            shape = falModel.entry.responseShape
        }

        await runFalJob(
            endpoint: endpoint,
            input: input,
            shape: shape,
            placeholders: placeholders,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    private func failJob(_ placeholders: [MediaAsset], _ message: String, _ onFailure: (@MainActor () -> Void)?) {
        Log.generation.error("generation failed: \(message)")
        for placeholder in placeholders {
            placeholder.generationStatus = .failed(message)
        }
        onFailure?()
    }

    private func runFalJob(
        endpoint: String,
        input: [String: Any],
        shape: CatalogEntry.ResponseShape,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.fal) else {
            return failJob(placeholders, "Add a fal.ai API key in Settings to generate.", onFailure)
        }

        do {
            // fal's raw HTTP queue API takes the input fields at the top level — NOT wrapped in
            // an "input" key (that is only the JS/Python SDK convention). Wrapping made fal see no
            // recognized fields and reject every job, so no fal generation ever produced an asset.
            let inputBody = try JSONSerialization.data(withJSONObject: input)
            let client = FalClient(apiKey: apiKey)
            let requestId = try await client.submit(endpoint: endpoint, inputBody: inputBody)
            let outputData = try await client.result(endpoint: endpoint, requestId: requestId)
            let urls = FalOutput.urls(from: outputData, shape: shape)
            guard !urls.isEmpty else {
                throw GenerationBackendError.transport("fal returned no output")
            }
            let job = BackendGenerationJob(
                _id: requestId,
                status: .succeeded,
                resultUrls: urls,
                errorMessage: nil,
                costCredits: nil,
                completedAt: nil
            )
            await finalizeSuccess(
                job: job,
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        } catch {
            failJob(placeholders, error.localizedDescription, onFailure)
        }
    }

    private func runHiggsfieldJob(
        endpoint: String,
        params: BackendGenerationParams,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.higgsfield) else {
            return failJob(placeholders, "Add a Higgsfield API key in Settings to generate.", onFailure)
        }
        guard let model = HiggsfieldModelRegistry.model(for: endpoint) else {
            return failJob(placeholders, "Unknown Higgsfield model: \(endpoint)", onFailure)
        }
        guard case .video(let p) = params else {
            return failJob(placeholders, "Unsupported Higgsfield request: \(endpoint)", onFailure)
        }
        guard let image = p.referenceImageURLs.first ?? p.startFrameURL else {
            return failJob(placeholders,
                           "\(model.entry.displayName) is image-to-video — add a reference image.",
                           onFailure)
        }
        do {
            let client = HiggsfieldClient(apiKey: apiKey)
            let urls = try await client.dopImageToVideo(
                model: model.apiModel, prompt: p.prompt, imageURL: image)
            let job = BackendGenerationJob(
                _id: UUID().uuidString, status: .succeeded, resultUrls: urls,
                errorMessage: nil, costCredits: nil, completedAt: nil)
            await finalizeSuccess(
                job: job, placeholders: placeholders, editor: editor,
                onComplete: onComplete, onFailure: onFailure)
        } catch {
            failJob(placeholders, error.localizedDescription, onFailure)
        }
    }

    private func runRunwayJob(
        endpoint: String,
        params: BackendGenerationParams,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.runway) else {
            return failJob(placeholders, "Add a Runway API key in Settings to generate.", onFailure)
        }
        guard let model = RunwayModelRegistry.model(for: endpoint) else {
            return failJob(placeholders, "Unknown Runway model: \(endpoint)", onFailure)
        }
        do {
            let client = RunwayClient(apiKey: apiKey)
            let urls: [String]
            switch params {
            case .video(let p):
                guard let image = p.referenceImageURLs.first ?? p.startFrameURL else {
                    return failJob(placeholders,
                                   "\(model.entry.displayName) is image-to-video — add a reference image.",
                                   onFailure)
                }
                urls = try await client.imageToVideo(
                    model: model.apiModel, promptImage: image, promptText: p.prompt,
                    ratio: RunwayModelRegistry.videoRatio(for: p.aspectRatio), duration: p.duration)
            case .image(let p):
                urls = try await client.textToImage(
                    model: model.apiModel, promptText: p.prompt,
                    ratio: RunwayModelRegistry.imageRatio(for: p.aspectRatio))
            default:
                return failJob(placeholders, "Unsupported Runway request: \(endpoint)", onFailure)
            }
            let job = BackendGenerationJob(
                _id: UUID().uuidString, status: .succeeded, resultUrls: urls,
                errorMessage: nil, costCredits: nil, completedAt: nil)
            await finalizeSuccess(
                job: job, placeholders: placeholders, editor: editor,
                onComplete: onComplete, onFailure: onFailure)
        } catch {
            failJob(placeholders, error.localizedDescription, onFailure)
        }
    }

    private func runElevenLabsJob(
        endpoint: String,
        params: AudioGenerationParams,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.elevenlabs) else {
            return failJob(placeholders, "Add an ElevenLabs API key in Settings to generate.", onFailure)
        }
        guard let placeholder = placeholders.first else { return }
        do {
            let client = ElevenLabsClient(apiKey: apiKey)
            let data: Data
            switch endpoint {
            case "fal-ai/elevenlabs/tts/multilingual-v2":
                data = try await client.textToSpeech(text: params.prompt, voiceName: params.voice ?? "Rachel")
            case "fal-ai/elevenlabs/sound-effects":
                data = try await client.soundEffect(
                    text: params.prompt, durationSeconds: params.durationSeconds.map(Double.init))
            case "fal-ai/elevenlabs/music":
                data = try await client.music(
                    prompt: params.prompt,
                    lengthMs: (params.durationSeconds ?? 90) * 1000,
                    forceInstrumental: params.instrumental)
            default:
                return failJob(placeholders, "Unsupported ElevenLabs model: \(endpoint)", onFailure)
            }
            // Bytes arrive directly (no result URL) — write to the placeholder's destination and
            // run the same finalize steps downloadAndFinalize performs after its move.
            try? FileManager.default.removeItem(at: placeholder.url)
            try data.write(to: placeholder.url, options: .atomic)
            placeholder.generationStatus = .none
            editor.importMediaAsset(placeholder, skipAppend: true)
            editor.appendGenerationLog(for: placeholder)
            await editor.finalizeImportedAsset(placeholder)
            onComplete?(placeholder)
            AppNotifications.generationComplete(
                assetId: placeholder.id,
                projectURL: editor.projectURL,
                assetName: placeholder.name,
                assetType: placeholder.type,
                count: 1
            )
        } catch {
            failJob(placeholders, error.localizedDescription, onFailure)
        }
    }

    private func runMarbleJob(
        model: MarbleModel,
        prompt: String,
        referencePath: String?,
        name: String,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.marble) else {
            return failJob(placeholders, "Add a Marble (World Labs) API key in Settings to generate.", onFailure)
        }
        guard let referencePath, let referenceURL = Self.localFileURL(referencePath) else {
            return failJob(placeholders, "Marble requires a reference image.", onFailure)
        }

        do {
            let displayName = String(name.prefix(60))
            let body = try MarbleInputBuilder.body(
                prompt: prompt, displayName: displayName, model: model.model, referenceImageURL: referenceURL
            )
            let client = MarbleClient(apiKey: apiKey)
            let operationId = try await client.submit(body: body)
            let outputData = try await client.result(operationId: operationId)
            let urls = MarbleOutput.urls(from: outputData)
            guard !urls.isEmpty else {
                throw GenerationBackendError.transport("Marble returned no panorama")
            }
            let job = BackendGenerationJob(
                _id: operationId,
                status: .succeeded,
                resultUrls: urls,
                errorMessage: nil,
                costCredits: nil,
                completedAt: nil
            )
            await finalizeSuccess(
                job: job,
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        } catch {
            failJob(placeholders, error.localizedDescription, onFailure)
        }
    }

    private static func localFileURL(_ path: String) -> URL? {
        if let url = URL(string: path), url.isFileURL { return url }
        return URL(fileURLWithPath: path)
    }

    private func finalizeSuccess(
        job: BackendGenerationJob,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        let urlStrings = job.resultUrls ?? []
        guard !urlStrings.isEmpty else {
            Log.generation.error("backend job succeeded with no resultUrls")
            for placeholder in placeholders {
                placeholder.generationStatus = .failed("No URL in response")
            }
            onFailure?()
            return
        }
        if urlStrings.count < placeholders.count {
            Log.generation.notice("backend returned \(urlStrings.count) URL(s) for \(placeholders.count) placeholder(s); marking extras as failed")
        }

        var finalized: [MediaAsset] = []
        for (i, placeholder) in placeholders.enumerated() {
            guard i < urlStrings.count, let remote = URL(string: urlStrings[i]) else {
                placeholder.generationStatus = .failed("No URL for placeholder")
                continue
            }
            if await downloadAndFinalize(asset: placeholder, remoteURL: remote, editor: editor) {
                onComplete?(placeholder)
                finalized.append(placeholder)
            }
        }

        if let first = finalized.first {
            AppNotifications.generationComplete(
                assetId: first.id,
                projectURL: editor.projectURL,
                assetName: first.name,
                assetType: first.type,
                count: finalized.count
            )
        } else {
            onFailure?()
        }
    }

}
