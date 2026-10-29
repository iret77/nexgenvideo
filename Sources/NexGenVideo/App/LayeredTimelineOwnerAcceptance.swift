import AppKit
import AVFoundation
import ImageIO
import NexGenEngine

@MainActor
enum LayeredTimelineOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "layered-timeline-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        let package = directory.appendingPathComponent("Layered film.ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var empty = Timeline()
        empty.width = 320; empty.height = 180; empty.fps = 30; empty.settingsConfigured = true
        try JSONEncoder().encode(empty).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let video = directory.appendingPathComponent("Moving background.mov")
        let audio = directory.appendingPathComponent("Original sound.wav")
        let green = directory.appendingPathComponent("Green corner.png")
        let yellow = directory.appendingPathComponent("Yellow corner.png")
        let motion = directory.appendingPathComponent("Bouncing dot.lottie")
        try await FullflowAcceptanceFixture.writeVideo(to: video, duration: 5, fps: 30, warm: true)
        try FullflowAcceptanceFixture.writeTone(to: audio, duration: 5)
        try writeCorner(to: green, green: true); try writeCorner(to: yellow, green: false)
        guard let lottie = Data(base64Encoded: lottieBytes) else { throw failed("The existing moving Lottie fixture is unreadable.") }
        try lottie.write(to: motion)
        var document = try await open(package)
        var window = try show(document)
        var editor = document.editorViewModel
        var driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var previousInteractions: [[String: Any]] = [], previousScreenshots: [String] = []
        defer { document.close() }
        do {
            try await layout(window, scale: scale, driver: driver)
            let viewport = [window.contentView!.bounds.width, window.contentView!.bounds.height]
            let measuredScale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
            try await NativeEditingOwnerAcceptance.workspace(.media, editor: editor, window: window, driver: driver)
            let sources = [motion, green, yellow, video, audio]
            var assets: [MediaAsset] = []
            var sourceFacts: [[String: String]] = []
            for url in sources {
                let before = editor.mediaAssets.count
                try await driver.chooseFile(url, in: window, trigger: "media.action.Import")
                try await driver.wait("native layered import " + url.lastPathComponent, seconds: 30) { editor.mediaAssets.count == before + 1 }
                guard let asset = editor.mediaAssets.first(where: { $0.userFacingFilename == url.lastPathComponent }),
                      let actual = editor.mediaResolver.resolveURL(for: asset.id), editor.timeline.tracks.isEmpty else {
                    throw failed("Import did not preserve the original filename and independent candidate.")
                }
                let sourceHash = try await Task.detached { try FileDigest.sha256(of: url) }.value
                guard try await Task.detached(operation: { try FileDigest.sha256(of: actual) }).value == sourceHash else {
                    throw failed("The native import changed source bytes.")
                }
                assets.append(asset); sourceFacts.append(["id": asset.id, "file": url.lastPathComponent, "sha256": sourceHash, "type": asset.type.rawValue])
            }
            guard assets.map(\.type) == [.lottie, .image, .image, .video, .audio],
                  assets[0].sourceWidth == 400, assets[0].sourceHeight == 400,
                  abs(assets[0].duration - 2) < 0.001, !assets[3].hasAudio else { throw failed("The actual imported types, Lottie clock or source audio differ from the fixture.") }
            try driver.capture("import-candidates", target: window)
            try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
            var clips: [Clip] = [], trackIDs: [String] = []
            for (index, asset) in assets.enumerated() {
                try await driver.reveal("media.asset." + asset.id, in: window)
                try await driver.click("media.asset." + asset.id, in: window)
                try await driver.wait("actual new-track source target") { driver.text("source.target." + asset.id, in: window) != nil }
                try await driver.picker("source.target." + asset.id, title: "New Track", expected: "", in: window)
                try await driver.reveal("source.overwrite." + asset.id, in: window)
                try driver.visible(["source.overwrite." + asset.id], in: window)
                try await driver.click("source.overwrite." + asset.id, in: window)
                try await driver.wait("native independent layer \(index)") { editor.timeline.tracks.count == index + 1 }
                guard let track = editor.timeline.tracks.first(where: { $0.clips.first?.mediaRef == asset.id }),
                      track.clips.count == 1, let clip = track.clips.first, clip.startFrame == 0,
                      clip.durationFrames == (index == 0 ? 60 : 150), clip.trimStartFrame == 0,
                      clips.allSatisfy({ editor.clipFor(id: $0.id) == $0 }) else { throw failed("New Track Overwrite shifted a previous layer or changed the source interval.") }
                clips.append(clip); trackIDs.append(track.id)
                try driver.record("native layered placement", fields: ["assetID": asset.id, "trackID": track.id, "clipID": clip.id,
                    "start": clip.startFrame, "duration": clip.durationFrames, "operation": "overwrite-new-track"])
            }
            try GenericNLEAcceptance.pointerOnRuler(frame: 0, window: window, driver: driver)
            try await driver.wait("native title insertion position") { editor.currentFrame == 0 && editor.activePreviewTab == .timeline }
            var titleIDs: [String] = []
            for (text, y) in [("ONE", 8), ("TWO", 42)] {
                let existing = Set(editor.timeline.tracks.flatMap(\.clips).map(\.id))
                try await driver.click("editing.add-text", in: window)
                try await driver.wait("actual title layer " + text) { editor.timeline.tracks.flatMap(\.clips).contains { !existing.contains($0.id) && $0.mediaType == .text } }
                guard let clip = editor.timeline.tracks.flatMap(\.clips).first(where: { !existing.contains($0.id) }) else { throw failed("The native title was not created.") }
                titleIDs.append(clip.id)
                guard let titleTrack = editor.timeline.tracks.first(where: { $0.clips.contains(where: { $0.id == clip.id }) }) else { throw failed("The actual title track disappeared.") }
                try await revealTrack(titleTrack.id, editor: editor, window: window, driver: driver)
                try GenericNLEAcceptance.pointerOnClip(clip, editor: editor, window: window, driver: driver)
                try await driver.wait("native title selection") { editor.selectedClipIds == [clip.id] && editor.activePreviewTab == .timeline }
                try await driver.click("inspector.tab.Text", in: window, enabled: false)
                try await driver.fill("text.content", value: text, in: window, requireFocusExit: true)
                try await driver.fill("inspector.value.Text size", value: "144", in: window, requireFocusExit: true)
                if editor.clipFor(id: clip.id)?.textStyle?.shadow.enabled == true { try await driver.click("text.toggle.Shadow", in: window) }
                try await driver.fill("inspector.value.Position X", value: "8", in: window, requireFocusExit: true)
                try await driver.fill("inspector.value.Position Y", value: String(y), in: window, requireFocusExit: true)
                try await driver.wait("actual independent title content and position") {
                    guard let title = editor.clipFor(id: clip.id) else { return false }
                    return title.textContent == text && title.textStyle?.fontSize == 144 && title.textStyle?.shadow.enabled == false
                        && abs(title.topLeftAt(frame: 0).x * 320 - 8) < 0.1 && abs(title.topLeftAt(frame: 0).y * 180 - Double(y)) < 0.1
                }
                try driver.capture("title-" + text.lowercased(), target: window)
            }
            let layered = editor.timeline
            guard layered.tracks.count == 7, layered.tracks.suffix(5).map(\.id) == trackIDs,
                  layered.tracks.prefix(2).flatMap(\.clips).map(\.id) == Array(titleIDs.reversed()), layered.totalFrames == 150 else {
                throw failed("The two native titles do not sit above the actual Lottie, image, video and audio layers.")
            }
            try snapshot("layered", timeline: layered, directory: directory)
            try await headerMenu("Move Track Down", trackID: trackIDs[1], editor: editor, window: window, driver: driver)
            var reordered = layered; reordered.tracks.swapAt(3, 4)
            try await driver.wait("native image track reorder") { editor.timeline == reordered }
            try snapshot("reordered", timeline: editor.timeline, directory: directory)
            try driver.capture("track-reordered", target: window)
            try await undo(layered, editor: editor, window: window, driver: driver)
            try await undo(reordered, redo: true, editor: editor, window: window, driver: driver)
            try await undo(layered, editor: editor, window: window, driver: driver)
            let index = try trackIndex(trackIDs[2], editor: editor)
            let removal = "Remove Track " + editor.timelineTrackDisplayLabel(at: index) + " and 1 Clip"
            try await headerMenu(removal, trackID: trackIDs[2], editor: editor, window: window, driver: driver)
            var removed = layered; removed.tracks.remove(at: 4)
            try await driver.wait("native populated track removal") { editor.timeline == removed }
            try snapshot("removed", timeline: editor.timeline, directory: directory)
            try driver.capture("track-removed", target: window)
            try await undo(layered, editor: editor, window: window, driver: driver)
            try await undo(removed, redo: true, editor: editor, window: window, driver: driver)
            try await undo(layered, editor: editor, window: window, driver: driver)
            try GenericNLEAcceptance.pointerOnRuler(frame: 30, window: window, driver: driver)
            try await driver.wait("actual layered preview at frame thirty") { editor.currentFrame == 30 && editor.activePreviewTab == .timeline }
            let preview = try await PostproductionControlsAcceptance.readablePreview(editor)
            try await toggle("hidden", trackID: trackIDs[0], editor: editor, window: window, driver: driver)
            _ = try await PostproductionControlsAcceptance.changedPreview(editor, from: preview)
            try driver.capture("hidden-lottie", target: window)
            try await toggle("muted", trackID: trackIDs[4], editor: editor, window: window, driver: driver)
            try await toggle("syncLocked", trackID: trackIDs[1], editor: editor, window: window, driver: driver)
            let beforeHeight = editor.timeline
            let canonicalBeforeHeight = try ExportArtwork.timelineHash(beforeHeight)
            try await revealTrack(trackIDs[0], editor: editor, window: window, driver: driver)
            let header = try headerView(window), row = try trackIndex(trackIDs[0], editor: editor)
            let geometry = TimelineGeometry(editor: editor, bounds: header.bounds)
            let from = NSPoint(x: header.bounds.midX, y: geometry.trackY(at: row) + geometry.trackHeight(at: row))
            try await AppNativeMenuAcceptance.drag(from: from, to: NSPoint(x: from.x, y: from.y + 24), in: header,
                window: window, driver: driver, label: "layered.track-height")
            try await driver.wait("actual resized Lottie track") { editor.timeline.tracks[row].displayHeight > beforeHeight.tracks[row].displayHeight + 20 }
            let flagged = editor.timeline, height = flagged.tracks[row].displayHeight
            guard try ExportArtwork.timelineHash(flagged) == canonicalBeforeHeight else { throw failed("A display-only track height changed film provenance.") }
            try await undo(beforeHeight, editor: editor, window: window, driver: driver)
            try await undo(flagged, redo: true, editor: editor, window: window, driver: driver)
            try snapshot("flags", timeline: flagged, directory: directory)
            try driver.capture("track-flags-height", target: window)
            try await save(document, expected: flagged, package: package, driver: driver)
            previousInteractions = driver.interactions; previousScreenshots = driver.screenshots
            document.close()
            document = try await open(package); window = try show(document); editor = document.editorViewModel
            driver = ProductionVisualSourcesDriver(window: window, output: output, name: name + "-reopen")
            try await layout(window, scale: scale, driver: driver)
            guard editor.timeline == flagged, editor.timeline.tracks[row].displayHeight == height else {
                throw failed("Save/Reopen lost the native track height, hidden/muted/sync-lock state or actual layered edits.")
            }
            try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
            try await revealTrack(trackIDs[0], editor: editor, window: window, driver: driver)
            try driver.capture("reopened-flags-height", target: window)
            try await toggle("hidden", trackID: trackIDs[0], editor: editor, window: window, driver: driver)
            try await toggle("muted", trackID: trackIDs[4], editor: editor, window: window, driver: driver)
            try GenericNLEAcceptance.pointerOnRuler(frame: 30, window: window, driver: driver)
            try await driver.wait("restored actual layered film preview") { editor.currentFrame == 30 && editor.activePreviewTab == .timeline }
            try await PostproductionControlsAcceptance.matchingPreview(editor, expected: preview)
            try driver.capture("layered-film-preview", target: window)
            let final = editor.timeline, hash = try ExportArtwork.timelineHash(final)
            try snapshot("final", timeline: final, directory: directory)
            try await NativeEditingOwnerAcceptance.workspace(.export, editor: editor, window: window, driver: driver)
            if editor.activePreviewTab != .timeline { try await driver.click("export.artwork.show-film", in: window) }
            try await driver.reveal("export.start", in: window); try driver.capture("export-settings", target: window)
            let movie = directory.appendingPathComponent("Layered film.mp4")
            try await driver.click("export.start", in: window); try await driver.saveFile(movie, in: window)
            try await driver.wait("actual layered export finishes", seconds: 90) {
                ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).first?.status.isTerminal == true
                    || !(driver.text("export.error", in: window) ?? "").isEmpty
            }
            guard let job = ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).first, job.status == .completed,
                  job.destinationURL?.standardizedFileURL.resolvingSymlinksInPath() == movie.standardizedFileURL.resolvingSymlinksInPath(),
                  let home = editor.workingRoot else { throw failed("The native layered export did not complete at the selected destination.") }
            let dataRoot = try ExportDataRoot.resolve(in: home), jobID = job.id
            let receipt = try await Task.detached { try PipelineDeliveryStore.loadAttempt(id: jobID, dataRoot: dataRoot) }.value
            guard receipt.probeQC?.passed == true, receipt.finishedTimelineSHA256 == hash else { throw failed("The actual output lacks current QC and film identity.") }
            try await driver.reveal("export.qc", in: window)
            try await driver.wait("actual layered QC passed") { driver.text("export.qc", in: window) == "passed" }
            try driver.capture("export-verified", target: window)
            let decoded = try await Task.detached { try await decode(movie, sourceAudio: audio, directory: directory) }.value
            guard decoded.frames.count == 150, abs(decoded.duration - 5) < 0.001 else { throw failed("The actual exported movie does not decode through all 150 frames.") }
            try await save(document, expected: final, package: package, driver: driver)
            try JSONEncoder().encode(decoded).write(to: directory.appendingPathComponent("decoded.json"), options: .atomic)
            try driver.record("layered film independently decoded", fields: ["frames": decoded.frames.count, "duration": decoded.duration,
                "trackHeightBefore": beforeHeight.tracks[row].displayHeight, "trackHeightAfter": height,
                "filmHashBeforeResize": canonicalBeforeHeight, "filmHashAfterResize": try ExportArtwork.timelineHash(flagged)])
            previousInteractions += driver.interactions; previousScreenshots += driver.screenshots
            document.close(); document = try await open(package); window = try show(document); editor = document.editorViewModel
            driver = ProductionVisualSourcesDriver(window: window, output: output, name: name + "-final")
            try await layout(window, scale: scale, driver: driver)
            guard editor.timeline == final else { throw failed("The final saved layered movie changed on reopen.") }
            try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
            try await revealTrack(trackIDs[0], editor: editor, window: window, driver: driver)
            try driver.capture("saved-final", target: window)
            return ["directory": name, "project": package.lastPathComponent, "movie": movie.lastPathComponent,
                "viewport": viewport, "effectiveScale": measuredScale, "backingScale": window.backingScaleFactor,
                "sources": sourceFacts, "trackIDs": trackIDs, "titleIDs": titleIDs, "height": height,
                "timelineSHA256": hash, "outputSHA256": receipt.outputSHA256 ?? "",
                "interactions": previousInteractions + driver.interactions, "screenshots": previousScreenshots + driver.screenshots]
        } catch { driver.failure(error); throw error }
    }

    private static func open(_ package: URL) async throws -> VideoProject {
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers()
        return document
    }

    private static func show(_ document: VideoProject) throws -> NSWindow {
        guard let window = document.windowControllers.first?.window else { throw failed("The native layered project window is missing.") }
        document.showWindows(); window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = MainMenuBuilder.buildMenu(); NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private static func layout(_ window: NSWindow, scale: Double, driver: ProductionVisualSourcesDriver) async throws {
        try await driver.wait("measured layered interface") {
            window.contentView?.bounds.size == AppTheme.Window.projectMin && window.isKeyWindow
                && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
        }
    }

    private static func save(_ document: VideoProject, expected: Timeline, package: URL, driver: ProductionVisualSourcesDriver) async throws {
        guard document.isDocumentEdited else { throw failed("The Save check has no unsaved native edit.") }
        try driver.pressKey(1, characters: "s", modifiers: .command, in: driver.window)
        try await driver.wait("native layered save", seconds: 30) {
            guard !document.isDocumentEdited, let data = try? Data(contentsOf: package.appendingPathComponent(Project.timelineFilename)),
                  let saved = try? JSONDecoder().decode(Timeline.self, from: data) else { return false }
            return (try? ExportArtwork.timelineHash(saved)) == (try? ExportArtwork.timelineHash(expected))
        }
    }

    private static func undo(_ timeline: Timeline, redo: Bool = false, editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try driver.pressKey(6, characters: redo ? "Z" : "z", modifiers: redo ? [.command, .shift] : .command, in: window)
        try await driver.wait("native layered Undo/Redo") { editor.timeline == timeline }
    }

    private static func trackIndex(_ id: String, editor: EditorViewModel) throws -> Int {
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == id }) else { throw failed("The actual target track disappeared.") }
        return index
    }

    private static func headerView(_ window: NSWindow) throws -> TimelineHeaderView {
        guard let root = window.contentView, let header = AppNativeMenuAcceptance.views(root).compactMap({ $0 as? TimelineHeaderView })
            .first(where: { !$0.isHiddenOrHasHiddenAncestor }) else { throw failed("The actual track header is unavailable.") }
        return header
    }

    private static func revealTrack(_ id: String, editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard let root = window.contentView, let screen = NSScreen.screens.first,
              let view = AppNativeMenuAcceptance.views(root).compactMap({ $0 as? TimelineView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else {
            throw failed("The actual timeline cannot receive native wheel input.")
        }
        for _ in 0..<25 {
            let row = try trackIndex(id, editor: editor), geometry = view.geometry
            let y = geometry.trackY(at: row), height = geometry.trackHeight(at: row)
            if y >= view.visibleRect.minY + geometry.rulerHeight && y + height + 28 < view.visibleRect.maxY { return }
            let point = NSPoint(x: view.visibleRect.midX, y: view.visibleRect.maxY - 8)
            guard window.isKeyWindow, let hit = root.hitTest(view.convert(point, to: root.superview)), hit === view || hit.isDescendant(of: view) else {
                throw failed("Another surface covers the actual timeline wheel target.")
            }
            let global = window.convertPoint(toScreen: view.convert(point, to: nil))
            let location = CGPoint(x: global.x, y: screen.frame.maxY - global.y)
            try await ProductionNativeReadingAcceptance.movePointer(to: location, window: window, driver: driver)
            let before = view.visibleRect
            for event in try HangDiagnosticReplay.scrollGestureEvents(delta: y < view.visibleRect.minY + geometry.rulerHeight ? 50 : -50,
                location: location) {
                guard let cg = event.cgEvent else { throw failed("The actual native wheel event is missing.") }
                cg.post(tap: .cghidEventTap); try await Task.sleep(for: .milliseconds(30))
            }
            try await driver.wait("native layered track reveal") { view.visibleRect != before }
            try driver.record("layered native wheel", fields: ["trackID": id, "offset": view.visibleRect.minY])
        }
        throw failed("The actual track cannot be reached by native wheel input.")
    }

    private static func toggle(_ kind: String, trackID: String, editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await revealTrack(trackID, editor: editor, window: window, driver: driver)
        let header = try headerView(window), row = try trackIndex(trackID, editor: editor), before = editor.timeline.tracks[row]
        header.displayIfNeeded()
        guard let rect = kind == "hidden" ? header.hideButtonRects[row] : kind == "muted" ? header.muteButtonRects[row] : header.syncLockButtonRects[row],
              header.visibleRect.contains(rect) else { throw failed("The actual track toggle is clipped.") }
        try AppNativeMenuAcceptance.pointer(.init(x: rect.midX, y: rect.midY), in: header, window: window, driver: driver, label: "layered." + kind)
        try await driver.wait("actual layered track " + kind) {
            let after = editor.timeline.tracks[row]
            return kind == "hidden" ? after.hidden != before.hidden : kind == "muted" ? after.muted != before.muted : after.syncLocked != before.syncLocked
        }
    }

    private static func headerMenu(_ title: String, trackID: String, editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await revealTrack(trackID, editor: editor, window: window, driver: driver)
        let header = try headerView(window), row = try trackIndex(trackID, editor: editor)
        let geometry = TimelineGeometry(editor: editor, bounds: header.bounds)
        try await NativeOwnerContextMenu.choose(title, window: window, driver: driver) {
            try AppNativeMenuAcceptance.pointer(.init(x: header.bounds.midX, y: geometry.trackY(at: row) + geometry.trackHeight(at: row) / 2),
                in: header, window: window, driver: driver, label: "layered.track-menu", right: true)
        }
    }

    private static func snapshot(_ name: String, timeline: Timeline, directory: URL) throws {
        try JSONEncoder().encode(timeline).write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    private static func writeCorner(to url: URL, green: Bool) throws {
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        for y in 0..<180 { for x in 0..<320 where green ? x >= 240 && y < 45 : x < 80 && y >= 135 {
            let offset = (y * 320 + x) * 4
            bytes[offset] = green ? 0 : 255; bytes[offset + 1] = 255; bytes[offset + 2] = 0; bytes[offset + 3] = 255
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let image = CGImage(width: 320, height: 180, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw failed("The transparent corner fixture cannot be encoded.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failed("The transparent corner fixture is incomplete.") }
    }

    private struct Decoded: Codable, Sendable {
        let duration: Double
        let frames: [Double]
        let audioStart: Double
        let audioSamples: Int
        let sourceSamples: Int
    }

    private nonisolated static func decode(_ url: URL, sourceAudio: URL, directory: URL) async throws -> Decoded {
        let asset = AVURLAsset(url: url), duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let sound = try await asset.loadTracks(withMediaType: .audio).first else { throw failed("The actual layered export lost video or audio.") }
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(video)
        guard reader.startReading() else { throw reader.error ?? failed("The actual movie cannot be decoded.") }
        let pixelsURL = directory.appendingPathComponent("decoded.bgra")
        guard FileManager.default.createFile(atPath: pixelsURL.path, contents: nil) else { throw failed("Decoded pixel evidence cannot be created.") }
        let file = try FileHandle(forWritingTo: pixelsURL)
        defer { try? file.close() }
        var frames: [Double] = []
        while let sample = video.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(buffer) == 320, CVPixelBufferGetHeight(buffer) == 180 else { throw failed("The actual layered output dimensions changed.") }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            do {
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw failed("Decoded movie pixels are unreadable.") }
                for y in 0..<180 { try file.write(contentsOf: Data(bytes: base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)), count: 1280)) }
            } catch { CVPixelBufferUnlockBaseAddress(buffer, .readOnly); throw error }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        guard reader.status == .completed else { throw reader.error ?? failed("The actual layered movie stopped decoding.") }
        let soundReader = try AVAssetReader(asset: asset)
        let decodedAudio = AVAssetReaderTrackOutput(track: sound, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        soundReader.add(decodedAudio)
        guard soundReader.startReading() else { throw soundReader.error ?? failed("The actual movie audio cannot be decoded.") }
        var samples = Data(), audioStart: Double?
        while let sample = decodedAudio.copyNextSampleBuffer() {
            if audioStart == nil { audioStart = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw failed("The actual decoded audio has no PCM bytes.") }
            var part = Data(count: CMBlockBufferGetDataLength(block))
            let status = part.withUnsafeMutableBytes { bytes in CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw failed("The actual PCM bytes are unreadable.") }
            samples.append(part)
        }
        guard soundReader.status == .completed, let audioStart else { throw soundReader.error ?? failed("Actual audio did not finish decoding.") }
        try samples.write(to: directory.appendingPathComponent("decoded.f32"))
        let source = try AVAudioFile(forReading: sourceAudio)
        guard source.processingFormat.channelCount == 1, source.processingFormat.sampleRate == 48000,
              let original = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)) else { throw failed("The source PCM clock changed.") }
        try source.read(into: original)
        guard let originalSamples = original.floatChannelData?[0] else { throw failed("The original sound PCM is unreadable.") }
        try Data(bytes: originalSamples, count: Int(original.frameLength) * 4).write(to: directory.appendingPathComponent("source.f32"))
        return .init(duration: duration.seconds, frames: frames, audioStart: audioStart, audioSamples: samples.count / 4, sourceSamples: Int(original.frameLength))
    }

    private nonisolated static func failed(_ message: String) -> GateBlocked { GateBlocked("Native layered timeline: " + message) }

    private static let lottieBytes = "UEsDBBQAAAAIAEuwz1wI8a0UUwAAAGEAAAANAAAAbWFuaWZlc3QuanNvbhXKMQ6AIAxG4bv8MxJYuYpxILExJEJJqS6Eu1vX972Jl2QUbkiIPvgAh4saSVYWaz3ftZBsSkONcis1q+0DaZ8opy1/M7qZO5LKQw6jExnFdawPUEsDBAoAAAAAAEuwz1wAAAAAAAAAAAAAAAALAAAAYW5pbWF0aW9ucy9QSwMEFAAAAAgAS7DPXCMVmRqVAQAA9QUAABQAAABhbmltYXRpb25zL2FuaW0uanNvbq1U246CMBR85yuaPrukBctm/RXTBxRUoguGshdj+Pc9pzdAiskmJoTM4VymM6W9R4TQb7ohVMTvMaMrQg8thCkDVF0BIWgQZIh+AKwZopNH9Sf275qvel/Vx7ei6XBMURS2O1eq7BQEW7lCukt+K1sd3yEk49KqRsQBdTec76fboarVadN2xhlmBEQNBjS3g85Yx1gPsJ0l4LPrus6SWwD4SOzNn6fVPM3REveSveaxdDRvdKUJ1Cm/liMXiNVMjy31so/Ur7TqsNZGBGhNdXnRZlvXQgtKcC2JWfCCXNl7R4bJBz150da9T3A3yo/QQ2yLlsjiBGjibIXFXOJO6/ZfkxT45aZXq5fZhJPTdTqSzLNw5EjxJZCl96VBfV1Lx8NG3oQEjSRZtg+ACewxfpioyZ6pWS+qcQyp15NyT/FShsExp6EfVclJz9IReKhS/zRPwA4J3NlH84TevkGf3sjZLzEtmv3CITO5wHMg5ma+mHEw12p84m3walo6c77RIWkuF2kvlMBtrdwh3OFtwiKsjvroD1BLAQIeAxQAAAAIAEuwz1wI8a0UUwAAAGEAAAANAAAAAAAAAAEAAACkgQAAAABtYW5pZmVzdC5qc29uUEsBAh4DCgAAAAAAS7DPXAAAAAAAAAAAAAAAAAsAAAAAAAAAAAAQAO1BfgAAAGFuaW1hdGlvbnMvUEsBAh4DFAAAAAgAS7DPXCMVmRqVAQAA9QUAABQAAAAAAAAAAQAAAKSBpwAAAGFuaW1hdGlvbnMvYW5pbS5qc29uUEsFBgAAAAADAAMAtgAAAG4CAAAAAA=="
}
