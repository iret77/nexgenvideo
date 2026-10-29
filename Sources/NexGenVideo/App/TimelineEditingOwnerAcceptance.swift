import AppKit
import CryptoKit
import NexGenEngine

@MainActor
enum TimelineEditingOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "timeline-editing-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        let package = directory.appendingPathComponent("Timeline editing.ngv", isDirectory: true)
        let media = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let source = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        let movie = media.appendingPathComponent("Moving picture and tone.mov")
        try FileManager.default.copyItem(at: source, to: movie)
        let asset = MediaAsset(id: "source", url: movie, type: .video, name: "Moving picture and tone", duration: 8)
        var initial = Timeline()
        initial.width = 160; initial.height = 90; initial.fps = 30; initial.settingsConfigured = true
        func clip(_ id: String, _ start: Int, _ duration: Int, audio: Bool = false, group: String? = nil) -> Clip {
            var value = Clip(id: id, mediaRef: asset.id, mediaType: audio ? .audio : .video,
                sourceClipType: .video, startFrame: start, durationFrames: duration)
            value.trimStartFrame = 30; value.trimEndFrame = 240 - 30 - duration; value.linkGroupId = group
            return value
        }
        initial.tracks = [
            Track(id: "picture", type: .video, clips: [clip("a", 30, 60, group: "pair-a"), clip("b", 150, 60, group: "pair-b"), clip("target", 300, 60)]),
            Track(id: "sound", type: .audio, clips: [clip("a-audio", 30, 60, audio: true, group: "pair-a"), clip("b-audio", 150, 60, audio: true, group: "pair-b")]),
            Track(id: "sync", type: .audio, clips: [clip("obstacle", 0, 120, audio: true), clip("follower", 150, 60, audio: true)])
        ]
        var manifest = MediaManifest(); manifest.entries = [asset.toManifestEntry(projectURL: package)]
        try JSONEncoder().encode(initial).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The timeline editing window did not open.") }
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = MainMenuBuilder.buildMenu(); NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var closed = false
        defer { if !closed { document.close() } }
        do {
            try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
            try await driver.wait("actual timeline owner layout") { window.contentView?.bounds.size == AppTheme.Window.projectMin }
            let bounds = window.contentView!.bounds
            let effectiveScale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
            guard effectiveScale == scale, editor.timeline == initial else { throw GateBlocked("The native timeline fixture or interface scale changed before input.") }
            let view = try timelineView(window)
            try await fitVisibleFrames(380...650, view: view, window: window, editor: editor, driver: driver)
            try snapshot("initial", editor: editor, directory: directory)
            let pairIDs: Set<String> = ["a", "b", "a-audio", "b-audio"]
            try await marquee(view: view, window: window, driver: driver)
            try await driver.wait("marquee expands only the two actual linked pairs") { editor.selectedClipIds == pairIDs }
            try driver.record("timeline-marquee-selection", fields: ["ids": editor.selectedClipIds.sorted()])
            let toggle = point(frame: 60, row: 0, view: view)
            for (label, expected) in [("shift-remove-pair-a", Set(["b", "b-audio"])), ("shift-add-pair-a", pairIDs)] {
                try await gesture(from: toggle, to: toggle, modifiers: .shift, view: view, window: window, driver: driver, label: label)
                try await driver.wait("native linked Shift selection") { editor.selectedClipIds == expected }
                try driver.record("timeline-shift-selection", fields: ["ids": editor.selectedClipIds.sorted()])
            }
            try driver.capture("marquee", target: window)
            try await move("a", delta: 30, editor: editor, view: view, window: window, driver: driver, label: "group-move")
            var moved = initial
            for ti in moved.tracks.indices { for ci in moved.tracks[ti].clips.indices where pairIDs.contains(moved.tracks[ti].clips[ci].id) { moved.tracks[ti].clips[ci].startFrame += 30 } }
            try await driver.wait("exact group movement retains all source ranges") { editor.timeline == moved }
            try snapshot("group-move", editor: editor, directory: directory); try driver.capture("group-move", target: window)
            try await undo(initial, editor: editor, window: window, driver: driver)
            try await undo(moved, redo: true, editor: editor, window: window, driver: driver)
            try await undo(initial, editor: editor, window: window, driver: driver)
            try await marquee(view: view, window: window, driver: driver)
            try await driver.wait("same four native participants before duplicate") { editor.selectedClipIds == pairIDs }
            try await move("a", delta: 60, modifiers: .option, editor: editor, view: view, window: window, driver: driver, label: "option-duplicate")
            try await driver.wait("four native duplicates") { editor.timeline.tracks.flatMap(\.clips).count == 11 }
            let duplicated = editor.timeline
            let clones = duplicated.tracks.flatMap(\.clips).filter { !Set(initial.tracks.flatMap(\.clips).map(\.id)).contains($0.id) }
            guard clones.count == 4, editor.selectedClipIds == Set(clones.map(\.id)), Set(clones.compactMap(\.linkGroupId)).count == 2,
                  Set(clones.compactMap(\.linkGroupId)).isDisjoint(with: ["pair-a", "pair-b"]),
                  duplicated.tracks[2] == initial.tracks[2], initial.tracks.flatMap(\.clips).allSatisfy({ old in duplicated.tracks.flatMap(\.clips).contains(old) }) else {
                throw GateBlocked("Option-drag changed originals or reused their link identities.")
            }
            try snapshot("duplicate", editor: editor, directory: directory); try driver.capture("duplicate", target: window)
            try await undo(initial, editor: editor, window: window, driver: driver)
            try await undo(duplicated, redo: true, editor: editor, window: window, driver: driver)
            try await undo(initial, editor: editor, window: window, driver: driver)
            try await clickClip("a", editor: editor, view: view, window: window, driver: driver)
            try await key(8, "c", window: window, driver: driver)
            guard editor.toolMode == .razor else { throw GateBlocked("The native Razor shortcut was not routed to the timeline.") }
            let cut = point(frame: 60, row: 0, view: view)
            try await gesture(from: cut, to: cut, view: view, window: window, driver: driver, label: "razor-60", hover: true)
            try await driver.wait("native linked Razor split") { editor.timeline.tracks.flatMap(\.clips).count == 9 }
            try snapshot("razor", editor: editor, directory: directory); try driver.capture("razor", target: window)
            try await key(9, "v", window: window, driver: driver)
            try await undo(initial, editor: editor, window: window, driver: driver)
            for edge in ["left", "right"] {
                let rect = view.geometry.clipRect(for: initial.tracks[0].clips[0], trackIndex: 0)
                let from = NSPoint(x: edge == "left" ? rect.minX + 1 : rect.maxX - 1, y: rect.midY)
                let to = point(frame: edge == "left" ? 45 : 75, row: 0, view: view)
                try await gesture(from: from, to: to, view: view, window: window, driver: driver, label: "trim-" + edge)
                try await driver.wait("native linked " + edge + " trim") { editor.clipFor(id: "a")?.durationFrames == 45 && editor.clipFor(id: "a-audio")?.durationFrames == 45 }
                try snapshot("trim-" + edge, editor: editor, directory: directory); try driver.capture("trim-" + edge, target: window)
                try await undo(initial, editor: editor, window: window, driver: driver)
            }
            try await clickClip("a", editor: editor, view: view, window: window, driver: driver)
            let action = editor.undoManager?.undoActionName
            try await key(51, "\u{7f}", modifiers: .shift, window: window, driver: driver)
            guard editor.timeline == initial, editor.undoManager?.undoActionName == action else { throw GateBlocked("Sync-locked ripple collision mutated the edit or its undo stack.") }
            try snapshot("ripple-refused", editor: editor, directory: directory); try driver.capture("ripple-refused", target: window)
            try await toggleSync(editor: editor, view: view, window: window, driver: driver)
            let unlocked = editor.timeline
            guard !unlocked.tracks[2].syncLocked else { throw GateBlocked("The actual Sync Lock control did not change the intended track.") }
            try await revealRow(0, view: view, window: window, driver: driver)
            let rippleRect = view.geometry.clipRect(for: unlocked.tracks[0].clips[0], trackIndex: 0)
            try await gesture(from: NSPoint(x: rippleRect.maxX - 1, y: rippleRect.midY), to: point(frame: 75, row: 0, view: view),
                modifiers: .shift, view: view, window: window, driver: driver, label: "ripple-trim-right")
            try await driver.wait("native ripple trim moves linked following edits") { editor.clipFor(id: "a")?.durationFrames == 45 && editor.clipFor(id: "b")?.startFrame == 135 }
            try snapshot("ripple-trim", editor: editor, directory: directory); try driver.capture("ripple-trim", target: window)
            try await undo(unlocked, editor: editor, window: window, driver: driver)
            try await clickClip("a", editor: editor, view: view, window: window, driver: driver)
            try await key(51, "\u{7f}", modifiers: .shift, window: window, driver: driver)
            try await driver.wait("native ripple deletes the selected linked pair") { editor.clipFor(id: "a") == nil && editor.clipFor(id: "a-audio") == nil }
            try snapshot("ripple-delete", editor: editor, directory: directory); try driver.capture("ripple-delete", target: window)
            try await undo(unlocked, editor: editor, window: window, driver: driver)
            let gap = point(frame: 120, row: 0, view: view)
            try await gesture(from: gap, to: gap, view: view, window: window, driver: driver, label: "select-gap-90-150")
            guard editor.selectedGap?.range.start == 90, editor.selectedGap?.range.end == 150 else { throw GateBlocked("The native gap selection does not match the visible empty interval.") }
            try await key(51, "\u{7f}", modifiers: .shift, window: window, driver: driver)
            try await driver.wait("native gap closure") { editor.clipFor(id: "b")?.startFrame == 90 && editor.clipFor(id: "b-audio")?.startFrame == 90 }
            try snapshot("gap-close", editor: editor, directory: directory); try driver.capture("gap-close", target: window)
            try await undo(unlocked, editor: editor, window: window, driver: driver)
            try await clickClip("a", editor: editor, view: view, window: window, driver: driver)
            try await move("a", delta: 209, editor: editor, view: view, window: window, driver: driver, label: "snap-raw-239-to-240")
            try await driver.wait("native edge snapping at target frame 300") { editor.clipFor(id: "a")?.startFrame == 240 && editor.clipFor(id: "a-audio")?.startFrame == 240 }
            try snapshot("snap", editor: editor, directory: directory); try driver.capture("snap", target: window)
            try await undo(unlocked, editor: editor, window: window, driver: driver)
            try await clickClip("target", editor: editor, view: view, window: window, driver: driver)
            try await key(51, "\u{7f}", window: window, driver: driver)
            try await driver.wait("remove only the snapping target before edge-drag") { editor.clipFor(id: "target") == nil }
            let beforeScroll = editor.timeline
            try snapshot("before-scroll", editor: editor, directory: directory)
            try GenericNLEAcceptance.pointerOnRuler(frame: 0, window: window, driver: driver)
            try await driver.wait("zoom anchor at zero") { editor.currentFrame == 0 }
            try await fitVisibleFrames(110...150, view: view, window: window, editor: editor, driver: driver)
            try await clickClip("a", editor: editor, view: view, window: window, driver: driver)
            let scroll = try await heldEdgeMove(editor: editor, view: view, window: window, driver: driver, cancel: false)
            let final = editor.timeline
            guard let delta = scroll["deltaFrames"] as? Int, delta > 0 else { throw GateBlocked("No actual edge move was committed.") }
            var expected = beforeScroll
            for ti in expected.tracks.indices { for ci in expected.tracks[ti].clips.indices where ["a", "a-audio"].contains(expected.tracks[ti].clips[ci].id) { expected.tracks[ti].clips[ci].startFrame += delta } }
            guard final == expected else { throw GateBlocked("Autoscroll changed unrelated clips or source trims.") }
            try snapshot("scroll-move", editor: editor, directory: directory); try driver.capture("scroll-move", target: window)
            try await undo(beforeScroll, editor: editor, window: window, driver: driver)
            try await revealFrame(45, view: view, window: window, driver: driver)
            try await clickClip("a", editor: editor, view: view, window: window, driver: driver)
            let cancelled = try await heldEdgeMove(editor: editor, view: view, window: window, driver: driver, cancel: true)
            guard editor.timeline == beforeScroll else { throw GateBlocked("Escape committed a pending edge drag.") }
            try snapshot("scroll-cancel", editor: editor, directory: directory); try driver.capture("scroll-cancel", target: window)
            try await undo(final, redo: true, editor: editor, window: window, driver: driver)
            try await key(1, "s", modifiers: .command, window: window, driver: driver)
            try await driver.wait("native timeline save", seconds: 30) { !document.isDocumentEdited }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
            defer { reopened.close() }
            guard reopened.editorViewModel.timeline == final, let actual = reopened.editorViewModel.mediaResolver.resolveURL(for: asset.id),
                  try Data(contentsOf: actual) == Data(contentsOf: movie) else { throw GateBlocked("Reopening lost actual timeline edits or their media source.") }
            return ["directory": name, "project": package.lastPathComponent, "viewport": [bounds.width, bounds.height],
                "effectiveScale": effectiveScale, "sourceSHA256": SHA256.hash(data: try Data(contentsOf: movie)).map { String(format: "%02x", $0) }.joined(),
                "scroll": scroll, "cancelledScroll": cancelled, "interactions": driver.interactions, "screenshots": driver.screenshots]
        } catch { driver.failure(error); throw error }
    }

    private static func snapshot(_ name: String, editor: EditorViewModel, directory: URL) throws {
        try JSONEncoder().encode(editor.timeline).write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    private static func timelineView(_ window: NSWindow) throws -> TimelineView {
        guard let root = window.contentView, let view = AppNativeMenuAcceptance.views(root).compactMap({ $0 as? TimelineView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else { throw GateBlocked("The actual timeline is unavailable.") }
        return view
    }

    private static func point(frame: Int, row: Int, view: TimelineView) -> NSPoint {
        NSPoint(x: view.geometry.xForFrame(frame) + view.geometry.pixelsPerFrame / 2,
            y: view.geometry.trackY(at: row) + view.geometry.trackHeight(at: row) / 2)
    }

    private static func exposed(_ point: NSPoint, view: NSView, window: NSWindow) throws {
        guard window.isKeyWindow, view.window === window, !view.isHiddenOrHasHiddenAncestor, view.visibleRect.contains(point),
              let root = window.contentView, let hit = root.hitTest(view.convert(point, to: root.superview)), hit === view || hit.isDescendant(of: view) else { throw GateBlocked("The native timeline target is clipped or covered.") }
    }

    private static func post(_ type: NSEvent.EventType, point: NSPoint, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) throws {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { throw GateBlocked("The native timeline pointer event is unavailable.") }
        NSApp.postEvent(event, atStart: false)
    }

    private static func gesture(from: NSPoint, to: NSPoint, modifiers: NSEvent.ModifierFlags = [], view: TimelineView,
                                window: NSWindow, driver: ProductionVisualSourcesDriver, label: String, hover: Bool = false) async throws {
        try exposed(from, view: view, window: window); try exposed(to, view: view, window: window)
        let first = view.convert(from, to: nil), last = view.convert(to, to: nil)
        if hover {
            try post(.mouseMoved, point: first, window: window)
            try await driver.wait("actual Razor hover at frame 60") { view.inputController.razorPreviewFrame == 60 }
        }
        var released = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            MainActor.assumeIsolated { if event.windowNumber == window.windowNumber { released = true } }; return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let steps = from == to ? [0, 9] : Array(0...9)
        for step in steps {
            let f = CGFloat(min(step, 8)) / 8
            try post(step == 0 ? .leftMouseDown : step == 9 ? .leftMouseUp : .leftMouseDragged,
                point: NSPoint(x: first.x + (last.x - first.x) * f, y: first.y + (last.y - first.y) * f), modifiers: modifiers, window: window)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await driver.wait("native mouse-up delivery: " + label) { released }
        try driver.record("timeline-gesture", fields: ["target": label, "from": [from.x, from.y], "to": [to.x, to.y],
            "modifiers": modifiers.rawValue, "window": window.windowNumber, "delivered": released])
    }

    private static func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        var delivered = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            MainActor.assumeIsolated { if event.windowNumber == window.windowNumber, event.keyCode == code { delivered = true } }; return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        try driver.pressKey(code, characters: characters, modifiers: modifiers, in: window)
        try await driver.wait("native key-up delivery") { delivered }
    }

    private static func undo(_ expected: Timeline, redo: Bool = false, editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await key(6, redo ? "Z" : "z", modifiers: redo ? [.command, .shift] : .command, window: window, driver: driver)
        try await driver.wait("exact timeline Undo/Redo") { editor.timeline == expected }
    }

    private static func clickClip(_ id: String, editor: EditorViewModel, view: TimelineView, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard let clip = editor.clipFor(id: id), let row = editor.timeline.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }) else { throw GateBlocked("The actual timeline clip is missing.") }
        try await key(53, "\u{1b}", window: window, driver: driver)
        let p = point(frame: clip.startFrame + clip.durationFrames / 2, row: row, view: view)
        try await gesture(from: p, to: p, view: view, window: window, driver: driver, label: "select-" + id)
        try await driver.wait("native linked clip selection") { editor.selectedClipIds == editor.expandToLinkGroup([id]) }
    }

    private static func marquee(view: TimelineView, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        let y = view.geometry.trackY(at: 0)
        try await gesture(from: NSPoint(x: view.geometry.xForFrame(10), y: y + 4),
            to: NSPoint(x: view.geometry.xForFrame(220), y: y + view.geometry.trackHeight(at: 0) - 4),
            view: view, window: window, driver: driver, label: "marquee-pairs")
    }

    private static func move(_ id: String, delta: Int, modifiers: NSEvent.ModifierFlags = [], editor: EditorViewModel,
                             view: TimelineView, window: NSWindow, driver: ProductionVisualSourcesDriver, label: String) async throws {
        guard let clip = editor.clipFor(id: id), let row = editor.timeline.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }) else { throw GateBlocked("The moved clip is missing.") }
        let from = point(frame: clip.startFrame + 15, row: row, view: view)
        try await gesture(from: from, to: NSPoint(x: from.x + Double(delta) * view.geometry.pixelsPerFrame, y: from.y),
            modifiers: modifiers, view: view, window: window, driver: driver, label: label)
    }

    private static func fitVisibleFrames(_ range: ClosedRange<Double>, view: TimelineView, window: NSWindow, editor: EditorViewModel,
                                         driver: ProductionVisualSourcesDriver) async throws {
        for _ in 0..<30 {
            let count = view.visibleRect.width / view.geometry.pixelsPerFrame
            if range.contains(count) { return }
            let before = editor.zoomScale
            try await driver.click(count > range.upperBound ? "timeline.zoom.in" : "timeline.zoom.out", in: window)
            try await driver.wait("actual timeline zoom") { editor.zoomScale != before }
        }
        throw GateBlocked("The required native timeline zoom could not be reached.")
    }

    private static func wheel(_ delta: Int32, horizontal: Bool, view: TimelineView, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard let screen = NSScreen.screens.first else { throw GateBlocked("No native screen for timeline scroll.") }
        let p = NSPoint(x: view.visibleRect.midX, y: view.visibleRect.maxY - 8)
        try exposed(p, view: view, window: window)
        let global = window.convertPoint(toScreen: view.convert(p, to: nil))
        let location = CGPoint(x: global.x, y: screen.frame.maxY - global.y)
        try await ProductionNativeReadingAcceptance.movePointer(to: location, window: window, driver: driver)
        let before = view.visibleRect
        for event in try HangDiagnosticReplay.scrollGestureEvents(delta: delta, location: location) {
            guard let cg = event.cgEvent else { throw GateBlocked("The native wheel event is unavailable.") }
            if horizontal { cg.flags.insert(.maskCommand) }
            cg.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await driver.wait("actual timeline wheel delivery") {
            horizontal ? view.visibleRect.minX != before.minX : view.visibleRect.minY != before.minY
        }
        try driver.record("timeline-wheel", fields: ["horizontal": horizontal, "delta": delta,
            "before": [before.minX, before.minY], "after": [view.visibleRect.minX, view.visibleRect.minY]])
    }

    private static func revealFrame(_ frame: Int, view: TimelineView, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        for _ in 0..<30 {
            let x = view.geometry.xForFrame(frame)
            if x > view.visibleRect.minX + 20, x < view.visibleRect.maxX - 20 { return }
            try await wheel(x < view.visibleRect.midX ? 60 : -60, horizontal: true, view: view, window: window, driver: driver)
        }
        throw GateBlocked("The timeline frame cannot be reached by native wheel input.")
    }

    private static func revealRow(_ row: Int, view: TimelineView, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        for _ in 0..<30 {
            let y = view.geometry.trackY(at: row) + view.geometry.trackHeight(at: row) / 2
            if y > view.visibleRect.minY + view.geometry.rulerHeight + 4, y < view.visibleRect.maxY - 4 { return }
            try await wheel(y < view.visibleRect.midY ? 60 : -60, horizontal: false, view: view, window: window, driver: driver)
        }
        throw GateBlocked("The timeline row cannot be reached by native wheel input.")
    }

    private static func toggleSync(editor: EditorViewModel, view: TimelineView, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await revealRow(2, view: view, window: window, driver: driver)
        guard let root = window.contentView, let header = AppNativeMenuAcceptance.views(root).compactMap({ $0 as? TimelineHeaderView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else { throw GateBlocked("The actual track header is missing.") }
        header.displayIfNeeded()
        guard let rect = header.syncLockButtonRects[2], header.visibleRect.contains(rect) else { throw GateBlocked("The actual Sync Lock control is clipped.") }
        try AppNativeMenuAcceptance.pointer(NSPoint(x: rect.midX, y: rect.midY), in: header, window: window, driver: driver, label: "sync-track-unlock")
        try await driver.wait("native Sync Lock change") { !editor.timeline.tracks[2].syncLocked }
    }

    private static func heldEdgeMove(editor: EditorViewModel, view: TimelineView, window: NSWindow,
                                     driver: ProductionVisualSourcesDriver, cancel: Bool) async throws -> [String: Any] {
        guard let clip = editor.clipFor(id: "a") else { throw GateBlocked("The edge-drag clip is missing.") }
        let from = point(frame: clip.startFrame + 15, row: 0, view: view)
        let to = NSPoint(x: view.visibleRect.maxX - 2, y: from.y)
        try exposed(from, view: view, window: window); try exposed(to, view: view, window: window)
        let initial = view.visibleRect, pixelsPerFrame = view.geometry.pixelsPerFrame
        let held = view.convert(to, to: nil), first = view.convert(from, to: nil)
        try post(.leftMouseDown, point: first, window: window)
        try post(.leftMouseDragged, point: held, window: window)
        try await driver.wait("edge drag enters the actual move controller") { if case .moveClip = view.inputController.dragState { true } else { false } }
        let firstOffset = view.visibleRect.minX
        try await driver.wait("stationary native pointer continues scrolling") {
            if case .moveClip(let drag) = view.inputController.dragState {
                return view.visibleRect.minX > firstOffset + 20 && drag.lead.originalFrame + drag.deltaFrames > 215
            }
            return false
        }
        var releasedDelta: Int?
        var released = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            MainActor.assumeIsolated {
                if event.windowNumber == window.windowNumber {
                    released = true
                    if case .moveClip(let drag) = view.inputController.dragState { releasedDelta = drag.deltaFrames }
                }
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let heldOffset = view.visibleRect.minX
        if cancel { try await key(53, "\u{1b}", window: window, driver: driver) }
        try post(.leftMouseUp, point: held, window: window)
        try await driver.wait("native edge drag finishes") { if case .idle = view.inputController.dragState { released } else { false } }
        let stopped = view.visibleRect
        try await Task.sleep(for: .milliseconds(160))
        guard view.visibleRect == stopped, cancel || releasedDelta != nil else { throw GateBlocked("The timeline kept scrolling after the native gesture ended.") }
        let result: [String: Any] = ["initialX": initial.minX, "initialWidth": initial.width, "pixelsPerFrame": pixelsPerFrame,
            "firstX": firstOffset, "heldX": heldOffset, "stoppedX": stopped.minX, "afterStopX": view.visibleRect.minX,
            "deltaFrames": releasedDelta ?? 0, "cancelled": cancel, "dragEvents": 1,
            "fromWindow": [first.x, first.y], "heldWindow": [held.x, held.y]]
        try driver.record("timeline-held-edge", fields: result)
        return result
    }
}
