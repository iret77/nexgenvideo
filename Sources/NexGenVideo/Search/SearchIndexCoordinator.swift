import Foundation

/// Per-project indexing queue and search
@MainActor
@Observable
final class SearchIndexCoordinator {
    private(set) var batchTotal = 0
    private(set) var batchCompleted = 0
    private(set) var currentAssetFraction: Double = 0

    var checkingIndex: Bool { !preflightTokens.isEmpty }
    var indexingActive: Bool { batchCompleted < batchTotal || checkingIndex }
    var indexingProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min(1, (Double(batchCompleted) + min(max(currentAssetFraction, 0), 1)) / Double(batchTotal))
    }

    var assetsProvider: () -> [MediaAsset] = { [] }

    private var queue: [String] = []
    @ObservationIgnored private var preflightTasks: [String: Task<Void, Never>] = [:]
    private var preflightTokens: [String: UUID] = [:]
    private(set) var failures: [String: String] = [:]
    private var indexingFailures: [String: String] = [:]
    private var failureURLs: [String: URL] = [:]
    private var forcedRetryIDs: Set<String> = []
    private var visualFailureIDs: Set<String> = []
    private var activeAssetID: String?
    private var queryConfiguration = 0

    struct QueryEncoder: Sendable {
        let spec: VisualEmbedder.Spec
        let encode: @Sendable (String) throws -> [Float]
    }

    enum Availability: Equatable, Sendable {
        case disabled, notInstalled, preparing, downloading(Double), ready, failed(String)
    }

    enum QueryStatus: Equatable, Sendable {
        case ready, indexing, notIndexed, unavailable(Availability), failed(String), cancelled, stale
    }

    struct SearchResult: Sendable {
        let hits: [VisualSearch.Hit]
        let status: QueryStatus
        let unavailableAssetIDs: Set<String>
        let failedAssetIDs: Set<String>
    }

    @ObservationIgnored var momentQueryPublicationBarrier: (@MainActor (UUID, String, URL?, UUID?, SearchResult) async -> Void)?
    @ObservationIgnored var momentQueryTaskObserver: (@MainActor (UUID, String, URL?, UUID?, Bool) -> Void)?

    @ObservationIgnored var queryEncoderOverride: QueryEncoder? {
        didSet {
            queryConfiguration += 1
            loadedIndexes.removeAll()
        }
    }

    var visualAvailability: Availability {
        if queryEncoderOverride != nil { return .ready }
        let loader = VisualModelLoader.shared
        guard loader.enabled else { return .disabled }
        switch loader.state {
        case .unknown, .preparing: return .preparing
        case .notInstalled: return .notInstalled
        case .downloading(let fraction): return .downloading(fraction)
        case .ready: return loader.embedder == nil ? .failed("The visual search model is unavailable.") : .ready
        case .failed(let message): return .failed(message)
        }
    }

    var failedAssetIDs: Set<String> { Set(failures.keys).intersection(assetsProvider().map(\.id)) }

    var canRetryFailed: Bool {
        !failedAssetIDs.isEmpty && VisualModelLoader.shared.enabled
            && VisualModelLoader.shared.isReady && VisualModelLoader.shared.embedder != nil
    }

    func retryFailed() {
        guard canRetryFailed else { return }
        let ids = failedAssetIDs
        forcedRetryIDs.formUnion(ids)
        for id in ids {
            failures[id] = nil
            indexingFailures[id] = nil
            failureURLs[id] = nil
            visualFailureIDs.remove(id)
            loadedIndexes[id] = nil
        }
        for asset in assetsProvider() where ids.contains(asset.id) { schedule(asset) }
    }
    private var worker: Task<Void, Never>?
    /// Bumped whenever `worker` is replaced or cancelled, so a stale worker's
    /// exit path can't clobber the reference to a newer one.
    private var workerGeneration = 0
    private var loadedIndexes: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]

    private static let registry = NSHashTable<SearchIndexCoordinator>.weakObjects()
    private static var live: [SearchIndexCoordinator] { registry.allObjects }

    init() {
        Self.registry.add(self)
    }

    // MARK: - App-level fan-out

    static func sweepAll() { for c in live { c.sweep() } }
    static func cancelAll() async { for c in live { await c.cancelIndexing() } }
    static func resetAll() async {
        for c in live {
            await c.cancelIndexing()
            c.loadedIndexes.removeAll()
            c.failures.removeAll()
            c.indexingFailures.removeAll()
            c.failureURLs.removeAll()
            c.forcedRetryIDs.removeAll()
            c.visualFailureIDs.removeAll()
            c.queryConfiguration += 1
        }
    }

    static func clearIndexGlobally() async {
        await resetAll()
        EmbeddingStore.clearAll()
        sweepAll()
    }

    static func clearIndexGloballyChecked() async throws {
        await resetAll()
        defer { sweepAll() }
        try await Task.detached { try EmbeddingStore.clearAllChecked() }.value
    }

    // MARK: - Triggers

    func projectOpened() {
        Log.search.notice(
            "index project opened enabled=\(VisualModelLoader.shared.enabled)",
            telemetry: "Search index project opened",
            data: ["enabled": VisualModelLoader.shared.enabled]
        )
        Task {
            await VisualModelLoader.shared.prepare()
            sweep()
        }
    }

    /// Failed items remain visible until an explicit retry or successful indexing.
    func sweep() {
        guard VisualModelLoader.shared.enabled, VisualModelLoader.shared.isReady else { return }
        let assets = assetsProvider()
        let currentIDs = Set(assets.map(\.id))
        failures = failures.filter { currentIDs.contains($0.key) }
        indexingFailures = indexingFailures.filter { currentIDs.contains($0.key) }
        failureURLs = failureURLs.filter { currentIDs.contains($0.key) }
        forcedRetryIDs.formIntersection(currentIDs)
        visualFailureIDs.formIntersection(currentIDs)
        Log.search.notice(
            "index sweep assets=\(assets.count) queuedBefore=\(queue.count)",
            telemetry: "Search index sweep",
            data: [
                "assets": assets.count,
                "ready": VisualModelLoader.shared.isReady,
                "queuedBefore": queue.count
            ]
        )
        for asset in assets {
            schedule(asset)
        }
    }

    func schedule(_ asset: MediaAsset) {
        if let failedURL = failureURLs[asset.id], failedURL != asset.url {
            failures[asset.id] = nil
            indexingFailures[asset.id] = nil
            failureURLs[asset.id] = nil
            visualFailureIDs.remove(asset.id)
            loadedIndexes[asset.id] = nil
        }
        let loader = VisualModelLoader.shared
        guard loader.enabled, loader.isReady, let model = loader.embedder, !asset.isGenerating,
              !queue.contains(asset.id), activeAssetID != asset.id, preflightTokens[asset.id] == nil,
              failures[asset.id] == nil else { return }
        let assetID = asset.id, url = asset.url
        let isVisual = asset.type == .video || asset.type == .image
        let wantsTranscript = Self.wantsTranscript(asset)
        let spec = model.spec
        let identity = ObjectIdentifier(model)
        let configuration = queryConfiguration
        let token = UUID()
        preflightTokens[assetID] = token
        preflightTasks[assetID] = Task { [weak self] in
            guard let self else { return }
            defer { self.finishPreflight(assetID: assetID, token: token) }
            let check = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let visual = isVisual && VisualIndexer.needsIndex(url: url, spec: spec)
                let transcript = wantsTranscript && !TranscriptCache.hasCachedOnDisk(for: url)
                try Task.checkCancellation()
                return visual || transcript
            }
            do {
                let needed = try await withTaskCancellationHandler { try await check.value } onCancel: { check.cancel() }
                try Task.checkCancellation()
                guard self.preflightTokens[assetID] == token, self.queryConfiguration == configuration,
                      let current = self.assetsProvider().first(where: { $0.id == assetID }) else { return }
                guard loader.enabled, loader.isReady, loader.embedder.map({ ObjectIdentifier($0) }) == identity,
                      current.url == url else {
                    self.finishPreflight(assetID: assetID, token: token)
                    self.schedule(current)
                    return
                }
                guard self.failures[assetID] == nil,
                      needed || (isVisual && self.forcedRetryIDs.contains(assetID)) else { return }
                self.queue.append(assetID)
                self.batchTotal += 1
                self.ensureWorker()
            } catch { }
        }
    }

    private func finishPreflight(assetID: String, token: UUID) {
        guard preflightTokens[assetID] == token else { return }
        preflightTokens[assetID] = nil
        preflightTasks[assetID] = nil
    }

    static func wantsTranscript(_ asset: MediaAsset) -> Bool {
        asset.type == .audio || (asset.type == .video && asset.hasAudio)
    }

    /// Stops the worker and waits for the in-flight asset to actually stop.
    private func cancelIndexing() async {
        let current = worker
        let checking = Array(preflightTasks.values)
        preflightTokens.removeAll()
        preflightTasks.removeAll()
        for task in checking { task.cancel() }
        workerGeneration += 1
        queryConfiguration += 1
        worker = nil
        activeAssetID = nil
        queue.removeAll()
        resetBatch()
        current?.cancel()
        for task in checking { await task.value }
        await current?.value
    }

    // MARK: - Worker

    private func ensureWorker() {
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        Log.search.notice(
            "index worker start generation=\(generation) depth=\(queue.count)",
            telemetry: "Search index worker started",
            data: ["generation": generation, "queueDepth": queue.count, "batchTotal": batchTotal]
        )
        worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, let asset = self.dequeue() {
                while ExportCoordinator.isExportActive, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                }
                self.currentAssetFraction = 0
                await self.indexOne(asset, generation: generation)
            }
            if let self, self.workerGeneration == generation {
                self.worker = nil
            }
        }
    }

    private func dequeue() -> MediaAsset? {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let asset = assetsProvider().first(where: { $0.id == id }) { return asset }
            batchCompleted += 1
        }
        resetBatch()
        return nil
    }

    private func resetBatch() {
        batchTotal = 0
        batchCompleted = 0
        currentAssetFraction = 0
    }

    private func indexOne(_ asset: MediaAsset, generation: Int) async {
        guard workerGeneration == generation, let model = VisualModelLoader.shared.embedder else { return }
        let assetID = asset.id
        activeAssetID = assetID
        defer {
            if workerGeneration == generation {
                batchCompleted += 1
                activeAssetID = nil
            }
        }
        let force = forcedRetryIDs.remove(assetID) != nil
        let url = asset.url
        let wantsTranscript = Self.wantsTranscript(asset)
        let transcribe = await Task.detached(priority: .utility) {
            wantsTranscript && !TranscriptCache.hasCachedOnDisk(for: url)
        }.value
        guard workerGeneration == generation, !Task.isCancelled else { return }
        let visualShare = transcribe ? 0.5 : 1.0
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.workerGeneration == generation, self.activeAssetID == assetID else { return }
                self.currentAssetFraction = fraction * visualShare
            }
        }
        let isVideo = asset.type == .video
        do {
            async let transcriptDone: Void = {
                if transcribe {
                    try await ExportCoordinator.waitWhileExportActive()
                    _ = try await TranscriptCache.shared.transcript(for: url, isVideo: isVideo, range: nil)
                }
            }()
            switch asset.type {
            case .image: try await VisualIndexer.indexImage(url: url, model: model, force: force)
            case .video:
                try await VisualIndexer.index(url: url, duration: asset.duration, model: model, progress: onProgress, force: force)
            default: break
            }
            try await transcriptDone
            try Task.checkCancellation()
            guard workerGeneration == generation else { return }
            loadedIndexes[assetID] = nil
            failures[assetID] = nil
            indexingFailures[assetID] = nil
            failureURLs[assetID] = nil
            forcedRetryIDs.remove(assetID)
            visualFailureIDs.remove(assetID)
            currentAssetFraction = 1
        } catch is CancellationError {
            Log.search.notice("index cancelled asset=\(assetID.prefix(8))")
        } catch {
            guard workerGeneration == generation else { return }
            failures[assetID] = error.localizedDescription
            indexingFailures[assetID] = error.localizedDescription
            failureURLs[assetID] = url
            Log.search.warning("index failed asset=\(assetID.prefix(8)): \(error.localizedDescription)")
        }
    }

    // MARK: - Query

    private struct QueryAsset: Equatable, Sendable {
        let id: String
        let url: URL
        let duration: Double
        let isImage: Bool
    }

    private func queryAssets(within ids: Set<String>?) -> [QueryAsset] {
        assetsProvider().filter {
            ($0.type == .video || $0.type == .image) && (ids?.contains($0.id) ?? true)
        }.map { QueryAsset(id: $0.id, url: $0.url, duration: $0.duration, isImage: $0.type == .image) }
    }

    func search(query: String, limit: Int = 20, within ids: Set<String>? = nil) async -> [VisualSearch.Hit] {
        await searchResult(query: query, limit: limit, within: ids).hits
    }

    func searchResult(query: String, limit: Int = 20, within ids: Set<String>? = nil) async -> SearchResult {
        let candidates = queryAssets(within: ids)
        let candidateIDs = Set(candidates.map(\.id))
        let availability = visualAvailability
        guard availability == .ready else {
            return SearchResult(hits: [], status: .unavailable(availability), unavailableAssetIDs: candidateIDs,
                                failedAssetIDs: failedAssetIDs.intersection(candidateIDs))
        }
        let encoder: QueryEncoder
        let modelIdentity: ObjectIdentifier?
        if let override = queryEncoderOverride {
            encoder = override
            modelIdentity = nil
        } else if let model = VisualModelLoader.shared.embedder {
            encoder = QueryEncoder(spec: model.spec, encode: { try model.encode(text: $0) })
            modelIdentity = ObjectIdentifier(model)
        } else {
            return SearchResult(hits: [], status: .unavailable(.preparing), unavailableAssetIDs: candidateIDs, failedAssetIDs: [])
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else {
            return SearchResult(hits: [], status: .ready, unavailableAssetIDs: [], failedAssetIDs: [])
        }
        let configuration = queryConfiguration
        let cached = loadedIndexes
        let task = Task.detached(priority: .userInitiated) {
            var indexes: [(String, EmbeddingStore.AssetIndex)] = []
            var loaded: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]
            var missing = Set<String>()
            var failures: [String: String] = [:]
            var identities: [String: String] = [:]
            for asset in candidates {
                try Task.checkCancellation()
                guard let key = EmbeddingStore.key(for: asset.url) else {
                    failures[asset.id] = "The source file is unavailable. Relink it, then retry indexing."
                    missing.insert(asset.id)
                    continue
                }
                identities[asset.id] = key
                let index: EmbeddingStore.AssetIndex
                do {
                    if let existing = cached[asset.id], existing.key == key { index = existing.index }
                    else { index = try EmbeddingStore.load(key: key) }
                    try EmbeddingStore.validate(index)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    missing.insert(asset.id)
                    continue
                } catch {
                    failures[asset.id] = error.localizedDescription
                    missing.insert(asset.id)
                    continue
                }
                guard index.header.model == encoder.spec.model, index.header.modelVersion == encoder.spec.version,
                      index.header.samplerVersion == FrameSampler.samplerVersion, index.header.dim == encoder.spec.embeddingDim,
                      index.header.count > 0 else { missing.insert(asset.id); continue }
                let rangesMatch: Bool
                if asset.isImage {
                    rangesMatch = index.header.count == 1 && index.rows.allSatisfy { $0.time == 0 && $0.shotStart == 0 && $0.shotEnd == 0 }
                } else {
                    rangesMatch = asset.duration.isFinite && asset.duration > 0
                        && index.rows.allSatisfy { $0.shotEnd <= asset.duration }
                }
                guard rangesMatch else {
                    failures[asset.id] = "The indexed ranges do not match the source duration. Retry indexing."
                    missing.insert(asset.id)
                    continue
                }
                indexes.append((asset.id, index))
                loaded[asset.id] = (key, index)
            }
            var errorMessage: String?
            var hits: [VisualSearch.Hit] = []
            if !indexes.isEmpty {
                do {
                    let vector = try encoder.encode(trimmed)
                    guard vector.count == encoder.spec.embeddingDim, vector.allSatisfy(\.isFinite) else {
                        throw VisualEmbedder.ModelError.badOutput
                    }
                    try Task.checkCancellation()
                    hits = VisualSearch.search(query: vector, indexes: indexes, limit: limit,
                                               minScore: SearchIndexConfig.visualMatchCosineFloor)
                } catch is CancellationError { throw CancellationError() }
                catch { errorMessage = error.localizedDescription }
            }
            try Task.checkCancellation()
            for asset in candidates where identities[asset.id] != EmbeddingStore.key(for: asset.url) {
                throw QueryChanged.source
            }
            return (hits, loaded, missing, failures, errorMessage)
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            let currentIdentity = queryEncoderOverride == nil ? VisualModelLoader.shared.embedder.map { ObjectIdentifier($0) } : nil
            guard queryConfiguration == configuration, visualAvailability == .ready,
                  modelIdentity == currentIdentity, queryAssets(within: ids) == candidates else {
                return SearchResult(hits: [], status: .stale, unavailableAssetIDs: candidateIDs, failedAssetIDs: [])
            }
            loadedIndexes.merge(result.1) { _, new in new }
            for assetID in visualFailureIDs.intersection(Set(result.1.keys)) {
                failures[assetID] = indexingFailures[assetID]
                if failures[assetID] == nil { failureURLs[assetID] = nil }
                visualFailureIDs.remove(assetID)
            }
            for (assetID, message) in result.3 {
                failures[assetID] = message
                failureURLs[assetID] = candidates.first(where: { $0.id == assetID })?.url
                visualFailureIDs.insert(assetID)
                loadedIndexes[assetID] = nil
            }
            let status: QueryStatus
            if let message = result.4 { status = .failed(message) }
            else if !result.3.isEmpty { status = .failed("Some media could not be searched. Retry the failed items.") }
            else if !result.2.isEmpty { status = indexingActive ? .indexing : .notIndexed }
            else { status = .ready }
            return SearchResult(hits: result.0, status: status, unavailableAssetIDs: result.2,
                                failedAssetIDs: failedAssetIDs.intersection(candidateIDs))
        } catch is CancellationError {
            return SearchResult(hits: [], status: .cancelled, unavailableAssetIDs: [], failedAssetIDs: [])
        } catch {
            return SearchResult(hits: [], status: .stale, unavailableAssetIDs: candidateIDs, failedAssetIDs: [])
        }
    }

    private enum QueryChanged: Error { case source }

}
