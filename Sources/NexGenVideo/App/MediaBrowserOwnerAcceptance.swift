import AppKit
import NexGenEngine

@MainActor
enum MediaBrowserOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "media-browser-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        let package = directory.appendingPathComponent("Browser.ngv", isDirectory: true)
        let incoming = directory.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        var initial = Timeline(); initial.width = 320; initial.height = 180; initial.fps = 30; initial.settingsConfigured = true
        try JSONEncoder().encode(initial).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        try await FullflowAcceptanceFixture.writeVideo(to: incoming.appendingPathComponent("A.mov"), duration: 4, fps: 30, warm: true)
        try await FullflowAcceptanceFixture.writeVideo(to: incoming.appendingPathComponent("B.mov"), duration: 3, fps: 30, warm: false)
        try FullflowAcceptanceFixture.writeTone(to: incoming.appendingPathComponent("C.wav"), duration: 2)
        try FullflowAcceptanceFixture.writeReference(to: incoming.appendingPathComponent("D.png"))
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The media browser did not open.") }
        window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = MainMenuBuilder.buildMenu(); NSApp.activate(ignoringOtherApps: true)
        defer { document.close() }
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        let spec = VisualEmbedder.Spec(model: "native-search-fixture", version: 1, embeddingDim: 2, imageSize: 2, contextLength: 4)
        editor.searchIndex.queryEncoderOverride = .init(spec: spec, encode: { _ in [1, 0] })
        func workspace(_ value: EditorViewModel.WorkspaceFocus) async throws {
            try await driver.click("editor.workspace." + value.rawValue, in: window, enabled: false)
            try await driver.wait("media browser workspace") { editor.workspaceFocus == value }
        }
        func view(_ value: MediaBrowserViewMode) async throws {
            try await driver.menu("media.menu.View", title: value.title, in: window)
            try await driver.wait("media browser layout") { editor.mediaBrowserState(for: editor.workspaceFocus).viewMode == value }
        }
        func selection(_ ids: Set<String>, label: String) async throws {
            try await driver.wait(label) { editor.selectedMediaAssetIds == ids }
            try driver.record(label, fields: ["ids": editor.selectedMediaAssetIds.sorted(), "filenames": editor.mediaAssets.filter { ids.contains($0.id) }.map(\.userFacingFilename).sorted()])
        }
        do {
            try await driver.wait("actual media browser viewport and interface scale") {
                window.contentView?.bounds.size == NSSize(width: 960, height: 640)
                    && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
            }
            try await workspace(.media)
            try await driver.chooseFile(incoming, in: window, trigger: "media.action.Import")
            try await driver.wait("browser actual import", seconds: 45) { editor.mediaAssets.count == 4 && editor.mediaImportProgress == nil }
            func asset(_ name: String) throws -> MediaAsset {
                guard let value = editor.mediaAssets.first(where: { $0.userFacingFilename == name }) else { throw GateBlocked("Missing imported media: " + name) }
                return value
            }
            let a = try asset("A.mov"), b = try asset("B.mov"), c = try asset("C.wav"), d = try asset("D.png")
            guard abs(a.duration - 4) < 1 / 30.0, abs(b.duration - 3) < 1 / 30.0,
                  abs(c.duration - 2) < 1 / 48_000.0, d.duration == 5,
                  a.type == .video, b.type == .video, c.type == .audio, d.type == .image,
                  !a.hasAudio, !b.hasAudio else { throw GateBlocked("The imported browser fixtures have unexpected real media properties.") }
            try driver.visible(["media.menu.View", "media.menu.Sort", "media.menu.Filter"], in: window)
            try await view(.list)
            try await driver.menu("media.menu.Sort", title: "Name", in: window)
            try await driver.wait("literal name order") { editor.mediaPanelOrderedItemIds == [a.id, b.id, c.id, d.id] }
            try driver.record("name order", fields: ["ids": editor.mediaPanelOrderedItemIds])
            try await driver.click("media.asset." + a.id, in: window)
            try await driver.modifiedClick("media.asset." + c.id, modifiers: .command, in: window)
            try await selection([a.id, c.id], label: "command selection")
            try await driver.modifiedClick("media.asset." + a.id, modifiers: .command, in: window)
            try await selection([c.id], label: "command deselection")
            try await driver.click("media.asset." + a.id, in: window)
            try await driver.modifiedClick("media.asset." + c.id, modifiers: .shift, in: window)
            try await selection([a.id, b.id, c.id], label: "shift range")
            try driver.capture("range-selection", target: window)
            try await driver.menu("media.menu.Filter", title: "Image", in: window)
            try await driver.wait("filtered selection pruned") { editor.mediaPanelOrderedItemIds == [d.id] && editor.selectedMediaAssetIds.isEmpty }
            try driver.record("filtered selection pruned", fields: ["visibleIDs": editor.mediaPanelOrderedItemIds, "selectedIDs": editor.selectedMediaAssetIds.sorted()])
            try await driver.click("media.asset." + d.id, in: window)
            try driver.pressKey(0, characters: "a", modifiers: .command, in: window)
            try await selection([d.id], label: "filtered select all")
            try await driver.menu("media.menu.Filter", title: "AI Generated", in: window)
            try await driver.wait("AI filter excludes imported files") { editor.mediaPanelOrderedItemIds.isEmpty && editor.selectedMediaAssetIds.isEmpty }
            try driver.record("AI filter excludes imported files", fields: ["visibleIDs": editor.mediaPanelOrderedItemIds, "selectedIDs": editor.selectedMediaAssetIds.sorted()])
            try driver.capture("filtered-selection", target: window)
            try await driver.menu("media.menu.Filter", title: "Clear Filters", in: window)
            try await driver.menu("media.menu.Sort", title: "Duration", in: window)
            try await driver.wait("literal duration order") { editor.mediaPanelOrderedItemIds == [d.id, a.id, b.id, c.id] }
            try driver.record("duration order", fields: ["ids": editor.mediaPanelOrderedItemIds])
            try await marquee(first: a.id, last: b.id, ordered: editor.mediaPanelOrderedItemIds, driver: driver, window: window)
            try await selection([a.id, b.id], label: "marquee selection")
            try driver.capture("marquee-selection", target: window)
            try await view(.flat)
            try await driver.menu("media.menu.View", title: "Small", in: window)
            try await driver.reveal("media.asset." + a.id, in: window)
            guard let small = WorkspaceUIAcceptance.probeFrame(identifier: "media.asset." + a.id, in: window) else { throw GateBlocked("No small thumbnail.") }
            try await driver.menu("media.menu.View", title: "Extra Large", in: window)
            try await driver.wait("actual thumbnail size changed") {
                guard let large = WorkspaceUIAcceptance.probeFrame(identifier: "media.asset." + a.id, in: window) else { return false }
                return large.width > small.width && large.height > small.height
            }
            try await driver.reveal("media.asset." + a.id, in: window)
            try driver.visible(["media.asset." + a.id], in: window)
            guard let large = WorkspaceUIAcceptance.probeFrame(identifier: "media.asset." + a.id, in: window) else { throw GateBlocked("No large thumbnail.") }
            try driver.record("thumbnail dimensions", fields: ["id": a.id, "small": rect(small), "large": rect(large)])
            try driver.capture("large-thumbnails", target: window)
            try await driver.menu("media.menu.View", title: "Small", in: window)
            try await groupFolderDrop(a: a, b: b, editor: editor, driver: driver, window: window)
            guard editor.timeline == initial else { throw GateBlocked("Library organization changed the timeline.") }
            let searchCaches = try await prepareSearch(a: a, b: b, image: d, audio: c, spec: spec, output: directory)
            try await workspace(.edit)
            try await driver.fill("media.search", value: "harbor", in: window)
            try await driver.wait("real disk search result") {
                driver.text("media.search.results", in: window) == "settled"
                    && driver.text("media.moment." + a.id + ".1.0", in: window) == "1.0...2.0"
                    && driver.text("media.spoken." + c.id + ".0.5", in: window) == "The harbor lights."
            }
            try await driver.click("media.moment." + a.id + ".1.0", in: window)
            try await driver.wait("moment exact source time") { editor.activePreviewTabId == PreviewTab.mediaAssetTabId(for: a.id) && editor.sourcePlayheadFrame == 30 }
            try driver.record("moment source time", fields: ["filename": "A.mov", "frame": editor.sourcePlayheadFrame])
            try driver.capture("moment-source", target: window)
            try await segmentDrop("media.moment." + a.id + ".1.0", frame: 0, editor: editor, driver: driver, window: window)
            try await driver.wait("actual moment drag") {
                let clips = editor.timeline.tracks.flatMap(\.clips)
                return clips.count == 1 && clips[0].mediaRef == a.id && clips[0].startFrame == 0
                    && clips[0].trimStartFrame == 30 && clips[0].durationFrames == 30
            }
            let momentTimeline = editor.timeline
            try driver.record("moment drop binding", fields: ["clips": clipRows(momentTimeline)])
            try await driver.click("media.spoken." + c.id + ".0.5", in: window)
            try await driver.wait("spoken exact source time") { editor.activePreviewTabId == PreviewTab.mediaAssetTabId(for: c.id) && editor.sourcePlayheadFrame == 15 }
            try driver.record("spoken source time", fields: ["filename": "C.wav", "frame": editor.sourcePlayheadFrame])
            try driver.capture("spoken-source", target: window)
            try await segmentDrop("media.spoken." + c.id + ".0.5", frame: 45, editor: editor, driver: driver, window: window)
            try await driver.wait("actual spoken drag") {
                let clips = editor.timeline.tracks.flatMap(\.clips)
                return clips.count == 2 && clips.contains(where: { $0.mediaRef == c.id && $0.startFrame == 45 && $0.trimStartFrame == 15 && $0.durationFrames == 30 })
                    && clips.contains(momentTimeline.tracks.flatMap(\.clips)[0])
            }
            try driver.capture("segment-timeline", target: window)
            let expectedTimeline = editor.timeline
            try driver.record("spoken drop binding", fields: ["clips": clipRows(expectedTimeline)])
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("segment drop undo") { editor.timeline == momentTimeline }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("segment drop redo") { editor.timeline == expectedTimeline }
            guard document.isDocumentEdited else { throw GateBlocked("The browser Save case has no real unsaved change.") }
            try driver.record("segment undo redo", fields: ["undoClips": clipRows(momentTimeline), "redoClips": clipRows(editor.timeline), "unsaved": document.isDocumentEdited])
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("browser native save", seconds: 30) {
                guard !document.isDocumentEdited, let data = try? Data(contentsOf: package.appendingPathComponent(Project.timelineFilename)),
                      let saved = try? JSONDecoder().decode(Timeline.self, from: data) else { return false }
                return saved == expectedTimeline
            }
            guard let content = window.contentView, let projectID = ProjectIdentity.existingUUID(for: package) else { throw GateBlocked("The saved browser document lost its identity or window.") }
            let manifest = try JSONDecoder().decode(MediaManifest.self, from: Data(contentsOf: package.appendingPathComponent(Project.manifestFilename)))
            guard Set(manifest.entries.map(\.id)) == Set([a.id, b.id, c.id, d.id]),
                  manifest.entries.allSatisfy({ entry in editor.mediaAssets.contains { $0.id == entry.id && $0.folderId == entry.folderId } }) else {
                throw GateBlocked("Native Save did not preserve the actual library and restored folder assignments.")
            }
            let sources: [[String: Any]] = try editor.mediaAssets.map {
                ["id": $0.id, "filename": $0.userFacingFilename, "duration": $0.duration,
                 "type": $0.type.rawValue, "sha256": try FileDigest.sha256(of: $0.url)]
            }
            let saved = ["timelineSHA256": try FileDigest.sha256(of: package.appendingPathComponent(Project.timelineFilename)),
                         "manifestSHA256": try FileDigest.sha256(of: package.appendingPathComponent(Project.manifestFilename))]
            try driver.record("native browser save", fields: ["projectID": projectID, "clips": clipRows(editor.timeline), "hashes": saved])
            var result = driver.result()
            result.merge(["scale": scale, "effectiveScale": AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)),
                          "viewport": [content.bounds.width, content.bounds.height], "backingScale": window.backingScaleFactor,
                          "project": name + "/Browser.ngv", "projectID": projectID, "saved": saved,
                          "isolatedQueryEncoder": true, "isolatedTranscriptInput": true, "liveSearchModel": false,
                          "searchCaches": searchCaches, "sources": sources, "clips": clipRows(editor.timeline),
                          "nativeSelection": true, "nativeFilteredSelection": true, "nativeMarquee": true,
                          "nativeFolderGroupDropUndo": true, "nativeThumbnailResize": true,
                          "nativeMomentSourceAndDrop": true, "nativeSpokenSourceAndDrop": true,
                          "nativeSegmentUndoRedoSave": true]) { _, new in new }
            return result
        } catch { driver.failure(error); throw error }
    }

    private static func marquee(first: String, last: String, ordered: [String], driver: ProductionVisualSourcesDriver, window: NSWindow) async throws {
        try await driver.reveal("media.asset." + first, in: window)
        try await driver.reveal("media.asset." + last, in: window)
        try driver.visible(["media.asset." + first, "media.asset." + last], in: window)
        guard let root = window.contentView,
              let surface = WorkspaceUIAcceptance.findProbe(in: root, identifier: "media.selection-surface") else { throw GateBlocked("Marquee geometry is unavailable.") }
        let frames = Dictionary(uniqueKeysWithValues: ordered.compactMap { id -> (String, NSRect)? in
            guard let view = WorkspaceUIAcceptance.findProbe(in: root, identifier: "media.asset." + id) else { return nil }
            return (id, view.convert(view.bounds, to: surface))
        })
        guard let firstRect = frames[first], let lastRect = frames[last] else { throw GateBlocked("The requested marquee rows are missing.") }
        let leftEdge = min(firstRect.minX, lastRect.minX), minY = min(firstRect.minY, lastRect.minY), maxY = max(firstRect.maxY, lastRect.maxY)
        let start = NSPoint(x: (surface.bounds.minX + leftEdge) / 2, y: minY + 1)
        let end = NSPoint(x: min(firstRect.midX, lastRect.midX), y: maxY - 1)
        let selection = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard leftEdge > surface.bounds.minX, !frames.values.contains(where: { $0.contains(start) }),
              Set(frames.filter { selection.intersects($0.value) }.keys) == Set([first, last]) else {
            throw GateBlocked("The native marquee has no visible empty start or intersects unintended rows.")
        }
        try driver.record("marquee geometry", fields: ["ids": [first, last].sorted(), "first": rect(firstRect), "last": rect(lastRect),
            "start": [start.x, start.y], "end": [end.x, end.y], "selection": rect(selection), "surface": rect(surface.bounds), "emptyStart": true])
        try await driver.dragBetween("media.selection-surface", sourcePoint: start, destination: surface,
                                     point: end, label: "marquee", in: window)
    }

    private static func groupFolderDrop(a: MediaAsset, b: MediaAsset, editor: EditorViewModel,
                                        driver: ProductionVisualSourcesDriver, window: NSWindow) async throws {
        try await driver.menu("media.menu.View", title: "Folders", in: window)
        guard let incoming = editor.folders.first(where: { $0.name == "Incoming" }) else { throw GateBlocked("The imported folder is missing.") }
        if editor.mediaBrowserState(for: .media).currentFolderId != incoming.id {
            try await driver.contextMenu("media.folder-tile." + incoming.id, path: ["Open"], in: window)
        }
        let existing = Set(editor.folders.map(\.id))
        try await driver.click("media.action.New Folder", in: window)
        try await driver.wait("new drop folder") { editor.folders.count == existing.count + 1 }
        guard let folder = editor.folders.first(where: { !existing.contains($0.id) }) else { throw GateBlocked("The drop folder is missing.") }
        try await driver.fill("media.folder-rename." + folder.id, value: "Selected", in: window, requireFocusExit: true)
        try await driver.click("media.asset." + a.id, in: window)
        try await driver.modifiedClick("media.asset." + b.id, modifiers: .command, in: window)
        try await driver.wait("group selected for actual drag") { editor.selectedMediaAssetIds == [a.id, b.id] }
        guard let root = window.contentView,
              let destination = WorkspaceUIAcceptance.findProbe(in: root, identifier: "media.folder-tile." + folder.id) else { throw GateBlocked("The inner folder drop target is missing.") }
        try await driver.dragBetween("media.asset." + a.id, destination: destination,
            point: .init(x: destination.bounds.midX, y: destination.bounds.midY), label: "Selected folder", in: window)
        try await driver.wait("native group folder drop") { a.folderId == folder.id && b.folderId == folder.id }
        try driver.record("group folder drop", fields: ["ids": [a.id, b.id].sorted(), "from": incoming.id, "to": folder.id, "folder": folder.name])
        try driver.capture("group-folder-drop", target: window)
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("one undo restores group folder drop") { a.folderId == incoming.id && b.folderId == incoming.id }
        try driver.record("group folder drop undo", fields: ["ids": [a.id, b.id].sorted(), "restoredFolder": incoming.id, "destinationRetained": editor.folders.contains { $0.id == folder.id }])
    }

    private static func prepareSearch(a: MediaAsset, b: MediaAsset, image: MediaAsset, audio: MediaAsset,
                                      spec: VisualEmbedder.Spec, output: URL) async throws -> [String: [String: String]] {
        let sources = [(a.id, a.url, a.userFacingFilename, false, true), (b.id, b.url, b.userFacingFilename, false, false),
                       (image.id, image.url, image.userFacingFilename, true, false)]
        let audioID = audio.id, audioURL = audio.url
        return try await Task.detached {
            var evidence: [String: [String: String]] = [:]
            for (id, url, filename, isImage, matches) in sources {
                guard let key = EmbeddingStore.key(for: url) else { throw GateBlocked("No actual search source identity.") }
                let row = isImage ? EmbeddingStore.Row(time: 0, shotStart: 0, shotEnd: 0) : EmbeddingStore.Row(time: 1.5, shotStart: 1, shotEnd: 2)
                try EmbeddingStore.save(header: .init(model: spec.model, modelVersion: spec.version,
                    samplerVersion: FrameSampler.samplerVersion, dim: 2, count: 1), rows: [row], vectors: matches ? [1, 0] : [-1, 0], key: key)
                let destination = output.appendingPathComponent(filename + ".embed")
                try FileManager.default.copyItem(at: EmbeddingStore.diskURL(key), to: destination)
                evidence[id] = ["file": destination.lastPathComponent, "sha256": try FileDigest.sha256(of: destination), "sourceSHA256": try FileDigest.sha256(of: url)]
            }
            guard let cache = TranscriptCache.diskURL(for: audioURL) else { throw GateBlocked("No actual transcript source identity.") }
            let transcript = TranscriptionResult(text: "The harbor lights.", language: "en-US", words: [],
                segments: [.init(text: "The harbor lights.", start: 0.5, end: 1.5)])
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(transcript)
            try bytes.write(to: cache, options: .atomic)
            let destination = output.appendingPathComponent("isolated-transcript.json")
            try bytes.write(to: destination, options: .atomic)
            evidence[audioID] = ["file": destination.lastPathComponent, "sha256": try FileDigest.sha256(of: destination), "sourceSHA256": try FileDigest.sha256(of: audioURL)]
            return evidence
        }.value
    }

    private static func rect(_ value: NSRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }

    private static func clipRows(_ timeline: Timeline) -> [[String: Any]] {
        timeline.tracks.flatMap { track in track.clips.map { clip in
            ["id": clip.id, "trackID": track.id, "type": track.type.rawValue, "sourceID": clip.mediaRef,
             "startFrame": clip.startFrame, "durationFrames": clip.durationFrames, "trimStartFrame": clip.trimStartFrame]
        } }
    }

    private static func segmentDrop(_ source: String, frame: Int, editor: EditorViewModel,
                                    driver: ProductionVisualSourcesDriver, window: NSWindow) async throws {
        func find(_ view: NSView) -> TimelineView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let value = view as? TimelineView, !value.visibleRect.isEmpty { return value }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let root = window.contentView, let timeline = find(root) else { throw GateBlocked("The actual drop timeline is missing.") }
        let geometry = timeline.geometry
        let y: CGFloat
        if editor.timeline.tracks.isEmpty { y = geometry.rulerHeight + geometry.dropZoneHeight / 2 }
        else { y = geometry.trackY(at: editor.timeline.tracks.count - 1) + geometry.trackHeight(at: editor.timeline.tracks.count - 1) + geometry.dropZoneHeight / 2 }
        let point = NSPoint(x: geometry.xForFrame(frame) + geometry.pixelsPerFrame / 2, y: y)
        guard geometry.frameAt(x: point.x) == frame, geometry.dropTargetAt(y: point.y) == .newTrackAt(editor.timeline.tracks.count) else {
            throw GateBlocked("The actual native drop geometry does not address the requested frame and new track.")
        }
        try driver.record("segment drop geometry", fields: ["id": source, "frame": frame, "pixelsPerFrame": geometry.pixelsPerFrame,
            "point": [point.x, point.y], "viewport": rect(timeline.visibleRect), "newTrackIndex": editor.timeline.tracks.count])
        try await driver.dragBetween(source, destination: timeline, point: point, label: "timeline frame \(frame)", in: window)
    }
}
