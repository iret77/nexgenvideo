import AppKit
import AVFoundation
import Darwin
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

@MainActor
enum ProductionPackRecoveryAcceptance {
    private static let stableScenario = "stable-compatible"
    private static let previewScenario = "known-preview172-approved-resume"
    private static var scenario: String { ProcessInfo.processInfo.environment["NGV_PACK_RECOVERY_SCENARIO"] ?? stableScenario }
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
        let initialTimeline: Timeline
        let initialVideoEntry: MediaManifestEntry
        let savedFiles: [ProductionWorkflowRecoveryMigration.File]
        let scale: Double
        let scenario: String
        let projectID: String
        let oldStorySHA256: String?
        let oldIdentitySHA256: String?
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
              [1.0, 1.25, 1.5].contains(scale), [stableScenario, previewScenario].contains(scenario) else {
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
        if scenario == stableScenario {
            let brief = root.appendingPathComponent(PipelineLayout.briefFile)
            try Data("Legacy unapproved creative proposal to archive unchanged.\n".utf8).write(to: brief)
            _ = try ProjectLocalFile.ensureDirectory("treatment", dataRoot: root)
            try Data("Legacy unapproved treatment revision to archive unchanged.\n".utf8)
                .write(to: root.appendingPathComponent("treatment/v4.md"))
        }
        var timeline = Timeline()
        timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
        timeline.tracks = [Track(type: .video, clips: [Clip(mediaRef: "retained-original", mediaType: .video,
            sourceClipType: .video, startFrame: 0, durationFrames: 180, trimStartFrame: 30)])]
        let initialTimeline = timeline
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "retained-original", name: "Retained original moving shot", type: .video,
            source: .project(relativePath: mediaPath), duration: 8, originalFilename: media.lastPathComponent)]
        let initialVideoEntry = manifest.entries[0]
        try JSONEncoder().encode(timeline).write(to: projectURL.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(manifest).write(to: projectURL.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: projectURL.appendingPathComponent(Project.generationLogFilename))
        _ = try ProjectIdentity.uuid(for: projectURL)
        let document: VideoProject
        var oldStorySHA256: String?, oldIdentitySHA256: String?
        if scenario == previewScenario {
            guard source.version == "0.5.16", source.projectSchema == "musicvideo/2.0.0" else {
                throw GateBlocked("The known preview journey requires its actual Musicvideo 0.5.16 pack.")
            }
            let legacyOutput = output.appendingPathComponent("legacy-approved")
            let flow = try await MusicvideoHostFlowAcceptance.openExisting(projectURL: projectURL, evidenceURL: legacyOutput)
            let track = output.appendingPathComponent("Retained original song.wav")
            try FullflowAcceptanceFixture.writeTone(to: track, duration: 4.3)
            try await flow.beginTrackIntake(track: track, lyrics: nil)
            try await flow.runAnalysis { $0.registerAudioDecoder(AVFoundationAudioDecoder()) }
            try await flow.finishPlanningIntake(sectionLabels: ["opening"], finalResolution: .res720p)
            let references = try await FullflowAcceptanceFixture.finishLegacyReferences(editor: flow.editor,
                evidenceURL: legacyOutput, initialGateApprovals: flow.gateApprovals)
            try JSONEncoder().encode(references.nativeGateApprovals).write(to: legacyOutput.appendingPathComponent("legacy-native-approvals.json"))
            try JSONEncoder().encode(flow.report()).write(to: legacyOutput.appendingPathComponent("legacy-hostflow.json"))
            document = flow.document
            let oldRoot = flow.dataRoot
            let oldGates = try YAMLArtifactStore(dataRoot: oldRoot).load(Gates.self, at: PipelineLayout.gatesFile)
            let approved = ["project_init", "analysis", "brief", "production_design", "treatment", "storyboard", "bible"]
            let preparedTimeline = document.editorViewModel.timeline
            var originalVideo = preparedTimeline
            originalVideo.tracks.removeAll { $0.type == .audio }
            let songClips = preparedTimeline.tracks.filter { $0.type == .audio }.flatMap(\.clips)
            guard approved.allSatisfy({ oldGates.gates[$0]?.approved == true }),
                  originalVideo == initialTimeline, preparedTimeline.tracks.count == 2,
                  document.editorViewModel.mediaManifest.entries.filter({ $0.id == initialVideoEntry.id }) == [initialVideoEntry],
                  let songID = document.editorViewModel.mediaManifest.songAnchorAssetId,
                  let song = document.editorViewModel.mediaManifest.entries.first(where: { $0.id == songID && $0.type == .audio }),
                  songClips.count == 1, songClips[0].mediaRef == songID, songClips[0].startFrame == 0,
                  songClips[0].durationFrames == Int((song.duration * Double(preparedTimeline.fps)).rounded()),
                  songClips[0].trimStartFrame == 0, songClips[0].trimEndFrame == 0,
                  let identity = try ConfirmedIdentityAssetStoreV1.load(dataRoot: oldRoot).entries.values.first(where: {
                      $0.role == .location && $0.identitySlug == "stage"
                  }) else { throw GateBlocked("The original preview did not produce genuine approved Storyboard and References evidence.") }
            timeline = preparedTimeline
            oldStorySHA256 = try FileDigest.sha256(of: oldRoot.appendingPathComponent(PipelineLayout.treatmentCurrentFile))
            oldIdentitySHA256 = identity.sha256
        } else {
            document = try await VideoProject.load(from: projectURL, agentService: isolatedAgent())
            document.makeWindowControllers(); NSDocumentController.shared.addDocument(document)
        }
        AppState.shared.showEditor(for: document)
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
            let state = State(initialPID: getpid(), projectURL: projectURL, source: source, target: target, timeline: timeline, initialTimeline: initialTimeline,
                initialVideoEntry: initialVideoEntry, savedFiles: files, scale: scale,
                scenario: scenario, projectID: try ProjectIdentity.uuid(for: projectURL),
                oldStorySHA256: oldStorySHA256, oldIdentitySHA256: oldIdentitySHA256)
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
        guard state.scale == scale, state.scenario == scenario, state.initialPID != getpid(), let request = ProjectPackMigration.request(for: state.projectURL),
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
        let flow: MusicvideoHostFlowAcceptance?
        let document: VideoProject
        if state.scenario == previewScenario {
            flow = try await MusicvideoHostFlowAcceptance.openExisting(projectURL: state.projectURL,
                evidenceURL: output.appendingPathComponent("v2-resume"))
            document = flow!.document
        } else {
            flow = nil
            document = try await VideoProject.load(from: state.projectURL, agentService: isolatedAgent())
            document.makeWindowControllers(); NSDocumentController.shared.addDocument(document)
        }
        AppState.shared.showEditor(for: document)
        guard let window = document.windowControllers.first?.window, let working = document.editorViewModel.workingRoot,
              let root = DataRootResolver.dataRoot(of: working) else { throw GateBlocked("The upgraded native editor did not open.") }
        window.setContentSize(AppTheme.Window.projectMin)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "pack-recovery-after-restart")
        do {
            let histories = try await Task.detached { try ProductionWorkflowRecoveryMigration.readCommittedHistories(staging: working) }.value
            guard histories.contains(where: { $0.intent == reset && $0.completed && $0.retainedStartupPhases == (flow == nil ? [] : ["project_init", "analysis"]) }),
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
            guard gates.gates.allSatisfy({ phase, gate in
                gate.approved == (flow != nil && ["project_init", "analysis"].contains(phase))
            }),
                  namespace.protectedPaths.contains("pipeline/frames/Retained original still.png") else {
                throw GateBlocked("The new production workflow silently retained approval or lost its output protection.")
            }
            do {
                try ProductionWorkflowRecoveryMigration.requireNewOutput("frames/Retained original still.png", dataRoot: root)
                throw GateBlocked("A new production writer accepted an output outside its new namespace.")
            } catch is ProductionWorkflowRecoveryMigration.MigrationError { }
            _ = try ProductionWorkflowRecoveryMigration.outputPath(area: "frames", leaf: "Future frame.png", dataRoot: root)
            await document.editorViewModel.refreshEngineState()
            let nextPhase = flow == nil ? "project_init" : "brief"
            guard document.editorViewModel.projectState?.nextPhaseName == nextPhase else {
                throw GateBlocked("The upgraded native workflow did not resume at " + nextPhase + ".")
            }
            let pointSize: Double
            if flow != nil {
                try await driver.wait("actual previous-story intake restored") {
                    document.editorViewModel.agentService.pendingDialog?.title == "Existing story"
                        && driver.text("agent.dialog.title", in: window) == "Existing story"
                }
                pointSize = try await driver.measureFont("agent.dialog.direction", in: window, scale: scale)
            } else {
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
                pointSize = try await measureComposerFont(driver: driver, window: window, scale: scale)
                try document.checkpointForProductionUpgrade()
                let afterSession = try Data(contentsOf: working.appendingPathComponent(sessionPath))
                try afterSession.write(to: output.appendingPathComponent("pack-recovery-session-after-input.json"), options: .atomic)
                try driver.record("native Recovery session edit", fields: ["path": sessionPath, "sessionID": sessionID.uuidString,
                    "beforeSHA256": FileDigest.sha256(of: beforeSession), "afterSHA256": FileDigest.sha256(of: afterSession)])
            }
            var afterViewport = try viewport(window, scale: scale)
            afterViewport["renderedFontPointSize"] = pointSize
            try driver.record("native Recovery viewport after restart", fields: afterViewport)
            try driver.capture("actual-upgraded-recovery", target: window)
            var result: [String: Any] = ["schema": "native-pack-recovery/v1", "scenario": state.scenario, "initialPID": state.initialPID, "resumedPID": getpid(),
                "projectURL": state.projectURL.path, "recoveryURL": working.path, "source": state.source.version,
                "target": state.target.version, "historyFingerprint": reset.fingerprint, "savedUnchanged": flow == nil,
                "savedUnchangedBeforeContinuationSave": true,
                "timelineUnchanged": true, "canonicalHistoryVerified": true, "allApprovalsReset": flow == nil, "productionApprovalsReset": true,
                "mediaNamespaceProtected": true, "requestedSelectionRetained": true,
                "nextPhase": nextPhase, "driver": driver.result(), "effectiveScale": try viewport(window, scale: scale)["scale"]!,
                "viewport": [window.contentView?.bounds.width ?? 0, window.contentView?.bounds.height ?? 0],
                "renderedFontPointSize": pointSize,
                "localFakes": [flow == nil ? "agent readiness only; no API key or agent run" : "existing RecordingRuntime; supplied creative proposals; no live LLM",
                    "catalog ZIP transport only"], "providerGeneration": false]
            if let flow {
                result["approvedResume"] = try await continueApprovedPreview(flow: flow, state: state,
                    reset: reset, output: output)
            }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("pack-recovery-result.json"), options: .atomic)
            SettingsOwnerAcceptance.clearPackRecoverySettings()
        } catch { driver.failure(error); throw error }
    }

    private static func continueApprovedPreview(flow: MusicvideoHostFlowAcceptance, state: State,
                                                reset: ProductionWorkflowRecoveryMigration.Intent,
                                                output: URL) async throws -> [String: Any] {
        guard let storyHash = state.oldStorySHA256, let identityHash = state.oldIdentitySHA256,
              let working = flow.editor.workingRoot, ProjectIdentity.existingUUID(for: working) == state.projectID,
              ProjectIdentity.existingUUID(for: state.projectURL) == state.projectID else {
            throw GateBlocked("The approved preview continuation lost its original project identity or material evidence.")
        }
        let original = output.appendingPathComponent("original-before-resume-save.ngv")
        let resetCopy = output.appendingPathComponent("reset-recovery-evidence.ngv")
        try FileManager.default.copyItem(at: state.projectURL, to: original)
        try FileManager.default.copyItem(at: working, to: resetCopy)
        let window = try MusicvideoNativeAcceptance.window(for: flow.editor)
        let driver = ProductionVisualSourcesDriver(window: window, output: output.appendingPathComponent("v2-resume"), name: "resume172-continuation")
        let context = ProductionPlanningAcceptanceFixture.Context(document: flow.document, packageURL: state.projectURL,
            dataRoot: flow.dataRoot, executor: ToolExecutor(editor: flow.editor))
        try await ProductionV2PlanningAcceptance.selectPhase("brief", context: context, driver: driver)
        if flow.editor.agentService.pendingDialog == nil {
            try await driver.wait("actual migrated Brief can continue") {
                driver.state("pipeline.overview.dock.continue", in: window) == true && !flow.editor.agentService.isComposerBlocked
            }
            try await driver.click("pipeline.overview.dock.continue", in: window)
        }
        let selected = try await flow.finishPreviousWorkflowIntake(historyFingerprint: reset.fingerprint,
            storySHA256: storyHash, identitySHA256: identityHash)
        try await ProductionV2OwnerAcceptance.seedMusicvideoScript(context: context, driver: driver)
        let source = state.projectURL.appendingPathComponent("media/Retained original moving shot.mov")
        let board = try await ProductionV2PlanningAcceptance.runStoryboard(context: context, sourceVideo: source, driver: driver)
        guard flow.editor.timeline == state.timeline, ProjectIdentity.existingUUID(for: working) == state.projectID,
              try await Task.detached(operation: { try inventory(state.projectURL) }).value == state.savedFiles,
              ProjectPluginSettings.bindingResolution(projectURL: state.projectURL) == .bound(state.source) else {
            throw GateBlocked("Continuing the new planning workflow changed the original cut, identity or unsaved source package.")
        }
        let root = flow.dataRoot
        var paths = [PipelineLayout.productionDesignFile, PipelineLayout.treatmentCurrentFile,
            ScriptV1.currentPath, StoryboardV2.currentPath, StoryboardTimingV1.currentPath,
            StoryboardCausalityV2.currentPath, StoryboardIdentityV1.currentPath, StorySourceV1.currentPath,
            PipelineLayout.gatesFile, PipelineLayout.lineageFile, PipelineLayout.confirmedIdentityAssetsFile,
            "brief/story-source-selection.v1.json", "import/script.md"]
        paths += board.timing.shots.flatMap { $0.moments.compactMap(\.asset).flatMap { [$0.image.path, $0.proof.path] } }
        let canonical = try Dictionary(uniqueKeysWithValues: Set(paths).map { path in
            (path, try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: root)))
        })
        try await ProductionV2PlanningAcceptance.selectPhase("storyboard", context: context, driver: driver)
        try driver.capture("same-project-v2-storyboard-before-save", target: window)
        try await AppNativeMenuAcceptance.choose(["File", "Save"], in: window, driver: driver)
        try await driver.wait("same upgraded project saved", seconds: 30) { !flow.document.isDocumentEdited }
        guard ProjectPluginSettings.bindingResolution(projectURL: state.projectURL) == .bound(state.target),
              ProjectIdentity.existingUUID(for: state.projectURL) == state.projectID else {
            throw GateBlocked("Saving the migrated document changed its identity or lost its current pack pin.")
        }
        try await AppNativeMenuAcceptance.close(window, driver: driver)
        try await driver.wait("native close returns to Home") { HomeWindowController.shared.window?.isKeyWindow == true }
        guard let home = HomeWindowController.shared.window else { throw GateBlocked("The native Home window is missing.") }
        try await AppNativeMenuAcceptance.choose(["File", "Open…"], in: home, driver: driver)
        try await driver.chooseFile(state.projectURL, in: home, trigger: nil, returnsToParent: false)
        try await driver.wait("same migrated project reopened", seconds: 30) {
            guard let reopened = AppState.shared.activeProject else { return false }
            return reopened !== flow.document && reopened.fileURL?.standardizedFileURL == state.projectURL.standardizedFileURL
                && reopened.windowControllers.first?.window?.isKeyWindow == true
        }
        guard let reopened = AppState.shared.activeProject, let reopenedRoot = reopened.editorViewModel.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
              let reopenedWindow = reopened.windowControllers.first?.window,
              ProjectIdentity.existingUUID(for: reopened.editorViewModel.workingRoot!) == state.projectID,
              reopened.editorViewModel.declaredPluginBinding == state.target, reopened.editorViewModel.timeline == state.timeline,
              ProjectPackMigration.request(for: state.projectURL) == nil else {
            throw GateBlocked("Native reopen did not retain this exact migrated project, cut and pack pin.")
        }
        for (path, hash) in canonical {
            guard try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: reopenedRoot)) == hash else {
                throw GateBlocked("Native Save/Close/Reopen changed the accepted planning bytes: " + path)
            }
        }
        await reopened.editorViewModel.refreshEngineState()
        guard reopened.editorViewModel.projectState?.nextPhaseName == "shot_planning" else {
            throw GateBlocked("The reopened new Storyboard did not retain its actual next planning phase.")
        }
        let reopenedContext = ProductionPlanningAcceptanceFixture.Context(document: reopened, packageURL: state.projectURL,
            dataRoot: reopenedRoot, executor: ToolExecutor(editor: reopened.editorViewModel))
        let reopenedDriver = ProductionVisualSourcesDriver(window: reopenedWindow, output: driver.output, name: "resume172-reopened")
        try await ProductionV2PlanningAcceptance.selectPhase("storyboard", context: reopenedContext, driver: reopenedDriver)
        try reopenedDriver.capture("same-project-v2-storyboard-reopened", target: reopenedWindow)
        try reopenedDriver.record("same approved preview project saved closed and reopened", fields: ["projectID": state.projectID,
            "projectURL": state.projectURL.path, "packVersion": state.target.version, "canonicalFiles": canonical,
            "nextPhase": reopened.editorViewModel.projectState?.nextPhaseName ?? "missing"])
        try JSONSerialization.data(withJSONObject: driver.result(), options: [.prettyPrinted, .sortedKeys])
            .write(to: driver.output.appendingPathComponent("resume172-continuation-result.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: reopenedDriver.result(), options: [.prettyPrinted, .sortedKeys])
            .write(to: driver.output.appendingPathComponent("resume172-reopened-result.json"), options: .atomic)
        return ["projectID": state.projectID, "projectURL": state.projectURL.path,
            "originalBeforeSave": original.path, "resetRecoveryEvidence": resetCopy.path,
            "reopenedRecoveryURL": reopened.editorViewModel.workingRoot!.path,
            "sourceStorySHA256": storyHash, "sourceIdentitySHA256": identityHash,
            "selected": selected, "canonicalFiles": canonical, "driver": "v2-resume/resume172-continuation-result.json",
            "materialDriver": "v2-resume/resume172-previous-material-result.json",
            "reopenDriver": "v2-resume/resume172-reopened-result.json",
            "legacyApprovals": "legacy-approved/legacy-native-approvals.json",
            "retainedStartupPhases": ["project_init", "analysis"],
            "nextPhase": reopened.editorViewModel.projectState?.nextPhaseName ?? "missing"]
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
