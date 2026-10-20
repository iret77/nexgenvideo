import AppKit
import Darwin
import NexGenEngine
import SwiftUI

@MainActor
enum SettingsOwnerAcceptance {
    private static let recoveryDefaultsSuiteName = "native-pack-recovery.settings"
    static var isRequested: Bool { ProcessInfo.processInfo.environment["NGV_SETTINGS_OWNER_ACCEPTANCE"] == "1" }

    struct PackFixture: Decodable {
        struct Version: Decodable {
            let zipPath: String
            let version: String
            let projectSchema: String
            let minAppVersion: String
            let migratesFrom: [String]
        }
        let id: String
        let displayName: String
        let baseline: Version
        let target: Version

        func entry(_ value: Version) throws -> PluginCatalog.Entry {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: value.zipPath))
            return .init(id: id, displayName: displayName, tagline: "Local native acceptance artifact", version: value.version,
                projectSchema: value.projectSchema, migratesFrom: value.migratesFrom, minAppVersion: value.minAppVersion,
                url: URL(string: "https://native-acceptance.invalid/" + id + "/" + value.version + ".zip")!,
                sha256: FileDigest.sha256(of: bytes))
        }
    }

    @MainActor @Observable fileprivate final class LocalState {
        let defaults: UserDefaults
        let directory: URL
        var keys: [String: String] = [:]
        var oauth = Set<String>()
        var endpoints: [String: URL] = [:]
        var secureValues: [String: String] = [:]
        var rejectSecureWrite = false
        var rejectStorageWrite = false
        var notificationRequests = 0
        var relaunchRequests = 0
        var cliChecks = 0
        var backend: AgentBackend = .anthropicAPI
        var mcpEnabled = false
        var knownProjects: [ProjectEntry] = []
        var catalogRefreshing = false
        var catalogRefreshRequests = 0

        init(defaults: UserDefaults, directory: URL) { self.defaults = defaults; self.directory = directory }
        func key(_ name: String, value: String?) -> Bool {
            guard !rejectSecureWrite else { return false }
            keys[name] = value
            return true
        }
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func clear(_ name: String) async throws {
            guard !rejectStorageWrite else { throw GateBlocked("The isolated derived data could not be cleared.") }
            let url = file(name)
            try await Task.detached { try Data().write(to: url, options: .atomic) }.value
        }
        func sizes() async -> StorageSettingsServices.Sizes {
            let root = directory
            return await Task.detached {
                func size(_ name: String) -> Int64 { Int64((try? Data(contentsOf: root.appendingPathComponent(name)).count) ?? 0) }
                return .init(cache: size("cache.bin"), index: size("index.bin"), model: size("model.bin"))
            }.value
        }
    }

    static func runIfRequested() {
        guard isRequested else { return }
        let env = ProcessInfo.processInfo.environment
        guard let outputPath = env["NGV_SETTINGS_OWNER_EVIDENCE"], let packPath = env["NGV_SETTINGS_PACK_FIXTURE"],
              let homePath = env["CFFIXED_USER_HOME"], let scaleText = env["NGV_SETTINGS_OWNER_SCALE"],
              let scale = Double(scaleText), AppTheme.Typography.validatedScale(scale) == scale,
              env["NGV_WORKSPACE_UI_ACCEPTANCE"] == "1" else {
            FileHandle.standardError.write(Data("SETTINGS_OWNER_FAIL invalid isolated acceptance configuration\n".utf8)); exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu(title: "NexGenVideo")
        menu.addItem(application); menu.addItem(MainMenuBuilder.editMenu()); app.mainMenu = menu
        BundledFonts.register()
        Task { @MainActor in
            do {
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                let fixture = try JSONDecoder().decode(PackFixture.self, from: Data(contentsOf: URL(fileURLWithPath: packPath)))
                let result = try await run(output: output, isolatedHome: URL(fileURLWithPath: homePath, isDirectory: true),
                    scale: scale, pack: fixture)
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("settings-owner-result.json"), options: .atomic)
                FileHandle.standardOutput.write(Data("SETTINGS_OWNER_OK\n".utf8)); exit(0)
            } catch {
                FileHandle.standardError.write(Data(("SETTINGS_OWNER_FAIL " + error.localizedDescription + "\n").utf8)); exit(1)
            }
        }
        app.run()
    }

    private static func run(output: URL, isolatedHome: URL, scale: Double, pack: PackFixture) async throws -> [String: Any] {
        try requireIsolatedPacks(isolatedHome)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let name = "settings-owner-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "settings-native-acceptance." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw GateBlocked("The isolated Settings store could not be opened.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(scale, forKey: AppTheme.Typography.scaleKey)
        let local = LocalState(defaults: defaults, directory: directory)
        for name in ["cache.bin", "index.bin", "model.bin"] { try Data(repeating: 7, count: 128).write(to: local.file(name)) }
        let preferences = ModelPreferences(defaults: defaults)
        let catalog = ModelCatalog(preferences: preferences)
        guard let entry = FalModelRegistry.model(for: "fal-ai/qwen-image")?.entry else { throw GateBlocked("The actual image adapter fixture is missing.") }
        catalog.load(entries: [entry])
        let store = ModelCapabilityResearchStore(fileURL: directory.appendingPathComponent("research.v1.json"))
        let research = ModelCapabilityResearchController(store: store, locateExecutable: { URL(fileURLWithPath: "/native-acceptance/fake-claude") },
            probe: { .init(executableURL: $0, version: "2.0.0", verifiedFlags: ClaudeCapabilityResearchProbe.requiredFlags) },
            research: { request, _ in
                try await Task.sleep(for: .milliseconds(750))
                guard let host = request.allowedSourceHosts.first else { throw GateBlocked("No source authority is available.") }
                let evidence = CapabilityEvidenceV1(sourceURL: "https://" + host + "/native-acceptance-synthetic",
                    sourceTitle: "Synthetic native UI acceptance evidence; no research was executed", observedAt: request.observedAt,
                    kind: .documentedAPI, confidence: 1)
                let candidate = ModelCapabilityResearchCandidateV1(binding: request.binding, scope: request.scope,
                    fields: .init(integers: [CapabilityFieldIDV1.imageVisibleCharacters:
                        .init(value: 2, semantics: .reliableCapacity, evidence: [evidence])]))
                return .init(candidate: candidate, proof: .init(cliVersion: "2.0.0", availableTools: [], usedTools: []))
            }, catalog: catalog)
        let services = try await services(local: local, catalog: catalog, preferences: preferences, research: research, pack: pack, isolatedHome: isolatedHome)
        let controller = SettingsWindowController(services: services, savesFrame: false)
        guard let window = controller.window else { throw GateBlocked("The actual Settings controller did not create its window.") }
        window.setContentSize(.init(width: 960, height: 640))
        controller.show()
        defer { controller.close() }
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        do {
            try await driver.wait("actual Settings window") { probe("settings.tab.general", in: window) != nil }
            let alternateScale = scale == 1.25 ? 1.5 : 1.25
            try await driver.menu("settings.general.scale", title: scaleLabel(alternateScale), in: window)
            try await driver.wait("native interface scale persisted") { defaults.double(forKey: AppTheme.Typography.scaleKey) == alternateScale }
            try await driver.menu("settings.general.scale", title: scaleLabel(scale), in: window)
            try await driver.wait("requested interface scale restored") { defaults.double(forKey: AppTheme.Typography.scaleKey) == scale }
            try await driver.click("settings.general.notifications", in: window)
            try await driver.click("settings.general.telemetry", in: window)
            try await driver.wait("isolated general preferences") {
                defaults.bool(forKey: "fixture.notifications") && defaults.bool(forKey: "fixture.telemetry") && local.notificationRequests == 1
            }
            try driver.capture("general", target: window)
            try await tab(.providers, driver: driver, window: window)
            try await driver.wait("model refresh requires a connection") {
                driver.state("settings.catalog.refresh", in: window) == false
            }
            try await driver.click("settings.providers.raw", in: window)
            try await driver.wait("explicit raw-prompt preference") { defaults.bool(forKey: PromptCompiler.rawPromptsDefaultsKey) }
            try await driver.click("settings.providers.raw", in: window)
            try await driver.wait("raw prompt escape hatch disabled") { !defaults.bool(forKey: PromptCompiler.rawPromptsDefaultsKey) }
            if let oauth = GenerationProvider.allCases.first(where: { $0.mcpCapability?.auth == .oauth }) {
                try await driver.click("settings.provider.signin." + oauth.id, in: window)
                try await driver.wait("cancelled local OAuth simulation") {
                    driver.text("settings.provider.error." + oauth.id, in: window)?.contains("cancelled") == true && local.oauth.isEmpty
                }
            } else { throw GateBlocked("The production OAuth setting disappeared.") }
            if let endpoint = GenerationProvider.allCases.first(where: { $0.mcpCapability?.auth == .localApp }) {
                try await driver.click("settings.provider.local." + endpoint.id, in: window)
                try await driver.wait("local application connection enabled") { local.endpoints[endpoint.id] != nil }
                try await driver.click("settings.provider.local." + endpoint.id, in: window)
                try await driver.wait("local application connection disabled") { local.endpoints[endpoint.id] == nil }
            } else { throw GateBlocked("The production local-application connection setting disappeared.") }
            let fakeKey = "native-acceptance-not-a-real-provider-key"
            try await type("settings.provider.key.fal", value: fakeKey, driver: driver, window: window)
            local.rejectSecureWrite = true
            try await driver.click("settings.provider.save.fal", in: window)
            try await driver.wait("visible provider secure-storage refusal") {
                probe("settings.provider.error.fal", in: window) != nil && local.keys["fal"] == nil
            }
            try driver.capture("keychain-refused", target: window)
            local.rejectSecureWrite = false
            try await driver.click("settings.provider.save.fal", in: window)
            try await driver.wait("same native draft saved after retry") { local.keys["fal"] == fakeKey }
            catalog.setProviderDiscoveryState(.unavailable("The isolated model request failed. Refresh models to retry."), for: .fal)
            try await driver.wait("model request failure has a real retry") {
                driver.text("settings.provider.status.fal", in: window) == "Connection failed"
                    && driver.state("settings.catalog.refresh", in: window) == true
            }
            try await driver.click("settings.catalog.refresh", in: window)
            try await driver.wait("model retry is busy and cannot be repeated") {
                local.catalogRefreshRequests == 1 && local.catalogRefreshing
                    && driver.state("settings.catalog.refresh", in: window) == false
            }
            try driver.capture("models-refreshing", target: window)
            local.catalogRefreshing = false
            catalog.setProviderDiscoveryState(.ready(modelCount: 1), for: .fal)
            try await driver.wait("model refresh finished and can be requested again") {
                driver.state("settings.catalog.refresh", in: window) == true
                    && driver.text("settings.provider.status.fal", in: window) == "Key saved"
            }
            try await tab(.models, driver: driver, window: window)
            try await driver.fill("settings.models.search", value: "no-such-native-model", in: window)
            try await driver.wait("native catalog search excludes unmatched model") { probe("settings.models.enabled." + entry.id, in: window) == nil }
            try await driver.fill("settings.models.search", value: "", in: window)
            let modelID = "settings.models.enabled." + entry.id
            guard catalog.productionRouteCandidates(activation: services.activation()).contains(where: {
                $0.modelID == entry.id && $0.candidate.providerActivated && $0.candidate.liveAvailable
            }) else { throw GateBlocked("The actual supported generation model was not executable before its visibility change.") }
            try await driver.click(modelID, in: window)
            try await driver.wait("model hidden from actual generation candidates") {
                !services.preferences.isEnabled(entry.id) && catalog.productionRouteCandidates(activation: services.activation()).allSatisfy { !$0.candidate.liveAvailable }
            }
            guard !ModelPreferences(defaults: defaults).isEnabled(entry.id) else { throw GateBlocked("The model preference did not persist.") }
            try await driver.click(modelID, in: window)
            try await driver.wait("model re-enabled in actual generation candidates") {
                services.preferences.isEnabled(entry.id) && catalog.productionRouteCandidates(activation: services.activation()).contains {
                    $0.modelID == entry.id && $0.candidate.providerActivated && $0.candidate.liveAvailable
                }
            }
            try await researchLifecycle(local: local, catalog: catalog, research: research, modelID: entry.id, driver: driver, window: window)
            try await agentLifecycle(local: local, services: services, driver: driver, window: window)
            try await tab(.storage, driver: driver, window: window)
            try await driver.chooseFile(nil, in: window, trigger: "settings.storage.folder.choose")
            guard defaults.string(forKey: Project.projectsFolderKey) == nil else { throw GateBlocked("Cancelling the folder panel changed Settings.") }
            try await driver.chooseFile(directory, in: window, trigger: "settings.storage.folder.choose")
            try await driver.wait("native folder persisted") { defaults.string(forKey: Project.projectsFolderKey) == directory.path }
            try await driver.click("settings.storage.folder.reset", in: window)
            try await driver.wait("native projects folder reset") { defaults.string(forKey: Project.projectsFolderKey) == "" }
            try await driver.click("settings.toggle.Index imported media", in: window)
            try await driver.wait("native search preference persisted") { defaults.bool(forKey: "fixture.search") }
            local.rejectStorageWrite = true
            try await driver.click("settings.storage.cache.clear", in: window)
            try await driver.wait("visible storage refusal") {
                driver.text("settings.storage.error", in: window)?.contains("could not be cleared") == true
                    && (try? Data(contentsOf: local.file("cache.bin")).count) == 128
                    && driver.state("settings.storage.cache.clear", in: window) == true
            }
            local.rejectStorageWrite = false
            try await driver.click("settings.storage.cache.clear", in: window)
            try await driver.wait("actual fixture cache cleared") {
                (try? Data(contentsOf: local.file("cache.bin")).isEmpty) == true
                    && driver.state("settings.storage.index.clear", in: window) == true
            }
            try await driver.click("settings.storage.index.clear", in: window)
            try await driver.wait("actual fixture index cleared") {
                (try? Data(contentsOf: local.file("index.bin")).isEmpty) == true
                    && driver.state("settings.storage.model.remove", in: window) == true
            }
            try await driver.click("settings.storage.model.remove", in: window)
            try await driver.wait("isolated derived data cleared") {
                (try? Data(contentsOf: local.file("index.bin")).isEmpty) == true && (try? Data(contentsOf: local.file("model.bin")).isEmpty) == true
                    && driver.state("settings.storage.search", in: window) == true
            }
            try driver.capture("storage", target: window)
            try await tab(.general, driver: driver, window: window)
            try await driver.wait("visible diagnostics restart notice") { probe("settings.general.telemetry.restart", in: window) != nil }
            try await packs(pack, services: services, isolatedHome: isolatedHome, driver: driver, window: window)
            controller.close()
            controller.show(tab: .general)
            try await driver.wait("actual Settings reopened") { driver.text("settings.general.notifications", in: window) == "true" }
            try await tab(.providers, driver: driver, window: window)
            try await driver.wait("provider key after view reopen") { driver.text("settings.provider.status.fal", in: window) == "Key saved" }
            local.rejectSecureWrite = true
            try await driver.click("settings.provider.remove.fal", in: window)
            try await driver.wait("provider secure removal refusal visible") {
                probe("settings.provider.error.fal", in: window) != nil && local.keys["fal"] == fakeKey
            }
            local.rejectSecureWrite = false
            try await driver.click("settings.provider.remove.fal", in: window)
            try await driver.wait("native key removal") { local.keys["fal"] == nil }
            try driver.capture("reopened", target: window)
            return ["schema": "native-settings-owner/v1", "scale": scale, "nativePointerAndKeyboard": true,
                "realPackInstallerAndLoad": true, "realNetworkRequests": 0, "realCredentials": false,
                "localFakes": ["credential vault", "CLI availability", "research backend/evidence", "notification authorization",
                    "MCP service lifecycle", "derived cache/index/model files", "catalog HTTP transport", "application relaunch"],
                "driver": driver.result(), "recoveryUpgrade": "separate actual project enrollment acceptance required"]
        } catch { driver.failure(error); throw error }
    }

    private static func services(local: LocalState, catalog: ModelCatalog, preferences: ModelPreferences, research: ModelCapabilityResearchController,
                                 pack: PackFixture, isolatedHome: URL) async throws -> SettingsServices {
        try requireIsolatedPacks(isolatedHome)
        let baseline = try pack.entry(pack.baseline)
        let target = try pack.entry(pack.target)
        guard let before = SemanticVersion(baseline.version), let after = SemanticVersion(target.version), after > before else {
            throw GateBlocked("Settings acceptance needs two actual increasing pack versions.")
        }
        let oldBytes = try Data(contentsOf: URL(fileURLWithPath: pack.baseline.zipPath))
        let newBytes = try Data(contentsOf: URL(fileURLWithPath: pack.target.zipPath))
        let loaded = try await PluginInstaller.install(baseline, appVersion: AppVersion.marketing, fetch: { _ in oldBytes })
        guard loaded.isLoaded else { throw GateBlocked("The actual baseline pack did not load.") }
        let pinnedProject = local.directory.appendingPathComponent("Pinned original format.ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: pinnedProject, withIntermediateDirectories: true)
        guard let binding = ProjectPackBinding(id: pack.id, version: baseline.version, projectSchema: baseline.projectSchema) else {
            throw GateBlocked("The actual baseline binding is invalid.")
        }
        try ProjectPluginSettings.setActivePlugin(binding, projectURL: pinnedProject)
        local.knownProjects = [.init(id: UUID(), url: pinnedProject, createdDate: Date(), lastOpenedDate: Date())]
        let live = PluginManager.Services.live
        let manager = PluginManager(services: .init(installed: live.installed, reload: live.reload, versions: live.versions,
            fetch: { .success(.init(plugins: [target])) }, install: { entry in
                try requireIsolatedPacks(isolatedHome)
                guard entry == target else { throw GateBlocked("The native pack request left its isolated fixture.") }
                _ = try await PluginInstaller.install(entry, appVersion: AppVersion.marketing, fetch: { _ in newBytes })
            }, uninstall: { version in
                try requireIsolatedPacks(isolatedHome)
                try live.uninstall(version)
            }, refreshAttention: live.refreshAttention, badge: live.badge))
        let mcp = ExternalMcpServers.Dependencies(defaults: local.defaults, vault: .init(save: { value, account in
            guard !local.rejectSecureWrite else { return false }
            local.secureValues[account] = value; return true
        }, load: { local.secureValues[$0] }, delete: { local.secureValues[$0] = nil }),
            makeAccount: { "native-acceptance." + UUID().uuidString })
        let provider = ProviderSettingsConnections(loadKey: { local.keys[$0.id] }, saveKey: { local.key($1.id, value: $0) },
            deleteKey: { local.key($0.id, value: nil) }, oauthConnected: { local.oauth.contains($0.id) }, signOut: {
                guard !local.rejectSecureWrite else { return false }
                local.oauth.remove($0.id); return true
            }, localEndpoint: { local.endpoints[$0.id] }, setLocalEndpoint: { value, provider in
                local.endpoints[provider.id] = value.flatMap(URL.init(string:))
            }, signInOverride: { _ in throw OAuthError.userCancelled })
        let agent = AgentSettingsServices(backend: { local.backend }, setBackend: {
            local.backend = $0; local.defaults.set($0.rawValue, forKey: "fixture.backend")
            if $0 == .claudeCode { local.mcpEnabled = true }
        }, loadKey: { local.keys["agent"] }, saveKey: { local.key("agent", value: $0) },
            deleteKey: { local.key("agent", value: nil) }, checkClaude: {
                local.cliChecks += 1
                return .init(executableURL: URL(fileURLWithPath: "/native-acceptance/fake-claude"), version: "2.0.0", isAuthenticated: true)
            }, mcpRequired: { local.backend == .claudeCode }, mcpEnabled: { local.mcpEnabled },
            mcpRunning: { local.mcpEnabled }, mcpError: { nil }, setMCPEnabled: { local.mcpEnabled = $0 }, retryMCP: {})
        let storage = StorageSettingsServices(cacheDirectory: local.file("cache.bin"), projectsDirectory: {
            local.defaults.string(forKey: Project.projectsFolderKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? local.directory
        }, searchEnabled: { local.defaults.bool(forKey: "fixture.search") }, setSearchEnabled: {
            local.defaults.set($0, forKey: "fixture.search")
        }, modelName: "Isolated derived-data fixture; no ML model downloaded", sizes: { await local.sizes() },
            clearCache: { try await local.clear("cache.bin") }, clearIndex: { try await local.clear("index.bin") },
            removeModel: { try await local.clear("model.bin") })
        let actions = PluginSettingsServices(projectEntries: { local.knownProjects }, openRoots: { [] },
            relaunch: { local.relaunchRequests += 1 }, activePackID: { nil },
            canApplyUpdate: PluginSettingsServices.live.canApplyUpdate, upgradeProject: {},
            applyUpdates: { local.relaunchRequests += 1 })
        return .init(defaults: local.defaults, catalog: catalog, preferences: preferences, research: research,
            providers: provider, agent: agent, externalMCP: mcp, storage: storage, plugins: manager, pluginActions: actions,
            providerActivation: { .init(active: Set(local.keys.keys.compactMap { id in
                GenerationProvider(rawValue: id).map { .init(provider: $0, transport: .api) }
            })) }, general: .init(notifications: { local.defaults.bool(forKey: "fixture.notifications") },
                saveNotifications: { local.defaults.set($0, forKey: "fixture.notifications") }, configureNotifications: { local.notificationRequests += 1 },
                telemetry: { local.defaults.bool(forKey: "fixture.telemetry") }, launchTelemetry: false,
                saveTelemetry: { local.defaults.set($0, forKey: "fixture.telemetry") }),
            modelDiscovery: .init(isRefreshing: { local.catalogRefreshing }, refresh: {
                local.catalogRefreshRequests += 1; local.catalogRefreshing = true
            }))
    }

    static func packRecoveryServices(directory: URL, pack: PackFixture, isolatedHome: URL) async throws -> (services: SettingsServices, projectURL: URL) {
        try requireIsolatedPacks(isolatedHome)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: recoveryDefaultsSuiteName) else {
            throw GateBlocked("The isolated pack Settings store could not be opened.")
        }
        let local = LocalState(defaults: defaults, directory: directory)
        let preferences = ModelPreferences(defaults: defaults)
        let catalog = ModelCatalog(preferences: preferences)
        let research = ModelCapabilityResearchController(store: .init(fileURL: directory.appendingPathComponent("unused-research.json")),
            locateExecutable: { nil }, catalog: catalog)
        let original = try await services(local: local, catalog: catalog, preferences: preferences,
            research: research, pack: pack, isolatedHome: isolatedHome)
        let projectURL = try requireOne(original.pluginActions.projectEntries()).url
        ProjectRegistry.shared.register(projectURL)
        let live = SettingsServices(defaults: original.defaults, catalog: original.catalog, preferences: original.preferences,
            research: original.research, providers: original.providers, agent: original.agent,
            externalMCP: original.externalMCP, storage: original.storage, plugins: original.plugins,
            pluginActions: .live, providerActivation: original.providerActivation, general: original.general,
            modelDiscovery: original.modelDiscovery)
        return (live, projectURL)
    }

    static func clearPackRecoverySettings() {
        UserDefaults.standard.removePersistentDomain(forName: recoveryDefaultsSuiteName)
    }

    static func requireIsolatedPacks(_ home: URL) throws {
        let root = PluginPaths.installDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let expected = home.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let account = getpwuid(getuid()), let actualHome = account.pointee.pw_dir,
              root.hasPrefix(expected), root.hasSuffix("/NexGenVideo/Plugins"),
              home.standardizedFileURL.path != String(cString: actualHome) else {
            throw GateBlocked("The platform did not isolate its pack installation directory. No pack was changed.")
        }
    }

    private static func researchLifecycle(local: LocalState, catalog: ModelCatalog, research: ModelCapabilityResearchController,
                                          modelID: String, driver: ProductionVisualSourcesDriver, window: NSWindow) async throws {
        try await driver.wait("research store ready") { research.recordsLoaded }
        guard let target = ModelCapabilityResearchTargetBuilder.targets(catalog: catalog, records: research.records,
            corpus: CatalogCapabilityRuntime.corpus, activation: .init(active: [.init(provider: .fal, transport: .api)]))
            .first(where: { $0.request.binding.catalogModelID == modelID }) else { throw GateBlocked("The actual supported model has no research target.") }
        let original = catalog.offeringCapabilitiesByModelID
        try await driver.click("settings.research.start." + target.id, in: window)
        try await driver.wait("research cancellation available") { research.phase == .researching }
        try await driver.click("settings.research.cancel", in: window)
        try await driver.wait("native research cancelled") { research.phase == .idle && research.records.isEmpty }
        try await driver.click("settings.research.start." + target.id, in: window)
        try await driver.wait("actual field review") { research.phase == .review }
        guard research.records.isEmpty, catalog.offeringCapabilitiesByModelID == original else { throw GateBlocked("Research applied before native acceptance.") }
        try driver.capture("research-evidence", target: window)
        try await driver.click("settings.research.accept", in: window)
        try await driver.wait("accepted local fields affect actual catalog") {
            research.records.count == 1 && catalog.offeringCapabilitiesByModelID[modelID]?.first?.effective.fields.integers[CapabilityFieldIDV1.imageVisibleCharacters]?.value == 2
        }
        guard let record = research.records.first else { throw GateBlocked("The accepted record disappeared.") }
        guard catalog.curatedOfferingCapabilitiesByModelID == original else { throw GateBlocked("Local evidence rewrote the bundled catalog.") }
        try await driver.click("settings.research.disable." + record.id, in: window)
        try await driver.wait("accepted evidence disabled") { research.records.first?.status == .disabled && catalog.offeringCapabilitiesByModelID == original }
        try await driver.click("settings.research.enable." + record.id, in: window)
        try await driver.wait("accepted evidence enabled") { research.records.first?.status == .active }
        try await driver.click("settings.research.update." + record.id, in: window)
        try await driver.wait("native evidence update review") { research.phase == .review }
        try await driver.click("settings.research.decline", in: window)
        try await driver.wait("native evidence update declined without changing accepted fields") {
            research.phase == .idle && research.records.count == 1 && research.records.first?.status == .active
        }
        try await driver.click("settings.research.archive." + record.id, in: window)
        try await driver.wait("accepted evidence archived") { research.records.first?.status == .archived && catalog.offeringCapabilitiesByModelID == original }
        try await driver.click("settings.research.delete." + record.id, in: window)
        try await dialog("Cancel", driver: driver)
        guard research.records.count == 1 else { throw GateBlocked("Cancelling evidence deletion changed the store.") }
        try await driver.click("settings.research.delete." + record.id, in: window)
        try await dialog("Delete specifications", driver: driver)
        try await driver.wait("accepted evidence deleted") { research.records.isEmpty && catalog.offeringCapabilitiesByModelID == original }
    }

    private static func agentLifecycle(local: LocalState, services: SettingsServices, driver: ProductionVisualSourcesDriver,
                                       window: NSWindow) async throws {
        try await tab(.agent, driver: driver, window: window)
        try await type("settings.agent.key", value: "native-acceptance-not-a-real-agent-key", driver: driver, window: window)
        local.rejectSecureWrite = true
        try await driver.click("settings.agent.key.save", in: window)
        try await driver.wait("agent secure-storage refusal") { probe("settings.agent.key.error", in: window) != nil && local.keys["agent"] == nil }
        local.rejectSecureWrite = false
        try await driver.click("settings.agent.key.save", in: window)
        try await driver.wait("native agent key saved") { local.keys["agent"] != nil }
        try await driver.click("settings.agent.key.remove", in: window)
        try await driver.wait("native agent key removed") { local.keys["agent"] == nil }
        try await driver.segment("settings.agent.backend", title: AgentBackend.claudeCode.displayName,
            titles: AgentBackend.selectableCases.map(\.displayName), in: window)
        try await driver.wait("embedded runtime requires bridge") { local.backend == .claudeCode && local.cliChecks > 0 }
        guard driver.state("settings.agent.mcp", in: window) == false else { throw GateBlocked("The required local bridge remained editable.") }
        try await driver.segment("settings.agent.backend", title: AgentBackend.anthropicAPI.displayName,
            titles: AgentBackend.selectableCases.map(\.displayName), in: window)
        try await driver.wait("API runtime permits bridge choice") { local.backend == .anthropicAPI }
        try await driver.click("settings.agent.mcp", in: window)
        try await driver.wait("native local bridge disabled") { !local.mcpEnabled }
        try await driver.click("settings.mcp.add", in: window)
        try await type("settings.mcp.name", value: "nexgen", driver: driver, window: window)
        try await type("settings.mcp.connection", value: "https://native-acceptance.invalid/mcp", driver: driver, window: window)
        guard driver.state("settings.mcp.save", in: window) == false else { throw GateBlocked("The reserved server name remained saveable.") }
        try await driver.click("settings.mcp.cancel", in: window)
        guard ExternalMcpServers.settingsEntries(dependencies: services.externalMCP).isEmpty else { throw GateBlocked("Cancelled MCP intake persisted a server.") }
        try await driver.click("settings.mcp.add", in: window)
        try await type("settings.mcp.name", value: "fixture", driver: driver, window: window)
        try await type("settings.mcp.connection", value: "/usr/bin/true", driver: driver, window: window)
        try await driver.click("settings.mcp.save", in: window)
        try await dialog("Cancel", driver: driver)
        guard ExternalMcpServers.settingsEntries(dependencies: services.externalMCP).isEmpty else { throw GateBlocked("Cancelled MCP trust persisted executable configuration.") }
        try await driver.click("settings.mcp.save", in: window)
        try await dialog("Trust and Save", driver: driver)
        try await driver.wait("native MCP trust persisted") { ExternalMcpServers.settingsEntries(dependencies: services.externalMCP).map(\.name) == ["fixture"] }
        try await driver.click("settings.mcp.edit.fixture", in: window)
        try await type("settings.mcp.name", value: "renamed-fixture", driver: driver, window: window)
        try await driver.click("settings.mcp.save", in: window)
        try await driver.wait("native MCP rename preserves secure configuration") {
            ExternalMcpServers.settingsEntries(dependencies: services.externalMCP).map(\.name) == ["renamed-fixture"] && local.secureValues.count == 1
        }
        try await driver.click("settings.mcp.add", in: window)
        try await type("settings.mcp.name", value: "renamed-fixture", driver: driver, window: window)
        try await type("settings.mcp.connection", value: "https://native-acceptance.invalid/duplicate", driver: driver, window: window)
        guard driver.state("settings.mcp.save", in: window) == false else { throw GateBlocked("Duplicate MCP names remained saveable.") }
        try await driver.click("settings.mcp.cancel", in: window)
        try await driver.click("settings.mcp.remove.renamed-fixture", in: window)
        try await dialog("Cancel", driver: driver)
        guard !local.secureValues.isEmpty else { throw GateBlocked("Cancelling MCP removal deleted its secure configuration.") }
        try await driver.click("settings.mcp.remove.renamed-fixture", in: window)
        try await dialog("Remove “renamed-fixture”", driver: driver)
        try await driver.wait("native MCP removal") { local.secureValues.isEmpty && ExternalMcpServers.settingsEntries(dependencies: services.externalMCP).isEmpty }
        try driver.capture("agent-and-mcp", target: window)
    }

    private static func packs(_ pack: PackFixture, services: SettingsServices, isolatedHome: URL,
                              driver: ProductionVisualSourcesDriver, window: NSWindow) async throws {
        try await tab(.plugins, driver: driver, window: window)
        try await driver.wait("actual installed baseline") { services.plugins.versions(for: pack.id).contains { $0.version == pack.baseline.version } }
        let baselineURL = PluginPaths.installURL(id: pack.id, version: pack.baseline.version)
        let before = try FileDigest.sha256(of: baselineURL.appendingPathComponent("Contents/Info.plist"))
        let project = try requireOne(services.pluginActions.projectEntries()).url
        let projectBefore = try Data(contentsOf: project.appendingPathComponent("ngv.json"))
        try await driver.click("settings.pack.update." + pack.id, in: window)
        try await driver.wait("real staged update installed", seconds: 60) {
            services.plugins.versions(for: pack.id).contains { $0.version == pack.target.version && $0.isPresentOnDisk }
        }
        try requireIsolatedPacks(isolatedHome)
        guard try FileDigest.sha256(of: baselineURL.appendingPathComponent("Contents/Info.plist")) == before else {
            throw GateBlocked("Installing the new pack rewrote the pinned baseline.")
        }
        try driver.capture("side-by-side-pack-update", target: window)
        try await driver.click("settings.pack.remove." + pack.id + "@" + pack.baseline.version, in: window)
        let sheet = try await driver.sheet("settings.pack.removal.cancel", parent: window)
        guard driver.text("settings.pack.removal.message", in: sheet)?.contains("Pinned original format") == true else {
            throw GateBlocked("Removing a pinned version did not identify the actual known project.")
        }
        try await driver.click("settings.pack.removal.cancel", in: sheet)
        try await driver.wait("pack removal cancelled") { window.attachedSheet == nil && window.isKeyWindow }
        guard FileManager.default.fileExists(atPath: baselineURL.path) else { throw GateBlocked("Cancelling removal changed the installed pack.") }
        try await driver.click("settings.pack.remove." + pack.id + "@" + pack.baseline.version, in: window)
        let confirmation = try await driver.sheet("settings.pack.removal.confirm", parent: window)
        try await driver.click("settings.pack.removal.confirm", in: confirmation)
        try await driver.wait("exact selected version removed") { !FileManager.default.fileExists(atPath: baselineURL.path) }
        guard FileManager.default.fileExists(atPath: PluginPaths.installURL(id: pack.id, version: pack.target.version).path) else {
            throw GateBlocked("Removing one pack version removed another.")
        }
        guard try Data(contentsOf: project.appendingPathComponent("ngv.json")) == projectBefore else {
            throw GateBlocked("Installing or removing a pack silently rewrote the project pin.")
        }
        try driver.capture("exact-pack-removal", target: window)
    }

    private static func tab(_ tab: SettingsTab, driver: ProductionVisualSourcesDriver, window: NSWindow) async throws {
        try await driver.click("settings.tab." + tab.rawValue, in: window)
        try await driver.wait("native Settings tab " + tab.rawValue) { driver.text("settings.tab." + tab.rawValue, in: window) == "true" }
    }

    private static func probe(_ id: String, in window: NSWindow) -> NSView? {
        guard let root = window.contentView else { return nil }
        return WorkspaceUIAcceptance.findProbe(in: root, identifier: id)
    }

    private static func requireOne<Value>(_ values: [Value]) throws -> Value {
        guard values.count == 1, let value = values.first else { throw GateBlocked("The isolated Settings fixture changed.") }
        return value
    }

    private static func scaleLabel(_ scale: Double) -> String {
        if scale == AppTheme.Typography.standardScale { return "Standard" }
        return scale == AppTheme.Typography.largeScale ? "Larger · 125%" : "Largest · 150%"
    }

    private static func type(_ id: String, value: String, driver: ProductionVisualSourcesDriver, window: NSWindow) async throws {
        try await driver.click(id, in: window)
        try await driver.wait("native Settings text focus") { (window.firstResponder as? NSTextView)?.isEditable == true }
        guard let field = window.firstResponder as? NSTextView else { throw GateBlocked("The native Settings field did not own text input.") }
        try driver.pressKey(0, characters: "a", modifiers: .command, in: window)
        for character in value { try driver.pressKey(0, characters: String(character), in: window) }
        try await driver.wait("synthetic Settings text entered") { window.firstResponder === field && field.string == value }
        try driver.pressKey(48, characters: "\t", in: window)
        await Task.yield()
    }

    static func dialog(_ title: String, driver: ProductionVisualSourcesDriver) async throws {
        func buttons(_ view: NSView) -> [NSButton] { ([view as? NSButton].compactMap { $0 }) + view.subviews.flatMap(buttons) }
        var target: (NSWindow, NSButton)?
        try await driver.wait("native dialog button " + title) {
            target = NSApp.windows.filter { $0.isVisible && $0.isKeyWindow }.compactMap { window in
                window.contentView.flatMap { buttons($0).first { $0.title == title && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor } }
                    .map { (window, $0) }
            }.first
            return target != nil
        }
        guard let (window, button) = target else { throw GateBlocked("The native confirmation disappeared.") }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        try driver.record("native-dialog-pointer", fields: ["title": title, "window": window.windowNumber, "point": [point.x, point.y]])
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: eventType, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw GateBlocked("The native dialog input could not be posted.") }
            NSApp.postEvent(event, atStart: false)
        }
        try await driver.wait("native dialog dismissed") {
            !window.isVisible || !window.isKeyWindow || button.window == nil || button.isHiddenOrHasHiddenAncestor
        }
    }
}
