import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum NativeSourceOperationsAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "source-operations-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        let package = directory.appendingPathComponent("Source operations.ngv", isDirectory: true)
        let media = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var assets: [MediaAsset] = []
        for (id, warm, duration) in [("original", true, 8), ("replacement", false, 8), ("short", false, 3)] {
            let url = media.appendingPathComponent(id + ".mov")
            try await FullflowAcceptanceFixture.writeVideo(to: url, duration: Double(duration), fps: 30, warm: warm)
            assets.append(MediaAsset(id: id, url: url, type: .video, name: id, duration: Double(duration)))
        }
        for id in ["reference", "recorder", "silence"] {
            let url = media.appendingPathComponent(id + ".wav")
            try writeAudio(url, silent: id == "silence")
            assets.append(MediaAsset(id: id, url: url, type: .audio, name: id, duration: 8))
        }
        var timeline = Timeline()
        timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
        var video = Clip(id: "picture", mediaRef: "original", startFrame: 0, durationFrames: 60)
        video.trimStartFrame = 60; video.speed = 2
        timeline.tracks = [Track(type: .video, clips: [video])]
        for (id, start) in [("reference", 0), ("recorder", 60), ("silence", 90)] {
            timeline.tracks.append(Track(type: .audio, clips: [Clip(id: id, mediaRef: id,
                mediaType: .audio, sourceClipType: .audio, startFrame: start, durationFrames: 240)]))
        }
        var manifest = MediaManifest(); manifest.entries = assets.map { $0.toManifestEntry(projectURL: package) }
        try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(timeline).write(to: directory.appendingPathComponent("before.json"))
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The source operations window did not open.") }
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = MainMenuBuilder.buildMenu(); NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var closed = false
        defer { if !closed { document.close() } }
        do {
            try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
            try await driver.wait("actual source-operation layout") { window.contentView?.bounds.size == AppTheme.Window.projectMin }
            let bounds = window.contentView!.bounds
            let measuredScale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
            guard measuredScale == scale else { throw GateBlocked("The requested source-operation interface scale was not applied.") }
            try GenericNLEAcceptance.pointerOnClip(video, editor: editor, window: window, driver: driver)
            try await menu(["Swap Media"], clip: video, editor: editor, window: window, driver: driver)
            try await driver.click("media.swap.cancel", in: window)
            try await driver.wait("source picker cancellation") { editor.pendingSwapClipId == nil && editor.timeline == timeline }
            try await menu(["Swap Media"], clip: video, editor: editor, window: window, driver: driver)
            try await driver.reveal("media.asset.short", in: window)
            guard let short = editor.mediaAssets.first(where: { $0.id == "short" }),
                  !editor.isAssetCompatibleWithPendingSwap(short), editor.timeline == timeline else {
                throw GateBlocked("A short replacement would silently lose the existing source trim.")
            }
            try driver.capture("swap-source", target: window)
            try await driver.click("media.asset.replacement", in: window)
            var swapped = timeline; swapped.tracks[0].clips[0].mediaRef = "replacement"
            try await driver.wait("native source replacement preserves trim and speed") { editor.timeline == swapped && editor.pendingSwapClipId == nil }
            try await undo(timeline, editor: editor, window: window, driver: driver)
            try await undo(swapped, redo: true, editor: editor, window: window, driver: driver)
            video = swapped.tracks[0].clips[0]
            let oldIDs = Set(editor.mediaAssets.map(\.id))
            try await menu(["Save as Media"], clip: video, editor: editor, window: window, driver: driver)
            let savedClip = try await savedAsset(excluding: oldIDs, editor: editor, driver: driver)
            let clipEvidence = try await decode(savedClip.url, expectedFrames: 60, output: directory.appendingPathComponent("clip.bgra"))
            guard abs(savedClip.duration - 2) < 0.05, editor.timeline == swapped else { throw GateBlocked("Saving a clip changed the edit or failed to bake its source trim and speed.") }
            try driver.capture("saved-clip", target: window)
            let view = try timelineView(window)
            let y = view.visibleRect.minY + view.geometry.rulerHeight / 2
            try await gesture(from: .init(x: view.geometry.xForFrame(15) + view.geometry.pixelsPerFrame / 2, y: y),
                to: .init(x: view.geometry.xForFrame(45) + view.geometry.pixelsPerFrame / 2, y: y),
                modifiers: .shift, in: view, window: window, driver: driver, label: "range-15-45")
            try await driver.wait("native timeline range") { editor.validSelectedTimelineRange?.startFrame == 15 && editor.validSelectedTimelineRange?.endFrame == 45 }
            let rangeIDs = Set(editor.mediaAssets.map(\.id))
            let rangePoint = NSPoint(x: view.geometry.xForFrame(30), y: y)
            try await driver.contextMenu(path: ["Save Range as Media"], in: window) {
                try AppNativeMenuAcceptance.pointer(rangePoint, in: view, window: window, driver: driver, label: "selected-range", right: true)
            }
            let savedRange = try await savedAsset(excluding: rangeIDs, editor: editor, driver: driver)
            let rangeEvidence = try await decode(savedRange.url, expectedFrames: 30, output: directory.appendingPathComponent("range.bgra"))
            guard abs(savedRange.duration - 1) < 0.05, savedRange.hasAudio, editor.timeline == swapped else {
                throw GateBlocked("The saved range is not the actual one-second picture and sound selection.")
            }
            try driver.capture("saved-range", target: window)
            try await driver.contextMenu(path: ["Clear Range"], in: window) {
                try AppNativeMenuAcceptance.pointer(rangePoint, in: view, window: window, driver: driver, label: "clear-selected-range", right: true)
            }
            try await driver.wait("range cleared") { editor.validSelectedTimelineRange == nil }
            let reference = swapped.tracks[1].clips[0], recorder = swapped.tracks[2].clips[0]
            try await select(reference, and: recorder, editor: editor, window: window, driver: driver)
            try await menu(["Synchronize", "Audio"], clip: recorder, editor: editor, window: window, driver: driver)
            var synchronized = swapped; synchronized.tracks[2].clips[0].startFrame = 0
            try await driver.wait("actual recorded audio correlation", seconds: 45) { editor.timeline == synchronized }
            guard editor.mediaPanelToast?.message.hasPrefix("Synchronized by audio") == true else { throw GateBlocked("Audio synchronization has no actual success result.") }
            try driver.capture("synchronized-audio", target: window)
            try await undo(swapped, editor: editor, window: window, driver: driver)
            try await undo(synchronized, redo: true, editor: editor, window: window, driver: driver)
            let silence = synchronized.tracks[3].clips[0]
            try await select(reference, and: silence, editor: editor, window: window, driver: driver)
            let previousMessage = editor.mediaPanelToast?.message
            try await menu(["Synchronize", "Audio"], clip: silence, editor: editor, window: window, driver: driver)
            try await driver.wait("silent source synchronization refusal", seconds: 45) { editor.mediaPanelToast?.message != previousMessage }
            guard editor.timeline == synchronized, let refusal = editor.mediaPanelToast?.message,
                  !refusal.isEmpty, !refusal.hasPrefix("Synchronized") else { throw GateBlocked("Silent audio was falsely synchronized.") }
            try driver.capture("sync-refused", target: window)
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("native source-operation save", seconds: 30) { !document.isDocumentEdited }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
            NSDocumentController.shared.addDocument(reopened); reopened.makeWindowControllers()
            defer { reopened.close() }
            guard reopened.editorViewModel.timeline == synchronized else { throw GateBlocked("Reopening lost the exact source and synchronization edits.") }
            let copies = [(savedClip.id, "clip.mp4"), (savedRange.id, "range.mp4")]
            for (id, name) in copies {
                guard let url = reopened.editorViewModel.mediaResolver.resolveURL(for: id) else { throw GateBlocked("Saved media did not survive reopening.") }
                try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
            }
            return ["directory": directory.lastPathComponent, "project": "Source operations.ngv",
                "viewport": [bounds.width, bounds.height], "effectiveScale": measuredScale,
                "clipID": savedClip.id, "rangeID": savedRange.id, "clip": clipEvidence, "range": rangeEvidence,
                "refusal": refusal, "interactions": driver.interactions, "screenshots": driver.screenshots]
        } catch {
            driver.failure(error); throw error
        }
    }

    private static func timelineView(_ window: NSWindow) throws -> TimelineView {
        guard let root = window.contentView,
              let view = AppNativeMenuAcceptance.views(root).compactMap({ $0 as? TimelineView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else {
            throw GateBlocked("The actual timeline is unavailable.")
        }
        return view
    }

    private static func menu(_ path: [String], clip: Clip, editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        let (view, point) = try await visibleClip(clip, editor: editor, window: window, driver: driver)
        try await driver.contextMenu(path: path, in: window) {
            try AppNativeMenuAcceptance.pointer(point, in: view, window: window, driver: driver, label: clip.id, right: true)
        }
    }

    private static func select(_ first: Clip, and second: Clip, editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        let (firstView, firstPoint) = try await visibleClip(first, editor: editor, window: window, driver: driver)
        try AppNativeMenuAcceptance.pointer(firstPoint, in: firstView, window: window, driver: driver, label: first.id)
        try await driver.wait("select reference") { editor.selectedClipIds == [first.id] }
        let (view, point) = try await visibleClip(second, editor: editor, window: window, driver: driver)
        try await gesture(from: point, to: point,
            modifiers: .shift, in: view, window: window, driver: driver, label: "select-" + second.id)
        try await driver.wait("select the two exact audio sources") { editor.selectedClipIds == [first.id, second.id] }
    }

    private static func gesture(from: NSPoint, to: NSPoint, modifiers: NSEvent.ModifierFlags, in view: NSView,
                                window: NSWindow, driver: ProductionVisualSourcesDriver, label: String) async throws {
        guard view.visibleRect.contains(from), view.visibleRect.contains(to), window.isKeyWindow else { throw GateBlocked("The native timeline gesture is clipped.") }
        try requireExposed(from, in: view, window: window)
        try requireExposed(to, in: view, window: window)
        let steps = from == to ? [0, 9] : Array(0...9)
        for step in steps {
            let f = CGFloat(min(step, 8)) / 8
            let point = NSPoint(x: from.x + f * (to.x - from.x), y: from.y + f * (to.y - from.y))
            let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step == 9 ? .leftMouseUp : .leftMouseDragged
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: step, clickCount: 1, pressure: step == 9 ? 0 : 1) else { throw GateBlocked("No native timeline event.") }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(30))
        }
        try driver.record("source-operation-gesture", fields: ["target": label, "from": [from.x, from.y], "to": [to.x, to.y], "shift": modifiers.contains(.shift)])
    }

    private static func visibleClip(_ clip: Clip, editor: EditorViewModel, window: NSWindow,
                                    driver: ProductionVisualSourcesDriver) async throws -> (TimelineView, NSPoint) {
        let view = try timelineView(window)
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clip.id }) }),
              let screen = NSScreen.screens.first else { throw GateBlocked("The native clip target is missing.") }
        for _ in 0..<30 {
            let rect = view.geometry.clipRect(for: clip, trackIndex: index).insetBy(dx: 12, dy: 4)
            var viewport = view.visibleRect.insetBy(dx: 2, dy: 2)
            viewport.origin.y += view.geometry.rulerHeight
            viewport.size.height -= view.geometry.rulerHeight
            let visible = rect.intersection(viewport)
            if !visible.isNull, visible.width > 2, visible.height > 2 {
                let point = NSPoint(x: visible.midX, y: visible.midY)
                try requireExposed(point, in: view, window: window)
                return (view, point)
            }
            guard rect.maxX > viewport.minX, rect.minX < viewport.maxX else { throw GateBlocked("The source clip lies outside the visible timeline time range.") }
            let point = NSPoint(x: viewport.midX, y: viewport.midY)
            try requireExposed(point, in: view, window: window)
            let global = window.convertPoint(toScreen: view.convert(point, to: nil))
            let delta: Int32 = rect.midY > viewport.midY ? -70 : 70
            let previous = view.visibleRect
            for event in try HangDiagnosticReplay.scrollGestureEvents(delta: delta,
                location: .init(x: global.x, y: screen.frame.height - global.y)) {
                view.scrollWheel(with: event)
                try await Task.sleep(for: .milliseconds(30))
            }
            try driver.record("source-operation-wheel", fields: ["target": clip.id, "deltaY": delta,
                "beforeY": previous.minY, "afterY": view.visibleRect.minY])
            guard view.visibleRect != previous else { throw GateBlocked("The source track cannot be reached with native scrolling.") }
        }
        throw GateBlocked("The source track did not become visible.")
    }

    private static func requireExposed(_ point: NSPoint, in view: NSView, window: NSWindow) throws {
        guard window.isKeyWindow, view.window === window, !view.isHiddenOrHasHiddenAncestor,
              let root = window.contentView, let hit = root.hitTest(view.convert(point, to: root)),
              hit === view || hit.isDescendant(of: view) else {
            throw GateBlocked("Another surface covers the source-operation pointer target.")
        }
    }

    private static func undo(_ expected: Timeline, redo: Bool = false, editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try driver.pressKey(6, characters: redo ? "Z" : "z", modifiers: redo ? [.command, .shift] : .command, in: window)
        try await driver.wait("exact source-operation Undo/Redo") { editor.timeline == expected }
    }

    private static func savedAsset(excluding ids: Set<String>, editor: EditorViewModel, driver: ProductionVisualSourcesDriver) async throws -> MediaAsset {
        try await driver.wait("real saved media completion", seconds: 60) {
            editor.mediaAssets.contains { !ids.contains($0.id) && !$0.isGenerating }
        }
        let created = editor.mediaAssets.filter { !ids.contains($0.id) }
        guard created.count == 1, let asset = created.first, asset.generationStatus == .none,
              FileManager.default.fileExists(atPath: asset.url.path) else { throw GateBlocked("Saving media did not finish successfully.") }
        return asset
    }

    private nonisolated static func writeAudio(_ url: URL, silent: Bool) throws {
        let rate = 16_000, count = 8 * 16_000
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(count * 2))
        var state: UInt64 = 101, amplitude = 0.0
        for index in 0..<count {
            if index % 160 == 0 { state = state &* 6364136223846793005 &+ 1442695040888963407; amplitude = 0.1 + Double((state >> 33) % 10_000) / 14_000 }
            word(Int16(silent ? 0 : (sin(2 * .pi * 440 * Double(index) / Double(rate)) * amplitude * 28_000).rounded()))
        }
        try data.write(to: url)
    }

    private static func decode(_ url: URL, expectedFrames: Int, output: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GateBlocked("Saved media has no video.") }
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(samples)
        guard reader.startReading() else { throw GateBlocked("Saved media is not decodable.") }
        var frames = 0, pixels = Data(), centers: [Double] = []
        while let sample = samples.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw GateBlocked("Saved video frame has no pixels.") }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { CVPixelBufferUnlockBaseAddress(buffer, .readOnly); throw GateBlocked("Saved video pixels are unreadable.") }
            let offset = (CVPixelBufferGetHeight(buffer) / 20) * CVPixelBufferGetBytesPerRow(buffer) + (CVPixelBufferGetWidth(buffer) / 20) * 4
            pixels.append(base.assumingMemoryBound(to: UInt8.self).advanced(by: offset), count: 4)
            let row = base.assumingMemoryBound(to: UInt8.self).advanced(by: (CVPixelBufferGetHeight(buffer) / 2) * CVPixelBufferGetBytesPerRow(buffer))
            let white = (0..<CVPixelBufferGetWidth(buffer)).filter { x in row[x * 4] > 220 && row[x * 4 + 1] > 220 && row[x * 4 + 2] > 220 }
            centers.append(white.isEmpty ? -1 : Double(white.reduce(0, +)) / Double(white.count))
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly); frames += 1
        }
        let duration = try await asset.load(.duration).seconds
        guard reader.status == .completed, frames == expectedFrames, abs(duration - Double(expectedFrames) / 30) < 0.05 else { throw GateBlocked("Decoded saved video has the wrong source duration.") }
        try pixels.write(to: output)
        let motion = output.deletingPathExtension().appendingPathExtension("motion.json")
        try JSONEncoder().encode(centers).write(to: motion)
        return ["sha256": try FileDigest.sha256(of: url), "frames": frames, "duration": duration,
            "pixels": output.lastPathComponent, "pixelsSHA256": FileDigest.sha256(of: pixels), "motion": motion.lastPathComponent]
    }
}
