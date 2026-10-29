import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum AppWorkspaceOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "app-nle-owner-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        HomeWindowController.shared.showWindow(nil)
        guard let home = HomeWindowController.shared.window else { throw GateBlocked("The real Home window is unavailable.") }
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        home.setContentSize(NSSize(width: 960, height: AppTheme.Window.homeMin.height)); home.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: home, output: output, name: name)
        let package = directory.appendingPathComponent("Original portrait.ngv", isDirectory: true)
        let copy = directory.appendingPathComponent("Independent copy.ngv", isDirectory: true)
        var ownedDocuments: [VideoProject] = []
        defer { for document in ownedDocuments where document.windowControllers.contains(where: { $0.window?.isVisible == true }) { document.close() } }
        do {
            try await driver.wait("native Home at requested scale") {
                home.isKeyWindow && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
            }
            if ChangelogStore.shared.pending != nil {
                try AppNativeMenuAcceptance.accessibilityClick("Continue", in: home, driver: driver)
                try await driver.wait("native release notes dismissed") { ChangelogStore.shared.pending == nil }
            }
            let documentsBefore = NSDocumentController.shared.documents.count
            try await AppNativeMenuAcceptance.choose(["File", "New"], in: home, driver: driver)
            try await driver.wait("native New save dialog") { NSApp.windows.contains { $0 is NSSavePanel && $0.isVisible } }
            guard let cancelledPanel = NSApp.windows.compactMap({ $0 as? NSSavePanel }).first(where: \.isVisible) else { throw GateBlocked("New Project has no real save panel.") }
            try driver.capture("new-cancel", target: cancelledPanel)
            try driver.pressKey(53, characters: "\u{1b}", in: cancelledPanel)
            try await driver.wait("native New cancellation") { !cancelledPanel.isVisible && home.isKeyWindow }
            guard NSDocumentController.shared.documents.count == documentsBefore else { throw GateBlocked("Cancelled New created a hidden document.") }
            try await driver.click("home.new", in: home)
            if !InstalledPack.all.isEmpty {
                let format = try await driver.sheet("home.format.generic", parent: home)
                try driver.visible(["home.format.cancel", "home.format.create"], in: format)
                try await driver.click("home.format.generic", in: format)
                try await driver.wait("actual Generic format selected") { driver.text("home.format.generic", in: format) == "selected" }
                try driver.capture("new-format", target: format)
                try await driver.click("home.format.create", in: format)
            }
            try await driver.saveFile(package, in: home, returnsToParent: false)
            let document = try await opened(package, driver: driver)
            ownedDocuments.append(document)
            guard let window = document.windowControllers.first?.window else { throw GateBlocked("The new document has no native window.") }
            window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil)
            let editor = document.editorViewModel
            guard let originalID = ProjectIdentity.existingUUID(for: package) else { throw GateBlocked("Native New did not persist its actual project identity.") }
            guard editor.declaredPluginBinding == nil, editor.declaredProductionContract == nil, !editor.hasProductionPipeline,
                  editor.timeline.tracks.isEmpty else { throw GateBlocked("Native Generic New silently enrolled production or reused project content.") }
            try await settings(editor: editor, window: window, driver: driver)
            try await driver.menu("project.settings.Aspect Ratio", title: "9:16", in: window)
            try await driver.wait("native portrait aspect") { editor.timeline.width == 1080 && editor.timeline.height == 1920 }
            try await driver.menu("project.settings.Resolution", title: "720p", in: window)
            try await driver.wait("native portrait resolution") { editor.timeline.width == 720 && editor.timeline.height == 1280 }
            try await driver.menu("project.settings.Frame Rate", title: "25 fps", in: window)
            try await driver.wait("native project timebase") { editor.timeline.fps == 25 && editor.timeline.settingsConfigured }
            try driver.capture("project-settings", target: window)
            let editing = try await NativeEditingOwnerAcceptance.run(editor: editor, window: window, directory: directory, driver: driver)
            let beforeFPS = editor.timeline
            try await settings(editor: editor, window: window, driver: driver)
            try await driver.menu("project.settings.Frame Rate", title: "30 fps", in: window)
            try await driver.wait("actual populated timeline FPS change") { editor.timeline.fps == 30 && editor.timeline.totalFrames == 150 }
            let changedFPS = editor.timeline
            guard Double(changedFPS.totalFrames) / 30 == Double(beforeFPS.totalFrames) / 25 else { throw GateBlocked("FPS change altered the film duration.") }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("project FPS Undo exact timeline") { editor.timeline == beforeFPS }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("project FPS Redo exact timeline") { editor.timeline == changedFPS }
            let viewing = try await AppViewOwnerAcceptance.run(editor: editor, window: window, driver: driver)
            let help = try await AppHelpOwnerAcceptance.run(editor: editor, window: window, driver: driver)
            let movie = try await exportPortrait(editor: editor, window: window, directory: directory, driver: driver)
            let savedTimeline = editor.timeline, savedSHA = try ExportArtwork.timelineHash(savedTimeline)
            guard let editorViewport = window.contentView?.bounds.size, editorViewport == NSSize(width: 960, height: 640) else { throw GateBlocked("The actual editor viewport changed.") }
            guard document.isDocumentEdited,
                  try readTimeline(package) != savedTimeline else { throw GateBlocked("The native Save case has no actual unsaved mutation.") }
            let assets = try mediaHashes(editor)
            try await AppNativeMenuAcceptance.choose(["File", "Save"], in: window, driver: driver)
            try await driver.wait("native File Save", seconds: 30) { !document.isDocumentEdited && (try? readTimeline(package)) == savedTimeline }
            let originalBytes = try FileDigest.sha256(of: package.appendingPathComponent(Project.timelineFilename))
            try await AppNativeMenuAcceptance.choose(["File", "Save As…"], in: window, driver: driver)
            try await driver.saveFile(copy, in: window)
            try await driver.wait("native Save As completes", seconds: 30) { same(document.fileURL, copy) && !document.isDocumentEdited }
            guard let copyID = ProjectIdentity.existingUUID(for: copy) else { throw GateBlocked("Native Save As did not persist its independent identity.") }
            guard copyID != originalID, try readTimeline(copy) == savedTimeline,
                  try mediaHashes(editor) == assets, try FileDigest.sha256(of: package.appendingPathComponent(Project.timelineFilename)) == originalBytes else {
                throw GateBlocked("Save As failed to fork project identity while preserving original bytes and media bindings.")
            }
            try await AppNativeMenuAcceptance.close(window, driver: driver)
            try await driver.wait("closed document returns to Home") { home.isVisible && home.isKeyWindow }
            try await AppNativeMenuAcceptance.choose(["File", "Open…"], in: home, driver: driver)
            try await driver.chooseFile(package, in: home, trigger: nil, returnsToParent: false)
            let original = try await opened(package, driver: driver); ownedDocuments.append(original)
            guard original !== document, original.editorViewModel.timeline == savedTimeline,
                  ProjectIdentity.existingUUID(for: package) == originalID, try mediaHashes(original.editorViewModel) == assets,
                  let originalWindow = original.windowControllers.first?.window else { throw GateBlocked("File Open did not restore the independent original document.") }
            try driver.capture("file-open-original", target: originalWindow)
            try await AppNativeMenuAcceptance.close(originalWindow, driver: driver)
            try await driver.wait("Home after original close") { home.isKeyWindow }
            try await driver.chooseFile(copy, in: home, trigger: "home.open", returnsToParent: false)
            let reopened = try await opened(copy, driver: driver); ownedDocuments.append(reopened)
            guard reopened.editorViewModel.timeline == savedTimeline, try mediaHashes(reopened.editorViewModel) == assets,
                  ProjectIdentity.existingUUID(for: copy) == copyID, let copyWindow = reopened.windowControllers.first?.window else {
                throw GateBlocked("The copied project did not retain its own identity and media on native reopen.")
            }
            try await AppNativeMenuAcceptance.close(copyWindow, driver: driver)
            try await driver.wait("Home after copy close") { home.isKeyWindow }
            guard let entry = ProjectRegistry.shared.sortedEntries.first(where: { same($0.url, copy) }) else { throw GateBlocked("The native copy was not registered in Recent Projects.") }
            let id = "home.project." + entry.id.uuidString
            try await driver.contextMenu(id, path: ["Reveal in Finder"], in: home)
            try await AppNativeMenuAcceptance.requireFinderSelection(copy, driver: driver)
            try await driver.wait("native return from Finder") { home.isKeyWindow }
            try await driver.click(id, in: home)
            let recent = try await opened(copy, driver: driver); ownedDocuments.append(recent)
            guard recent.editorViewModel.timeline == savedTimeline, try mediaHashes(recent.editorViewModel) == assets,
                  let recentWindow = recent.windowControllers.first?.window else { throw GateBlocked("The Recent Projects card opened a different project.") }
            try await AppNativeMenuAcceptance.close(recentWindow, driver: driver)
            try await driver.wait("Home after Recent Projects") { home.isKeyWindow }
            try await driver.contextMenu(id, path: ["Delete Project"], in: home)
            try await driver.wait("actual delete confirmation") { home.attachedSheet != nil }
            guard let alert = home.attachedSheet else { throw GateBlocked("Delete Project skipped confirmation.") }
            try driver.capture("delete-confirmation", target: alert)
            try AppNativeMenuAcceptance.accessibilityClick("Cancel", in: alert, driver: driver)
            try await driver.wait("cancel project deletion") { home.attachedSheet == nil && home.isKeyWindow }
            guard FileManager.default.fileExists(atPath: copy.path), ProjectIdentity.existingUUID(for: copy) == copyID else {
                throw GateBlocked("Cancelled Delete changed project bytes.")
            }
            try await driver.contextMenu(id, path: ["Remove from Recents"], in: home)
            try await driver.wait("remove recent entry only") { !ProjectRegistry.shared.entries.contains(where: { same($0.url, copy) }) }
            guard FileManager.default.fileExists(atPath: copy.path), try readTimeline(copy) == savedTimeline else { throw GateBlocked("Remove from Recents deleted or changed the actual project.") }
            try driver.capture("recent-removed-file-preserved", target: home)
            try await driver.chooseFile(copy, in: home, trigger: "home.open", returnsToParent: false)
            let disposable = try await opened(copy, driver: driver); ownedDocuments.append(disposable)
            guard let disposableWindow = disposable.windowControllers.first?.window,
                  ProjectIdentity.existingUUID(for: copy) == copyID else { throw GateBlocked("The disposable delete target changed identity.") }
            try await AppNativeMenuAcceptance.close(disposableWindow, driver: driver)
            try await driver.wait("Home before explicit copy deletion") { home.isKeyWindow }
            guard let disposableEntry = ProjectRegistry.shared.entries.first(where: { same($0.url, copy) }) else { throw GateBlocked("The disposable copy is not in Recents.") }
            try await driver.contextMenu("home.project." + disposableEntry.id.uuidString, path: ["Delete Project"], in: home)
            try await driver.wait("actual disposable delete confirmation") { home.attachedSheet != nil }
            guard let delete = home.attachedSheet else { throw GateBlocked("The disposable copy deletion skipped confirmation.") }
            try AppNativeMenuAcceptance.accessibilityClick("Delete", in: delete, driver: driver)
            try await driver.wait("native copy moved out of original location", seconds: 30) {
                !FileManager.default.fileExists(atPath: copy.path) && !ProjectRegistry.shared.entries.contains(where: { same($0.url, copy) })
            }
            let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: directory, create: false)
            let trashed = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
                .filter { ProjectIdentity.existingUUID(for: $0) == copyID }
            guard trashed.count == 1, let trashedCopy = trashed.first, try readTimeline(trashedCopy) == savedTimeline,
                  ProjectIdentity.existingUUID(for: package) == originalID,
                  try FileDigest.sha256(of: package.appendingPathComponent(Project.timelineFilename)) == originalBytes else {
                throw GateBlocked("Confirmed Delete did not preserve the exact copy in Trash and leave the original intact.")
            }
            try driver.record("native-project-persistence", fields: ["newID": originalID, "saveAsID": copyID,
                "originalTimelineSHA256": originalBytes, "originalPreserved": true, "copyReadbackEqual": true,
                "removedRecentFilePreserved": true, "confirmedCopyInTrash": true])
            var result = driver.result()
            result.merge(["scale": scale, "viewport": [editorViewport.width, editorViewport.height], "nativeNewCancelAndCreate": true,
                "nativeSaveAsIndependentIdentity": true, "nativeFileAndHomeOpen": true,
                "recentRemovalPreservesFile": true, "deleteCancelPreservesFile": true, "confirmedDeleteMovesExactCopyToTrash": true,
                "nativeRecentOpen": true, "finderExactProjectSelection": true,
                "homeViewport": [home.contentView?.bounds.width ?? 0, home.contentView?.bounds.height ?? 0],
                "projectSettingsAndFPSUndo": true, "genericWithoutPipeline": true,
                "originalID": originalID, "copyID": copyID,
                "timelineSHA256": savedSHA, "mediaHashes": assets, "editing": editing, "viewing": viewing,
                "help": help, "portraitExport": movie]) { _, new in new }
            return result
        } catch { driver.failure(error); throw error }
    }

    private static func settings(editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await NativeEditingOwnerAcceptance.workspace(.production, editor: editor, window: window, driver: driver)
        try await driver.click("project.settings.open", in: window)
        try await driver.wait("actual project settings without enrollment") { editor.cockpitTab == .project && !editor.hasProductionPipeline }
        try driver.visible(["project.settings.Resolution", "project.settings.Frame Rate", "project.settings.Aspect Ratio"], in: window)
    }

    private static func opened(_ url: URL, driver: ProductionVisualSourcesDriver) async throws -> VideoProject {
        try await driver.wait("native document opens " + url.lastPathComponent, seconds: 30) {
            guard let document = AppState.shared.activeProject else { return false }
            return same(document.fileURL, url) && document.windowControllers.contains { $0.window?.isKeyWindow == true }
        }
        guard let document = AppState.shared.activeProject, same(document.fileURL, url) else { throw GateBlocked("The active document identity changed.") }
        return document
    }

    private static func exportPortrait(editor: EditorViewModel, window: NSWindow, directory: URL,
                                       driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        try await NativeEditingOwnerAcceptance.workspace(.export, editor: editor, window: window, driver: driver)
        let destination = directory.appendingPathComponent("Portrait 30fps.mp4")
        try await driver.click("export.start", in: window)
        try await driver.saveFile(destination, in: window)
        try await driver.wait("actual portrait export", seconds: 90) { ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).first?.status.isTerminal == true }
        guard let job = ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).first, job.status == .completed,
              same(job.destinationURL, destination), let home = editor.workingRoot else { throw GateBlocked("Portrait export did not finish at the selected destination.") }
        let receipt = try PipelineDeliveryStore.loadAttempt(id: job.id, dataRoot: ExportDataRoot.resolve(in: home))
        guard receipt.probeQC?.passed == true else { throw GateBlocked("Portrait export has no passing actual media QC.") }
        let observed = try await Task.detached {
            let asset = AVURLAsset(url: destination)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw GateBlocked("Portrait output has no video track.") }
            let size = try await video.load(.naturalSize), fps = try await video.load(.nominalFrameRate)
            let reader = try AVAssetReader(asset: asset)
            let samples = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]); reader.add(samples)
            guard reader.startReading() else { throw reader.error ?? GateBlocked("Portrait output cannot be read.") }
            var count = 0
            while let sample = samples.copyNextSampleBuffer() {
                guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: CMTimeValue(count), timescale: 30)) == 0 else {
                    throw GateBlocked("Portrait output has the wrong presentation clock.")
                }
                count += 1
            }
            guard reader.status == .completed, count == 150, size == CGSize(width: 720, height: 1280), fps == 30 else {
                throw GateBlocked("Portrait dimensions, FPS or frame count do not match native project settings.")
            }
            return count
        }.value
        try await driver.reveal("export.qc", in: window)
        try await driver.wait("visible portrait QC") { driver.text("export.qc", in: window) == "passed" }
        try driver.capture("portrait-export-qc", target: window)
        return ["file": destination.lastPathComponent, "sha256": try FileDigest.sha256(of: destination),
            "width": 720, "height": 1280, "fps": 30, "frames": observed, "qc": true]
    }

    private static func mediaHashes(_ editor: EditorViewModel) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: editor.mediaAssets.map { asset in
            guard let url = editor.mediaResolver.resolveURL(for: asset.id) else { throw GateBlocked("A saved media binding is unresolved.") }
            return (asset.id, try FileDigest.sha256(of: url))
        })
    }

    private static func readTimeline(_ url: URL) throws -> Timeline {
        try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: url.appendingPathComponent(Project.timelineFilename)))
    }

    private static func same(_ left: URL?, _ right: URL) -> Bool {
        left?.standardizedFileURL.resolvingSymlinksInPath().path == right.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
