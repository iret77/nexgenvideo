import AppKit
import AVFoundation
import Darwin
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

@MainActor
enum ProductionPackRecoveryAcceptance {
    private static let resumeArgument = "--ngv-native-pack-recovery-resume"
    private static let ownerArgumentPrefix = "--ngv-pack-recovery-owner="

    @MainActor private final class TerminationDelegate: NSObject, NSApplicationDelegate {
        private let production = AppDelegate()
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            production.applicationShouldTerminate(sender)
        }
        func applicationWillTerminate(_ notification: Notification) {
            production.applicationWillTerminate(notification)
        }
    }
    static var isRequested: Bool { ProcessInfo.processInfo.environment["NGV_PACK_RECOVERY_ACCEPTANCE"] == "1" }

    private struct State: Codable, Sendable {
        let initialPID: Int32
        let projectURL: URL
        let source: ProjectPackBinding
        let target: ProjectPackBinding
        let timeline: Timeline
        let savedFiles: [ProductionWorkflowRecoveryMigration.File]
        let scale: Double
    }

    static func reopenArguments(_ requested: [String]) -> [String] {
        guard requested.isEmpty else { return requested }
        let owner = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(ownerArgumentPrefix) } ?? ""
        return [resumeArgument, owner, "-ApplePersistenceIgnoreState", "YES", "-agentBackend", "anthropicAPI",
            "-searchIndexEnabled", "NO", "-de.h5ventures.nexgenvideo.mcp.enabled", "NO",
            "-interfaceTextScale", ProcessInfo.processInfo.environment["NGV_PACK_RECOVERY_SCALE"] ?? "invalid"]
    }

    static func recordOwnedProcess(role: String, pid: Int32) throws {
        guard isRequested else { return }
        let owners = ProcessInfo.processInfo.arguments.filter { $0.hasPrefix(ownerArgumentPrefix) }
        guard ["initial", "reopener", "resumed"].contains(role), owners.count == 1,
              let owner = owners.first.map({ String($0.dropFirst(ownerArgumentPrefix.count)) }), UUID(uuidString: owner) != nil,
              let path = ProcessInfo.processInfo.environment["NGV_PACK_RECOVERY_EVIDENCE"] else {
            throw GateBlocked("The native Recovery process has no isolated owner identity.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scaleIndices = ProcessInfo.processInfo.arguments.indices.filter { ProcessInfo.processInfo.arguments[$0] == "-interfaceTextScale" }
        let actualScale = scaleIndices.count == 1 && scaleIndices[0] + 1 < ProcessInfo.processInfo.arguments.count
            ? ProcessInfo.processInfo.arguments[scaleIndices[0] + 1] : "missing"
        let record: [String: Any] = ["pid": pid, "owner": owner, "scaleArgument": actualScale]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("pack-recovery-process-" + role + ".json"), options: .atomic)
    }

    static func runIfRequested() {
        guard isRequested else { return }
        let env = ProcessInfo.processInfo.environment
        guard let outputPath = env["NGV_PACK_RECOVERY_EVIDENCE"], let packPath = env["NGV_SETTINGS_PACK_FIXTURE"],
              let homePath = env["CFFIXED_USER_HOME"], env["NGV_WORKSPACE_UI_ACCEPTANCE"] == "1",
              let scaleText = env["NGV_PACK_RECOVERY_SCALE"], let scale = Double(scaleText),
              [1.0, 1.25, 1.5].contains(scale) else {
            FileHandle.standardError.write(Data("PACK_RECOVERY_FAIL invalid isolated acceptance configuration\n".utf8)); exit(1)
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        let isolatedHome = URL(fileURLWithPath: homePath, isDirectory: true)
        let app = NSApplication.shared
        let lifecycle = TerminationDelegate()
        app.delegate = lifecycle
        app.setActivationPolicy(.regular)
        app.mainMenu = MainMenuBuilder.buildMenu()
        BundledFonts.register()
        Task { @MainActor in
            do {
                try SettingsOwnerAcceptance.requireIsolatedPacks(isolatedHome)
                try recordOwnedProcess(role: ProcessInfo.processInfo.arguments.contains(resumeArgument) ? "resumed" : "initial", pid: getpid())
                var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                let argv = ProcessInfo.processInfo.arguments
                let scaleIndices = argv.indices.filter { argv[$0] == "-interfaceTextScale" }
                guard scaleIndices.count == 1, let index = scaleIndices.first, index + 1 < argv.count,
                      Double(argv[index + 1]) == scale,
                      UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey) == scale else {
                    throw GateBlocked("The actual Recovery launch arguments did not preserve the requested interface scale.")
                }
                arguments[SearchIndexConfig.enabledDefaultsKey] = false
                arguments["de.h5ventures.nexgenvideo.mcp.enabled"] = false
                arguments[AgentBackendPreference.key] = AgentBackend.anthropicAPI.rawValue
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                guard !SearchIndexConfig.enabled, !AppState.shared.isMCPEnabled,
                      AgentBackendPreference.selected == .anthropicAPI else { throw GateBlocked("The isolated project services were not disabled.") }
                if ProcessInfo.processInfo.arguments.contains(resumeArgument) {
                    try await resume(output: output, scale: scale)
                    exit(0)
                }
                let pack = try JSONDecoder().decode(SettingsOwnerAcceptance.PackFixture.self,
                    from: Data(contentsOf: URL(fileURLWithPath: packPath)))
                try await start(output: output, isolatedHome: isolatedHome, pack: pack, scale: scale)
                throw GateBlocked("The native upgrade did not restart the process.")
            } catch {
                SettingsOwnerAcceptance.clearPackRecoverySettings()
                try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("pack-recovery-failure.txt"), options: .atomic)
                FileHandle.standardError.write(Data(("PACK_RECOVERY_FAIL " + error.localizedDescription + "\n").utf8)); exit(1)
            }
        }
        withExtendedLifetime(lifecycle) { app.run() }
    }

    private static func start(output: URL, isolatedHome: URL, pack: SettingsOwnerAcceptance.PackFixture, scale: Double) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try await SettingsOwnerAcceptance.packRecoveryServices(directory: output.appendingPathComponent("fixture"),
            pack: pack, isolatedHome: isolatedHome)
        let services = fixture.services, projectURL = fixture.projectURL
        guard let source = ProjectPackBinding(id: pack.id, version: pack.baseline.version, projectSchema: pack.baseline.projectSchema),
              let target = ProjectPackBinding(id: pack.id, version: pack.target.version, projectSchema: pack.target.projectSchema),
              ProductionWorkflowRecoveryMigration.isProductionTarget(target), source != target else {
            throw GateBlocked("The native Recovery acceptance requires an actual legacy-to-current production pack pair.")
        }
        let root = try ProjectScaffold.initProject(home: projectURL, name: "Retained native edit", mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: source.id))
        let mediaPath = "media/Retained original moving shot.mov"
        let media = projectURL.appendingPathComponent(mediaPath)
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Task.detached { try await FullflowAcceptanceFixture.writeVideo(to: media, duration: 8, fps: 30, warm: true) }.value
        let retainedImage = "frames/Retained original still.png"
        _ = try ProjectLocalFile.ensureDirectory("frames", dataRoot: root)
        let still = try await Task.detached {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media))
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: .zero)
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
                throw GateBlocked("The retained original still could not be encoded.")
            }
            CGImageDestinationAddImage(destination, frame.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw GateBlocked("The retained original still could not be encoded.") }
            return bytes as Data
        }.value
        try still.write(to: root.appendingPathComponent(retainedImage))
        let brief = root.appendingPathComponent(PipelineLayout.briefFile)
        try Data("Legacy unapproved creative proposal to archive unchanged.\n".utf8).write(to: brief)
        _ = try ProjectLocalFile.ensureDirectory("treatment", dataRoot: root)
        try Data("Legacy unapproved treatment revision to archive unchanged.\n".utf8)
            .write(to: root.appendingPathComponent("treatment/v4.md"))
        var timeline = Timeline()
        timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
        timeline.tracks = [Track(type: .video, clips: [Clip(mediaRef: "retained-original", mediaType: .video,
            sourceClipType: .video, startFrame: 0, durationFrames: 180, trimStartFrame: 30)])]
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "retained-original", name: "Retained original moving shot", type: .video,
            source: .project(relativePath: mediaPath), duration: 8, originalFilename: media.lastPathComponent)]
        try JSONEncoder().encode(timeline).write(to: projectURL.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(manifest).write(to: projectURL.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: projectURL.appendingPathComponent(Project.generationLogFilename))
        _ = try ProjectIdentity.uuid(for: projectURL)
        let document = try await VideoProject.load(from: projectURL, agentService: isolatedAgent())
        document.makeWindowControllers(); NSDocumentController.shared.addDocument(document); AppState.shared.showEditor(for: document)
        guard let editorWindow = document.windowControllers.first?.window else { throw GateBlocked("The legacy editor window did not open.") }
        editorWindow.setContentSize(AppTheme.Window.projectMin)
        let controller = SettingsWindowController(services: services, savesFrame: false)
        guard let window = controller.window else { throw GateBlocked("The native pack Settings window did not open.") }
        window.setContentSize(AppTheme.Window.projectMin)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "pack-recovery-before-restart")
        do {
            editorWindow.makeKeyAndOrderFront(nil)
            if !document.editorViewModel.agentPanelVisible {
                try await AppNativeMenuAcceptance.choose(["View", "Agent Panel"], in: editorWindow, driver: driver)
            }
            let pointSize = try await measureComposerFont(driver: driver, window: editorWindow, scale: scale)
            guard document.isDocumentEdited else { throw GateBlocked("The native composer edit did not mark its document edited.") }
            try await AppNativeMenuAcceptance.choose(["File", "Save"], in: editorWindow, driver: driver)
            try await driver.wait("native Recovery draft saved", seconds: 30) { !document.isDocumentEdited }
            guard let sessionID = document.editorViewModel.agentService.currentSessionId,
                  let savedDraft = try ChatSessionStore.loadThrowing(from: projectURL).first(where: { $0.id == sessionID })?.draft,
                  savedDraft.text == document.editorViewModel.agentService.draft,
                  savedDraft.task == document.editorViewModel.agentService.pendingFunction else {
                throw GateBlocked("The actual Save did not retain the native composer draft.")
            }
            try driver.record("native Recovery draft saved", fields: ["window": editorWindow.windowNumber,
                "sessionID": sessionID.uuidString, "draft": savedDraft.text, "wasEdited": true, "isEdited": document.isDocumentEdited])
            let files = try await Task.detached { try inventory(projectURL) }.value
            let state = State(initialPID: getpid(), projectURL: projectURL, source: source, target: target, timeline: timeline, savedFiles: files, scale: scale)
            try JSONEncoder().encode(state).write(to: output.appendingPathComponent("pack-recovery-state.json"), options: .atomic)
            var beforeViewport = try viewport(editorWindow, scale: scale)
            beforeViewport["renderedFontPointSize"] = pointSize
            try driver.record("native Recovery viewport before restart", fields: beforeViewport)
            controller.show(tab: .plugins)
            try await driver.click("settings.pack.update." + source.id, in: window)
            try await driver.wait("real current pack installed", seconds: 60) {
                services.plugins.versions(for: target.id).contains { $0.version == target.version && $0.isPresentOnDisk }
            }
            try await driver.click("settings.pack.apply." + source.id, in: window)
            try await requireResetConfirmation(driver: driver, attempt: "cancel")
            try await SettingsOwnerAcceptance.dialog("Cancel", driver: driver)
            guard ProjectPackMigration.request(for: projectURL) == nil,
                  try await Task.detached(operation: { try inventory(projectURL) }).value == files else {
                throw GateBlocked("Cancelling the native upgrade changed its saved project or pending request.")
            }
            try await driver.click("settings.pack.apply." + source.id, in: window)
            try await requireResetConfirmation(driver: driver, attempt: "stale")
            guard let working = document.editorViewModel.workingRoot, let workingRoot = DataRootResolver.dataRoot(of: working) else {
                throw GateBlocked("The actual source Recovery copy disappeared.")
            }
            let workingBrief = workingRoot.appendingPathComponent(PipelineLayout.briefFile)
            let previousBrief = try Data(contentsOf: workingBrief)
            try (previousBrief + Data("External stale-byte regression.\n".utf8)).write(to: workingBrief, options: .atomic)
            try await SettingsOwnerAcceptance.dialog("Upgrade and Restart", driver: driver)
            try await driver.wait("native stale-preview refusal") {
                NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && nativeText($0).contains("changed after the upgrade preview") }
            }
            try await SettingsOwnerAcceptance.dialog("OK", driver: driver)
            guard ProjectPackMigration.request(for: projectURL) == nil else { throw GateBlocked("A stale native upgrade scheduled a restart.") }
            try previousBrief.write(to: workingBrief, options: .atomic)
            try driver.capture("cancel-and-stale-refusal", target: window)
            try await driver.click("settings.pack.apply." + source.id, in: window)
            try await requireResetConfirmation(driver: driver, attempt: "commit")
            try driver.record("actual-upgrade-restart-request", fields: ["initialPID": getpid(), "savedProject": projectURL.lastPathComponent,
                "sourceVersion": source.version, "targetVersion": target.version])
            try await SettingsOwnerAcceptance.dialog("Upgrade and Restart", driver: driver)
            try await driver.wait("actual process termination", seconds: 60) { false }
        } catch { driver.failure(error); throw error }
    }

    private static func resume(output: URL, scale: Double) async throws {
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: output.appendingPathComponent("pack-recovery-state.json")))
        guard state.scale == scale, state.initialPID != getpid(), let request = ProjectPackMigration.request(for: state.projectURL),
              request.source == state.source, request.target == state.target, let reset = request.productionReset,
              PluginPaths.installedBundle(id: state.target.id, version: state.target.version) != nil else {
            throw GateBlocked("The actual restart did not retain its native upgrade request.")
        }
        guard PluginLoader.requestedVersionForNextLaunch(id: state.target.id) == state.target.version else {
            throw GateBlocked("The real restart lost its requested pack selection.")
        }
        let loaded = PluginLoader.loadInstalled()
        guard loaded.contains(where: { $0.id == state.target.id && $0.version == state.target.version && $0.isLoaded }),
              PluginLoader.liveBinding(id: state.target.id) == state.target else { throw GateBlocked("The production startup selector did not load the actual target pack.") }
        let retained = AppRelaunchIntentStore.consumeForLaunch(isSelfTest: false)
        guard retained == .openProject(state.projectURL), AppRelaunchIntentStore.take() == nil,
              PluginLoader.requestedVersionForNextLaunch(id: state.target.id) == state.target.version else {
            throw GateBlocked("The production launch consumer did not consume its exact project-open intent.")
        }
        let document = try await VideoProject.load(from: state.projectURL, agentService: isolatedAgent())
        document.makeWindowControllers(); NSDocumentController.shared.addDocument(document); AppState.shared.showEditor(for: document)
        guard let window = document.windowControllers.first?.window, let working = document.editorViewModel.workingRoot,
              let root = DataRootResolver.dataRoot(of: working) else { throw GateBlocked("The upgraded native editor did not open.") }
        window.setContentSize(AppTheme.Window.projectMin)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "pack-recovery-after-restart")
        do {
            let histories = try await Task.detached { try ProductionWorkflowRecoveryMigration.readCommittedHistories(staging: working) }.value
            guard histories.contains(where: { $0.intent == reset && $0.completed && $0.retainedStartupPhases.isEmpty }),
                  ProjectPluginSettings.bindingResolution(projectURL: working) == .bound(state.target),
                  ProjectPluginSettings.bindingResolution(projectURL: state.projectURL) == .bound(state.source),
                  document.editorViewModel.timeline == state.timeline,
                  try await Task.detached(operation: { try inventory(state.projectURL) }).value == state.savedFiles else {
                throw GateBlocked("The real Recovery upgrade changed the saved project, native cut, pin or history.")
            }
            try await Task.detached { try ProductionWorkflowRecoveryMigration.requireCompleted(reset, staging: working) }.value
            let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
            let namespace = try JSONArtifactStore(dataRoot: root).load(ProductionWorkflowRecoveryMigration.OutputNamespace.self,
                at: ProductionWorkflowRecoveryMigration.OutputNamespace.relativePath)
            guard gates.gates.values.allSatisfy({ !$0.approved }),
                  namespace.protectedPaths.contains("pipeline/frames/Retained original still.png") else {
                throw GateBlocked("The new production workflow silently retained approval or lost its output protection.")
            }
            do {
                try ProductionWorkflowRecoveryMigration.requireNewOutput("frames/Retained original still.png", dataRoot: root)
                throw GateBlocked("A new production writer accepted an output outside its new namespace.")
            } catch is ProductionWorkflowRecoveryMigration.MigrationError { }
            _ = try ProductionWorkflowRecoveryMigration.outputPath(area: "frames", leaf: "Future frame.png", dataRoot: root)
            await document.editorViewModel.refreshEngineState()
            guard document.editorViewModel.projectState?.nextPhaseName == "project_init" else {
                throw GateBlocked("The unverified legacy workflow did not restart at Project Init.")
            }
            guard let sessionID = document.editorViewModel.agentService.currentSessionId else {
                throw GateBlocked("The saved Recovery composer session was not restored.")
            }
            let sessionPath = ChatSessionStore.dirName + "/" + sessionID.uuidString + ".json"
            let beforeSession = try Data(contentsOf: working.appendingPathComponent(sessionPath))
            try beforeSession.write(to: output.appendingPathComponent("pack-recovery-session-before-input.json"), options: .atomic)
            window.makeKeyAndOrderFront(nil)
            if !document.editorViewModel.agentPanelVisible {
                try await AppNativeMenuAcceptance.choose(["View", "Agent Panel"], in: window, driver: driver)
            }
            let pointSize = try await measureComposerFont(driver: driver, window: window, scale: scale)
            try document.checkpointForProductionUpgrade()
            let afterSession = try Data(contentsOf: working.appendingPathComponent(sessionPath))
            try afterSession.write(to: output.appendingPathComponent("pack-recovery-session-after-input.json"), options: .atomic)
            try driver.record("native Recovery session edit", fields: ["path": sessionPath, "sessionID": sessionID.uuidString,
                "beforeSHA256": FileDigest.sha256(of: beforeSession), "afterSHA256": FileDigest.sha256(of: afterSession)])
            var afterViewport = try viewport(window, scale: scale)
            afterViewport["renderedFontPointSize"] = pointSize
            try driver.record("native Recovery viewport after restart", fields: afterViewport)
            try driver.capture("actual-upgraded-recovery", target: window)
            let result: [String: Any] = ["schema": "native-pack-recovery/v1", "initialPID": state.initialPID, "resumedPID": getpid(),
                "projectURL": state.projectURL.path, "recoveryURL": working.path, "source": state.source.version,
                "target": state.target.version, "historyFingerprint": reset.fingerprint, "savedUnchanged": true,
                "timelineUnchanged": true, "canonicalHistoryVerified": true, "allApprovalsReset": true,
                "mediaNamespaceProtected": true, "requestedSelectionRetained": true,
                "nextPhase": "project_init", "driver": driver.result(), "effectiveScale": try viewport(window, scale: scale)["scale"]!,
                "viewport": [window.contentView?.bounds.width ?? 0, window.contentView?.bounds.height ?? 0],
                "renderedFontPointSize": pointSize,
                "localFakes": ["agent readiness only; no API key or agent run", "catalog ZIP transport only"], "providerGeneration": false]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("pack-recovery-result.json"), options: .atomic)
            SettingsOwnerAcceptance.clearPackRecoverySettings()
        } catch { driver.failure(error); throw error }
    }

    private static func measureComposerFont(driver: ProductionVisualSourcesDriver, window: NSWindow, scale: Double) async throws -> Double {
        let id = "agent.composer.input"
        let task = "Apply a project change"
        if driver.state("agent.task.choose", in: window) != nil {
            try await driver.menu("agent.task.choose", title: task, in: window)
        } else {
            try AppNativeMenuAcceptance.accessibilityClick(task, in: window, driver: driver)
        }
        try await driver.wait("native Recovery task staged") { driver.text("agent.task.staged", in: window) == task }
        try await driver.click(id, in: window)
        guard let text = window.firstResponder as? NSTextView, text.isEditable, !text.isFieldEditor else {
            throw GateBlocked("The actual Recovery composer is not an editable text view.")
        }
        let before = text.string
        try driver.pressKey(125, characters: "\u{f701}", modifiers: .command, in: window)
        try await driver.wait("Recovery composer caret at end") {
            window.firstResponder === text && text.selectedRange() == NSRange(location: (before as NSString).length, length: 0)
        }
        try driver.pressKey(15, characters: "R", in: window)
        try await driver.wait("native Recovery composer input") {
            window.firstResponder === text && text.string == before + "R" && driver.text(id, in: window) == text.string
        }
        try driver.record("native Recovery composer input", fields: ["id": id, "before": before, "after": text.string,
            "added": "R", "task": task, "controlKind": "text-view", "window": window.windowNumber])
        return try await driver.measureFont(id, in: window, scale: scale)
    }

    private static func viewport(_ window: NSWindow, scale: Double) throws -> [String: Double] {
        guard let bounds = window.contentView?.bounds,
              abs(bounds.width - AppTheme.Window.projectMin.width) < 0.5,
              abs(bounds.height - AppTheme.Window.projectMin.height) < 0.5,
              AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale else {
            throw GateBlocked("The actual native Recovery viewport or interface scale changed across restart.")
        }
        return ["scale": scale, "width": bounds.width, "height": bounds.height]
    }

    private static func isolatedAgent() -> AgentService {
        AgentService(backend: .anthropicAPI, refreshBackendStatusOnInit: false, runtimeReadinessOverride: { nil }, apiKeyLoader: { nil })
    }

    private static func requireResetConfirmation(driver: ProductionVisualSourcesDriver, attempt: String) async throws {
        try await driver.wait("actual approval-reset confirmation", seconds: 60) {
            NSApp.windows.contains { window in
                guard window.isVisible && window.isKeyWindow else { return false }
                let text = nativeText(window)
                return text.contains("Upgrade and Restart") && text.contains("Brief and every later production approval will reset")
            }
        }
        if let window = NSApp.keyWindow { try driver.capture("actual-reset-confirmation-" + attempt, target: window) }
    }

    private static func nativeText(_ window: NSWindow) -> String {
        func text(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + ((view as? NSTextView).map { [$0.string] } ?? [])
                + ((view as? NSButton).map { [$0.title] } ?? []) + view.subviews.flatMap(text)
        }
        return window.contentView.map { text($0).joined(separator: "\n") } ?? ""
    }

    nonisolated private static func inventory(_ root: URL) throws -> [ProductionWorkflowRecoveryMigration.File] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw GateBlocked("The saved project cannot be inventoried.")
        }
        var result: [ProductionWorkflowRecoveryMigration.File] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw GateBlocked("The native fixture contains an unsupported symbolic link.") }
            if values.isRegularFile == true {
                result.append(.init(path: String(url.path.dropFirst(root.path.count + 1)), sha256: try FileDigest.sha256(of: url)))
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}
