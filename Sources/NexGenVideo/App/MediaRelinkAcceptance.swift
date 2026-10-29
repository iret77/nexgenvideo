import AppKit
import NexGenEngine

@MainActor
enum MediaRelinkAcceptance {
    static func run(savedProject: URL, sources: URL, output: URL, scale: Double) async throws -> [String: Any] {
        let name = "media-relink-\(Int(scale * 100))"
        let package = output.appendingPathComponent(name + ".ngv", isDirectory: true)
        let originalManifest = try Data(contentsOf: savedProject.appendingPathComponent(Project.manifestFilename))
        let originalTimeline = try Data(contentsOf: savedProject.appendingPathComponent(Project.timelineFilename))
        try FileManager.default.copyItem(at: savedProject, to: package)
        let identity = try ProjectIdentity.regenerate(at: package)
        let manifestURL = package.appendingPathComponent(Project.manifestFilename)
        var manifest = try JSONDecoder().decode(MediaManifest.self, from: originalManifest)
        let names: Set<String> = ["Original.mov", "Ambience.wav", "Reference.png"]
        var ids: [String: String] = [:]
        for index in manifest.entries.indices {
            guard let filename = manifest.entries[index].originalFilename, names.contains(filename) else { continue }
            let missing = output.appendingPathComponent(name + "-offline").appendingPathComponent(filename)
            guard !FileManager.default.fileExists(atPath: missing.path) else { throw GateBlocked("The offline media fixture already exists.") }
            manifest.entries[index].source = .external(absolutePath: missing.path)
            ids[filename] = manifest.entries[index].id
        }
        guard ids.count == 3, let videoID = ids["Original.mov"], let imageID = ids["Reference.png"] else {
            throw GateBlocked("Relink needs three real imported media sources.")
        }
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        let ambiguous = output.appendingPathComponent(name + "-ambiguous", isDirectory: true)
        for directory in ["One", "Two"] {
            let location = ambiguous.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sources.appendingPathComponent("Original.mov"), to: location.appendingPathComponent("Original.mov"))
        }
        let document = try await VideoProject.load(from: package)
        document.makeWindowControllers()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The offline library window did not open.") }
        document.showWindows()
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        window.setContentSize(NSSize(width: 960, height: 640))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var closed = false
        defer { if !closed { document.close() } }
        func select(_ id: String) async throws {
            try await driver.click("media.asset." + id, in: window)
            try await driver.wait("visible offline source " + id) {
                editor.selectedMediaAssetIds == [id] && driver.state("preview.relink.file." + id, in: window) == true
            }
        }
        do {
            try await driver.click("editor.workspace.edit", in: window, enabled: false)
            try await driver.wait("offline edit workspace") { editor.workspaceFocus == .edit }
            try await driver.menu("media.menu.View", title: MediaBrowserViewMode.flat.title, in: window)
            try await driver.wait("three offline original sources") { ids.values.allSatisfy { editor.isMediaOffline($0) } }
            let timeline = editor.timeline
            try await select(videoID)
            try driver.capture("offline-source", target: window)
            try await driver.chooseFile(nil, in: window, trigger: "preview.relink.file." + videoID)
            guard editor.mediaManifest == manifest, editor.timeline == timeline else { throw GateBlocked("Cancelled Relink changed the project.") }
            try await driver.chooseFile(sources.appendingPathComponent("Brief.txt"), in: window, trigger: "preview.relink.file." + videoID)
            try await driver.wait("visible incompatible source refusal") {
                driver.text("media.toast", in: window)?.contains("Choose a supported video file") == true
            }
            guard editor.mediaManifest == manifest else { throw GateBlocked("Relink accepted a document for a video.") }
            try driver.capture("incompatible-source", target: window)
            try await driver.chooseFile(ambiguous, in: window, trigger: "preview.relink.folder")
            try await driver.wait("visible ambiguous filename refusal") {
                driver.text("media.toast", in: window)?.contains("Multiple files match Original.mov") == true
            }
            guard editor.mediaManifest == manifest, editor.timeline == timeline else {
                throw GateBlocked("Folder Relink silently chose one of several same-named sources.")
            }
            try driver.capture("ambiguous-folder", target: window)
            try await driver.chooseFile(sources.appendingPathComponent("Original.mov"), in: window, trigger: "preview.relink.file." + videoID)
            try await driver.wait("native single-file relink") {
                !editor.isMediaOffline(videoID) && editor.mediaAssets.first(where: { $0.id == videoID })?.userFacingFilename == "Original.mov"
            }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("native relink undo") { editor.mediaManifest == manifest && editor.isMediaOffline(videoID) }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("native relink redo") { !editor.isMediaOffline(videoID) }
            try await select(imageID)
            try await driver.chooseFile(sources, in: window, trigger: "preview.relink.folder")
            try await driver.wait("native unique folder relink") { ids.values.allSatisfy { !editor.isMediaOffline($0) } }
            guard editor.timeline == timeline, Set(editor.mediaAssets.map(\.id)) == Set(manifest.entries.map(\.id)),
                  let home = editor.workingRoot else { throw GateBlocked("Relink replaced an asset or a timeline clip instance.") }
            for (filename, id) in ids {
                guard let asset = editor.mediaAssets.first(where: { $0.id == id }),
                      asset.url.path.hasPrefix(home.path + "/media/"),
                      asset.userFacingFilename == filename,
                      try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: sources.appendingPathComponent(filename)) else {
                    throw GateBlocked("Relink did not preserve the exact chosen source: " + filename)
                }
            }
            try driver.capture("all-relinked", target: window)
            let recovered = editor.mediaManifest
            guard document.isDocumentEdited else { throw GateBlocked("Relink did not mark the project unsaved.") }
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("save relinked sources", seconds: 30) {
                guard !document.isDocumentEdited, let data = try? Data(contentsOf: manifestURL),
                      let saved = try? JSONDecoder().decode(MediaManifest.self, from: data) else { return false }
                return saved == recovered
            }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package)
            reopened.makeWindowControllers()
            defer { reopened.close() }
            guard reopened.editorViewModel.mediaManifest == recovered, reopened.editorViewModel.timeline == timeline,
                  let reopenedHome = reopened.editorViewModel.workingRoot, ProjectIdentity.existingUUID(for: reopenedHome) == identity,
                  try Data(contentsOf: savedProject.appendingPathComponent(Project.manifestFilename)) == originalManifest,
                  try Data(contentsOf: savedProject.appendingPathComponent(Project.timelineFilename)) == originalTimeline else {
                throw GateBlocked("Relink did not survive reopen or changed the original project.")
            }
            for (filename, id) in ids {
                guard let url = reopened.editorViewModel.mediaResolver.resolveURL(for: id),
                      try FileDigest.sha256(of: url) == FileDigest.sha256(of: sources.appendingPathComponent(filename)) else {
                    throw GateBlocked("Relinked source bytes did not survive Save and reopen.")
                }
            }
            var result = driver.result()
            result.merge(["cancelPreservedBindings": true, "incompatibleSourceRejected": true, "ambiguousFolderRejected": true,
                "nativeFileUndoRedo": true, "nativeFolderRelink": true, "identitiesAndTimelinePreserved": true,
                "exactSourceBytes": true, "nativeSaveAndReopen": true, "originalProjectPreserved": true]) { _, new in new }
            return result
        } catch { driver.failure(error); throw error }
    }
}
