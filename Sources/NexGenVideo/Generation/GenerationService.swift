import AppKit
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

@MainActor
private final class MireloSettlementCallbacks {
    private var callbacks: [(@MainActor () -> Void)] = []
    private var resolved = false

    func add(_ callback: (@MainActor () -> Void)?) {
        guard !resolved, let callback else { return }
        callbacks.append(callback)
    }

    func resolveFailure() {
        guard !resolved else { return }
        resolved = true
        let pending = callbacks
        callbacks.removeAll()
        for callback in pending { callback() }
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

    private struct MireloReconciliationOperation {
        let assetID: String
        let transactionID: String
        let task: Task<Void, Never>
        let callbacks: MireloSettlementCallbacks
    }

    enum MCPFailureHandling: Equatable {
        case failBeforeSubmission(String)
        case failJob(String)
    }

    private static let uploadCacheTTL: TimeInterval = 6 * 24 * 60 * 60
    private var generationTasks: [String: Task<Void, Never>] = [:]
    private var batchResumeTasks: [String: Task<Void, Error>] = [:]
    private var mireloReconciliationTasks: [String: MireloReconciliationOperation] = [:]
    var mireloStoreProvider: () throws -> MireloExecutionStore = {
        try MireloExecutionStore.live()
    }
    var mireloAPIKeyProvider: () -> String? = {
        ProviderKeychain.load(.mirelo)
    }
    var mireloClientProvider: (String) -> MireloClient = {
        MireloClient(apiKey: $0)
    }
    var mireloBeforeFirstExecute: (@MainActor @Sendable () async -> Void)?

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
        preparedParameters: PreparedProviderParameters? = nil,
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
        authorizedGenInput.takeRepairPlanID = authorization.takeRepairPlanID
        authorizedGenInput.compileRecipe = authorization.compileRecipe
        authorizedGenInput.referenceReceipts = authorization.referenceSnapshot?.receipts
        authorizedGenInput.generationPackageID = authorization.generationPackage?.id
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
        let refURLs = authorization.referenceSnapshot?.urls ?? references.map(\.url)

        // Resolved ONCE, here, and handed to `runJob` — never re-resolved. Reading the activation a
        // second time after the upload would let the two disagree: a key added while a reference was
        // still uploading would re-route the dispatch to a provider that cannot read what was just
        // hosted (a direct provider handed a fal URL reads it as a file path, finds nothing, and
        // silently renders without the reference).
        let target = authorization.target
        let hosting = Self.referenceHosting(for: target)

        let task = Task { @MainActor [weak self, weak editor] in
            guard let self, let editor else {
                onFailure?()
                return
            }
            var tempToCleanup: [URL] = []
            defer {
                Self.cleanupTempFiles(tempToCleanup)
                self.generationTasks.removeValue(forKey: primaryId)
            }
            do {
                try authorization.projectMutationScope?.requireCurrent(editor: editor)
                try authorization.referenceSnapshot?.requireIdentity(references)
                try await authorization.referenceSnapshot?.requireUnchanged()
                try authorization.projectMutationScope?.requireCurrent(editor: editor)
                if let package = authorization.generationPackage {
                    try package.payload.destination.requireCurrent(editor: editor)
                    guard let preparedParameters else { throw GenerationRequestError.gate("The reviewed generation has no prepared request parameters.") }
                    try package.requireRequest(input: authorizedGenInput, target: target, parameters: preparedParameters,
                        references: authorization.referenceSnapshot?.receipts ?? [])
                }
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
                    uploaded = authorization.referenceSnapshot?.urls.map(\.path) ?? preUploadedURLs
                } else {
                    var urlsToUpload = refURLs
                    let refTypes = references.map(\.type)
                    if authorization.referenceSnapshot == nil, let trim = trimmedSourceOverride, trim.hasTrim, !urlsToUpload.isEmpty {
                        Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[0].lastPathComponent)")
                        let extracted = try await VideoTrimExtractor.extract(trim)
                        urlsToUpload[0] = extracted
                        tempToCleanup.append(extracted)
                    }
                    if authorization.referenceSnapshot == nil, let preprocessRef, !references.isEmpty {
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
                        if authorization.referenceSnapshot != nil { return nil }
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

                let params = try preparedParameters?.bind(uploaded) ?? buildParams(uploaded)
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

                let currentRepairPlan = try await TakeRepairPlan.requireForGeneration(input: finalGenInput, home: projectURL)
                guard currentRepairPlan == authorization.takeRepairPlanID else {
                    throw ToolError("The iteration decision changed before submission. Review the current request again.")
                }
                try await authorization.referenceSnapshot?.requireUnchanged()
                try authorization.referenceSnapshot?.requireIdentity(references)
                if let package = authorization.generationPackage, let preparedParameters {
                    try package.requireRequest(input: finalGenInput, target: target, parameters: preparedParameters,
                        references: authorization.referenceSnapshot?.receipts ?? [])
                }
                try await authorization.generationPackage?.requireCurrentContext(editor: editor)
                try authorization.projectMutationScope?.requireCurrent(editor: editor)
                try authorization.generationPackage?.payload.destination.requireCurrent(editor: editor)
                if assetType == .video {
                    try PipelineProductionRouting.validateSubmission(genInput: finalGenInput, target: target, references: references, editor: editor)
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
                self.failBeforeSubmission(
                    placeholders,
                    message,
                    authorization: authorization,
                    editor: editor,
                    onFailure: onFailure
                )
            } catch {
                let message = error.localizedDescription
                Log.generation.error("upload failed model=\(authorizedGenInput.model) error=\(message)")
                self.failBeforeSubmission(
                    placeholders,
                    "Upload failed: \(message)",
                    authorization: authorization,
                    editor: editor,
                    onFailure: onFailure
                )
            }
            do { try await authorization.batchItem?.settle(editor: editor) }
            catch { Log.generation.error("could not settle generation batch: \(error.localizedDescription)") }
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

    func waitForGeneration(placeholderId: String) async {
        await generationTasks[placeholderId]?.value
        let reconciliations = mireloReconciliationTasks.values.filter {
            $0.assetID == placeholderId
        }
        for reconciliation in reconciliations {
            await reconciliation.task.value
        }
    }

    func resumeBatchJob(_ item: GenerationBatchAuthorization, editor: EditorViewModel) async throws {
        let identity = item.batchID + "/" + item.itemID
        if let task = batchResumeTasks[identity] { return try await task.value }
        let task = Task { @MainActor in
            defer { self.batchResumeTasks.removeValue(forKey: identity) }
            try await self.performResumeBatchJob(item, editor: editor)
        }
        batchResumeTasks[identity] = task
        try await task.value
    }

    private func performResumeBatchJob(_ item: GenerationBatchAuthorization, editor: EditorViewModel) async throws {
        guard let home = editor.workingRoot else { throw GenerationRequestError.storage("The batch project is closed.") }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let saved = try GenerationBatchStore.load(id: item.batchID, home: home)
        guard let execution = saved.journal.executions.first(where: { $0.itemID == item.itemID }),
              let specification = saved.batch.payload.items.first(where: { $0.id == item.itemID }),
              let requestID = execution.providerRequestID, execution.providerRequestResumable,
              let primaryID = execution.placeholders.first?.id else {
            throw GenerationRequestError.gate("This interrupted request has no resumable provider receipt. It will not be submitted again.")
        }
        if let existing = generationTasks[primaryID] { await existing.value; return }
        let receipts = try await Task.detached(priority: .utility) {
            try execution.placeholders.compactMap {
                try GenerationBatchOutput.load(authorization: item, assetID: $0.id, home: home)
            }
        }.value
        try scope.requireCurrent(editor: editor)
        let completedIDs = Set(receipts.map(\.asset.id))
        let target = specification.package.payload.target
        guard target.transport == .api, [.fal, .runway, .marble].contains(target.provider) else {
            throw GenerationRequestError.gate("This provider request cannot yet resume status retrieval.")
        }
        var placeholders: [MediaAsset] = []
        for planned in execution.placeholders {
            let receipt = receipts.first { $0.asset.id == planned.id }
            let entry = receipt?.asset ?? planned
            guard case .project(let path) = entry.source,
                  case .project(let plannedPath) = planned.source else { throw GenerationRequestError.storage("The batch output is not project-local.") }
            let url = home.appendingPathComponent(path)
            guard url.resolvingSymlinksInPath() == home.resolvingSymlinksInPath().appendingPathComponent(path) else {
                throw GenerationRequestError.storage("The batch output cannot traverse a symbolic link.")
            }
            if let existing = editor.mediaAssets.first(where: { $0.id == entry.id }) {
                guard existing.generationInput?.spendTransactionId == execution.transactionID,
                      existing.generationInput?.generationPackageID == specification.package.id,
                      existing.generationInput.map(GenerationPackageV1.normalized) == specification.package.payload.generationInput,
                      existing.type == entry.type,
                      existing.url.standardizedFileURL == url.standardizedFileURL ||
                        (receipt != nil && existing.url.standardizedFileURL == home.appendingPathComponent(plannedPath).standardizedFileURL) else {
                    throw GenerationRequestError.gate("A saved batch destination now belongs to another asset.")
                }
                if receipt != nil {
                    existing.url = url
                    existing.duration = entry.duration
                    existing.sourceWidth = entry.sourceWidth
                    existing.sourceHeight = entry.sourceHeight
                    existing.sourceFPS = entry.sourceFPS
                    existing.hasAudio = entry.hasAudio ?? false
                    existing.pendingDownloadURL = nil
                    existing.generationStatus = .none
                }
                placeholders.append(existing)
            } else {
                let asset = MediaAsset(entry: entry, resolvedURL: url)
                asset.generationStatus = receipt == nil ? .generating : .none
                editor.mediaAssets.append(asset)
                placeholders.append(asset)
            }
        }
        _ = try GenerationBatchStore.update(saved, editor: editor) { try $0.resumeRecordedJob(itemID: item.itemID) }
        guard let key = ProviderKeychain.load(target.provider) else {
            throw GenerationRequestError.gate("Restore the approved provider's key before resuming its job.")
        }
        let task = Task { @MainActor [weak self, weak editor] in
            guard let self, let editor else { return }
            defer { self.generationTasks.removeValue(forKey: primaryID) }
            do {
                if completedIDs.count < execution.placeholders.count {
                    let urls: [String]
                    switch target.provider {
                    case .fal:
                        let data = try await FalClient(apiKey: key).result(endpoint: target.endpoint, requestId: requestID)
                        let shape: CatalogEntry.ResponseShape = specification.package.payload.modality == "image" ? .images : .video
                        urls = FalOutput.urls(from: data, shape: shape)
                    case .runway: urls = try await RunwayClient(apiKey: key).output(taskId: requestID)
                    case .marble: urls = MarbleOutput.urls(from: try await MarbleClient(apiKey: key).result(operationId: requestID))
                    default: throw GenerationRequestError.gate("The saved provider route has no status adapter.")
                    }
                    try scope.requireCurrent(editor: editor)
                    await self.finalizeSuccess(job: .init(_id: requestID, status: .succeeded, resultUrls: urls,
                        errorMessage: nil, costCredits: nil, completedAt: nil), placeholders: placeholders,
                        editor: editor, mutationScope: scope, batchItem: item,
                        completedAssetIDs: completedIDs, onComplete: nil, onFailure: nil)
                }
                if let transaction = execution.transactionID,
                   !editor.generationLog.spendEvents.contains(where: { $0.transactionId == transaction && $0.kind == .charged }) {
                    let reserved = editor.generationLog.spendEvents.first { $0.transactionId == transaction && $0.kind == .reserved }?.money
                    let recoveredAuthorization = GenerationAuthorization(transactionId: transaction, target: target,
                        estimate: reserved, projectMutationScope: scope, generationPackage: specification.package, batchItem: item)
                    if target.provider == .fal {
                        if let billed = try? await ProviderMoneyClient.shared.falCharge(requestId: requestID, endpoint: target.endpoint, apiKey: key) {
                            self.markCharged(authorization: recoveredAuthorization, money: billed, editor: editor)
                        }
                    } else { self.markCharged(authorization: recoveredAuthorization, editor: editor) }
                }
            } catch {
                self.failJob(placeholders, error.localizedDescription, nil)
            }
            do { try await item.settle(editor: editor) }
            catch { Log.generation.error("could not settle resumed batch: \(error.localizedDescription)") }
        }
        generationTasks[primaryID] = task
        await task.value
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
        mutationScope: GenerationProjectMutationScope?,
        batchItem: GenerationBatchAuthorization? = nil
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
            if batchItem != nil, FileManager.default.fileExists(atPath: asset.url.path) {
                throw GenerationRequestError.storage("An unverified batch output already occupies this destination. Preserve it for reconciliation.")
            }
            try? FileManager.default.removeItem(at: asset.url)
            try FileManager.default.moveItem(at: tempURL, to: asset.url)
            transientURL = nil

            asset.pendingDownloadURL = nil
            asset.generationStatus = .none
            editor.importMediaAsset(asset, skipAppend: true)
            editor.appendGenerationLog(for: asset)
            await editor.finalizeImportedAsset(asset)
            if let batchItem { try await GenerationBatchOutput.record(asset: asset, authorization: batchItem, editor: editor) }
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
            do {
                var batchItem: GenerationBatchAuthorization?
                if let home = editor.workingRoot, let transaction = asset.generationInput?.spendTransactionId,
                   asset.generationInput?.generationPackageID != nil {
                    let assetID = asset.id
                    batchItem = try await Task.detached(priority: .utility) {
                        let candidates = try GenerationBatchStore.all(home: home).flatMap { snapshot in
                            snapshot.journal.executions.filter {
                                $0.transactionID == transaction && $0.placeholders.contains(where: { $0.id == assetID })
                            }.map { GenerationBatchAuthorization(batchID: snapshot.batch.id, itemID: $0.itemID) }
                        }
                        guard candidates.count <= 1 else { throw GenerationRequestError.storage("This output belongs to conflicting batch executions.") }
                        return candidates.first
                    }.value
                    try mutationScope?.requireCurrent(editor: editor)
                }
                await downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor,
                    mutationScope: mutationScope, batchItem: batchItem)
                try await batchItem?.settle(editor: editor)
            } catch { asset.generationStatus = .failed(error.localizedDescription) }
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
        do { try authorization.batchItem?.consume(authorization: authorization, editor: editor) }
        catch {
            return failBeforeSubmission(placeholders, error.localizedDescription,
                authorization: authorization, editor: editor, onFailure: onFailure)
        }
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
        case .mirelo:
            guard case .audio(let audioParams) = params else {
                return failBeforeSubmission(
                    placeholders,
                    "Mirelo supports audio requests on this route.",
                    authorization: authorization, editor: editor, onFailure: onFailure)
            }
            await runMireloJob(
                endpoint: endpoint,
                params: audioParams,
                genInput: genInput,
                placeholders: placeholders,
                editor: editor,
                authorization: authorization,
                onComplete: onComplete,
                onFailure: onFailure
            )
            return
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
        do {
            try editor.releaseUnsubmittedSpendReservation(
                authorization: authorization,
                placeholders: placeholders,
                note: message
            )
            failJob(placeholders, message, onFailure)
        } catch {
            let persistenceMessage = message
                + " The project could not release its unsubmitted spend reservation: "
                + error.localizedDescription
            failJob(placeholders, persistenceMessage, onFailure)
        }
    }

    private func markSubmitted(
        authorization: GenerationAuthorization,
        providerRequestId: String,
        resumable: Bool = false,
        editor: EditorViewModel
    ) {
        do {
            try editor.recordSpendEvent(
                authorization: authorization,
                kind: .submitted,
                providerRequestId: providerRequestId,
                providerRequestResumable: resumable,
                money: authorization.estimate
            )
            if let transactionID = authorization.transactionId {
                try authorization.batchItem?.recordProviderRequest(transactionID: transactionID,
                    requestID: providerRequestId, resumable: resumable, editor: editor)
            }
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
                resumable: true,
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
                batchItem: authorization.batchItem,
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
                    batchItem: authorization.batchItem,
                    onComplete: onComplete, onFailure: onFailure)
            } else {
                await finalizeMCPMedia(
                    result.output.media,
                    placeholders: placeholders,
                    editor: editor,
                    mutationScope: authorization.projectMutationScope,
                    batchItem: authorization.batchItem,
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
                resumable: true,
                editor: editor
            )
            let urls = try await client.output(taskId: taskId)
            let job = BackendGenerationJob(
                _id: taskId, status: .succeeded, resultUrls: urls,
                errorMessage: nil, costCredits: nil, completedAt: nil)
            await finalizeSuccess(
                job: job, placeholders: placeholders, editor: editor,
                mutationScope: authorization.projectMutationScope,
                batchItem: authorization.batchItem,
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
        case .google, .marble, .mirelo: return .inline
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
                batchItem: authorization.batchItem,
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
        batchItem: GenerationBatchAuthorization?,
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
                if batchItem != nil, FileManager.default.fileExists(atPath: placeholder.url.path) {
                    throw GenerationRequestError.storage("An unverified batch output already occupies this destination. Preserve it for reconciliation.")
                }
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
            do {
                if let batchItem { try await GenerationBatchOutput.record(asset: placeholder, authorization: batchItem, editor: editor) }
            } catch {
                placeholder.generationStatus = .failed(error.localizedDescription)
                continue
            }
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
        batchItem: GenerationBatchAuthorization?,
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
                    mutationScope: mutationScope,
                    batchItem: batchItem
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
                    if batchItem != nil, FileManager.default.fileExists(atPath: placeholder.url.path) {
                        throw GenerationRequestError.storage("An unverified batch output already occupies this destination. Preserve it for reconciliation.")
                    }
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
                do {
                    if let batchItem { try await GenerationBatchOutput.record(asset: placeholder, authorization: batchItem, editor: editor) }
                } catch {
                    placeholder.generationStatus = .failed(error.localizedDescription)
                    continue
                }
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

    private func runMireloJob(
        endpoint: String,
        params: AudioGenerationParams,
        genInput: GenerationInput,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        authorization: GenerationAuthorization,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let placeholder = placeholders.first, placeholders.count == 1 else {
            return failBeforeSubmission(
                placeholders,
                "Mirelo's generic audio route produces one output per request.",
                authorization: authorization,
                editor: editor,
                onFailure: onFailure
            )
        }
        guard let apiKey = mireloAPIKeyProvider(), !apiKey.isEmpty else {
            return failBeforeSubmission(
                placeholders,
                "Add a Mirelo API key in Settings → Providers and wait for connection verification.",
                authorization: authorization,
                editor: editor,
                onFailure: onFailure
            )
        }
        guard let model = MireloCapabilityCatalog.shared.model(id: endpoint),
              let durationSeconds = params.durationSeconds,
              durationSeconds > 0,
              durationSeconds <= Int.max / 1_000 else {
            return failBeforeSubmission(
                placeholders,
                "Refresh Mirelo Providers and choose an executable SFX model with a valid duration.",
                authorization: authorization,
                editor: editor,
                onFailure: onFailure
            )
        }
        guard let projectKey = editor.projectId,
              let workingRoot = editor.workingRoot,
              let workingCopyKey = editor.openWorkingCopyKey,
              let transactionID = authorization.transactionId,
              UUID(uuidString: transactionID) != nil,
              let mutationScope = authorization.projectMutationScope else {
            return failBeforeSubmission(
                placeholders,
                "Save the project before running Mirelo audio.",
                authorization: authorization,
                editor: editor,
                onFailure: onFailure
            )
        }

        let sourceURL = params.videoURL.map { URL(fileURLWithPath: $0) }
        guard let operation = Self.mireloGenericOperation(
            model: model,
            hasVideoSource: sourceURL != nil
        ) else {
            return failBeforeSubmission(
                placeholders,
                "Mirelo model '\(model.id)' does not support this generic audio input.",
                authorization: authorization,
                editor: editor,
                onFailure: onFailure
            )
        }
        let durationMS = durationSeconds * 1_000
        do {
            try MireloRequestBuilder.validate(
                operation: operation,
                model: model,
                durationMS: durationMS,
                appendDurationMS: nil,
                regionStartMS: nil,
                regionEndMS: nil,
                numVariants: 1,
                prompt: params.prompt,
                loop: false,
                preserveSpeech: false
            )
            guard model.formats.contains("wav") else {
                throw GenerationRequestError.optionsInvalid(
                    "Mirelo model '\(model.id)' does not offer WAV output."
                )
            }
            try mutationScope.requireCurrent(editor: editor)
        } catch {
            return failBeforeSubmission(
                placeholders,
                error.localizedDescription,
                authorization: authorization,
                editor: editor,
                onFailure: onFailure
            )
        }

        let client = mireloClientProvider(apiKey)
        let store: MireloExecutionStore
        do {
            store = try mireloStoreProvider()
        } catch {
            return failBeforeSubmission(
                placeholders,
                error.localizedDescription,
                authorization: authorization,
                editor: editor,
                onFailure: onFailure
            )
        }
        var executionWasApproved = false
        do {
            let sourceReceipts: [MireloSourceReceipt]
            let uploadedID: String?
            if let sourceURL {
                guard let snapshot = authorization.referenceSnapshot,
                      snapshot.urls.count == 1,
                      snapshot.urls[0].standardizedFileURL == sourceURL.standardizedFileURL,
                      let source = snapshot.sources.first,
                      let receipt = snapshot.receipts.first,
                      source.type == ClipType.video.rawValue else {
                    throw GenerationRequestError.gate(
                        "The Mirelo video source no longer matches the approved project snapshot."
                    )
                }
                try await snapshot.requireUnchanged()
                try mutationScope.requireCurrent(editor: editor)
                let ticket = try await client.createAsset(for: sourceURL)
                try mutationScope.requireCurrent(editor: editor)
                try await client.upload(sourceURL, ticket: ticket)
                try mutationScope.requireCurrent(editor: editor)
                uploadedID = ticket.id
                sourceReceipts = [MireloSourceReceipt(
                    mediaAssetID: source.assetID,
                    projectPath: try Self.mireloProjectPath(source.url, root: workingRoot),
                    sha256: receipt.sourceSHA256,
                    type: .video
                )]
            } else {
                uploadedID = nil
                sourceReceipts = []
            }

            let body: Data
            if let uploadedID {
                body = try MireloRequestBuilder.videoToSFX(
                    model: model.id,
                    assetID: uploadedID,
                    prompt: params.prompt.isEmpty ? nil : params.prompt,
                    durationMS: durationMS,
                    startOffsetMS: 0,
                    numVariants: 1,
                    preserveSpeech: false,
                    outputFormat: "wav"
                )
            } else {
                body = try MireloRequestBuilder.textToSFX(
                    model: model.id,
                    prompt: params.prompt,
                    durationMS: durationMS,
                    numVariants: 1,
                    loop: false,
                    outputFormat: "wav"
                )
            }
            let intent = try JSONSerialization.data(withJSONObject: [
                "operation": operation.rawValue,
                "model": ModelCatalog.deriveLogicalId(genInput.model),
                "prompt": params.prompt,
                "durationMs": durationMS,
                "numVariants": 1,
                "outputFormat": "wav",
                "sourceMediaIds": sourceReceipts.map(\.mediaAssetID),
            ], options: [.sortedKeys])
            let preflight = try await client.preflight(
                operation: operation,
                body: body,
                durationMS: durationMS
            )
            try mutationScope.requireCurrent(editor: editor)
            try Self.validateMireloFunding(
                preflight,
                account: MireloCapabilityCatalog.shared.account
            )
            let catalogCredits = model.creditsPerSecond > 0
                ? Int((model.creditsPerSecond * Double(durationSeconds)).rounded(.up))
                : nil
            guard catalogCredits == preflight.credits else {
                throw GenerationRequestError.gate(
                    "Mirelo's current preflight is \(preflight.credits) credits, not the \(catalogCredits.map(String.init) ?? "unpriced") credits shown for this model. Refresh Providers and review the request again; no provider job was submitted."
                )
            }
            let prepared = try await MireloExecutionCoordinator.shared.prepare(
                store: store,
                projectKey: projectKey,
                logicalJobID: transactionID,
                operation: operation,
                intentBody: intent,
                requestBody: body,
                sources: sourceReceipts,
                preflight: preflight
            )
            try mutationScope.requireCurrent(editor: editor)
            _ = try await MireloExecutionCoordinator.shared.approve(
                store: store,
                record: prepared,
                spendTransactionID: transactionID
            )
            executionWasApproved = true
            try mutationScope.requireCurrent(editor: editor)
            placeholder.mireloExecutionTransactionId = transactionID
            placeholder.mireloResumeAvailable = false
            editor.persistMediaAsset(placeholder)
            await mireloBeforeFirstExecute?()
            try Task.checkCancellation()
            var outcome = try await MireloExecutionCoordinator.shared.execute(
                store: store,
                projectKey: projectKey,
                logicalJobID: transactionID,
                client: client,
                onAccepted: { accepted in
                    try mutationScope.requireCurrent(editor: editor)
                    try self.recordMireloSubmittedIfNeeded(
                        accepted,
                        authorization: authorization,
                        editor: editor
                    )
                }
            )
            try mutationScope.requireCurrent(editor: editor)
            _ = try await finalizeNativeMireloOutcome(
                &outcome,
                store: store,
                client: client,
                asset: placeholder,
                editor: editor,
                workingRoot: workingRoot,
                workingCopyKey: workingCopyKey,
                mutationScope: mutationScope
            )
            try mutationScope.requireCurrent(editor: editor)
            placeholder.mireloResumeAvailable = false
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
            if error is CancellationError, executionWasApproved {
                scheduleMireloSettlementReconciliation(
                    asset: placeholder,
                    editor: editor,
                    store: store,
                    projectKey: projectKey,
                    transactionID: transactionID,
                    mutationScope: mutationScope,
                    onFailure: onFailure
                )
                return
            }
            do {
                try mutationScope.requireCurrent(editor: editor)
            } catch {
                onFailure?()
                return
            }
            let current = try? store.load(
                projectKey: projectKey,
                logicalJobID: transactionID
            )
            if let current, current.providerJobID != nil {
                try? recordMireloSubmittedIfNeeded(
                    current,
                    authorization: authorization,
                    editor: editor
                )
            }
            if !executionWasApproved {
                placeholder.mireloResumeAvailable = false
                failBeforeSubmission(
                    placeholders,
                    error.localizedDescription,
                    authorization: authorization,
                    editor: editor,
                    onFailure: onFailure
                )
            } else if let current,
                      current.state == .failed,
                      current.providerJobID == nil {
                do {
                    try releaseNativeMireloReservationIfRejected(
                        current,
                        asset: placeholder,
                        editor: editor
                    )
                    placeholder.mireloResumeAvailable = false
                    failJob(
                        placeholders,
                        current.lastError ?? error.localizedDescription,
                        onFailure
                    )
                } catch {
                    placeholder.mireloResumeAvailable = false
                    failJob(placeholders, error.localizedDescription, onFailure)
                }
            } else {
                placeholder.mireloResumeAvailable = current.map(Self.mireloCanResume) ?? false
                failJob(placeholders, error.localizedDescription, onFailure)
            }
        }
    }

    typealias NativeMireloDownload = @Sendable (MireloResultDescriptor) async throws -> URL

    func resumeMireloGeneration(asset: MediaAsset, editor: EditorViewModel) {
        guard isMireloResumeActionAvailable(for: asset),
              let workingRoot = editor.workingRoot,
              let resumeScope = try? GenerationProjectMutationScope(
                projectHome: workingRoot,
                editor: editor
              ) else { return }
        asset.mireloResumeAvailable = false
        asset.generationStatus = .generating
        let task = Task { @MainActor [weak self, weak editor, weak asset] in
            guard let self, let editor, let asset else { return }
            defer { self.generationTasks.removeValue(forKey: asset.id) }
            do {
                guard let apiKey = self.mireloAPIKeyProvider(), !apiKey.isEmpty else {
                    throw GenerationRequestError.gate(
                        "Add a Mirelo API key in Settings → Providers and wait for connection verification."
                    )
                }
                try await self.performNativeMireloResume(
                    asset: asset,
                    editor: editor,
                    store: try self.mireloStoreProvider(),
                    client: self.mireloClientProvider(apiKey),
                    approveCreditChange: { previous, current in
                        Self.confirmMireloCreditChange(previous: previous, current: current)
                    }
                )
                AppNotifications.generationComplete(
                    assetId: asset.id,
                    projectURL: editor.projectURL,
                    assetName: asset.name,
                    assetType: asset.type,
                    count: 1
                )
            } catch {
                do {
                    try resumeScope.requireCurrent(editor: editor)
                } catch {
                    return
                }
                guard editor.mediaAssets.contains(where: { $0 === asset }) else { return }
                if error is CancellationError,
                   let projectKey = editor.projectId,
                   let transactionID = asset.mireloExecutionTransactionId
                        ?? asset.generationInput?.spendTransactionId,
                   let store = try? self.mireloStoreProvider() {
                    self.scheduleMireloSettlementReconciliation(
                        asset: asset,
                        editor: editor,
                        store: store,
                        projectKey: projectKey,
                        transactionID: transactionID,
                        mutationScope: resumeScope
                    )
                    return
                }
                asset.generationStatus = .failed(error.localizedDescription)
                if let projectKey = editor.projectId,
                   let transactionID = asset.mireloExecutionTransactionId
                        ?? asset.generationInput?.spendTransactionId,
                   let store = try? self.mireloStoreProvider() {
                    do {
                        guard let record = try store.load(
                            projectKey: projectKey,
                            logicalJobID: transactionID
                        ) else {
                            throw GenerationRequestError.storage(
                                "The saved Mirelo recovery record is missing."
                            )
                        }
                        try self.releaseNativeMireloReservationIfRejected(
                            record,
                            asset: asset,
                            editor: editor
                        )
                        asset.mireloResumeAvailable = Self.mireloCanResume(record)
                        if record.state == .failed {
                            asset.generationStatus = .failed(
                                record.lastError ?? error.localizedDescription
                            )
                        }
                    } catch {
                        asset.mireloResumeAvailable = false
                        asset.generationStatus = .failed(
                            "Mirelo recovery data could not be reconciled: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
        generationTasks[asset.id] = task
    }

    func isMireloResumeActionAvailable(for asset: MediaAsset) -> Bool {
        guard let transactionID = asset.mireloExecutionTransactionId
            ?? asset.generationInput?.spendTransactionId else { return false }
        return asset.mireloResumeAvailable
            && !asset.isGenerating
            && generationTasks[asset.id] == nil
            && !mireloReconciliationTasks.values.contains {
                $0.assetID == asset.id
                    && $0.transactionID == transactionID
            }
    }

    func performNativeMireloResume(
        asset: MediaAsset,
        editor: EditorViewModel,
        store: MireloExecutionStore,
        client: MireloClient,
        approveCreditChange: @MainActor (Int, Int) -> Bool,
        download: NativeMireloDownload? = nil
    ) async throws {
        guard let projectKey = editor.projectId,
              let workingRoot = editor.workingRoot,
              let workingCopyKey = editor.openWorkingCopyKey,
              let transactionID = asset.mireloExecutionTransactionId
                ?? asset.generationInput?.spendTransactionId else {
            throw GenerationRequestError.storage(
                "This media item has no saved Mirelo recovery identity."
            )
        }
        let mutationScope = try GenerationProjectMutationScope(
            projectHome: workingRoot,
            editor: editor
        )
        guard var record = try store.load(
            projectKey: projectKey,
            logicalJobID: transactionID
        ), record.spendTransactionID == transactionID,
           Self.mireloCanResume(record),
           record.operation == .textToSFX || record.operation == .videoToSFX else {
            throw GenerationRequestError.gate(
                "This Mirelo generation has no resumable native job. Start a new variation only if you intend a new paid request."
            )
        }
        let authorization = try nativeMireloAuthorization(
            record: record,
            asset: asset,
            editor: editor,
            mutationScope: mutationScope
        )

        if record.state == .prepared, record.providerJobID == nil {
            let currentPreflight: MireloPreflight
            let currentAccount: MireloAccount
            async let quoted = client.preflight(
                operation: record.operation,
                body: record.requestBody
            )
            async let account = client.account()
            (currentPreflight, currentAccount) = try await (quoted, account)
            try mutationScope.requireCurrent(editor: editor)
            try Self.validateMireloFunding(currentPreflight, account: currentAccount)
            let changed = currentPreflight.credits != record.preflight.credits
            if changed {
                guard approveCreditChange(
                    record.preflight.credits,
                    currentPreflight.credits
                ) else {
                    throw GenerationRequestError.gate(
                        "The changed Mirelo cost was not approved. No provider request was submitted."
                    )
                }
            }
            try mutationScope.requireCurrent(editor: editor)
            record = try store.refreshApprovedPreflight(
                record,
                with: currentPreflight,
                creditChangeApproved: changed
            )
        }

        try mutationScope.requireCurrent(editor: editor)
        asset.mireloResumeAvailable = false
        asset.generationStatus = .generating
        editor.persistMediaAsset(asset)
        var outcome = try await MireloExecutionCoordinator.shared.execute(
            store: store,
            projectKey: projectKey,
            logicalJobID: transactionID,
            client: client,
            onAccepted: { accepted in
                try mutationScope.requireCurrent(editor: editor)
                try self.recordMireloSubmittedIfNeeded(
                    accepted,
                    authorization: authorization,
                    editor: editor
                )
            }
        )
        try mutationScope.requireCurrent(editor: editor)
        _ = try await finalizeNativeMireloOutcome(
            &outcome,
            store: store,
            client: client,
            asset: asset,
            editor: editor,
            workingRoot: workingRoot,
            workingCopyKey: workingCopyKey,
            mutationScope: mutationScope,
            download: download
        )
        try mutationScope.requireCurrent(editor: editor)
        asset.mireloResumeAvailable = false
        markCharged(authorization: authorization, editor: editor)
    }

    func restoreMireloRecoveryState(
        asset: MediaAsset,
        editor: EditorViewModel,
        store suppliedStore: MireloExecutionStore? = nil
    ) {
        guard Self.isMireloRecoveryAsset(asset, editor: editor),
              let transactionID = asset.mireloExecutionTransactionId
                ?? asset.generationInput?.spendTransactionId,
              let projectKey = editor.projectId,
              let workingRoot = editor.workingRoot else { return }
        do {
            let store: MireloExecutionStore
            if let suppliedStore {
                store = suppliedStore
            } else {
                store = try mireloStoreProvider()
            }
            guard let record = try store.load(
                projectKey: projectKey,
                logicalJobID: transactionID
            ), record.spendTransactionID == transactionID,
               record.operation == .textToSFX || record.operation == .videoToSFX else { return }
            let scope = try GenerationProjectMutationScope(
                projectHome: workingRoot,
                editor: editor
            )
            if record.state == .failed {
                if record.providerJobID == nil {
                    try releaseNativeMireloReservationIfRejected(
                        record,
                        asset: asset,
                        editor: editor
                    )
                }
                asset.mireloResumeAvailable = false
                asset.generationStatus = .failed(
                    record.lastError ?? "The Mirelo job failed."
                )
                return
            }
            let authorization = try nativeMireloAuthorization(
                record: record,
                asset: asset,
                editor: editor,
                mutationScope: scope
            )
            if record.providerJobID != nil {
                try recordMireloSubmittedIfNeeded(
                    record,
                    authorization: authorization,
                    editor: editor
                )
            }
            if record.state == .completed,
               try nativeMireloArtifactIsInstalled(
                record,
                asset: asset,
                workingRoot: workingRoot
               ) {
                asset.mireloResumeAvailable = false
                asset.generationStatus = .none
                return
            }
            guard Self.mireloCanResume(record) else { return }
            asset.mireloResumeAvailable = true
            asset.generationStatus = .failed(
                record.lastError ?? Self.mireloResumeMessage(record)
            )
        } catch {
            asset.mireloResumeAvailable = false
            asset.generationStatus = .failed(
                "Mirelo recovery data could not be reconciled: \(error.localizedDescription)"
            )
        }
    }

    func reconcileMireloAcceptedSpend(
        editor: EditorViewModel,
        store suppliedStore: MireloExecutionStore? = nil
    ) throws {
        guard let projectKey = editor.projectId,
              let workingRoot = editor.workingRoot else { return }
        let projectHasMireloEvidence = editor.generationLog.spendEvents.contains {
            $0.provider == .mirelo
        } || editor.mediaManifest.entries.contains {
            $0.mireloExecutionTransactionId != nil
                || $0.generationInput?.model.hasPrefix("mirelo/") == true
        }
        let store: MireloExecutionStore
        do {
            if let suppliedStore {
                store = suppliedStore
            } else {
                store = try mireloStoreProvider()
            }
        } catch {
            if !projectHasMireloEvidence { return }
            throw error
        }
        let records: [MireloExecutionRecord]
        do {
            records = try store.all(projectKey: projectKey).filter {
                $0.approvedAt != nil && $0.spendTransactionID != nil
            }
        } catch {
            if !projectHasMireloEvidence { return }
            throw error
        }
        let grouped = Dictionary(grouping: records) { record in
            record.spendTransactionID ?? ""
        }
        let scope = try GenerationProjectMutationScope(
            projectHome: workingRoot,
            editor: editor
        )
        var submissions: [(MireloExecutionRecord, GenerationAuthorization)] = []
        var releases: [(MireloExecutionRecord, GenerationAuthorization)] = []
        var issues: [String] = []
        for record in records {
            guard let transactionID = record.spendTransactionID else { continue }
            let hasSubmissionRisk = record.providerJobID != nil
                || record.state == .submitting
                || record.state == .acceptanceUnknown
            let events = editor.generationLog.spendEvents.filter {
                $0.transactionId == transactionID
            }
            guard !events.isEmpty else {
                if hasSubmissionRisk {
                    issues.append(
                        "Authority \(record.logicalJobID) has provider acceptance evidence but no reservation in this project copy."
                    )
                }
                continue
            }
            guard grouped[transactionID]?.count == 1 else {
                issues.append(
                    "Multiple Mirelo authority records claim reservation \(transactionID)."
                )
                continue
            }
            guard let first = events.first,
                  first.kind == .reserved,
                  first.provider == .mirelo,
                  first.transport == .api,
                  let authorityModel = Self.mireloAuthorityModelID(record),
                  first.model == authorityModel,
                  first.endpoint == record.operation.createPath
                    || first.endpoint == String(authorityModel.dropFirst("mirelo/".count)),
                  events.allSatisfy({
                    $0.model == first.model
                        && $0.provider == first.provider
                        && $0.transport == first.transport
                        && $0.endpoint == first.endpoint
                  }) else {
                issues.append(
                    "Authority \(record.logicalJobID) conflicts with reservation \(transactionID)."
                )
                continue
            }
            let authorization = Self.mireloReconciliationAuthorization(
                first: first,
                scope: scope
            )
            if let providerJobID = record.providerJobID {
                let submitted = events.filter { $0.kind == .submitted }
                if !submitted.isEmpty {
                    guard submitted.count == 1,
                          submitted[0].providerRequestId == providerJobID,
                          events.last?.kind != .released else {
                        issues.append(
                            "Authority \(record.logicalJobID) names a different provider job than reservation \(transactionID)."
                        )
                        continue
                    }
                    continue
                }
                guard events.last?.kind == .reserved else {
                    issues.append(
                        "Authority \(record.logicalJobID) cannot attach its provider job to reservation \(transactionID)."
                    )
                    continue
                }
                submissions.append((record, authorization))
                continue
            }
            guard !events.contains(where: { $0.kind == .submitted }) else {
                issues.append(
                    "Authority \(record.logicalJobID) lost the provider job identity recorded by reservation \(transactionID)."
                )
                continue
            }
            if record.state == .failed {
                if events.last?.kind == .reserved {
                    releases.append((record, authorization))
                } else if events.last?.kind != .released {
                    issues.append(
                        "Rejected authority \(record.logicalJobID) conflicts with reservation \(transactionID)."
                    )
                }
            } else if record.state == .submitting || record.state == .acceptanceUnknown {
                issues.append(
                    "Authority \(record.logicalJobID) has unresolved Mirelo acceptance for reservation \(transactionID)."
                )
            }
        }
        for (record, authorization) in submissions {
            do {
                try scope.requireCurrent(editor: editor)
                try recordMireloSubmittedIfNeeded(
                    record,
                    authorization: authorization,
                    editor: editor
                )
            } catch {
                issues.append(
                    "Authority \(record.logicalJobID) could not persist its accepted provider job: \(error.localizedDescription)"
                )
            }
        }
        for (record, authorization) in releases {
            do {
                try scope.requireCurrent(editor: editor)
                try editor.releaseUnsubmittedSpendReservation(
                    authorization: authorization,
                    preserveMireloExecutionIdentity: true,
                    note: record.lastError
                )
            } catch {
                issues.append(
                    "Rejected authority \(record.logicalJobID) could not release its reservation: \(error.localizedDescription)"
                )
            }
        }
        reportMireloSpendRecovery(issues, editor: editor)
    }

    private static func mireloAuthorityModelID(
        _ record: MireloExecutionRecord
    ) -> String? {
        if record.operation == .audioToMIDI {
            return "mirelo/audio-to-midi/v1.0"
        }
        guard let root = try? JSONSerialization.jsonObject(
            with: record.requestBody
        ) as? [String: Any],
        let model = root["model"] as? String,
        !model.isEmpty else { return nil }
        return model.hasPrefix("mirelo/") ? model : "mirelo/\(model)"
    }

    private static func mireloReconciliationAuthorization(
        first: GenerationSpendEvent,
        scope: GenerationProjectMutationScope
    ) -> GenerationAuthorization {
        GenerationAuthorization(
            transactionId: first.transactionId,
            target: ResolvedGenerationTarget(
                modelId: first.model,
                provider: .mirelo,
                endpoint: first.endpoint,
                binding: ProviderBinding(
                    provider: .mirelo,
                    transport: .api,
                    kind: .generation,
                    providerRef: first.endpoint,
                    billing: .perCall
                )
            ),
            estimate: first.money,
            projectMutationScope: scope
        )
    }

    private func reportMireloSpendRecovery(
        _ issues: [String],
        editor: EditorViewModel
    ) {
        let fingerprint = issues.sorted().joined(separator: "\n")
        guard !fingerprint.isEmpty else {
            editor.mireloSpendRecoveryMessage = nil
            editor.mireloSpendRecoveryNoticeFingerprint = nil
            return
        }
        for issue in issues {
            Log.generation.error("Mirelo spend recovery: \(issue)")
        }
        let count = issues.count
        let message = "Budget stop: \(count) Mirelo "
            + "\(count == 1 ? "job has" : "jobs have") spend evidence that this project copy "
            + "cannot account for. Open the project copy that created the job or restore its "
            + "matching Recovery copy before generating again."
        editor.mireloSpendRecoveryMessage = message
        guard editor.mireloSpendRecoveryNoticeFingerprint != fingerprint else { return }
        editor.mireloSpendRecoveryNoticeFingerprint = fingerprint
        editor.mediaPanelToast = MediaPanelToast(message: message)
    }

    private static func isMireloRecoveryAsset(
        _ asset: MediaAsset,
        editor: EditorViewModel
    ) -> Bool {
        if asset.generationInput?.model.hasPrefix("mirelo/") == true {
            return true
        }
        guard let transactionID = asset.mireloExecutionTransactionId
            ?? asset.generationInput?.spendTransactionId else { return false }
        return editor.generationLog.spendEvents.contains {
            $0.transactionId == transactionID && $0.provider == .mirelo
        }
    }

    private func scheduleMireloSettlementReconciliation(
        asset: MediaAsset,
        editor: EditorViewModel,
        store: MireloExecutionStore,
        projectKey: String,
        transactionID: String,
        mutationScope: GenerationProjectMutationScope,
        onFailure: (@MainActor () -> Void)? = nil
    ) {
        let operationKey = projectKey + "/" + transactionID
        if let existing = mireloReconciliationTasks[operationKey] {
            existing.callbacks.add(onFailure)
            return
        }
        asset.mireloResumeAvailable = false
        asset.generationStatus = .generating
        let assetID = asset.id
        let callbacks = MireloSettlementCallbacks()
        callbacks.add(onFailure)
        let task = Task { @MainActor [weak self, weak editor] in
            defer {
                self?.mireloReconciliationTasks.removeValue(forKey: operationKey)
                callbacks.resolveFailure()
            }
            let settled: Result<MireloExecutionRecord?, Error>
            do {
                settled = .success(try await MireloExecutionCoordinator.shared.awaitSettlement(
                    store: store,
                    projectKey: projectKey,
                    logicalJobID: transactionID
                ))
            } catch {
                settled = .failure(error)
            }
            do {
                guard var record = try settled.get(),
                      record.projectKey == projectKey,
                      record.logicalJobID == transactionID,
                      record.spendTransactionID == transactionID else {
                    throw GenerationRequestError.storage(
                        "The Mirelo recovery authority changed while cancellation settled."
                    )
                }
                if record.state == .prepared, record.providerJobID == nil {
                    record = try store.update(record) {
                        $0.state = .failed
                        $0.lastError = "Mirelo submission was cancelled before any provider request was sent."
                    }
                }
                guard let self, let editor else { return }
                try mutationScope.requireCurrent(editor: editor)
                guard editor.projectId == projectKey else {
                    throw GenerationRequestError.storage(
                        "The active project changed while Mirelo cancellation settled."
                    )
                }
                try self.reconcileMireloAcceptedSpend(
                    editor: editor,
                    store: store
                )
                let currentAsset = editor.mediaAssets.first { current in
                    let currentTransactionID = current.mireloExecutionTransactionId
                        ?? current.generationInput?.spendTransactionId
                    return current.id == assetID
                        && currentTransactionID == transactionID
                }
                if let currentAsset {
                    self.restoreMireloRecoveryState(
                        asset: currentAsset,
                        editor: editor,
                        store: store
                    )
                }
            } catch {
                guard let editor else { return }
                do {
                    try mutationScope.requireCurrent(editor: editor)
                } catch {
                    return
                }
                guard editor.projectId == projectKey,
                      let currentAsset = editor.mediaAssets.first(where: { current in
                          let currentTransactionID = current.mireloExecutionTransactionId
                              ?? current.generationInput?.spendTransactionId
                          return current.id == assetID
                              && currentTransactionID == transactionID
                      }) else { return }
                currentAsset.mireloResumeAvailable = false
                currentAsset.generationStatus = .failed(
                    "Mirelo recovery data could not be reconciled: \(error.localizedDescription)"
                )
            }
        }
        mireloReconciliationTasks[operationKey] = MireloReconciliationOperation(
            assetID: assetID,
            transactionID: transactionID,
            task: task,
            callbacks: callbacks
        )
    }

    private func finalizeNativeMireloOutcome(
        _ outcome: inout MireloExecutionOutcome,
        store: MireloExecutionStore,
        client: MireloClient,
        asset: MediaAsset,
        editor: EditorViewModel,
        workingRoot: URL,
        workingCopyKey: String,
        mutationScope: GenerationProjectMutationScope,
        download: NativeMireloDownload? = nil
    ) async throws -> MireloExecutionRecord {
        let persistedArtifact = outcome.record.state == .completed
            ? outcome.record.artifacts.first(where: {
                $0.kind == .audio && $0.mediaAssetID == asset.id
            })
            : nil
        if outcome.record.state == .completed,
           try nativeMireloArtifactIsInstalled(
            outcome.record,
            asset: asset,
            workingRoot: workingRoot
           ), let artifact = persistedArtifact {
            try mutationScope.requireCurrent(editor: editor)
            asset.url = workingRoot.appendingPathComponent(artifact.projectPath)
            asset.pendingDownloadURL = nil
            asset.generationStatus = .none
            editor.persistMediaAsset(asset)
            return outcome.record
        }

        var descriptor = try Self.singleMireloAudioDescriptor(outcome)
        let staged: URL
        do {
            if let download {
                staged = try await download(descriptor)
            } else {
                staged = try await Self.downloadMireloAudio(descriptor)
            }
        } catch RemoteMediaPolicy.PolicyError.httpStatus(let status)
            where [403, 404, 410].contains(status) {
            outcome = try await MireloExecutionCoordinator.shared.refreshResult(
                store: store,
                record: outcome.record,
                client: client
            )
            try mutationScope.requireCurrent(editor: editor)
            descriptor = try Self.singleMireloAudioDescriptor(outcome)
            do {
                if let download {
                    staged = try await download(descriptor)
                } else {
                    staged = try await Self.downloadMireloAudio(descriptor)
                }
            } catch RemoteMediaPolicy.PolicyError.httpStatus(let refreshedStatus)
                where [403, 404, 410].contains(refreshedStatus) {
                throw GenerationRequestError.gate(
                    "Mirelo refreshed the result link, but it is already unavailable. Use Resume Mirelo Job later; no new request was submitted."
                )
            }
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        try Task.checkCancellation()
        try await RemoteMediaPayloadValidator.validate(staged, expectedType: .audio)
        try Task.checkCancellation()
        try mutationScope.requireCurrent(editor: editor)
        let returnedExtension = URL(fileURLWithPath: descriptor.filename).pathExtension
        let extensionValue = returnedExtension.isEmpty ? "wav" : returnedExtension
        let destination = persistedArtifact.map {
            workingRoot.appendingPathComponent($0.projectPath)
        } ?? asset.url.deletingPathExtension().appendingPathExtension(extensionValue)
        let digest = try FileDigest.sha256(of: staged)
        if let persistedArtifact {
            guard persistedArtifact.sha256 == digest,
                  try Self.mireloProjectPath(destination, root: workingRoot)
                    == persistedArtifact.projectPath else {
                throw GenerationRequestError.storage(
                    "The restored Mirelo result does not match its completed project artifact."
                )
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try FileDigest.sha256(of: destination) == digest else {
                throw GenerationRequestError.storage(
                    "The Mirelo destination already contains different bytes. Restore or reconcile this generation before resuming."
                )
            }
        } else {
            try ProjectWorkingCopy.markDirty(key: workingCopyKey)
            let partial = destination.deletingLastPathComponent()
                .appendingPathComponent(".mirelo-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: partial) }
            try FileManager.default.copyItem(at: staged, to: partial)
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        try Task.checkCancellation()
        try mutationScope.requireCurrent(editor: editor)
        asset.url = destination
        asset.pendingDownloadURL = nil
        asset.generationStatus = .none
        editor.persistMediaAsset(asset)
        if !editor.generationLog.entries.contains(where: {
            $0.spendTransactionId == asset.generationInput?.spendTransactionId
        }) {
            editor.appendGenerationLog(for: asset)
        }
        try await editor.finalizeImportedAsset(asset, mutationScope: mutationScope)
        let artifact = MireloArtifact(
            kind: .audio,
            projectPath: try Self.mireloProjectPath(destination, root: workingRoot),
            sha256: digest,
            mediaAssetID: asset.id,
            sourceURLExpiresAt: descriptor.sourceURLExpiresAt
        )
        if let persistedArtifact {
            guard artifact.kind == persistedArtifact.kind,
                  artifact.projectPath == persistedArtifact.projectPath,
                  artifact.sha256 == persistedArtifact.sha256,
                  artifact.mediaAssetID == persistedArtifact.mediaAssetID else {
                throw GenerationRequestError.storage(
                    "The restored Mirelo artifact does not match its execution record."
                )
            }
            return outcome.record
        }
        return try await MireloExecutionCoordinator.shared.complete(
            store: store,
            record: outcome.record,
            artifacts: [artifact]
        )
    }

    private func nativeMireloAuthorization(
        record: MireloExecutionRecord,
        asset: MediaAsset,
        editor: EditorViewModel,
        mutationScope: GenerationProjectMutationScope
    ) throws -> GenerationAuthorization {
        guard let transactionID = asset.mireloExecutionTransactionId
                ?? asset.generationInput?.spendTransactionId,
              transactionID == record.spendTransactionID else {
            throw GenerationRequestError.storage(
                "The media item does not match its Mirelo spend transaction."
            )
        }
        _ = try GenerationBudgetGuard.verifiedSpend(
            log: editor.generationLog,
            generatedAssets: editor.mediaAssets,
            requireCompleteMoney: false
        )
        let events = editor.generationLog.spendEvents.filter {
            $0.transactionId == transactionID
        }
        guard let first = events.first,
              let last = events.last,
              first.kind == .reserved,
              first.model == asset.generationInput?.model,
              first.provider == .mirelo,
              first.transport == .api,
              last.kind != .released,
              events.allSatisfy({
                  $0.model == first.model
                      && $0.provider == first.provider
                      && $0.transport == first.transport
                      && $0.endpoint == first.endpoint
              }),
              last.kind != .submitted
                || (record.providerJobID != nil
                    && last.providerRequestId == record.providerJobID) else {
            throw GenerationRequestError.gate(
                "The saved Mirelo job has no matching active project spend record. Reconcile the project copy before resuming it."
            )
        }
        try mutationScope.requireCurrent(editor: editor)
        return GenerationAuthorization(
            transactionId: transactionID,
            target: ResolvedGenerationTarget(
                modelId: first.model,
                provider: .mirelo,
                endpoint: first.endpoint,
                binding: ProviderBinding(
                    provider: .mirelo,
                    transport: .api,
                    kind: .generation,
                    providerRef: first.endpoint,
                    billing: .perCall
                )
            ),
            estimate: first.money,
            projectMutationScope: mutationScope
        )
    }

    private func recordMireloSubmittedIfNeeded(
        _ record: MireloExecutionRecord,
        authorization: GenerationAuthorization,
        editor: EditorViewModel
    ) throws {
        guard let providerJobID = record.providerJobID,
              let transactionID = authorization.transactionId else { return }
        if let submitted = editor.generationLog.spendEvents.first(where: {
            $0.transactionId == transactionID && $0.kind == .submitted
        }) {
            guard submitted.providerRequestId == providerJobID else {
                throw GenerationRequestError.storage(
                    "The Mirelo provider job does not match the project spend record."
                )
            }
            return
        }
        try authorization.projectMutationScope?.requireCurrent(editor: editor)
        try editor.recordSpendEvent(
            authorization: authorization,
            kind: .submitted,
            providerRequestId: providerJobID,
            providerRequestResumable: true,
            money: authorization.estimate,
            note: "Mirelo preflight: \(record.preflight.credits) credits. Monetary conversion is not published."
        )
    }

    private func releaseNativeMireloReservationIfRejected(
        _ record: MireloExecutionRecord,
        asset: MediaAsset,
        editor: EditorViewModel
    ) throws {
        guard record.state == .failed,
              record.providerJobID == nil,
              let workingRoot = editor.workingRoot else { return }
        let transactionID = record.spendTransactionID ?? ""
        guard let last = editor.generationLog.spendEvents.last(where: {
            $0.transactionId == transactionID
        }) else {
            throw GenerationRequestError.storage(
                "The rejected Mirelo job has no project spend reservation."
            )
        }
        if last.kind == .released {
            guard asset.mireloExecutionTransactionId == transactionID,
                  asset.generationInput?.spendTransactionId == nil else {
                throw GenerationRequestError.storage(
                    "The released Mirelo reservation is still attached to generated media."
                )
            }
            return
        }
        guard last.kind == .reserved else {
            throw GenerationRequestError.storage(
                "An accepted or unresolved Mirelo job cannot release its reservation."
            )
        }
        let scope = try GenerationProjectMutationScope(
            projectHome: workingRoot,
            editor: editor
        )
        let authorization = try nativeMireloAuthorization(
            record: record,
            asset: asset,
            editor: editor,
            mutationScope: scope
        )
        try editor.releaseRejectedSpendReservation(
            authorization: authorization,
            asset: asset,
            executionTransactionID: transactionID,
            note: record.lastError
        )
    }

    private func nativeMireloArtifactIsInstalled(
        _ record: MireloExecutionRecord,
        asset: MediaAsset,
        workingRoot: URL
    ) throws -> Bool {
        guard let artifact = record.artifacts.first(where: {
            $0.kind == .audio && $0.mediaAssetID == asset.id
        }) else { return false }
        let url = workingRoot.appendingPathComponent(artifact.projectPath)
        return FileManager.default.fileExists(atPath: url.path)
            && (try FileDigest.sha256(of: url)) == artifact.sha256
    }

    private static func mireloCanResume(_ record: MireloExecutionRecord) -> Bool {
        guard record.approvedAt != nil, record.spendTransactionID != nil else { return false }
        switch record.state {
        case .prepared, .submitting, .accepted, .acceptanceUnknown,
             .pollingInterrupted, .providerSucceeded, .completed:
            true
        case .failed:
            false
        }
    }

    private static func mireloResumeMessage(_ record: MireloExecutionRecord) -> String {
        switch record.state {
        case .prepared:
            "Mirelo has not received this approved request. Resume checks current cost and funding before the first submission."
        case .submitting, .acceptanceUnknown:
            "Mirelo acceptance is unresolved. Resume reuses the saved idempotency key; it does not create a variation."
        case .accepted, .pollingInterrupted:
            "Mirelo accepted this job. Resume continues polling the same provider job."
        case .providerSucceeded, .completed:
            "Mirelo completed this job. Resume restores its project-local result."
        case .failed:
            record.lastError ?? "Mirelo reported a terminal failure."
        }
    }

    private static func confirmMireloCreditChange(previous: Int, current: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Approve updated Mirelo cost?"
        alert.informativeText = "The saved request changed from \(previous) to \(current) credits. It has not been submitted to Mirelo."
        alert.addButton(withTitle: "Approve \(current) Credits")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func singleMireloAudioDescriptor(
        _ outcome: MireloExecutionOutcome
    ) throws -> MireloResultDescriptor {
        let descriptors = try MireloResultParser.descriptors(
            operation: outcome.record.operation,
            terminalResponse: outcome.terminalResponse
        )
        guard descriptors.count == 1,
              let descriptor = descriptors.first,
              descriptor.kind == .audio,
              descriptor.remoteURL != nil else {
            throw GenerationRequestError.storage(
                "Mirelo's generic audio route returned an unsupported result set."
            )
        }
        return descriptor
    }

    nonisolated static func mireloGenericOperation(
        model: MireloModel,
        hasVideoSource: Bool
    ) -> MireloOperation? {
        let operation: MireloOperation = hasVideoSource ? .videoToSFX : .textToSFX
        return MireloCatalogDiscovery.supportedOperationIDs(model).contains(operation.rawValue)
            ? operation
            : nil
    }

    private static func downloadMireloAudio(
        _ descriptor: MireloResultDescriptor
    ) async throws -> URL {
        guard let remoteURL = descriptor.remoteURL else {
            throw GenerationRequestError.storage("Mirelo returned no audio result URL.")
        }
        let result = try await RemoteMediaDownloader.download(
            remoteURL,
            maxBytes: 1024 * 1024 * 1024,
            timeout: 120
        )
        return result.temporaryURL
    }

    private static func validateMireloFunding(
        _ preflight: MireloPreflight,
        account: MireloAccount?
    ) throws {
        guard preflight.credits >= 0 else {
            throw GenerationRequestError.gate(
                "Mirelo preflight returned an invalid credit amount. No provider job was submitted."
            )
        }
        if let recovery = preflight.creditRecovery {
            guard recovery.creditsRequired == preflight.credits else {
                throw GenerationRequestError.gate(
                    "Mirelo preflight returned inconsistent funding evidence. No provider job was submitted."
                )
            }
            guard recovery.canFundRequest else {
                throw GenerationRequestError.gate(
                    "Mirelo requires \(recovery.creditsRequired) credits; \(recovery.creditsAvailable) are currently spendable. No provider job was submitted."
                )
            }
        }
        let billingMode = preflight.billingMode ?? account?.billingMode
        guard billingMode == "metered" || billingMode == "unmetered" else {
            throw GenerationRequestError.gate(
                "Mirelo preflight did not identify the account's billing mode. No provider job was submitted."
            )
        }
        guard billingMode != "metered" || preflight.creditRecovery != nil else {
            throw GenerationRequestError.gate(
                "Mirelo preflight omitted the metered account's funding decision. No provider job was submitted."
            )
        }
        guard account == nil || account?.provisioningState == "ready" else {
            throw GenerationRequestError.gate(
                "Mirelo account provisioning is not ready. No provider job was submitted."
            )
        }
    }

    private static func mireloProjectPath(_ url: URL, root: URL) throws -> String {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        guard canonicalURL.path.hasPrefix(prefix) else {
            throw GenerationRequestError.storage(
                "Mirelo sources and results must remain inside the project working copy."
            )
        }
        return String(canonicalURL.path.dropFirst(prefix.count))
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
            if let batchItem = authorization.batchItem {
                try await GenerationBatchOutput.record(asset: placeholder, authorization: batchItem, editor: editor)
            }
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
                resumable: true,
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
                batchItem: authorization.batchItem,
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
        batchItem: GenerationBatchAuthorization?,
        completedAssetIDs: Set<String> = [],
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
            if completedAssetIDs.contains(placeholder.id) { continue }
            guard editor.mediaAssets.contains(where: { $0.id == placeholder.id }) else { continue }
            guard i < urlStrings.count, let remote = URL(string: urlStrings[i]) else {
                placeholder.generationStatus = .failed("No URL for placeholder")
                continue
            }
            if await downloadAndFinalize(
                asset: placeholder,
                remoteURL: remote,
                editor: editor,
                mutationScope: mutationScope,
                batchItem: batchItem
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
