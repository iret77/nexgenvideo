import AppKit
import NexGenEngine

@MainActor
enum ProductionCoreStartupOwnerAcceptance {
    static func start(runtime: ProductionV2RecordingRuntime, output: URL) async throws -> ProductionPlanningAcceptanceFixture.Context {
        guard WorkspaceUIAcceptance.isRequested, AppState.shared.newProjectDocumentFactory == nil else {
            throw GateBlocked("Core startup requires an isolated native owner session.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let service = runtime.service()
        var created: VideoProject?
        AppState.shared.newProjectDocumentFactory = {
            let document = VideoProject(agentService: service)
            created = document
            return document
        }
        defer { AppState.shared.newProjectDocumentFactory = nil }
        HomeWindowController.shared.showWindow(nil)
        guard let home = HomeWindowController.shared.window else { throw GateBlocked("The native Home window is unavailable.") }
        let previousMenu = NSApp.mainMenu, previousHomeSize = home.frame.size
        defer { NSApp.mainMenu = previousMenu; home.setFrame(NSRect(origin: home.frame.origin, size: previousHomeSize), display: false) }
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        home.setContentSize(NSSize(width: AppTheme.Window.projectMin.width, height: AppTheme.Window.homeMin.height))
        home.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let homeDriver = ProductionVisualSourcesDriver(window: home, output: output, name: "core-new-project")
        let package = output.appendingPathComponent("Native Core Film.ngv", isDirectory: true)
        var succeeded = false
        var enrollmentDriver: ProductionVisualSourcesDriver?
        defer { if !succeeded { created?.close() } }
        do {
            if ChangelogStore.shared.pending != nil {
                try AppNativeMenuAcceptance.accessibilityClick("Continue", in: home, driver: homeDriver)
                try await homeDriver.wait("release notes dismissed") { ChangelogStore.shared.pending == nil }
            }
            try await homeDriver.click("home.new", in: home)
            if !InstalledPack.all.isEmpty {
                let format = try await homeDriver.sheet("home.format.generic", parent: home)
                try await homeDriver.click("home.format.generic", in: format)
                try await homeDriver.wait("native Generic format selected") { homeDriver.text("home.format.generic", in: format) == "selected" }
                try homeDriver.capture("generic-format", target: format)
                try await homeDriver.click("home.format.create", in: format)
            }
            try await homeDriver.saveFile(package, in: home, returnsToParent: false)
            try await homeDriver.wait("actual new Generic document opened", seconds: 30) {
                guard let document = created else { return false }
                return AppState.shared.activeProject === document && document.fileURL?.standardizedFileURL == package.standardizedFileURL
                    && document.windowControllers.contains { $0.window?.isKeyWindow == true }
            }
            guard let document = created, let window = document.windowControllers.first?.window else {
                throw GateBlocked("The native Generic document did not open.")
            }
            let editor = document.editorViewModel
            window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
            guard editor.agentService === service, editor.declaredPluginBinding == nil,
                  editor.declaredProductionContract == nil, !editor.hasProductionPipeline,
                  editor.timeline.tracks.isEmpty, let identity = ProjectIdentity.existingUUID(for: package) else {
                throw GateBlocked("Native Generic New reused another project or silently enrolled production.")
            }
            let initialDeclaration = try ProjectPackGate.captureMutationDeclaration(projectURL: package)
            guard initialDeclaration.packName == nil, initialDeclaration.binding == nil, initialDeclaration.productionContract == nil else {
                throw GateBlocked("The saved Generic project was already enrolled before its explicit production choice.")
            }
            let initialSettings = try Data(contentsOf: package.appendingPathComponent("ngv.json"))
            try initialSettings.write(to: output.appendingPathComponent("core-before-enrollment-ngv.json"), options: .atomic)
            try homeDriver.record("native Generic New remains outside production", fields: ["projectID": identity,
                "settingsSHA256": FileDigest.sha256(of: initialSettings), "viewport": try ProductionV2OwnerAcceptance.actualViewport(window)])
            try JSONSerialization.data(withJSONObject: homeDriver.result(), options: [.sortedKeys])
                .write(to: output.appendingPathComponent("core-new-project-result.json"), options: .atomic)
            let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "core-enrollment")
            enrollmentDriver = driver
            try await driver.click("editor.workspace.production", in: window, enabled: false)
            try await driver.reveal("dock.start", in: window)
            try driver.capture("before-explicit-enrollment", target: window)
            try await driver.click("dock.start", in: window)
            try await SettingsOwnerAcceptance.dialog("Start Production", driver: driver)
            try await driver.wait("actual Core enrollment completed", seconds: 60) {
                editor.declaredProductionContract == .current && editor.hasProductionPipeline
                    && editor.projectState?.nextPhaseName == "project_init" && !editor.productionStarting
            }
            guard let working = editor.workingRoot, let root = DataRootResolver.dataRoot(of: working),
                  editor.declaredPluginBinding == nil, let enrolledIdentity = ProjectIdentity.existingUUID(for: working),
                  enrolledIdentity == identity, editor.projectId == enrolledIdentity else {
                throw GateBlocked("Core enrollment changed its actual working-copy project identity.")
            }
            let settings = try Data(contentsOf: working.appendingPathComponent("ngv.json"))
            try settings.write(to: output.appendingPathComponent("core-enrolled-ngv.json"), options: .atomic)
            let context = ProductionPlanningAcceptanceFixture.Context(document: document, packageURL: package,
                dataRoot: root, executor: ToolExecutor(editor: editor))
            try await driver.wait("Core startup actual project setup handoff", seconds: 30) {
                !service.isStreaming && runtime.phases.last == "project_init" && service.currentSessionId != nil
            }
            try await ProductionV2PlanningAcceptance.approve("project_init", artifact: PipelineLayout.projectFile,
                next: "brief", context: context, driver: driver)
            try await ProductionV2PlanningAcceptance.selectPhase("brief", context: context, driver: driver)
            try await driver.wait("explicit native story decision available") { driver.state("story-source.greenfield", in: window) == true }
            guard try PipelineStorySourceWriter.confirmedSelection(dataRoot: root, workflowID: HostWorkflowKey.core(.current).contractID) == nil else {
                throw GateBlocked("A new Core project silently chose a story source.")
            }
            try await driver.click("story-source.greenfield", in: window)
            try await driver.wait("actual greenfield choice displayed") { driver.text("story-source.selected", in: window) == "greenfield" }
            guard try PipelineStorySourceWriter.confirmedSelection(dataRoot: root, workflowID: HostWorkflowKey.core(.current).contractID)?.disposition == .greenfield else {
                throw GateBlocked("The native source choice did not persist its actual host selection.")
            }
            try driver.capture("explicit-greenfield-selection", target: window)
            try await ProductionPlanningAcceptanceFixture.run("write_brief", args: [
                "mission": "single_release", "target_platform": "Native acceptance film", "aspect_ratio": "16:9",
                "project_mode": "generic", "concept_type": "abstract", "visual_medium": "live_action_realistic",
                "figures": "none", "lyrics_integration": "literal"], in: context)
            try await ProductionV2PlanningAcceptance.approve("brief", artifact: PipelineLayout.briefFile,
                next: "production_design", context: context, driver: driver)
            try await ProductionV2OwnerAcceptance.seedMusicvideoScript(context: context, driver: driver)
            guard editor.projectState?.nextPhaseName == "script", runtime.phases.contains("brief"),
                  runtime.phases.contains("production_design"), runtime.phases.contains("treatment"), runtime.phases.last == "script",
                  AudioProjectLayout.songFiles(dataRoot: root).isEmpty else {
                throw GateBlocked("Native Core startup did not reach Script through its own approved phases without a song intake.")
            }
            let paths = [PipelineLayout.projectFile, PipelineLayout.briefFile, PipelineLayout.productionDesignFile,
                PipelineLayout.treatmentCurrentFile, ScriptV1.currentPath, StorySourceV1.currentPath, PipelineLayout.gatesFile]
            let artifacts = try await Task.detached {
                let source = try PlanningWriterIO.read(StorySourceV1.self, at: StorySourceV1.currentPath, dataRoot: root)
                guard let receipt = source.declineReceipt else { throw GateBlocked("Core startup lost its native story decision.") }
                return try (paths + [receipt.path, "brief/story-source-selection.v1.json"]).enumerated().map { index, path -> [String: String] in
                    let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root))
                    let retained = "core-start-artifact-\(index).json"
                    try bytes.write(to: output.appendingPathComponent(retained), options: .atomic)
                    return ["path": path, "retained": retained, "sha256": FileDigest.sha256(of: bytes)]
                }
            }.value
            try driver.record("native Core startup reached Script", fields: ["projectID": identity, "enrolledProjectID": enrolledIdentity,
                "settingsSHA256": FileDigest.sha256(of: settings), "artifacts": artifacts,
                "viewport": try ProductionV2OwnerAcceptance.actualViewport(window), "sourceDisposition": "greenfield",
                "liveAgent": false, "fixtureCanonicalWrites": true, "phaseRequests": runtime.phases])
            try JSONSerialization.data(withJSONObject: driver.result(), options: [.sortedKeys])
                .write(to: output.appendingPathComponent("core-enrollment-result.json"), options: .atomic)
            succeeded = true
            return context
        } catch { enrollmentDriver?.failure(error); homeDriver.failure(error); throw error }
    }
}
