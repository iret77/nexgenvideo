import AVFoundation
import Foundation
import ImageIO

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
private final class MCPSubmissionDispatchState {
    private(set) var didDispatch = false

    func recordDispatch() {
        didDispatch = true
    }
}

/// Where a model's reference files have to live before the provider can read them. NGV is
/// provider-agnostic: hosting is a property of the RESOLVED provider, never a fixed dependency on
/// one vendor's storage (#244 — fal used to host references even for calls that never touched fal,
/// which made a fal key mandatory for providers that need none).
enum ReferenceHosting: Equatable {
    /// The provider reads the file itself — bytes in the request body (Google) or base64 off a local
    /// path (Marble). References stay local paths and are never hosted.
    case inline
    /// Runway hosts its own, on the user's Runway key.
    case runway
    /// The provider MCP uploads and owns its reference media.
    case mcp
    /// fal storage — for fal-hosted models.
    case fal

    /// Whether this hosting yields a URL worth writing into the project's media manifest. Local
    /// paths must never be persisted: `GenerationInput` rides in the manifest, and an absolute path
    /// would break the self-contained `.ngv` the moment the project moves machines — while also
    /// claiming a hosted URL that never existed. Hosted refs are a cache with a TTL either way; the
    /// durable record of what was referenced is `imageURLAssetIds`.
    var persistsHostedURLs: Bool { self == .runway || self == .fal }
}

@MainActor
final class GenerationService {

    enum MCPFailureHandling: Equatable {
        case failBeforeSubmission(String)
        case failJob(String)
    }

    private static let uploadCacheTTL: TimeInterval = 6 * 24 * 60 * 60
    private var generationTasks: [String: Task<Void, Never>] = [:]

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
        resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1? = nil,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        authorization: GenerationAuthorization,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let count = max(1, min(4, numImages))
        var authorizedGenInput = genInput
        authorizedGenInput.spendTransactionId = authorization.transactionId
        let baseName = name ?? String(authorizedGenInput.prompt.prefix(30))

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
                genInput: authorizedGenInput,
                folderId: resolvedFolderId,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            placeholders.append(placeholder)
        }
        let primaryId = placeholders[0].id
        let refURLs = references.map(\.url)

        // Resolved ONCE, here, and handed to `runJob` — never re-resolved. Reading the activation a
        // second time after the upload would let the two disagree: a key added while a reference was
        // still uploading would re-route the dispatch to a provider that cannot read what was just
        // hosted (a direct provider handed a fal URL reads it as a file path, finds nothing, and
        // silently renders without the reference).
        let target = authorization.target
        let hosting = Self.referenceHosting(for: target)

        let task = Task { @MainActor [weak self, weak editor] in
            guard let self, let editor else { return }
            var tempToCleanup: [URL] = []
            defer {
                Self.cleanupTempFiles(tempToCleanup)
                self.generationTasks.removeValue(forKey: primaryId)
            }
            do {
                try authorization.projectMutationScope?.requireCurrent(editor: editor)
                if assetType == .video {
                    try Self.validateVideoTargetCapabilities(
                        resolvedVideoCapabilities,
                        target: target
                    )
                }
                if authorizedGenInput.productionRouting != nil {
                    guard preUploadedURLs?.isEmpty != false,
                          trimmedSourceOverride?.hasTrim != true,
                          preprocessRef == nil else {
                        throw PipelineProductionRoutingError.publicationInvalid(
                            "A routed submission must upload the exact proven project bytes."
                        )
                    }
                }
                if assetType == .video {
                    try PipelineProductionRouting.validateSubmission(
                        genInput: authorizedGenInput,
                        target: target,
                        references: references,
                        editor: editor
                    )
                }
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
                        if authorizedGenInput.productionRouting != nil { return nil }
                        if preprocessRef != nil { return nil }
                        if i == 0 && trimmedFirst { return nil }
                        return asset
                    }
                    switch hosting {
                    case .inline, .mcp:
                        // Hosting these on fal first would demand a fal key for a call that never
                        // touches fal — exactly the dependency the direct providers exist to remove.
                        // Local paths, purely so the direct client can read the bytes off disk.
                        uploaded = urlsToUpload.map(\.path)
                    case .runway:
                        uploaded = try await uploadReferencesToRunway(at: urlsToUpload, types: refTypes)
                    case .fal:
                        uploaded = try await uploadReferences(
                            at: urlsToUpload,
                            types: refTypes,
                            cacheKeys: cacheKeys,
                        )
                    }
                }

                let persistedRefs = hosting.persistsHostedURLs ? uploaded : []
                var finalGenInput = authorizedGenInput
                if let snapshotRefs {
                    snapshotRefs(&finalGenInput, persistedRefs)
                } else {
                    finalGenInput.imageURLs = persistedRefs.isEmpty ? nil : persistedRefs
                }
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                for placeholder in placeholders {
                    placeholder.generationInput = finalGenInput
                }

                let params = buildParams(uploaded)
                try Self.validateVideoDispatchCapabilities(
                    resolvedVideoCapabilities,
                    target: target,
                    params: params
                )
                try PipelineProductionRouting.validateProviderEnvelope(
                    genInput: finalGenInput,
                    target: target,
                    params: params,
                    uploadedReferences: uploaded
                )

                if assetType == .video {
                    try PipelineProductionRouting.validateSubmission(
                        genInput: finalGenInput,
                        target: target,
                        references: references,
                        editor: editor
                    )
                }

                await self.runJob(
                    placeholders: placeholders,
                    params: params,
                    genInput: finalGenInput,
                    target: target,
                    authorization: authorization,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            } catch is CancellationError {
                let message = "Generation cancelled."
                for placeholder in placeholders {
                    placeholder.generationStatus = .failed(message)
                }
                try? editor.recordSpendEvent(
                    authorization: authorization,
                    kind: .released,
                    note: message
                )
                onFailure?()
            } catch {
                let message = error.localizedDescription
                Log.generation.error("upload failed model=\(authorizedGenInput.model) error=\(message)")
                for placeholder in placeholders {
                    placeholder.generationStatus = .failed("Upload failed: \(message)")
                }
                try? editor.recordSpendEvent(
                    authorization: authorization,
                    kind: .released,
                    note: "Preparation failed: \(message)"
                )
                onFailure?()
            }
        }
        generationTasks[primaryId] = task

        return primaryId
    }

    @discardableResult
    func cancelGeneration(placeholderId: String) -> Bool {
        guard let task = generationTasks[placeholderId] else { return false }
        task.cancel()
        return true
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

    /// Move a freshly downloaded file into the project's Caches-tier staging dir (per-project,
    /// purgeable) and return the staged URL. Falls back to the original URL when no project is open or
    /// the move fails — staging is a convenience, never a hard dependency of the download.
    @MainActor
    private static func stageDownload(_ downloaded: URL, ext: String, editor: EditorViewModel) -> URL {
        guard let key = editor.openWorkingCopyKey else { return downloaded }
        let dir = AppPaths.ensure(AppPaths.projectStaging(projectId: key))
        let dest = dir.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "bin" : ext)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: downloaded, to: dest)
            return dest
        } catch {
            return downloaded
        }
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
    private func downloadAndFinalize(
        asset: MediaAsset,
        remoteURL: URL,
        editor: EditorViewModel,
        mutationScope: GenerationProjectMutationScope?
    ) async -> Bool {
        asset.generationStatus = .downloading
        var transientURL: URL?
        defer {
            if let transientURL {
                try? FileManager.default.removeItem(at: transientURL)
            }
        }
        do {
            let (downloadURL, _) = try await URLSession.shared.download(from: remoteURL)
            transientURL = downloadURL
            guard editor.mediaAssets.contains(where: { $0.id == asset.id }) else {
                return false
            }
            try mutationScope?.requireCurrent(editor: editor)
            let realExt = remoteURL.pathExtension.lowercased()
            if !realExt.isEmpty, realExt != asset.url.pathExtension.lowercased(),
               ClipType(fileExtension: realExt) != nil {
                asset.url = asset.url.deletingPathExtension().appendingPathExtension(realExt)
            }
            // Stage the freshly downloaded bytes in the project's Caches-tier scratch (purgeable,
            // per-project) before finalizing into the working media store. Falls back to the
            // system temp URL when no project is open.
            let tempURL = Self.stageDownload(downloadURL, ext: asset.url.pathExtension, editor: editor)
            transientURL = tempURL
            try? FileManager.default.removeItem(at: asset.url)
            try FileManager.default.moveItem(at: tempURL, to: asset.url)
            transientURL = nil

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
        let mutationScope: GenerationProjectMutationScope?
        do {
            if let workingRoot = editor.workingRoot {
                mutationScope = try GenerationProjectMutationScope(
                    projectHome: workingRoot,
                    editor: editor
                )
            } else {
                mutationScope = nil
            }
        } catch {
            asset.generationStatus = .failed(error.localizedDescription)
            return
        }
        Task { @MainActor in
            await downloadAndFinalize(
                asset: asset,
                remoteURL: remoteURL,
                editor: editor,
                mutationScope: mutationScope
            )
        }
    }

    /// #244 — host references on RUNWAY for Runway's own models, so image-to-video and Aleph restyle
    /// need no fal key. Runway's video models all require a hosted `promptImage`/`videoUri`, so
    /// routing them through fal storage made a fal key mandatory for a provider that hosts its own.
    ///
    /// Deliberately does NOT use the shared upload cache: `MediaAsset.cachedRemoteURL` holds ONE url
    /// per asset and is written by the fal path, so consulting it here would hand a fal URL to Runway
    /// (re-introducing the dependency) or cache a Runway URI where fal is expected. Runway's URIs
    /// expire after ~24h against that cache's 6-day TTL anyway. Uploads are free; re-uploading per run
    /// is the honest trade.
    private func uploadReferencesToRunway(at urls: [URL], types: [ClipType]) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        guard let apiKey = ProviderKeychain.load(.runway) else {
            throw GenerationBackendError.transport("Add a Runway API key in Settings to use references.")
        }
        let client = RunwayClient(apiKey: apiKey)
        let uploaded = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, url) in urls.enumerated() {
                let type = types.indices.contains(i) ? types[i] : .image
                let filename = Self.uploadFilename(for: url, fallback: type)
                group.addTask { (i, try await client.uploadReference(fileURL: url, filename: filename)) }
            }
            var results = [(Int, String)]()
            for try await r in group { results.append(r) }
            return results
        }
        return uploaded.sorted(by: { $0.0 < $1.0 }).map(\.1)
    }

    /// Runway reads the content type off the filename EXTENSION and then pins it in the upload
    /// policy, so a name without a usable extension fails the S3 check rather than defaulting. Give
    /// the file one that matches what it really is.
    static func uploadFilename(for url: URL, fallback: ClipType) -> String {
        // `.text` maps every UNKNOWN extension to application/octet-stream, so anything else means
        // the extension is one `contentType(for:)` recognizes and the real name can stand.
        if contentType(for: url, fallback: .text) != "application/octet-stream" {
            return url.lastPathComponent
        }
        let ext: String
        switch fallback {
        case .image: ext = "jpg"
        case .video: ext = "mp4"
        case .audio: ext = "mp3"
        case .text, .lottie: ext = "bin"
        case .document: ext = "txt"
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return (stem.isEmpty ? "reference" : stem) + "." + ext
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
            case .document: return "text/plain"
            }
        }
    }

    // MARK: - Job execution

    nonisolated static func validateVideoDispatchCapabilities(
        _ submitted: ResolvedVideoOfferingCapabilitiesV1?,
        target: ResolvedGenerationTarget,
        params: BackendGenerationParams
    ) throws {
        guard case .video(let video) = params else { return }
        try validateVideoTargetCapabilities(submitted, target: target)
        guard let exact = target.binding?.resolvedVideoCapabilities else {
            throw GenerationBackendError.transport(
                "The selected provider endpoint has no versioned video capability contract."
            )
        }
        guard exact.contractViolation == nil,
              (video.sourceVideoURL != nil)
                == exact.inputPolicy.requiresSourceVideo else {
            throw GenerationBackendError.transport(
                "The video request does not match the selected provider endpoint's source-video contract."
            )
        }
        if let error = exact.validate(
            duration: video.duration,
            aspectRatio: video.aspectRatio,
            resolution: video.resolution,
            generateAudio: video.generateAudio,
            displayName: target.modelId
        ) {
            throw GenerationBackendError.transport(error)
        }
        if let error = validateVideoInputEnvelope(
            video,
            capabilities: exact,
            displayName: target.modelId
        ) {
            throw GenerationBackendError.transport(error)
        }
    }

    nonisolated static func validateVideoInputEnvelope(
        _ video: VideoGenerationParams,
        capabilities: ResolvedVideoOfferingCapabilitiesV1,
        displayName: String
    ) -> String? {
        let policy = capabilities.inputPolicy
        let frameCount = (video.startFrameURL == nil ? 0 : 1)
            + (video.endFrameURL == nil ? 0 : 1)
        if policy.requiresSourceVideo {
            guard video.sourceVideoURL != nil else {
                return "\(displayName) requires a source video"
            }
            if frameCount > 0
                || !video.referenceVideoURLs.isEmpty
                || !video.referenceAudioURLs.isEmpty {
                return "\(displayName) only accepts a source video and image references"
            }
            if capabilities.requiresReferenceImage,
               video.referenceImageURLs.isEmpty {
                return "\(displayName) requires an image reference"
            }
            if video.referenceImageURLs.count > capabilities.maxReferenceImages {
                return "\(displayName) accepts at most \(capabilities.maxReferenceImages) image reference(s)"
            }
            if let totalCap = capabilities.maxTotalReferences,
               video.referenceImageURLs.count > totalCap {
                return "\(displayName) accepts at most \(totalCap) references total"
            }
            return nil
        }

        guard video.sourceVideoURL == nil else {
            return "\(displayName) does not accept a source video"
        }
        if video.endFrameURL != nil, video.startFrameURL == nil {
            return "\(displayName) requires a start frame before an end frame"
        }
        if frameCount > 0, !capabilities.supportsFirstFrame {
            return "\(displayName) does not accept frame references"
        }
        if video.endFrameURL != nil, !capabilities.supportsLastFrame {
            return "\(displayName) does not accept a last frame"
        }
        let hasReferences = !video.referenceImageURLs.isEmpty
            || !video.referenceVideoURLs.isEmpty
            || !video.referenceAudioURLs.isEmpty
        if capabilities.requiresReferenceImage,
           frameCount == 0,
           video.referenceImageURLs.isEmpty {
            return "\(displayName) requires a start frame"
        }
        if capabilities.framesAndReferencesExclusive,
           frameCount > 0,
           hasReferences {
            return "\(displayName) uses frames OR references, not both"
        }
        let framesInImageLimit = policy.framesCountTowardImageReferenceLimit
            ? frameCount : 0
        let imageLimit = capabilities.maxReferenceImages(
            hasVideoReference: !video.referenceVideoURLs.isEmpty
        )
        if video.referenceImageURLs.count + framesInImageLimit > imageLimit {
            return "\(displayName) accepts at most \(imageLimit) image inputs"
        }
        if video.referenceVideoURLs.count > capabilities.maxReferenceVideos {
            return "\(displayName) accepts at most \(capabilities.maxReferenceVideos) video references"
        }
        if video.referenceAudioURLs.count > capabilities.maxReferenceAudios {
            return "\(displayName) accepts at most \(capabilities.maxReferenceAudios) audio references"
        }
        let framesInTotalLimit = policy.framesCountTowardTotalReferenceLimit
            ? frameCount : 0
        let totalReferences = video.referenceImageURLs.count
            + video.referenceVideoURLs.count
            + video.referenceAudioURLs.count
            + framesInTotalLimit
        if let totalCap = capabilities.maxTotalReferences,
           totalReferences > totalCap {
            return "\(displayName) accepts at most \(totalCap) references total"
        }
        return nil
    }

    nonisolated static func validateVideoTargetCapabilities(
        _ submitted: ResolvedVideoOfferingCapabilitiesV1?,
        target: ResolvedGenerationTarget
    ) throws {
        guard let exact = target.binding?.resolvedVideoCapabilities,
              exact.contractViolation == nil,
              submitted == exact,
              target.binding?.productionInputPolicy == exact.inputPolicy else {
            throw GenerationBackendError.transport(
                "The selected provider endpoint has no matching versioned video capability contract."
            )
        }
    }

    private func runJob(
        placeholders: [MediaAsset],
        params: BackendGenerationParams,
        genInput: GenerationInput,
        target: ResolvedGenerationTarget,
        authorization: GenerationAuthorization,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        let runId = String(UUID().uuidString.prefix(8))
        Log.generation.notice(
            "run \(runId) start model=\(genInput.model) provider=\(target.provider.rawValue) "
                + "transport=\(target.transport.rawValue) endpoint=\(target.endpoint) "
                + "placeholders=\(placeholders.count)"
        )
        defer { Log.generation.notice("run \(runId) settled") }

        // `.mcp` runs over MCP, not a keyless REST call, so `canRun` matches what executes.
        let provider = target.provider
        let endpoint = target.endpoint
        let binding = target.binding

        if binding?.transport == .mcp {
            await runMCPJob(
                provider: provider, toolName: endpoint, modelParam: binding?.modelParam,
                mediaRoles: binding?.mcpMediaRoles,
                params: params, genInput: genInput,
                placeholders: placeholders, editor: editor,
                authorization: authorization,
                onComplete: onComplete, onFailure: onFailure)
            return
        }

        switch provider {
        case .marble:
            guard case .image(let p) = params, let marbleModel = MarbleModelRegistry.model(for: endpoint) else {
                return failBeforeSubmission(
                    placeholders, "Unsupported Marble request for model: \(endpoint)",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            await runMarbleJob(
                model: marbleModel, prompt: p.prompt, referencePath: p.imageURLs.first,
                name: genInput.prompt, placeholders: placeholders, editor: editor,
                authorization: authorization,
                onComplete: onComplete, onFailure: onFailure)
            return
        case .runway:
            await runRunwayJob(
                endpoint: endpoint,
                params: params,
                inputPolicy: binding?.resolvedVideoCapabilities?.inputPolicy,
                placeholders: placeholders, editor: editor,
                authorization: authorization,
                onComplete: onComplete, onFailure: onFailure)
            return
        case .elevenlabs:
            // Direct to the user's ElevenLabs key (their account, no fal middleman); a non-audio
            // request falls through to fal's hosted endpoints below.
            if case .audio(let audioParams) = params {
                await runElevenLabsJob(
                    endpoint: endpoint, params: audioParams,
                    placeholders: placeholders, editor: editor,
                    authorization: authorization,
                    onComplete: onComplete, onFailure: onFailure)
                return
            }
        case .higgsfield, .openart, .ace:
            // MCP-only providers: a resolved `.mcp` binding was handled above. Reaching here means the
            // provider isn't signed in (no `.mcp` binding, no direct-API path) — its models were never
            // offered (usable-only), so this is the guidance for a stale id.
            return failBeforeSubmission(
                placeholders,
                "\(provider.displayName) runs over MCP — sign in under Settings \u{2192} Providers.",
                authorization: authorization, editor: editor, onFailure: onFailure)
        case .google:
            guard case .image(let p) = params,
                  let model = GoogleModelRegistry.model(for: endpoint) else {
                return failBeforeSubmission(
                    placeholders, "Unsupported Google AI request for model: \(endpoint)",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            await runGoogleImageJob(
                apiModel: endpoint, model: model, params: p,
                placeholders: placeholders, editor: editor, authorization: authorization,
                onComplete: onComplete, onFailure: onFailure)
            return
        case .fal:
            break
        }

        let falModel = FalModelRegistry.model(for: genInput.model)
            ?? FalModelRegistry.model(for: endpoint)
        let input: [String: Any]
        let shape: CatalogEntry.ResponseShape

        switch params {
        case .image(let p):
            guard let falModel else {
                return failBeforeSubmission(
                    placeholders, "Unknown image model: \(endpoint)",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            input = FalInputBuilder.imageInput(p, model: falModel, count: placeholders.count)
            shape = .images
        case .video(let p):
            guard let falModel else {
                return failBeforeSubmission(
                    placeholders, "Unknown video model: \(endpoint)",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            let videoInput = FalInputBuilder.videoInput(p, model: falModel)
            do {
                try PipelineProductionRouting.validateFalProviderEnvelope(
                    genInput: genInput,
                    params: p,
                    input: videoInput,
                    model: falModel
                )
            } catch {
                return failBeforeSubmission(
                    placeholders,
                    "The routed fal request failed its final provider-envelope check: \(error)",
                    authorization: authorization,
                    editor: editor,
                    onFailure: onFailure
                )
            }
            input = videoInput
            shape = .video
        case .audio(let p):
            guard let falModel else {
                return failBeforeSubmission(
                    placeholders, "Unknown audio model: \(endpoint)",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            input = FalInputBuilder.audioInput(p, model: falModel)
            shape = .audio
        case .upscale(let p):
            guard let falModel else {
                return failBeforeSubmission(
                    placeholders, "Unknown upscale model: \(endpoint)",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            input = FalInputBuilder.upscaleInput(p, model: falModel)
            shape = falModel.entry.responseShape
        }

        await runFalJob(
            endpoint: endpoint,
            input: input,
            shape: shape,
            placeholders: placeholders,
            editor: editor,
            authorization: authorization,
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

    private func failBeforeSubmission(
        _ placeholders: [MediaAsset],
        _ message: String,
        authorization: GenerationAuthorization,
        editor: EditorViewModel,
        onFailure: (@MainActor () -> Void)?
    ) {
        try? editor.recordSpendEvent(
            authorization: authorization,
            kind: .released,
            note: message
        )
        failJob(placeholders, message, onFailure)
    }

    private func markSubmitted(
        authorization: GenerationAuthorization,
        providerRequestId: String,
        editor: EditorViewModel
    ) {
        do {
            try editor.recordSpendEvent(
                authorization: authorization,
                kind: .submitted,
                providerRequestId: providerRequestId,
                money: authorization.estimate
            )
        } catch {
            Log.generation.error(
                "could not record provider request \(providerRequestId): \(error.localizedDescription)"
            )
        }
    }

    private func markCharged(
        authorization: GenerationAuthorization,
        money: GenerationMoney? = nil,
        editor: EditorViewModel
    ) {
        guard let charged = money ?? authorization.estimate else { return }
        do {
            try editor.recordSpendEvent(
                authorization: authorization,
                kind: .charged,
                money: charged
            )
        } catch {
            Log.generation.error("could not record generation charge: \(error.localizedDescription)")
        }
    }

    private func runFalJob(
        endpoint: String,
        input: [String: Any],
        shape: CatalogEntry.ResponseShape,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        authorization: GenerationAuthorization,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.fal) else {
            return failBeforeSubmission(
                placeholders, "Add a fal.ai API key in Settings to generate.",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }

        var requestId: String?
        do {
            // fal's raw HTTP queue API takes the input fields at the top level — NOT wrapped in
            // an "input" key (that is only the JS/Python SDK convention). Wrapping made fal see no
            // recognized fields and reject every job, so no fal generation ever produced an asset.
            let inputBody = try JSONSerialization.data(withJSONObject: input)
            let client = FalClient(apiKey: apiKey)
            let submittedId = try await client.submit(endpoint: endpoint, inputBody: inputBody)
            requestId = submittedId
            markSubmitted(
                authorization: authorization,
                providerRequestId: submittedId,
                editor: editor
            )
            let outputData = try await client.result(endpoint: endpoint, requestId: submittedId)
            let urls = FalOutput.urls(from: outputData, shape: shape)
            guard !urls.isEmpty else {
                throw GenerationBackendError.transport("fal returned no output")
            }
            let job = BackendGenerationJob(
                _id: submittedId,
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
                mutationScope: authorization.projectMutationScope,
                onComplete: onComplete,
                onFailure: onFailure
            )
            let billed = try? await ProviderMoneyClient.shared.falCharge(
                requestId: submittedId,
                endpoint: endpoint,
                apiKey: apiKey
            )
            if let billed {
                markCharged(
                    authorization: authorization,
                    money: billed,
                    editor: editor
                )
            }
        } catch let error as FalClient.SubmissionOutcomeUnknownError {
            markSubmitted(
                authorization: authorization,
                providerRequestId: error.ledgerRequestID,
                editor: editor
            )
            failJob(placeholders, error.localizedDescription, onFailure)
        } catch let error as FalClient.SubmissionAcknowledgedError {
            markSubmitted(
                authorization: authorization,
                providerRequestId: error.ledgerRequestID,
                editor: editor
            )
            failJob(placeholders, error.localizedDescription, onFailure)
        } catch is CancellationError {
            if requestId == nil {
                failBeforeSubmission(
                    placeholders, "Generation cancelled.",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            } else {
                failJob(placeholders, "Generation cancelled.", onFailure)
            }
        } catch {
            if requestId == nil {
                failBeforeSubmission(
                    placeholders, error.localizedDescription,
                    authorization: authorization, editor: editor, onFailure: onFailure)
            } else {
                failJob(placeholders, error.localizedDescription, onFailure)
            }
        }
    }

    /// Run a generation over a provider's MCP transport — NGV as MCP client, behind the gate. It
    /// discovers the provider's tools (`tools/list`), matches one to the request's modality, calls it
    /// with the gate-compiled prompt, and imports the returned media URL(s) through the same finalize
    /// path as the REST providers. Tool match + argument shape come from live discovery; a
    /// provider whose MCP exposes no matching tool fails with guidance, not a keyless REST attempt.
    private func runMCPJob(
        provider: GenerationProvider,
        toolName: String?,
        modelParam: String?,
        mediaRoles: [String]?,
        params: BackendGenerationParams,
        genInput: GenerationInput,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        authorization: GenerationAuthorization,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let client = await ProviderMCP.client(for: provider) else {
            return failBeforeSubmission(
                placeholders, "No MCP endpoint configured for \(provider.displayName).",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
        let submissionState = MCPSubmissionDispatchState()
        var selectedToolName = toolName
        let requiredCandidateNames = PipelineProductionRouting.requiredMCPFieldNames(
            genInput: genInput
        )
        do {
            let tools = try await client.discoverTools()
            // Prefer the exact generate tool the resolved offer named (from discovery); fall back to
            // modality matching for a bootstrap/legacy offer that carried no tool name.
            let tool = toolName.flatMap { name in tools.first { $0.name == name } }
                ?? Self.matchMCPTool(tools, for: params)
            guard let tool else {
                await client.disconnect()
                return failBeforeSubmission(
                    placeholders,
                    "\(provider.displayName)'s MCP exposes no tool for this request — check the provider's MCP or add its API key.",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            selectedToolName = tool.name
            let requestId = UUID().uuidString
            _ = try MCPGenerationArguments.make(
                for: params,
                model: modelParam,
                schema: tool.inputSchema,
                mediaRoles: mediaRoles,
                requestID: requestId,
                requiredCandidateNames: requiredCandidateNames
            )
            guard MCPGenerationExecutor.hasProvenResultPath(
                generationTool: tool,
                tools: tools
            ) else {
                throw GenerationBackendError.transport(
                    "\(provider.displayName)'s generation tool exposes no proven direct, synchronous, or asynchronous media result path. No job was submitted."
                )
            }
            let preparedParams = try await MCPMediaUpload.prepare(
                params,
                tools: tools,
                client: client
            )
            let arguments = try MCPGenerationArguments.make(
                for: preparedParams,
                model: modelParam,
                schema: tool.inputSchema,
                mediaRoles: mediaRoles,
                requestID: requestId,
                requiredCandidateNames: requiredCandidateNames
            )
            Log.generation.notice(
                "MCP submit provider=\(provider.rawValue) tool=\(tool.name) model=\(modelParam ?? "<implicit>") fields=\(arguments.keys.sorted().joined(separator: ","))"
            )
            let result = try await MCPGenerationExecutor.run(
                generationTool: tool,
                arguments: arguments,
                tools: tools,
                provider: provider,
                client: client,
                onSubmissionDispatched: {
                    submissionState.recordDispatch()
                    self.markSubmitted(
                        authorization: authorization,
                        providerRequestId: requestId,
                        editor: editor
                    )
                }
            )
            await client.disconnect()
            let job = BackendGenerationJob(
                _id: result.jobID ?? requestId, status: .succeeded,
                resultUrls: result.output.urls,
                errorMessage: nil, costCredits: nil, completedAt: nil)
            if result.output.inlineMedia.isEmpty {
                await finalizeSuccess(
                    job: job, placeholders: placeholders, editor: editor,
                    mutationScope: authorization.projectMutationScope,
                    onComplete: onComplete, onFailure: onFailure)
            } else {
                await finalizeMCPMedia(
                    result.output.media,
                    placeholders: placeholders,
                    editor: editor,
                    mutationScope: authorization.projectMutationScope,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            }
            markCharged(authorization: authorization, editor: editor)
        } catch {
            await client.disconnect()
            if let failure = error as? MCPGenerationExecutor.JobFailure {
                Log.generation.error(
                    "MCP provider job abandoned id=\(failure.jobID) error=\(failure.message)"
                )
            }
            let tool = selectedToolName ?? "<undiscovered>"
            let model = modelParam ?? "<implicit>"
            switch Self.classifyMCPFailure(
                error,
                didDispatch: submissionState.didDispatch,
                providerName: provider.displayName,
                toolName: tool,
                modelName: model
            ) {
            case .failJob(let message):
                failJob(placeholders, message, onFailure)
            case .failBeforeSubmission(let message):
                failBeforeSubmission(
                    placeholders,
                    message,
                    authorization: authorization,
                    editor: editor,
                    onFailure: onFailure
                )
            }
        }
    }

    nonisolated static func classifyMCPFailure(
        _ error: any Error,
        didDispatch: Bool,
        providerName: String,
        toolName: String,
        modelName: String
    ) -> MCPFailureHandling {
        let message: String
        if error is CancellationError {
            message = "Generation cancelled."
        } else if error is MCPGenerationArguments.MappingError {
            message = "NexGenVideo cannot map \(providerName) MCP tool '\(toolName)' for model '\(modelName)': \(error.localizedDescription) The generation request was not sent."
        } else if error is MCPMediaUpload.UploadError, !didDispatch {
            message = "\(providerName) reference upload failed before generation: \(error.localizedDescription)"
        } else {
            message = "\(providerName) MCP tool '\(toolName)' for model '\(modelName)' failed: \(error.localizedDescription)"
        }
        return didDispatch ? .failJob(message) : .failBeforeSubmission(message)
    }

    /// Best-effort match of a discovered MCP tool to the request modality by name/description keywords
    /// — discovery-driven, no hardcoded per-provider table. A single-tool server uses that one tool.
    private static func matchMCPTool(
        _ tools: [MCPProviderClient.DiscoveredTool], for params: BackendGenerationParams
    ) -> MCPProviderClient.DiscoveredTool? {
        let wanted: [String]
        switch params {
        case .video: wanted = ["video", "animate", "motion", "i2v", "t2v"]
        case .image: wanted = ["image", "picture", "txt2img", "img"]
        case .audio: wanted = ["audio", "music", "sound", "speech", "voice", "tts"]
        case .upscale: wanted = ["upscale", "enhance", "super"]
        }
        if let hit = tools.first(where: { t in
            let hay = (t.name + " " + (t.description ?? "")).lowercased()
            return wanted.contains { hay.contains($0) }
        }) { return hit }
        return tools.count == 1 ? tools.first : nil
    }

    private func runRunwayJob(
        endpoint: String,
        params: BackendGenerationParams,
        inputPolicy: ProviderProductionInputPolicyV1?,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        authorization: GenerationAuthorization,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.runway) else {
            return failBeforeSubmission(
                placeholders, "Add a Runway API key in Settings to generate.",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
        guard let model = RunwayModelRegistry.model(for: endpoint) else {
            return failBeforeSubmission(
                placeholders, "Unknown Runway model: \(endpoint)",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
        var taskId: String?
        do {
            let client = RunwayClient(apiKey: apiKey)
            switch params {
            case .video(let p) where inputPolicy?.requiresSourceVideo == true:
                // #223 — the restyle pass: re-render an existing clip. No duration (the output follows
                // the source) and no reference image; the source clip IS the input.
                guard let source = p.sourceVideoURL else {
                    return failBeforeSubmission(
                        placeholders,
                        "\(model.entry.displayName) restyles an existing clip — pass the source video.",
                        authorization: authorization, editor: editor, onFailure: onFailure)
                }
                taskId = try await client.createVideoToVideo(
                    model: model.apiModel, videoUri: source, promptText: p.prompt,
                    ratio: RunwayModelRegistry.videoRatio(for: p.aspectRatio))
            case .video(let p):
                guard let image = p.referenceImageURLs.first ?? p.startFrameURL else {
                    return failBeforeSubmission(
                        placeholders,
                        "\(model.entry.displayName) is image-to-video — add a reference image.",
                        authorization: authorization, editor: editor, onFailure: onFailure)
                }
                guard case .seconds(let duration) = p.duration else {
                    return failBeforeSubmission(
                        placeholders, "Runway does not support automatic video duration.",
                        authorization: authorization, editor: editor, onFailure: onFailure)
                }
                taskId = try await client.createImageToVideo(
                    model: model.apiModel, promptImage: image, promptText: p.prompt,
                    ratio: RunwayModelRegistry.videoRatio(for: p.aspectRatio), duration: duration)
            case .image(let p):
                taskId = try await client.createTextToImage(model: model, params: p)
            default:
                return failBeforeSubmission(
                    placeholders, "Unsupported Runway request: \(endpoint)",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            guard let taskId else {
                return failBeforeSubmission(
                    placeholders, "Runway returned no task id.",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            markSubmitted(
                authorization: authorization,
                providerRequestId: taskId,
                editor: editor
            )
            let urls = try await client.output(taskId: taskId)
            let job = BackendGenerationJob(
                _id: taskId, status: .succeeded, resultUrls: urls,
                errorMessage: nil, costCredits: nil, completedAt: nil)
            await finalizeSuccess(
                job: job, placeholders: placeholders, editor: editor,
                mutationScope: authorization.projectMutationScope,
                onComplete: onComplete, onFailure: onFailure)
            markCharged(authorization: authorization, editor: editor)
        } catch let error as RunwayClient.SubmissionOutcomeUnknownError {
            markSubmitted(
                authorization: authorization,
                providerRequestId: error.ledgerRequestID,
                editor: editor
            )
            failJob(placeholders, error.localizedDescription, onFailure)
        } catch let error as RunwayClient.SubmissionAcknowledgedError {
            markSubmitted(
                authorization: authorization,
                providerRequestId: error.ledgerRequestID,
                editor: editor
            )
            failJob(placeholders, error.localizedDescription, onFailure)
        } catch is CancellationError {
            let message = "Generation cancelled."
            if taskId == nil {
                failBeforeSubmission(
                    placeholders,
                    message,
                    authorization: authorization,
                    editor: editor,
                    onFailure: onFailure
                )
            } else {
                failJob(placeholders, message, onFailure)
            }
        } catch {
            if taskId == nil {
                failBeforeSubmission(
                    placeholders, error.localizedDescription,
                    authorization: authorization, editor: editor, onFailure: onFailure)
            } else {
                failJob(placeholders, error.localizedDescription, onFailure)
            }
        }
    }

    /// Where this model's references must live. Decided from `dispatchTarget` — the SAME resolution
    /// `runJob` dispatches on — so the upload step and the dispatch cannot disagree about the
    /// provider. (`GenerationProvider.servicing` is not usable here: with no bindings it falls back to
    /// `.fal` while dispatch falls back to `nominalProvider`, so an undiscovered Runway/Google model
    /// would have its references hosted on fal and then handed to a provider that can't read them.)
    @MainActor
    static func referenceHosting(modelId: String) -> ReferenceHosting {
        referenceHosting(for: dispatchTarget(modelId: modelId))
    }

    static func referenceHosting(for target: ResolvedGenerationTarget) -> ReferenceHosting {
        if target.transport == .mcp { return .mcp }
        return referenceHosting(for: target.provider)
    }

    static func referenceHosting(for provider: GenerationProvider) -> ReferenceHosting {
        switch provider {
        // Marble takes a local path and base64s the file itself, so its reference was never hosted —
        // it only reached the fal branch because the submission hands the path in pre-uploaded, which
        // then got persisted as if it were a hosted URL.
        case .google, .marble: return .inline
        case .runway: return .runway
        default: return .fal
        }
    }

    /// LLM → NGV → Provider. The LLM's model id is a LOGICAL id; the resolver decides which provider +
    /// transport runs it (activated ∩ offers ∩ cheapest), and dispatch then uses the resolved offer's
    /// `providerRef` — the provider's OWN endpoint — so a logical id can differ from the provider
    /// endpoint (provider-neutral models). The nominal-provider fallback keeps the "add a key" errors
    /// naming the right provider when nothing is activated.
    @MainActor
    static func dispatchTarget(
        modelId: String,
        requiringSourceVideo: Bool? = nil,
        matchingVideoCapabilities: ((ResolvedVideoOfferingCapabilitiesV1) -> Bool)? = nil
    ) -> ResolvedGenerationTarget {
        let binding = ProviderResolver.resolve(
            bindings: ProviderManifest.bindings(forModelId: modelId).filter { binding in
                videoBindingIsCompatible(
                    binding,
                    requiringSourceVideo: requiringSourceVideo,
                    matchingCapabilities: matchingVideoCapabilities
                )
            },
            activation: .current(),
            effectiveCost: ProviderManifest.effectiveCost)
        return ResolvedGenerationTarget(
            modelId: modelId,
            provider: binding?.provider ?? ProviderManifest.nominalProvider(forModelId: modelId),
            endpoint: binding?.providerRef ?? modelId,
            binding: binding
        )
    }

    nonisolated static func videoBindingIsCompatible(
        _ binding: ProviderBinding,
        requiringSourceVideo: Bool?,
        matchingCapabilities: ((ResolvedVideoOfferingCapabilitiesV1) -> Bool)? = nil
    ) -> Bool {
        guard requiringSourceVideo != nil || matchingCapabilities != nil else { return true }
        guard let capabilities = binding.resolvedVideoCapabilities,
              capabilities.contractViolation == nil,
              binding.productionInputPolicy == capabilities.inputPolicy else {
            return false
        }
        if let requiringSourceVideo,
           capabilities.inputPolicy.requiresSourceVideo != requiringSourceVideo {
            return false
        }
        return matchingCapabilities?(capabilities) ?? true
    }

    static func referenceBytes(_ paths: [String]) throws -> [Data] {
        try paths.map { path in
            let url = URL(fileURLWithPath: path)
            do {
                return try Data(contentsOf: url)
            } catch {
                throw GenerationBackendError.transport(
                    "Could not read approved reference '\(url.lastPathComponent)' from project storage."
                )
            }
        }
    }

    /// #212 — Google AI on the user's own key: the Gemini image line, all on `:generateContent`.
    private func runGoogleImageJob(
        apiModel: String,
        model: GoogleImageModel,
        params: ImageGenerationParams,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        authorization: GenerationAuthorization,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.google) else {
            return failBeforeSubmission(
                placeholders, "Add a Google AI API key in Settings to generate.",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
        let client = GoogleImageClient(apiKey: apiKey)
        let prepared: GoogleImageClient.PreparedGeminiImageRequest
        do {
            let references = try Self.referenceBytes(params.imageURLs)
            prepared = try await client.prepareGeminiImageRequest(
                model: apiModel,
                prompt: params.prompt,
                aspectRatio: params.aspectRatio,
                referenceImages: references
            )
        } catch {
            return failBeforeSubmission(
                placeholders, error.localizedDescription,
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
        do {
            markSubmitted(
                authorization: authorization,
                providerRequestId: UUID().uuidString,
                editor: editor
            )
            let images = try await client.geminiImage(prepared: prepared)
            await finalizeBytes(
                images,
                placeholders: placeholders,
                editor: editor,
                mutationScope: authorization.projectMutationScope,
                onComplete: onComplete,
                onFailure: onFailure
            )
            markCharged(authorization: authorization, editor: editor)
        } catch {
            failJob(placeholders, error.localizedDescription, onFailure)
        }
    }

    /// The image format a provider ACTUALLY returned, sniffed from the bytes.
    ///
    /// Not from a `mimeType` header, and never assumed: a live Gemini call returns **JPEG** even though
    /// the placeholder is created as `.png`, so trusting the extension writes JPEG bytes into a `.png`
    /// file. The URL path handles this by renaming (`downloadAndFinalize` does it from the remote
    /// URL's extension); the bytes path has no URL to read, so it reads the bytes. Magic numbers are
    /// also provider-independent — the next provider's default format needs no new plumbing.
    /// nil for anything unrecognized, which leaves the placeholder's own extension alone.
    nonisolated private static func imageExtension(sniffing data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 12 else { return nil }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "tiff"
        }
        if Array(b[4..<8]) == [0x66, 0x74, 0x79, 0x70],
           ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(
               String(bytes: b[8..<12], encoding: .ascii)
           ) {
            return "heic"
        }
        return nil
    }

    /// Finalize providers that answer with BYTES instead of a hosted URL: write each image to its
    /// placeholder's destination and run the same steps `downloadAndFinalize` performs after its move.
    /// A placeholder with no image left over (the provider returned fewer than asked) fails alone.
    private func finalizeBytes(
        _ images: [Data],
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        mutationScope: GenerationProjectMutationScope?,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        var finalized: [MediaAsset] = []
        for (i, placeholder) in placeholders.enumerated() {
            guard editor.mediaAssets.contains(where: { $0.id == placeholder.id }) else { continue }
            guard i < images.count else {
                placeholder.generationStatus = .failed("No image for placeholder")
                continue
            }
            // Name the file after what the bytes ARE, not what we asked for — same correction
            // `downloadAndFinalize` makes from the remote URL's extension.
            if let realExt = Self.imageExtension(sniffing: images[i]),
               realExt != placeholder.url.pathExtension.lowercased() {
                placeholder.url = placeholder.url.deletingPathExtension().appendingPathExtension(realExt)
            }
            do {
                try mutationScope?.requireCurrent(editor: editor)
                try? FileManager.default.removeItem(at: placeholder.url)
                try images[i].write(to: placeholder.url, options: .atomic)
            } catch {
                placeholder.generationStatus = .failed(error.localizedDescription)
                continue
            }
            placeholder.generationStatus = .none
            editor.importMediaAsset(placeholder, skipAppend: true)
            editor.appendGenerationLog(for: placeholder)
            await editor.finalizeImportedAsset(placeholder)
            onComplete?(placeholder)
            finalized.append(placeholder)
        }
        guard let first = finalized.first else { return onFailure?() ?? () }
        AppNotifications.generationComplete(
            assetId: first.id, projectURL: editor.projectURL, assetName: first.name,
            assetType: first.type, count: finalized.count)
    }

    private func finalizeMCPMedia(
        _ outputMedia: [MCPGenerationLifecycle.OutputMedia],
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        mutationScope: GenerationProjectMutationScope?,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        var finalized: [MediaAsset] = []
        for (index, placeholder) in placeholders.enumerated() {
            guard editor.mediaAssets.contains(where: { $0.id == placeholder.id }) else { continue }
            guard outputMedia.indices.contains(index) else {
                placeholder.generationStatus = .failed("No media for placeholder")
                continue
            }
            switch outputMedia[index] {
            case .remoteURL(let value):
                guard let remoteURL = URL(string: value) else {
                    placeholder.generationStatus = .failed("Provider returned an invalid media URL.")
                    continue
                }
                if await downloadAndFinalize(
                    asset: placeholder,
                    remoteURL: remoteURL,
                    editor: editor,
                    mutationScope: mutationScope
                ) {
                    onComplete?(placeholder)
                    finalized.append(placeholder)
                }
                continue
            case .inline(let media):
                let expectedPrefix: String
                switch placeholder.type {
                case .image: expectedPrefix = "image/"
                case .audio: expectedPrefix = "audio/"
                default:
                    placeholder.generationStatus = .failed(
                        "The provider returned inline media for an unsupported \(placeholder.type.rawValue) request."
                    )
                    continue
                }
                guard media.mimeType.lowercased().hasPrefix(expectedPrefix) else {
                    placeholder.generationStatus = .failed(
                        "Provider returned \(media.mimeType) for a \(placeholder.type.rawValue) request."
                    )
                    continue
                }
                let expectedType = placeholder.type
                let fileExtension = await Task.detached(priority: .utility) {
                    Self.validatedFileExtension(
                        data: media.data,
                        mimeType: media.mimeType,
                        expectedType: expectedType
                    )
                }.value
                guard let fileExtension else {
                    placeholder.generationStatus = .failed(
                        "Provider media bytes do not match the declared \(media.mimeType) container."
                    )
                    continue
                }
                if fileExtension != placeholder.url.pathExtension.lowercased() {
                    placeholder.url = placeholder.url.deletingPathExtension()
                        .appendingPathExtension(fileExtension)
                }
                do {
                    try mutationScope?.requireCurrent(editor: editor)
                    try? FileManager.default.removeItem(at: placeholder.url)
                    try media.data.write(to: placeholder.url, options: .atomic)
                } catch {
                    placeholder.generationStatus = .failed(error.localizedDescription)
                    continue
                }
                placeholder.generationStatus = .none
                editor.importMediaAsset(placeholder, skipAppend: true)
                editor.appendGenerationLog(for: placeholder)
                await editor.finalizeImportedAsset(placeholder)
                onComplete?(placeholder)
                finalized.append(placeholder)
            }
        }
        guard let first = finalized.first else {
            onFailure?()
            return
        }
        AppNotifications.generationComplete(
            assetId: first.id,
            projectURL: editor.projectURL,
            assetName: first.name,
            assetType: first.type,
            count: finalized.count
        )
    }

    nonisolated static func validatedFileExtension(
        data: Data,
        mimeType: String,
        expectedType: ClipType
    ) -> String? {
        let base = mimeType.lowercased().split(separator: ";", maxSplits: 1)
            .first.map(String.init) ?? ""
        let allowedExtensions: Set<String>
        let actualExtension: String?
        switch expectedType {
        case .image:
            allowedExtensions = switch base {
            case "image/jpeg", "image/jpg": ["jpg"]
            case "image/png": ["png"]
            case "image/webp": ["webp"]
            case "image/heic", "image/heif": ["heic"]
            case "image/tiff", "image/x-tiff": ["tiff"]
            default: []
            }
            actualExtension = imageExtension(sniffing: data)
        case .audio:
            allowedExtensions = switch base {
            case "audio/mpeg", "audio/mp3": ["mp3"]
            case "audio/wav", "audio/x-wav", "audio/wave": ["wav"]
            case "audio/aac": ["aac"]
            case "audio/mp4", "audio/x-m4a", "audio/m4a": ["m4a"]
            case "audio/flac", "audio/x-flac": ["flac"]
            case "audio/aiff", "audio/x-aiff", "audio/aifc", "audio/x-aifc":
                ["aiff", "aifc"]
            default: []
            }
            actualExtension = audioExtension(sniffing: data)
        default:
            return nil
        }
        guard let actualExtension, allowedExtensions.contains(actualExtension) else { return nil }
        switch expectedType {
        case .image:
            guard isDecodableImage(data) else { return nil }
        case .audio:
            guard isReadableAudio(data, fileExtension: actualExtension) else { return nil }
        default:
            return nil
        }
        return actualExtension
    }

    nonisolated private static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           width > 0, height > 0,
           width <= 16_384, height <= 16_384,
           width <= 64_000_000 / height else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) != nil
    }

    nonisolated private static func isReadableAudio(
        _ data: Data,
        fileExtension: String
    ) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-provider-audio-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  file.processingFormat.channelCount > 0,
                  file.processingFormat.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: file.processingFormat,
                      frameCapacity: AVAudioFrameCount(min(file.length, 1_024))
                  ) else {
                return false
            }
            try file.read(into: buffer)
            return buffer.frameLength > 0
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    nonisolated private static func audioExtension(sniffing data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 12 else { return nil }
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return "flac" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x41, 0x56, 0x45] {
            return "wav"
        }
        if bytes.starts(with: [0x46, 0x4F, 0x52, 0x4D]) {
            let form = String(bytes: bytes[8..<12], encoding: .ascii)
            if form == "AIFF" { return "aiff" }
            if form == "AIFC" { return "aifc" }
        }
        if bytes.starts(with: [0x49, 0x44, 0x33])
            || (bytes[0] == 0xFF
                && (bytes[1] & 0xE0) == 0xE0
                && (bytes[1] & 0x06) != 0) {
            return "mp3"
        }
        if bytes[0] == 0xFF, (bytes[1] & 0xF6) == 0xF0 { return "aac" }
        if Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return "m4a" }
        return nil
    }

    private func runElevenLabsJob(
        endpoint: String,
        params: AudioGenerationParams,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        authorization: GenerationAuthorization,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.elevenlabs) else {
            return failBeforeSubmission(
                placeholders, "Add an ElevenLabs API key in Settings to generate.",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
        guard let placeholder = placeholders.first else {
            return failBeforeSubmission(
                placeholders, "No placeholder was created for the ElevenLabs request.",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
        guard [
            "fal-ai/elevenlabs/tts/multilingual-v2",
            "fal-ai/elevenlabs/sound-effects",
            "fal-ai/elevenlabs/music",
        ].contains(endpoint) else {
            return failBeforeSubmission(
                placeholders, "Unsupported ElevenLabs model: \(endpoint)",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
        do {
            let client = ElevenLabsClient(apiKey: apiKey)
            markSubmitted(
                authorization: authorization,
                providerRequestId: UUID().uuidString,
                editor: editor
            )
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
                throw GenerationBackendError.transport(
                    "Unsupported ElevenLabs model: \(endpoint)"
                )
            }
            // Bytes arrive directly (no result URL) — write to the placeholder's destination and
            // run the same finalize steps downloadAndFinalize performs after its move.
            try authorization.projectMutationScope?.requireCurrent(editor: editor)
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
            markCharged(authorization: authorization, editor: editor)
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
        authorization: GenerationAuthorization,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let apiKey = ProviderKeychain.load(.marble) else {
            return failBeforeSubmission(
                placeholders, "Add a Marble (World Labs) API key in Settings to generate.",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
        guard let referencePath, let referenceURL = Self.localFileURL(referencePath) else {
            return failBeforeSubmission(
                placeholders, "Marble requires a reference image.",
                authorization: authorization, editor: editor, onFailure: onFailure)
        }

        var operationId: String?
        do {
            let displayName = String(name.prefix(60))
            let body = try MarbleInputBuilder.body(
                prompt: prompt, displayName: displayName, model: model.model, referenceImageURL: referenceURL
            )
            let client = MarbleClient(apiKey: apiKey)
            let submittedId = try await client.submit(body: body)
            operationId = submittedId
            markSubmitted(
                authorization: authorization,
                providerRequestId: submittedId,
                editor: editor
            )
            let outputData = try await client.result(operationId: submittedId)
            let urls = MarbleOutput.urls(from: outputData)
            guard !urls.isEmpty else {
                throw GenerationBackendError.transport("Marble returned no panorama")
            }
            let job = BackendGenerationJob(
                _id: submittedId,
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
                mutationScope: authorization.projectMutationScope,
                onComplete: onComplete,
                onFailure: onFailure
            )
            markCharged(authorization: authorization, editor: editor)
        } catch {
            if operationId == nil {
                failBeforeSubmission(
                    placeholders, error.localizedDescription,
                    authorization: authorization, editor: editor, onFailure: onFailure)
            } else {
                failJob(placeholders, error.localizedDescription, onFailure)
            }
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
        mutationScope: GenerationProjectMutationScope?,
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
            guard editor.mediaAssets.contains(where: { $0.id == placeholder.id }) else { continue }
            guard i < urlStrings.count, let remote = URL(string: urlStrings[i]) else {
                placeholder.generationStatus = .failed("No URL for placeholder")
                continue
            }
            if await downloadAndFinalize(
                asset: placeholder,
                remoteURL: remote,
                editor: editor,
                mutationScope: mutationScope
            ) {
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
