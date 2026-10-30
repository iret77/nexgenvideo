import AppKit
import Foundation
import NexGenEngine

@MainActor
enum NativeNewMusicvideoAcceptance {
    static func create(service: AgentService, binding: ProjectPackBinding, output: URL) async throws -> (VideoProject, URL) {
        guard WorkspaceUIAcceptance.isRequested, let packPath = ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_PACK"],
              let info = PluginBundleInfo(bundleURL: URL(fileURLWithPath: packPath)),
              info.id == binding.id, info.version == binding.version, info.projectSchema == binding.projectSchema,
              PluginGate.evaluate(info: info, appVersion: AppVersion.marketing) == nil,
              PluginSignature.verify(bundleURL: URL(fileURLWithPath: packPath), host: PluginSignature.hostSigningState()) == nil,
              PluginLoader.runtimeRejection(id: binding.id, version: binding.version) == nil else {
            throw GateBlocked("Native New Music Video requires the actual verified same-source CI pack.")
        }
        let packURL = URL(fileURLWithPath: packPath)
        guard PluginCatalogService.nativeAcceptanceSession == nil, AppState.shared.newProjectDocumentFactory == nil,
              let resident = PluginLoader.residentRecordsForInventory().first(where: { $0.id == binding.id && $0.version == binding.version && $0.isLoaded }),
              resident.bundleURL.resolvingSymlinksInPath() == packURL.resolvingSymlinksInPath() else {
            throw GateBlocked("Native creation requires its own verified resident CI pack and no other active creation fixture.")
        }
        let zip = output.appendingPathComponent("native-new-musicvideo-pack.zip")
        let archiveTask = Task.detached {
            guard !FileManager.default.fileExists(atPath: zip.path) else { throw GateBlocked("Use a fresh native pack evidence directory.") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", packURL.path, zip.path]
            process.standardInput = FileHandle.nullDevice
            let log = output.appendingPathComponent("native-new-pack-archive.log")
            guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw GateBlocked("The pack archive log could not be created.") }
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            try process.runCoordinated()
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw GateBlocked("Archiving the actual CI pack timed out.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw GateBlocked("The actual CI pack could not be archived.") }
            return try Data(contentsOf: zip)
        }
        let zipBytes = try await withTaskCancellationHandler { try await archiveTask.value } onCancel: { archiveTask.cancel() }
        let zipURL = URL(string: "https://native-new-musicvideo.invalid/musicvideo.ngvpack.zip")!
        let entry = PluginCatalog.Entry(id: info.id, displayName: info.displayName, tagline: info.tagline,
            version: info.version, projectSchema: info.projectSchema, migratesFrom: info.migratesFrom,
            minAppVersion: info.minAppVersion, url: zipURL, sha256: FileDigest.sha256(of: zipBytes))
        let catalogBytes = try JSONSerialization.data(withJSONObject: ["plugins": [["id": entry.id,
            "displayName": entry.displayName, "tagline": entry.tagline, "version": entry.version,
            "projectSchema": entry.projectSchema, "migratesFrom": entry.migratesFrom,
            "minAppVersion": entry.minAppVersion, "url": zipURL.absoluteString, "sha256": entry.sha256]]], options: [.sortedKeys])
        try catalogBytes.write(to: output.appendingPathComponent("native-new-project-catalog.json"), options: .atomic)
        let previousSession = PluginCatalogService.nativeAcceptanceSession
        let previousFactory = AppState.shared.newProjectDocumentFactory
        guard previousSession == nil, previousFactory == nil else { throw GateBlocked("Another native creation fixture is active.") }
        let catalogURL = PluginCatalogService.catalogURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeNewMusicvideoHTTP.self]
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        PluginCatalogService.nativeAcceptanceSession = session
        defer {
            PluginCatalogService.nativeAcceptanceSession = previousSession
            AppState.shared.newProjectDocumentFactory = previousFactory
            session.invalidateAndCancel(); NativeNewMusicvideoHTTP.clear()
        }
        NativeNewMusicvideoHTTP.install(catalogURL: catalogURL, catalog: catalogBytes, zipURL: zipURL, zip: zipBytes)
        guard PluginPaths.installedBundle(id: binding.id, version: binding.version) == nil else {
            throw GateBlocked("Native New Music Video requires a fresh isolated pack installation.")
        }
        _ = try await PluginInstaller.install(entry, appVersion: AppVersion.marketing, fetch: { url in
            let (bytes, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GateBlocked("The controlled CI pack transfer failed.") }
            return bytes
        })
        guard let installed = PluginLoader.installedInfo(id: binding.id, version: binding.version),
              installed.info == info, PluginSignature.verify(bundleURL: installed.url, host: PluginSignature.hostSigningState()) == nil,
              PluginLoader.liveBinding(id: binding.id) == binding else { throw GateBlocked("The real installer did not preserve the CI pack metadata/signature/live binding.") }
        var created: VideoProject?
        AppState.shared.newProjectDocumentFactory = {
            let document = VideoProject(agentService: service)
            created = document
            return document
        }
        HomeWindowController.shared.showWindow(nil)
        guard let home = HomeWindowController.shared.window else { throw GateBlocked("The actual Home window is unavailable.") }
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        home.setContentSize(NSSize(width: AppTheme.Window.projectMin.width, height: AppTheme.Window.homeMin.height))
        home.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: home, output: output, name: "hostflow-new-project")
        let project = output.appendingPathComponent("Native Music Video.ngv", isDirectory: true)
        var succeeded = false
        defer { if !succeeded { created?.close() } }
        do {
            if ChangelogStore.shared.pending != nil {
                try AppNativeMenuAcceptance.accessibilityClick("Continue", in: home, driver: driver)
                try await driver.wait("actual release notes dismissed") { ChangelogStore.shared.pending == nil }
            }
            try await driver.click("home.new", in: home)
            let format = try await driver.sheet("home.format.musicvideo", parent: home)
            try await driver.reveal("home.format.musicvideo", in: format)
            try await driver.click("home.format.musicvideo", in: format)
            guard driver.text("home.format.musicvideo", in: format) == "selected" else { throw GateBlocked("The native Music Video format was not selected.") }
            try driver.visible(["home.format.musicvideo", "home.format.cancel", "home.format.create"], in: format)
            try driver.capture("native-musicvideo-format", target: format)
            try await driver.click("home.format.create", in: format)
            try await driver.saveFile(project, in: home, returnsToParent: false)
            try await driver.wait("actual native Music Video document opened", seconds: 30) {
                guard let document = created else { return false }
                return AppState.shared.activeProject === document && document.fileURL?.standardizedFileURL == project.standardizedFileURL
                    && document.windowControllers.contains { $0.window?.isVisible == true && $0.window?.isKeyWindow == true }
            }
            guard let document = created, let window = document.windowControllers.first?.window,
                  document.editorViewModel.declaredPluginBinding == binding,
                  document.editorViewModel.agentService === service,
                  document.editorViewModel.declaredProductionContract == nil,
                  !document.editorViewModel.hasProductionPipeline,
                  let identity = ProjectIdentity.existingUUID(for: project) else {
                throw GateBlocked("Native New did not create its own exact Music Video document before production.")
            }
            let settings = try Data(contentsOf: project.appendingPathComponent("ngv.json"))
            try settings.write(to: output.appendingPathComponent("native-new-project-ngv.json"), options: .atomic)
            window.setContentSize(AppTheme.Window.projectMin)
            try await driver.click("editor.workspace.production", in: window, enabled: false)
            try await driver.reveal("dock.start", in: window)
            try driver.capture("native-musicvideo-before-start", target: window)
            try await driver.click("dock.start", in: window)
            try await driver.wait("native production setup reached Track", seconds: 60) {
                document.editorViewModel.hasProductionPipeline && service.pendingDialog?.title == "Track"
                    && !document.editorViewModel.productionStarting
            }
            guard let startedHome = document.editorViewModel.workingRoot,
                  ProjectIdentity.existingUUID(for: startedHome) == identity else { throw GateBlocked("Starting Music Video changed its actual project identity.") }
            let startedSettings = try Data(contentsOf: startedHome.appendingPathComponent("ngv.json"))
            try startedSettings.write(to: output.appendingPathComponent("native-new-project-started-ngv.json"), options: .atomic)
            guard NativeNewMusicvideoHTTP.catalogRequests >= 1, NativeNewMusicvideoHTTP.zipRequests == 1,
                  NativeNewMusicvideoHTTP.unexpectedRequests.isEmpty else { throw GateBlocked("Native creation did not fetch the current catalog or used an unexpected transport.") }
            try driver.record("native New Music Video completed", fields: ["projectID": identity, "binding": ["id": binding.id,
                "version": binding.version, "projectSchema": binding.projectSchema], "catalogSHA256": FileDigest.sha256(of: catalogBytes),
                "zipSHA256": FileDigest.sha256(of: zipBytes), "settingsSHA256": FileDigest.sha256(of: settings),
                "startedSettingsSHA256": FileDigest.sha256(of: startedSettings), "activation": "already-loaded-same-CI-pack",
                "unexpectedRequests": NativeNewMusicvideoHTTP.unexpectedRequests,
                "catalogRequests": NativeNewMusicvideoHTTP.catalogRequests, "zipRequests": NativeNewMusicvideoHTTP.zipRequests,
                "freshCatalogGate": true, "realInstallerAndSignature": true, "pipelineAbsentBeforeStart": true,
                "nextIntake": "Track", "viewport": try ProductionV2OwnerAcceptance.actualViewport(window),
                "liveCatalog": false, "runtimeFixture": true])
            try JSONSerialization.data(withJSONObject: driver.result(), options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("hostflow-new-project-result.json"), options: .atomic)
            succeeded = true
            return (document, project)
        } catch { driver.failure(error); throw error }
    }
}
