import AppKit
import AVFoundation
import ImageIO
import NexGenEngine

@MainActor
enum GenericNLEAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "generic-nle-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = directory.appendingPathComponent("Native editing.ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        var empty = Timeline()
        empty.width = 320; empty.height = 180; empty.fps = 30; empty.settingsConfigured = true
        try JSONEncoder().encode(empty).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let projectID = try ProjectIdentity.uuid(for: package)
        let source = directory.appendingPathComponent("Original warm moving shot.mov")
        try await FullflowAcceptanceFixture.writeVideo(to: source, duration: 8, fps: 30, warm: true)
        let sourceSHA = try await Task.detached { try FileDigest.sha256(of: source) }.value
        let document = try await VideoProject.load(from: package)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The plain editing window did not open.") }
        document.showWindows()
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        window.setContentSize(NSSize(width: 960, height: 640))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var documentClosed = false
        defer { if !documentClosed { document.close() } }
        do {
            try await driver.wait("plain document at requested scale") {
                guard let host = window.contentView else { return false }
                return abs(host.bounds.width - 960) < 1 && abs(host.bounds.height - 640) < 1
                    && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
            }
            try await workspace(.media, editor: editor, window: window, driver: driver)
            try await driver.chooseFile(source, in: window, trigger: "media.action.Import")
            try await driver.wait("actual media import", seconds: 30) {
                editor.mediaAssets.count == 1 && editor.mediaAssets.first?.userFacingFilename == source.lastPathComponent
            }
            guard let asset = editor.mediaAssets.first, let imported = editor.mediaResolver.resolveURL(for: asset.id),
                  try await Task.detached(operation: { try FileDigest.sha256(of: imported) }).value == sourceSHA,
                  editor.timeline.tracks.flatMap(\.clips).isEmpty else {
                throw GateBlocked("Native import changed source bytes or inserted a clip without an edit decision.")
            }
            try driver.capture("imported", target: window)
            try await workspace(.edit, editor: editor, window: window, driver: driver)
            try await driver.click("media.asset." + asset.id, in: window)
            try await driver.wait("source controls") { driver.state("source.insert." + asset.id, in: window) == true }
            for id in ["source.in." + asset.id, "source.out." + asset.id, "source.insert." + asset.id] {
                try await driver.reveal(id, in: window)
                try driver.visible([id], in: window)
            }
            try await driver.click("source.insert." + asset.id, in: window)
            try await driver.wait("native source insertion") { editor.timeline.tracks.flatMap(\.clips).count == 1 }
            guard let first = editor.timeline.tracks.first?.clips.first,
                  first.mediaRef == asset.id, first.durationFrames == 240, first.startFrame == 0 else {
                throw GateBlocked("The inserted clip did not preserve the imported eight-second source.")
            }
            try pointerOnClip(first, editor: editor, window: window, driver: driver)
            try await driver.wait("timeline clip selection") { editor.selectedClipIds == [first.id] && editor.activePreviewTab == .timeline }
            try pointerOnRuler(frame: 90, window: window, driver: driver)
            try await driver.wait("native timeline seek") { editor.currentFrame == 90 }
            let unsplit = editor.timeline
            try driver.pressKey(40, characters: "k", modifiers: .command, in: window)
            try await driver.wait("native split") { editor.timeline.tracks.flatMap(\.clips).count == 2 }
            let split = editor.timeline
            guard split.tracks.flatMap(\.clips).map(\.durationFrames).sorted() == [90, 150], split.totalFrames == 240 else {
                throw GateBlocked("Split changed the source interval or total film duration.")
            }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("native split undo") { editor.timeline == unsplit }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("native split redo") { editor.timeline == split }
            guard let left = split.tracks.first?.clips.first else { throw GateBlocked("The first split clip disappeared.") }
            try pointerOnClip(left, editor: editor, window: window, driver: driver)
            try await driver.wait("copy source selection") { editor.selectedClipIds == [left.id] }
            try driver.pressKey(8, characters: "c", modifiers: .command, in: window)
            try driver.pressKey(9, characters: "v", modifiers: .command, in: window)
            try await driver.wait("native paste") { editor.timeline.tracks.flatMap(\.clips).count > 2 }
            let pasted = editor.timeline
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("native paste undo") { editor.timeline == split }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("native paste redo") { editor.timeline == pasted }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("restore edited cut") { editor.timeline == split }
            try driver.capture("edit-undo-clipboard", target: window)
            try pointerOnClip(left, editor: editor, window: window, driver: driver)
            try pointerOnRuler(frame: 30, window: window, driver: driver)
            try await driver.wait("finishing playhead inside selected clip") { editor.currentFrame == 30 && editor.selectedClipIds == [left.id] }
            try await workspace(.postproduction, editor: editor, window: window, driver: driver)
            let finishing = try await PostproductionControlsAcceptance.run(editor: editor, clipID: left.id, window: window, driver: driver)
            var lut = try await NativeLUTAcceptance.run(editor: editor, clipID: left.id, directory: directory, window: window, driver: driver)
            try await driver.fill("inspector.value.Opacity", value: "50", in: window, requireFocusExit: true)
            try await driver.wait("native opacity finishing") {
                editor.timeline.tracks.flatMap(\.clips).first(where: { $0.id == left.id })?.opacity == 0.5
            }
            try driver.capture("postproduction", target: window)
            let finished = editor.timeline
            let finishedSHA = try ExportArtwork.timelineHash(finished)
            try await workspace(.export, editor: editor, window: window, driver: driver)
            if editor.activePreviewTab != .timeline { try await driver.click("export.artwork.show-film", in: window) }
            try await driver.click("export.artwork.frame", in: window)
            try await driver.wait("actual film poster selection") { driver.text("export.artwork.selection", in: window)?.hasPrefix("Film frame ") == true }
            try await driver.reveal("export.start", in: window)
            try driver.capture("export-settings", target: window)
            let movie = directory.appendingPathComponent("Final cut.mp4")
            try await driver.click("export.start", in: window)
            try await driver.saveFile(movie, in: window)
            try await driver.wait("finished export or failure", seconds: 90) {
                ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).first?.status.isTerminal == true
                    || !(driver.text("export.error", in: window) ?? "").isEmpty
            }
            guard let job = ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).first,
                  job.status == .completed, job.destinationURL?.standardizedFileURL.resolvingSymlinksInPath() == movie.standardizedFileURL.resolvingSymlinksInPath(),
                  let home = editor.workingRoot else {
                throw GateBlocked("Plain editing export failed: " + (driver.text("export.error", in: window) ?? "No completed export."))
            }
            let root = try ExportDataRoot.resolve(in: home)
            let receipt = try PipelineDeliveryStore.loadAttempt(id: job.id, dataRoot: root)
            let loadedPoster = try ExportArtwork.load(spec: receipt.spec, dataRoot: root, timelineSHA256: finishedSHA)
            guard receipt.probeQC?.passed == true, receipt.finishedTimelineSHA256 == finishedSHA,
                  let poster = loadedPoster, try FileDigest.sha256(of: ExportArtwork.outputURL(for: movie)) == poster.pngSHA256,
                  DataRootResolver.dataRoot(of: home) == nil, editor.declaredPluginBinding == nil,
                  editor.declaredProductionContract == nil else { throw GateBlocked("Plain output lacks its own film/poster proof or enrolled production unexpectedly.") }
            try await driver.reveal("export.qc", in: window)
            try await driver.wait("visible output quality result") { driver.text("export.qc", in: window) == "passed" }
            try driver.capture("verified-output", target: window)
            try await driver.reveal("export.artwork.verified", in: window)
            try await driver.wait("visible poster proof") { driver.text("export.artwork.verified", in: window) == poster.pngSHA256 }
            try driver.capture("verified-poster", target: window)
            let decoded = try await decode(movie)
            guard decoded.frames == 240, abs(decoded.duration - 8) < 0.0001,
                  decoded.firstRed < 15,
                  decoded.firstGreen / decoded.lastGreen > 0.35, decoded.firstGreen / decoded.lastGreen < 0.85,
                  decoded.lastRed > 180, decoded.lastRed < 245, decoded.motionPixels > 20,
                  abs(decoded.beforeSplitRed - decoded.firstRed) < 8,
                  abs(decoded.afterSplitRed - decoded.lastRed) < 8,
                  decoded.afterSplitRed - decoded.beforeSplitRed > 150,
                  abs(decoded.beforeSplitGreen - decoded.firstGreen) < 8,
                  abs(decoded.afterSplitGreen - decoded.lastGreen) < 8,
                  decoded.afterSplitGreen - decoded.beforeSplitGreen > 8 else {
                throw GateBlocked("Independent movie decoding did not preserve duration, source motion, native LUT and opacity edits.")
            }
            lut["exportGradeVerified"] = true
            let packageTimeline = try JSONDecoder().decode(Timeline.self,
                from: Data(contentsOf: package.appendingPathComponent(Project.timelineFilename)))
            guard document.isDocumentEdited, packageTimeline != finished,
                  home.standardizedFileURL.resolvingSymlinksInPath() != package.standardizedFileURL.resolvingSymlinksInPath(),
                  !FileManager.default.fileExists(atPath: package.appendingPathComponent("pipeline/delivery/attempts/\(job.id).v1.json").path) else {
                throw GateBlocked("The native Save check has no unsaved timeline and delivery changes to prove.")
            }
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("native document save", seconds: 30) {
                guard !document.isDocumentEdited,
                      let bytes = try? Data(contentsOf: package.appendingPathComponent(Project.timelineFilename)),
                      let saved = try? JSONDecoder().decode(Timeline.self, from: bytes) else { return false }
                return saved == finished && FileManager.default.fileExists(atPath: package.appendingPathComponent("pipeline/delivery/attempts/\(job.id).v1.json").path)
            }
            document.close()
            documentClosed = true
            try NativeLUTAcceptance.requireSaved(lut, in: package)
            let reopened = try await VideoProject.load(from: package)
            NSDocumentController.shared.addDocument(reopened)
            reopened.makeWindowControllers()
            var reopenedClosed = false
            defer { if !reopenedClosed { reopened.close() } }
            let reopenedEditor = reopened.editorViewModel
            guard reopenedEditor.timeline == finished, let reopenedHome = reopenedEditor.workingRoot,
                  ProjectIdentity.existingUUID(for: reopenedHome) == projectID,
                  DataRootResolver.dataRoot(of: reopenedHome) == nil else {
                throw GateBlocked("Saving and reopening changed the plain editing project.")
            }
            let reopenedRoot = try ExportDataRoot.resolve(in: reopenedHome)
            try NativeLUTAcceptance.requireSaved(lut, in: reopenedHome)
            lut["nativeSaveAndReopen"] = true
            let persisted = try PipelineDeliveryStore.loadAttempt(id: job.id, dataRoot: reopenedRoot)
            guard persisted == receipt else { throw GateBlocked("The delivery receipt did not survive Save and reopen.") }
            reopened.close(); reopenedClosed = true
            let originalPackageTimeline = try Data(contentsOf: package.appendingPathComponent(Project.timelineFilename))
            lut["legacyRecovery"] = try await NativeLUTRecoveryAcceptance.run(savedProject: package,
                replacement: directory.appendingPathComponent("second-look/Look.cube"), output: output, scale: scale)
            guard try Data(contentsOf: package.appendingPathComponent(Project.timelineFilename)) == originalPackageTimeline else {
                throw GateBlocked("The separate LUT recovery case changed the original saved film.")
            }
            let colorReference = try await ColorReferenceComparisonAcceptance.run(savedProject: package, output: output, scale: scale)
            let renderedPostproduction = try await PostproductionRenderedOutputAcceptance.run(output: output, scale: scale)
            try driver.record("plain editing persistence and decoded output", fields: ["projectID": projectID,
                "jobID": job.id, "sourceSHA256": sourceSHA, "timelineSHA256": finishedSHA,
                "posterSHA256": poster.pngSHA256, "decodedFrames": decoded.frames,
                "decodedFirstRed": decoded.firstRed, "decodedLastRed": decoded.lastRed,
                "decodedFirstGreen": decoded.firstGreen, "decodedLastGreen": decoded.lastGreen,
                "beforeSplitRed": decoded.beforeSplitRed, "afterSplitRed": decoded.afterSplitRed, "motionPixels": decoded.motionPixels])
            var result = driver.result()
            if let recovery = lut["legacyRecovery"] as? [String: Any], let images = recovery["screenshots"] as? [String] {
                result["screenshots"] = driver.screenshots + images
            }
            result.merge(["scale": scale, "viewport": [960, 640], "nativeImport": true,
                "libraryImportDidNotInsert": true, "nativeSourceInsert": true, "nativeSplitUndoRedo": true,
                "nativeClipboardUndoRedo": true, "nativePostproduction": true, "finishingControls": finishing,
                "nativeLUT": lut, "colorReference": colorReference, "renderedPostproduction": renderedPostproduction, "nativeExportAndPoster": true,
                "visibleQC": true, "nativeSaveAndReopen": true, "noProductionEnrollment": true,
                "decodedFrames": decoded.frames, "durationSeconds": decoded.duration, "motionPixels": decoded.motionPixels,
                "splitBoundaryVerified": true, "unsavedBaselineVerified": true,
                "timelineSHA256": finishedSHA, "outputSHA256": receipt.outputSHA256 ?? "", "posterSHA256": poster.pngSHA256]) { _, new in new }
            return result
        } catch { driver.failure(error); throw error }
    }

    private static func timelineView(in window: NSWindow) throws -> TimelineView {
        func visibleTimeline(_ view: NSView) -> TimelineView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let timeline = view as? TimelineView, !timeline.visibleRect.isEmpty { return timeline }
            return view.subviews.lazy.compactMap(visibleTimeline).first
        }
        guard let root = window.contentView, let view = visibleTimeline(root) else { throw GateBlocked("The visible native timeline is unavailable.") }
        return view
    }

    private static func workspace(_ focus: EditorViewModel.WorkspaceFocus, editor: EditorViewModel,
                                  window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        let id = "editor.workspace." + focus.rawValue
        try await driver.click(id, in: window, enabled: false)
        try await driver.wait("workspace " + focus.rawValue) {
            editor.workspaceFocus == focus && driver.state(id, in: window) == true
        }
    }

    static func pointerOnClip(_ clip: Clip, editor: EditorViewModel, window: NSWindow,
                                      driver: ProductionVisualSourcesDriver) throws {
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clip.id }) }) else {
            throw GateBlocked("The native target clip is missing.")
        }
        let view = try timelineView(in: window)
        let frame = view.geometry.clipRect(for: clip, trackIndex: index)
        try pointer(NSPoint(x: frame.midX, y: frame.midY), in: view, window: window, driver: driver)
    }

    static func pointerOnRuler(frame: Int, window: NSWindow, driver: ProductionVisualSourcesDriver) throws {
        let view = try timelineView(in: window)
        try pointer(NSPoint(x: view.geometry.xForFrame(frame) + view.geometry.pixelsPerFrame / 2, y: view.visibleRect.minY + view.geometry.rulerHeight / 2),
            in: view, window: window, driver: driver)
    }

    private static func pointer(_ point: NSPoint, in view: TimelineView, window: NSWindow,
                                driver: ProductionVisualSourcesDriver) throws {
        guard window.isKeyWindow, view.visibleRect.insetBy(dx: 1, dy: 1).contains(point),
              let root = window.contentView else { throw GateBlocked("The timeline pointer target is clipped.") }
        let local = view.convert(point, to: root.superview)
        guard let hit = root.hitTest(local), hit === view || hit.isDescendant(of: view) else {
            throw GateBlocked("Another surface covers the native timeline pointer target.")
        }
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw GateBlocked("Could not create native timeline pointer input.")
            }
            NSApp.postEvent(event, atStart: false)
        }
        try driver.record("native timeline pointer", fields: ["point": [point.x, point.y], "window": window.windowNumber])
    }

    private nonisolated static func decode(_ url: URL) async throws -> (frames: Int, duration: Double, firstRed: Double, lastRed: Double, beforeSplitRed: Double, afterSplitRed: Double, motionPixels: Double, firstGreen: Double, lastGreen: Double, beforeSplitGreen: Double, afterSplitGreen: Double) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GateBlocked("The exported movie has no video.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? GateBlocked("The exported movie cannot be decoded.") }
        var count = 0, first = 0.0, last = 0.0, beforeSplit = 0.0, afterSplit = 0.0
        var firstGreen = 0.0, lastGreen = 0.0, beforeSplitGreen = 0.0, afterSplitGreen = 0.0
        var centers: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw GateBlocked("A decoded frame has no pixels.") }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            guard let data = CVPixelBufferGetBaseAddress(pixel) else {
                CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                throw GateBlocked("A decoded frame has unreadable pixels.")
            }
            let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            let x = max(0, width / 20), y = max(0, height / 20)
            let red = Double(data.load(fromByteOffset: y * stride + x * 4 + 2, as: UInt8.self))
            let green = Double(data.load(fromByteOffset: y * stride + x * 4 + 1, as: UInt8.self))
            if count == 100 || count == 200 {
                let row = height / 2 * stride
                let white = (0..<width).filter { x in
                    data.load(fromByteOffset: row + x * 4 + 1, as: UInt8.self) > 230
                        && data.load(fromByteOffset: row + x * 4 + 2, as: UInt8.self) > 230
                }
                if !white.isEmpty { centers.append(Double(white.reduce(0, +)) / Double(white.count)) }
            }
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            if count == 89 { beforeSplit = red; beforeSplitGreen = green }
            if count == 90 { afterSplit = red; afterSplitGreen = green }
            if count == 0 { first = red; firstGreen = green }
            last = red; lastGreen = green; count += 1
        }
        guard reader.status == .completed else { throw reader.error ?? GateBlocked("The exported movie did not decode completely.") }
        let motion = centers.count == 2 ? centers[1] - centers[0] : 0
        return (count, duration.seconds, first, last, beforeSplit, afterSplit, motion, firstGreen, lastGreen, beforeSplitGreen, afterSplitGreen)
    }
}
