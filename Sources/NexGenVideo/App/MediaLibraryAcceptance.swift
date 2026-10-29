import AppKit
import NexGenEngine

@MainActor
enum MediaLibraryAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "media-library-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        let package = directory.appendingPathComponent("Library.ngv", isDirectory: true)
        let incoming = directory.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        var empty = Timeline()
        empty.width = 320; empty.height = 180; empty.fps = 30; empty.settingsConfigured = true
        try JSONEncoder().encode(empty).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        try await FullflowAcceptanceFixture.writeVideo(to: incoming.appendingPathComponent("Original.mov"), duration: 2, fps: 30, warm: true)
        try FullflowAcceptanceFixture.writeTone(to: incoming.appendingPathComponent("Ambience.wav"), duration: 2)
        try FullflowAcceptanceFixture.writeReference(to: incoming.appendingPathComponent("Reference.png"))
        try Data("An independently imported source document.\n".utf8).write(to: incoming.appendingPathComponent("Brief.txt"))
        try Data("1\n00:00:00,200 --> 00:00:01,200\nActual caption source\n".utf8).write(to: incoming.appendingPathComponent("Captions.srt"))
        let animation = ##"{"v":"5.7.0","fr":30,"ip":0,"op":30,"w":100,"h":100,"assets":[],"layers":[{"ind":1,"ty":1,"nm":"red","sr":1,"sw":50,"sh":50,"sc":"#ff0000","ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[25,25,0]},"a":{"a":0,"k":[25,25,0]},"s":{"a":0,"k":[100,100,100]}},"ip":0,"op":30,"st":0,"bm":0}]}"##
        try Data(animation.utf8).write(to: incoming.appendingPathComponent("Motion.json"))
        let expected: [String: ClipType] = ["Original.mov": .video, "Ambience.wav": .audio, "Reference.png": .image,
            "Brief.txt": .document, "Captions.srt": .subtitle, "Motion.json": .lottie]
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The media library window did not open.") }
        document.showWindows()
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        window.setContentSize(NSSize(width: 960, height: 640))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var closed = false
        defer { if !closed { document.close() } }
        func workspace(_ focus: EditorViewModel.WorkspaceFocus) async throws {
            try await driver.click("editor.workspace." + focus.rawValue, in: window, enabled: false)
            try await driver.wait("library workspace " + focus.rawValue) { editor.workspaceFocus == focus }
        }
        func mode(_ mode: MediaBrowserViewMode) async throws {
            try await driver.menu("media.menu.View", title: mode.title, in: window)
            try await driver.wait("native media view " + mode.title) { editor.mediaBrowserState(for: .media).viewMode == mode }
        }
        func undo(_ label: String, until condition: @escaping @MainActor () -> Bool) async throws {
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait(label, condition)
        }
        func createFolder(_ name: String, parent: String?) async throws -> String {
            let previous = Set(editor.folders.map(\.id))
            try await driver.click("media.action.New Folder", in: window)
            try await driver.wait("native new folder") { editor.folders.count == previous.count + 1 }
            guard let folder = editor.folders.first(where: { !previous.contains($0.id) }), folder.parentFolderId == parent else {
                throw GateBlocked("New Folder used the wrong library location.")
            }
            try await driver.fill("media.folder-rename." + folder.id, value: name, in: window, requireFocusExit: true)
            try await driver.wait("native folder name") { editor.folder(id: folder.id)?.name == name }
            return folder.id
        }
        do {
            try await workspace(.media)
            try await driver.chooseFile(nil, in: window, trigger: "media.action.Import")
            guard editor.mediaAssets.isEmpty, editor.timeline == empty else { throw GateBlocked("Cancelled import changed the library.") }
            try await driver.chooseFile(incoming, in: window, trigger: "media.action.Import")
            try await driver.wait("native folder import", seconds: 45) { editor.mediaAssets.count == 6 && editor.mediaImportProgress == nil }
            var sources: [[String: String]] = []
            for (filename, type) in expected {
                let matches = editor.mediaAssets.filter { $0.userFacingFilename == filename }
                guard matches.count == 1, let asset = matches.first, asset.type == type,
                      let imported = editor.mediaResolver.resolveURL(for: asset.id),
                      try FileDigest.sha256(of: imported) == FileDigest.sha256(of: incoming.appendingPathComponent(filename)) else {
                    throw GateBlocked("Folder import changed bytes, type or readable filename: " + filename)
                }
                sources.append(["id": asset.id, "filename": filename, "type": type.rawValue, "sha256": try FileDigest.sha256(of: imported)])
            }
            guard editor.timeline == empty, editor.folders.filter({ $0.name == "Incoming" }).count == 1,
                  let video = editor.mediaAssets.first(where: { $0.userFacingFilename == "Original.mov" }),
                  let sourceDocument = editor.mediaAssets.first(where: { $0.type == .document }) else {
                throw GateBlocked("Import did not preserve the folder or inserted media into the timeline.")
            }
            try await mode(.flat)
            try driver.capture("six-file-types", target: window)
            try await driver.click("media.asset." + sourceDocument.id, in: window)
            try await driver.wait("actual document source selection") { editor.selectedMediaAssetIds == [sourceDocument.id] }
            guard driver.state("source.insert." + sourceDocument.id, in: window) != true,
                  editor.timeline == empty else { throw GateBlocked("Source documents must not be inserted as timeline clips.") }
            try await driver.contextMenu("media.asset." + video.id, path: ["Rename"], in: window)
            try await driver.fill("media.rename." + video.id, value: "Opening movement", in: window, requireFocusExit: true)
            try await driver.wait("native asset rename") { video.libraryDisplayName == "Opening movement" }
            guard video.userFacingFilename == "Original.mov", editor.mediaManifest.entries.first(where: { $0.id == video.id })?.name == "Opening movement" else {
                throw GateBlocked("Renaming confused the displayed title with the original filename.")
            }
            try await undo("native asset rename undo") { video.libraryDisplayName != "Opening movement" }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("native asset rename redo") { video.libraryDisplayName == "Opening movement" }
            try await driver.contextMenu("media.asset." + video.id, path: ["Copy Path"], in: window)
            guard NSPasteboard.general.string(forType: .string) == video.url.path else { throw GateBlocked("Copy Path did not copy the actual selected media path.") }
            try await driver.fill("media.search", value: "Original.mov", in: window)
            try await driver.wait("native original filename search") { driver.text("media.item-count", in: window) == "1" }
            try driver.capture("original-filename-search", target: window)
            try await driver.fill("media.search", value: "", in: window)
            try await driver.menu("media.menu.Filter", title: "Image", in: window)
            try await driver.wait("native type filter") { driver.text("media.item-count", in: window) == "1" && editor.mediaBrowserState(for: .media).filterTypes == [.image] }
            try driver.capture("image-filter", target: window)
            try await driver.menu("media.menu.Filter", title: "Clear Filters", in: window)
            try await driver.wait("clear native filter") { driver.text("media.item-count", in: window) == "6" }
            try await driver.click("media.asset." + video.id, in: window)
            try driver.pressKey(0, characters: "a", modifiers: .command, in: window)
            try await driver.wait("native select all library assets") { editor.selectedMediaAssetIds == Set(editor.mediaAssets.map(\.id)) }
            try driver.capture("select-all", target: window)
            try await workspace(.edit)
            try await driver.click("media.asset." + video.id, in: window)
            try await driver.wait("native video source ready") { driver.state("source.insert." + video.id, in: window) == true }
            try await driver.click("source.insert." + video.id, in: window)
            try await driver.wait("library asset inserted through source controls") { editor.timeline.tracks.flatMap(\.clips).count == 1 }
            let inserted = editor.timeline
            guard inserted.tracks.flatMap(\.clips).first?.mediaRef == video.id else { throw GateBlocked("The source inserted a different asset.") }
            try await workspace(.media)
            try await mode(.flat)
            try await driver.click("media.asset." + video.id, in: window)
            try await driver.wait("single used asset selection") { editor.selectedMediaAssetIds == [video.id] }
            try await driver.contextMenu("media.asset." + video.id, path: ["Delete"], in: window)
            try await driver.wait("native used asset removal") { !editor.mediaAssets.contains(where: { $0.id == video.id }) && editor.timeline.tracks.flatMap(\.clips).isEmpty }
            try await undo("native used asset deletion undo") { editor.timeline == inserted && editor.mediaAssets.contains(where: { $0.id == video.id }) }
            try await driver.click("media.breadcrumb.__root__", in: window)
            let archive = try await createFolder("Archive", parent: nil)
            try await driver.contextMenu("media.folder-tile." + archive, path: ["Open"], in: window)
            try await driver.wait("native folder open") { editor.mediaBrowserState(for: .media).currentFolderId == archive }
            let nested = try await createFolder("Selected", parent: archive)
            try await mode(.flat)
            try await driver.contextMenu("media.asset." + video.id, path: ["Move to Folder", "Selected"], in: window)
            try await driver.wait("native asset move") { editor.mediaAssets.first(where: { $0.id == video.id })?.folderId == nested }
            try await driver.click("media.breadcrumb.__root__", in: window)
            try await mode(.folder)
            let organized = editor.mediaManifest
            try driver.capture("nested-folders", target: window)
            try await driver.contextMenu("media.folder-tile." + archive, path: ["Delete"], in: window)
            try await driver.wait("native recursive folder deletion") {
                editor.folder(id: archive) == nil && editor.folder(id: nested) == nil
                    && !editor.mediaAssets.contains(where: { $0.id == video.id }) && editor.timeline.tracks.flatMap(\.clips).isEmpty
            }
            try await undo("native recursive deletion undo") { editor.mediaManifest == organized && editor.timeline == inserted }
            try driver.capture("folder-delete-undo", target: window)
            guard document.isDocumentEdited else { throw GateBlocked("The native library edits did not mark the document unsaved.") }
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("native media library save", seconds: 30) {
                guard !document.isDocumentEdited,
                      let bytes = try? Data(contentsOf: package.appendingPathComponent(Project.manifestFilename)),
                      let saved = try? JSONDecoder().decode(MediaManifest.self, from: bytes) else { return false }
                return saved == organized
            }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
            NSDocumentController.shared.addDocument(reopened)
            reopened.makeWindowControllers()
            defer { reopened.close() }
            guard reopened.editorViewModel.mediaManifest == organized, reopened.editorViewModel.timeline == inserted else {
                throw GateBlocked("Native library names, folders or clip identities did not survive Save and reopen.")
            }
            let relink = try await MediaRelinkAcceptance.run(savedProject: package, sources: incoming, output: output, scale: scale)
            let organization = try await MediaOrganizationAcceptance.run(savedProject: package, output: output, scale: scale)
            var result = driver.result()
            result["nativeRelink"] = relink
            result["nativeOrganization"] = organization
            result["screenshots"] = driver.screenshots + (relink["screenshots"] as? [String] ?? []) + (organization["screenshots"] as? [String] ?? [])
            result.merge(["scale": scale, "viewport": [960, 640], "sources": sources.sorted { $0["filename"]! < $1["filename"]! },
                "nativeFolderImport": true, "cancelPreservedLibrary": true, "importDidNotInsert": true,
                "documentNotPlaceable": true, "nativeRenameUndoRedo": true, "originalFilenamePreserved": true,
                "nativeCopyPath": true, "nativeSearchAndFilter": true, "nativeSelectAll": true,
                "nativeUsedDeleteUndo": true, "nativeNestedMoveDeleteUndo": true, "nativeSaveAndReopen": true]) { _, new in new }
            return result
        } catch { driver.failure(error); throw error }
    }
}
