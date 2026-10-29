import Foundation

/// App-level search model loader. Loads the SigLIP model on app launch.
@MainActor
@Observable
final class VisualModelLoader {
    static let shared = VisualModelLoader()

    enum State: Equatable {
        case unknown
        case notInstalled
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .unknown
    private(set) var enabled = SearchIndexConfig.enabled
    @ObservationIgnored private(set) var embedder: VisualEmbedder?
    private let downloader = ModelDownloader()
    private var isRemovingModel = false
    private var operationID: UUID?
    @ObservationIgnored var completionBarrier: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored var verifiedArchiveObserver: (@Sendable (URL, ModelDownloader.Manifest.File) throws -> Void)?

    var isReady: Bool { state == .ready }

    private init() {}

    /// Loads an installed model if present; never downloads. Idempotent
    func prepare() async {
        guard enabled, state == .unknown, !isRemovingModel else { return }
        guard let installed = ModelDownloader.installed(for: SearchIndexConfig.manifest) else {
            state = .notInstalled
            return
        }
        let id = UUID()
        operationID = id
        state = .preparing
        defer { finishOperation(id) }
        await load(installed, operationID: id)
    }

    func download() {
        guard !isRemovingModel else { return }
        switch state {
        case .downloading, .preparing, .ready: return
        default: break
        }
        let retryingFailure: Bool
        if case .failed = state { retryingFailure = true } else { retryingFailure = false }
        let id = UUID()
        operationID = id
        state = .downloading(0)
        Task {
            defer { finishOperation(id) }
            do {
                if retryingFailure {
                    let directory = ModelDownloader.installDir(for: SearchIndexConfig.manifest)
                    try await Task.detached(priority: .utility) {
                        do { try FileManager.default.removeItem(at: directory) }
                        catch let error as CocoaError where error.code == .fileNoSuchFile { }
                    }.value
                    guard enabled, operationID == id else { return }
                }
                let installed = try await downloader.install(
                    manifest: SearchIndexConfig.manifest, baseURL: SearchIndexConfig.baseURL,
                    verifiedArchive: verifiedArchiveObserver
                ) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.enabled, self.operationID == id, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                guard enabled, operationID == id, !isRemovingModel else { return }
                state = .preparing
                await load(installed, operationID: id)
            } catch {
                guard enabled, operationID == id else { return }
                state = .failed(error.localizedDescription)
                Log.search.error("model download failed: \(error.localizedDescription)")
            }
        }
    }

    func setEnabled(_ value: Bool) {
        SearchIndexConfig.enabled = value
        enabled = value
        if value {
            Task { await prepare(); SearchIndexCoordinator.sweepAll() }
        } else {
            Task {
                await SearchIndexCoordinator.cancelAll()
                guard !enabled else {
                    SearchIndexCoordinator.sweepAll()
                    return
                }
                embedder = nil
                if operationID == nil, state == .ready || state == .preparing { state = .unknown }
            }
        }
    }

    /// Deletes the installed model and resets every project's index state.
    func remove() async {
        await SearchIndexCoordinator.resetAll()
        embedder = nil
        state = .notInstalled
        try? FileManager.default.removeItem(at: ModelDownloader.modelsDir)
    }

    func removeChecked() async throws {
        guard !isRemovingModel else {
            throw NSError(domain: "NexGenVideo.Storage", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Finish the search model operation before removing it."])
        }
        switch state {
        case .downloading, .preparing:
            throw NSError(domain: "NexGenVideo.Storage", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Finish the search model operation before removing it."])
        default: break
        }
        isRemovingModel = true
        defer { isRemovingModel = false }
        state = .preparing
        await SearchIndexCoordinator.resetAll()
        do {
            try await Task.detached {
                do { try FileManager.default.removeItem(at: ModelDownloader.modelsDir) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { }
            }.value
            embedder = nil
            state = .notInstalled
        } catch {
            state = enabled && embedder != nil ? .ready : .unknown
            if enabled { SearchIndexCoordinator.sweepAll() }
            throw error
        }
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        if !enabled {
            embedder = nil
            switch state {
            case .preparing, .downloading: state = .unknown
            default: break
            }
        }
    }

    private func load(_ installed: ModelDownloader.InstalledModel, operationID id: UUID) async {
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let tokenizer = try await TextTokenizer(
                    tokenizerFolder: installed.tokenizerFolder,
                    contextLength: installed.spec.contextLength
                )
                let model = try VisualEmbedder(
                    imageEncoderURL: installed.imageEncoderURL,
                    textEncoderURL: installed.textEncoderURL,
                    tokenizer: tokenizer,
                    spec: installed.spec
                )
                _ = try model.encode(text: "warm up")
                return model
            }.value
            await completionBarrier?()
            try Task.checkCancellation()
            guard enabled, operationID == id, !isRemovingModel, state == .preparing else { return }
            embedder = loaded
            state = .ready
            Log.search.notice("search model ready dim=\(loaded.spec.embeddingDim)")
            SearchIndexCoordinator.sweepAll()
        } catch is CancellationError {
            guard operationID == id, !isRemovingModel, state == .preparing else { return }
            embedder = nil
            state = .unknown
        } catch {
            guard enabled, operationID == id, !isRemovingModel, state == .preparing else { return }
            state = .failed(error.localizedDescription)
            Log.search.error("search model load failed: \(error.localizedDescription)")
        }
    }
}
