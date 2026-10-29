import AppKit
import Darwin
import Foundation
import NexGenEngine

@MainActor
enum SmartSearchOwnerAcceptance {
    private struct ModelFile: Codable, Sendable { let path: String; let sha256: String }
    private struct ArchiveReceipt: Codable, Sendable {
        let name: String
        let sha256: String
        let byteCount: Int64
        let verifiedUptime: Double
    }

    @MainActor private final class CompletionGate {
        private(set) var reached = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            reached = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["NGV_SMART_SEARCH_OWNER_ACCEPTANCE"] == "1" else { return }
        guard let path = env["NGV_SMART_SEARCH_EVIDENCE"], let home = env["CFFIXED_USER_HOME"],
              let scale = env["NGV_SMART_SEARCH_SCALE"].flatMap(Double.init),
              AppTheme.Typography.validatedScale(scale) == scale,
              let mode = env["NGV_SMART_SEARCH_MODE"], ["cold", "warm"].contains(mode) else { exit(1) }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = MainMenuBuilder.buildMenu()
        BundledFonts.register()
        UserDefaults.standard.set(scale, forKey: AppTheme.Typography.scaleKey)
        UserDefaults.standard.set(AgentBackend.anthropicAPI.rawValue, forKey: AgentBackendPreference.key)
        UserDefaults.standard.set(false, forKey: "de.h5ventures.nexgenvideo.mcp.enabled")
        SearchIndexConfig.enabled = true
        Task { @MainActor in
            do {
                let result = try await run(output: output, home: URL(fileURLWithPath: home, isDirectory: true),
                    scale: scale, cold: mode == "cold", failureURL: env["NGV_SMART_SEARCH_FAILURE_URL"])
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("smart-search-result.json"), options: .atomic)
                exit(0)
            } catch {
                try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("smart-search-failure.txt"), options: .atomic)
                FileHandle.standardError.write(Data(("SMART_SEARCH_FAIL " + error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        app.run()
    }

    private static func run(output: URL, home: URL, scale: Double, cold: Bool, failureURL: String?) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try requireIsolation(home: home)
        let model = VisualModelLoader.shared
        let archives = output.appendingPathComponent("verified-archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        model.verifiedArchiveObserver = { url, file in
            let copy = archives.appendingPathComponent(file.name)
            guard !FileManager.default.fileExists(atPath: copy.path) else { throw GateBlocked("A model archive was downloaded more than once.") }
            try FileManager.default.copyItem(at: url, to: copy)
            let actual = try FileDigest.sha256(of: copy)
            let size = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard actual == file.sha256, size.map(Int64.init) == file.bytes else { throw GateBlocked("The actual model archive copy changed.") }
            let receipt = ArchiveReceipt(name: file.name, sha256: actual, byteCount: file.bytes,
                verifiedUptime: ProcessInfo.processInfo.systemUptime)
            try JSONEncoder().encode(receipt).write(to: output.appendingPathComponent(file.name + ".receipt.json"), options: .atomic)
        }
        let initialLoad = CompletionGate()
        if cold { model.completionBarrier = { await initialLoad.wait() } }
        defer { initialLoad.release() }
        defer { model.verifiedArchiveObserver = nil; model.completionBarrier = nil }
        if cold {
            guard ModelDownloader.installed(for: SearchIndexConfig.manifest) == nil,
                  let failureURL, let url = URL(string: failureURL), url.host == "localhost" else {
                throw GateBlocked("Cold Smart Search requires an empty isolated model store and the controlled loopback failure endpoint.")
            }
            UserDefaults.standard.set(failureURL, forKey: "searchIndexModelBaseURL")
            guard SearchIndexConfig.baseURL == url else { throw GateBlocked("The debug failure transport is unavailable in this distribution.") }
        } else {
            UserDefaults.standard.removeObject(forKey: "searchIndexModelBaseURL")
            guard ModelDownloader.installed(for: SearchIndexConfig.manifest) != nil else { throw GateBlocked("Warm layout requires the actual previously installed model store.") }
        }
        let package = output.appendingPathComponent("Search.ngv", isDirectory: true)
        let incoming = output.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        var timeline = Timeline(); timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
        try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        try await FullflowAcceptanceFixture.writeVideo(to: incoming.appendingPathComponent("Moving search sample.mov"), duration: 4, fps: 30, warm: true)
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        defer { document.close() }
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The actual Smart Search editor did not open.") }
        window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "smart-search-owner")
        var stages: [String: Double] = [:]
        do {
            try await driver.click("editor.workspace.media", in: window, enabled: false)
            try await driver.chooseFile(incoming, in: window, trigger: "media.action.Import")
            try await driver.wait("actual search media import", seconds: 30) { editor.mediaAssets.count == 1 && editor.mediaImportProgress == nil }
            guard let asset = editor.mediaAssets.first, asset.type == .video, !asset.hasAudio,
                  editor.searchIndex.queryEncoderOverride == nil else { throw GateBlocked("Search acceptance requires actual silent video and the live encoder.") }
            let started = ProcessInfo.processInfo.systemUptime
            if cold {
                try await driver.wait("native Smart Search download control") { driver.state("media.index.download", in: window) == true }
                try await driver.click("media.index.download", in: window)
                try await driver.wait("actual controlled download failure", seconds: 30) {
                    if case .failed = model.state { return driver.state("media.index.retry-model", in: window) == true }
                    return false
                }
                guard model.embedder == nil, ModelDownloader.installed(for: SearchIndexConfig.manifest) == nil else { throw GateBlocked("Failed HTTP download installed a model.") }
                stages["failureSeconds"] = ProcessInfo.processInfo.systemUptime - started
                try driver.capture("actual-503-failure", target: window)
                UserDefaults.standard.removeObject(forKey: "searchIndexModelBaseURL")
                guard SearchIndexConfig.baseURL == SearchIndexConfig.hostedURL else { throw GateBlocked("Retry did not restore the actual public manifest source.") }
                try await driver.click("media.index.retry-model", in: window)
            }
            if cold {
                try await driver.wait("actual public archives compiled and CoreML warmed", seconds: 600) { initialLoad.reached }
                stages["downloadCompileWarmupAndEvidenceSeconds"] = ProcessInfo.processInfo.systemUptime - started - (stages["failureSeconds"] ?? 0)
                initialLoad.release()
                model.completionBarrier = nil
            }
            let indexingStart = ProcessInfo.processInfo.systemUptime
            try await driver.wait("actual CoreML load and indexing", seconds: 180) {
                model.isReady && model.embedder != nil && !editor.searchIndex.indexingActive
                    && (EmbeddingStore.key(for: asset.url).flatMap { EmbeddingStore.header(key: $0) }?.count ?? 0) > 0
            }
            stages["readyAndIndexSeconds"] = ProcessInfo.processInfo.systemUptime - indexingStart
            stages["observedSuccessIncludingUIAndEvidenceSeconds"] = ProcessInfo.processInfo.systemUptime - started - (stages["failureSeconds"] ?? 0)
            guard let encoder = model.embedder else { throw GateBlocked("The actual loaded model disappeared.") }
            let vector = try await Task.detached { try encoder.encode(text: "moving picture") }.value
            guard vector.count == SearchIndexConfig.manifest.embeddingDim, vector.allSatisfy(\.isFinite) else { throw GateBlocked("The real text encoder did not return its declared finite vector.") }
            try JSONEncoder().encode(vector).write(to: output.appendingPathComponent("text-embedding.json"), options: .atomic)
            let key = try requireKey(asset.url)
            let index = try await Task.detached { try EmbeddingStore.load(key: key) }.value
            guard index.header.model == SearchIndexConfig.manifest.model, index.header.dim == vector.count,
                  !index.rows.isEmpty, index.rows.allSatisfy({ $0.shotEnd <= asset.duration }) else { throw GateBlocked("The actual image index does not match the real media/model.") }
            try driver.record("actual model and media index", fields: ["dimension": vector.count, "indexRows": index.rows.count,
                "indexKey": key, "filename": asset.userFacingFilename, "sourceSHA256": try FileDigest.sha256(of: asset.url)])
            try driver.capture("actual-ready-index", target: window)
            let cache = output.appendingPathComponent("installed-model-cache", isDirectory: true)
            try await Task.detached { try FileManager.default.copyItem(at: ModelDownloader.installDir(for: SearchIndexConfig.manifest), to: cache) }.value
            let stored = try await Task.detached { try inventory(cache) }.value
            if cold { try await storageLifecycle(model: model, editor: editor, driver: driver, home: home, output: output, indexKey: key) }
            else { try await storageLayout(driver: driver, output: output) }
            return ["schema": "native-smart-search-owner/v1", "cold": cold, "scale": scale,
                "manifest": try JSONSerialization.jsonObject(with: JSONEncoder().encode(SearchIndexConfig.manifest)),
                "modelStore": ModelDownloader.installDir(for: SearchIndexConfig.manifest).path,
                "indexPath": EmbeddingStore.diskURL(key).path,
                "cache": cache.path, "cacheFiles": try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)), "dimension": vector.count, "indexRows": index.rows.count,
                "stages": stages, "driver": driver.result(), "semanticQualityClaim": false,
                "localFakes": ["initial loopback HTTP503", "unexercised non-Storage Settings dependencies"]]
        } catch { driver.failure(error); throw error }
    }

    private static func storageLayout(driver: ProductionVisualSourcesDriver, output: URL) async throws {
        let settings = SettingsWindowController(services: isolatedSettings(output: output), savesFrame: false)
        settings.show(tab: .storage)
        defer { settings.close() }
        guard let window = settings.window else { throw GateBlocked("The actual Storage Settings did not open.") }
        window.setContentSize(NSSize(width: 960, height: 640))
        try await driver.wait("actual warm Storage model controls") { driver.state("settings.storage.model.remove", in: window) == true }
        try await driver.reveal("settings.storage.model.remove", in: window)
        try driver.visible(["settings.toggle.Index imported media", "settings.storage.index.clear", "settings.storage.model.remove"], in: window)
        try driver.capture("actual-warm-storage-layout", target: window)
    }

    private static func storageLifecycle(model: VisualModelLoader, editor: EditorViewModel,
        driver: ProductionVisualSourcesDriver, home: URL, output: URL, indexKey: String) async throws {
        let settings = SettingsWindowController(services: isolatedSettings(output: output), savesFrame: false)
        settings.show(tab: .storage)
        defer { settings.close() }
        guard let window = settings.window else { throw GateBlocked("The actual Storage Settings did not open.") }
        window.setContentSize(NSSize(width: 960, height: 640))
        try await driver.wait("actual enabled Storage toggle") { driver.text("settings.storage.search", in: window) == "true" && driver.state("settings.storage.model.remove", in: window) == true }
        try await driver.reveal("settings.storage.model.remove", in: window)
        try driver.visible(["settings.toggle.Index imported media", "settings.storage.index.clear", "settings.storage.model.remove"], in: window)
        try await driver.click("settings.toggle.Index imported media", in: window)
        try await driver.wait("actual disabled model") { !model.enabled && model.embedder == nil }
        let gate = CompletionGate()
        model.completionBarrier = { await gate.wait() }
        defer { gate.release(); model.completionBarrier = nil }
        try await driver.click("settings.toggle.Index imported media", in: window)
        try await driver.wait("actual CoreML completion awaiting native disabled choice", seconds: 120) { gate.reached && model.state == .preparing }
        try await driver.click("settings.storage.model.remove", in: window)
        try await driver.wait("actual busy model removal refusal") {
            driver.text("settings.storage.error", in: window)?.contains("Finish the search model operation") == true
                && driver.state("settings.toggle.Index imported media", in: window) == true
        }
        try requireIsolation(home: home)
        guard ModelDownloader.installed(for: SearchIndexConfig.manifest) != nil else { throw GateBlocked("Busy removal deleted the real model.") }
        try driver.capture("busy-model-remove-refused", target: window)
        try await driver.click("settings.toggle.Index imported media", in: window)
        try await driver.wait("native disabled while real load completion pending") { !model.enabled }
        gate.release()
        try await driver.wait("late real completion remains disabled") { model.state == .unknown && model.embedder == nil && !model.enabled }
        try driver.record("disabled late completion", fields: ["ready": model.isReady, "embedderPresent": model.embedder != nil])
        model.completionBarrier = nil
        try await driver.click("settings.toggle.Index imported media", in: window)
        try await driver.wait("actual installed model reload", seconds: 120) { model.isReady && !editor.searchIndex.indexingActive }
        let oldIndexIdentity = EmbeddingStore.key(for: EmbeddingStore.diskURL(indexKey))
        try await driver.click("settings.storage.index.clear", in: window)
        try await driver.wait("actual clear and reindex", seconds: 60) {
            model.isReady && !editor.searchIndex.indexingActive && editor.searchIndex.failures.isEmpty
                && (EmbeddingStore.header(key: indexKey)?.count ?? 0) > 0
                && EmbeddingStore.key(for: EmbeddingStore.diskURL(indexKey)) != oldIndexIdentity
                && driver.state("settings.storage.model.remove", in: window) == true
        }
        try await driver.click("settings.storage.model.remove", in: window)
        try await driver.wait("actual model removed") { model.state == .notInstalled && model.embedder == nil && ModelDownloader.installed(for: SearchIndexConfig.manifest) == nil }
        try driver.record("actual model removed", fields: ["installed": false, "modelBytes": DiskCache.bytes(at: ModelDownloader.modelsDir)])
        try driver.capture("actual-model-removed", target: window)
    }

    private static func requireIsolation(home: URL) throws {
        let prefix = home.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let account = getpwuid(getuid()), let raw = account.pointee.pw_dir else { throw GateBlocked("The actual account home is unavailable.") }
        let real = URL(fileURLWithPath: String(cString: raw)).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for directory in [ModelDownloader.modelsDir, EmbeddingStore.directory, FileManager.default.temporaryDirectory] {
            let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
            guard prefix != real, path.hasPrefix(prefix) else { throw GateBlocked("Smart Search storage is not isolated from the account home.") }
        }
    }

    private static func requireKey(_ source: URL) throws -> String {
        guard let key = EmbeddingStore.key(for: source) else { throw GateBlocked("The imported search source is unavailable.") }
        return key
    }

    nonisolated private static func inventory(_ root: URL) throws -> [ModelFile] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw GateBlocked("The installed model cache cannot be inventoried.") }
        return try enumerator.compactMap { value -> ModelFile? in
            guard let url = value as? URL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return ModelFile(path: String(url.path.dropFirst(root.path.count + 1)), sha256: try FileDigest.sha256(of: url))
        }.sorted { $0.path < $1.path }
    }

    private static func isolatedSettings(output: URL) -> SettingsServices {
        let defaults = UserDefaults.standard
        let preferences = ModelPreferences(defaults: defaults), catalog = ModelCatalog(preferences: ModelPreferences(defaults: defaults))
        let research = ModelCapabilityResearchController(store: .init(fileURL: output.appendingPathComponent("unused-research.json")), locateExecutable: { nil }, catalog: catalog)
        let providers = ProviderSettingsConnections(loadKey: { _ in nil }, saveKey: { _, _ in false }, deleteKey: { _ in false },
            oauthConnected: { _ in false }, signOut: { _ in false }, localEndpoint: { _ in nil }, setLocalEndpoint: { _, _ in }, signInOverride: { _ in throw OAuthError.userCancelled })
        let agent = AgentSettingsServices(backend: { .anthropicAPI }, setBackend: { _ in }, loadKey: { nil }, saveKey: { _ in false }, deleteKey: { false },
            checkClaude: { .init(executableURL: nil, version: nil, isAuthenticated: false) }, mcpRequired: { false }, mcpEnabled: { false },
            mcpRunning: { false }, mcpError: { nil }, setMCPEnabled: { _ in }, retryMCP: {})
        let mcp = ExternalMcpServers.Dependencies(defaults: defaults, vault: .init(save: { _, _ in false }, load: { _ in nil }, delete: { _ in }), makeAccount: { UUID().uuidString })
        let plugins = PluginManager(services: .init(installed: { [] }, reload: { [] }, versions: { [] }, fetch: { .success(.init(plugins: [])) },
            install: { _ in throw GateBlocked("Pack installation is outside this search acceptance.") }, uninstall: { _ in throw GateBlocked("Pack removal is outside this search acceptance.") }, refreshAttention: {}, badge: { _ in nil }))
        return SettingsServices(defaults: defaults, catalog: catalog, preferences: preferences, research: research, providers: providers, agent: agent,
            externalMCP: mcp, storage: .live, plugins: plugins, pluginActions: .init(projectEntries: { [] }, openRoots: { [] }, relaunch: {}, activePackID: { nil }, canApplyUpdate: { _ in false }, upgradeProject: {}, applyUpdates: {}),
            providerActivation: { .init(active: []) }, general: .init(notifications: { false }, saveNotifications: { _ in }, configureNotifications: {}, telemetry: { false }, launchTelemetry: false, saveTelemetry: { _ in }))
    }
}
