import AppKit
import NexGenEngine

@MainActor
enum AppViewOwnerAcceptance {
    struct PersistedLayout {
        let documentInstance: String
        let windowInstance: String
        let timeline: Timeline
        let widths: [CGFloat]
        let savedFrames: String
    }

    static func prepareReopen(document: VideoProject, window: NSWindow,
                              driver: ProductionVisualSourcesDriver) async throws -> PersistedLayout {
        let editor = document.editorViewModel
        let timeline = editor.timeline
        window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil)
        try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
        try await AppNativeMenuAcceptance.choose(["View", "Layout", "Media"], in: window, driver: driver)
        try await driver.wait("reopen Media layout") {
            editor.layoutPreset == .media && window.contentView?.bounds.size == NSSize(width: 960, height: 640)
        }
        if !editor.isSidebarPresented { try await driver.click("editor.panel.sidebar", in: window, enabled: false) }
        if editor.isInspectorPresented { try await driver.click("editor.panel.inspector", in: window, enabled: false) }
        try await driver.wait("reopen panel choices") {
            editor.isSidebarPresented && !editor.isInspectorPresented && persistedSplit(window) != nil
        }
        guard let split = persistedSplit(window) else { throw GateBlocked("The saved Media divider is unavailable.") }
        let before = split.subviews[0].frame.width
        let previousFrames = savedDividerFrames()
        let point = NSPoint(x: split.subviews[0].frame.maxX + split.dividerThickness / 2, y: split.bounds.midY)
        let unsavedWidth = round(split.bounds.width * 0.3)
        var offset: CGFloat = before < split.bounds.width / 2 ? 24 : -24
        if abs(before + offset - unsavedWidth) <= 8 { offset *= 2 }
        try await AppNativeMenuAcceptance.drag(from: point, to: .init(x: point.x + offset, y: point.y), in: split,
            window: window, driver: driver, label: "editor.persisted-splitter")
        try await driver.wait("reopen divider actually changed and autosaved") {
            abs(split.subviews[0].frame.width - before) > 8
                && abs(split.subviews[0].frame.width - unsavedWidth) > 8
                && savedDividerFrames() != nil && savedDividerFrames() != previousFrames
        }
        guard let frames = savedDividerFrames(), editor.timeline == timeline, !document.isDocumentEdited else {
            throw GateBlocked("The layout change mutated project truth or did not autosave its divider.")
        }
        let expected = PersistedLayout(documentInstance: String(describing: ObjectIdentifier(document)),
            windowInstance: String(describing: ObjectIdentifier(window)), timeline: timeline,
            widths: split.subviews.map { $0.frame.width }, savedFrames: frames)
        var fields = layoutFields(document: document, window: window, split: split, widths: expected.widths, frames: frames)
        fields["resizeStartWidth"] = before
        fields["timelineSHA256"] = try ExportArtwork.timelineHash(timeline)
        try driver.record("layout before close", fields: fields)
        try driver.capture("layout-before-close", target: window)
        return expected
    }

    static func verifyReopen(_ expected: PersistedLayout, document: VideoProject, window: NSWindow,
                             driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let editor = document.editorViewModel
        guard String(describing: ObjectIdentifier(document)) != expected.documentInstance,
              String(describing: ObjectIdentifier(window)) != expected.windowInstance,
              editor.layoutPreset == .media else { throw GateBlocked("The layout check reused a document or reset its persisted preset.") }
        window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil)
        try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
        try await driver.wait("actual reopened layout, independent panels and divider") {
            guard let split = persistedSplit(window), split.subviews.count == expected.widths.count else { return false }
            return editor.layoutPreset == .media && editor.isSidebarPresented && !editor.isInspectorPresented
                && zip(split.subviews.map { $0.frame.width }, expected.widths).allSatisfy { abs($0.0 - $0.1) < 2 }
                && savedDividerFrames() == expected.savedFrames && editor.timeline == expected.timeline
        }
        guard let split = persistedSplit(window), let frames = savedDividerFrames() else {
            throw GateBlocked("The reopened layout has no actual autosaved divider.")
        }
        var fields = layoutFields(document: document, window: window, split: split, widths: split.subviews.map { $0.frame.width }, frames: frames)
        fields["timelineSHA256"] = try ExportArtwork.timelineHash(editor.timeline)
        try driver.record("layout after reopen", fields: fields)
        try driver.capture("layout-after-reopen", target: window)
        return fields
    }

    private static func currentDefaultSplit(_ window: NSWindow) -> NSSplitView? {
        guard let root = window.contentView else { return nil }
        return AppNativeMenuAcceptance.views(root).compactMap { $0 as? NSSplitView }.first {
            $0.isVertical && !$0.isHiddenOrHasHiddenAncestor && $0.subviews.count >= 3
                && $0.subviews.allSatisfy { $0.frame.width > 80 }
        }
    }

    private static func persistedSplit(_ window: NSWindow) -> NSSplitView? {
        guard let root = window.contentView else { return nil }
        return AppNativeMenuAcceptance.views(root).compactMap { $0 as? NSSplitView }.first {
            $0.autosaveName == "editor.media.preset" && $0.isVertical && !$0.isHiddenOrHasHiddenAncestor
                && $0.subviews.count == 2 && $0.subviews.allSatisfy { $0.frame.width > 80 }
        }
    }

    private static func savedDividerFrames() -> String? {
        guard let value = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames editor.media.preset"),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func layoutFields(document: VideoProject, window: NSWindow, split: NSSplitView, widths: [CGFloat], frames: String) -> [String: Any] {
        ["documentInstance": String(describing: ObjectIdentifier(document)),
         "windowInstance": String(describing: ObjectIdentifier(window)), "windowNumber": window.windowNumber,
         "projectID": document.fileURL.flatMap { ProjectIdentity.existingUUID(for: $0) } ?? "", "layout": document.editorViewModel.layoutPreset.rawValue,
         "sidebar": document.editorViewModel.isSidebarPresented, "inspector": document.editorViewModel.isInspectorPresented,
         "widths": widths, "autosaveName": split.autosaveName ?? "", "savedFrames": frames,
         "splitWidth": split.bounds.width, "dividerThickness": split.dividerThickness,
         "viewport": [window.contentView?.bounds.width ?? 0, window.contentView?.bounds.height ?? 0]]
    }

    static func run(editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
        guard let clip = editor.timeline.tracks.first(where: { $0.type == .video })?.clips.first else { throw GateBlocked("The layout check needs an actual edited clip.") }
        try GenericNLEAcceptance.pointerOnClip(clip, editor: editor, window: window, driver: driver)
        try GenericNLEAcceptance.pointerOnRuler(frame: 12, window: window, driver: driver)
        try await driver.wait("selected timeline context") { editor.currentFrame == 12 && editor.activePreviewTab == .timeline }
        let timeline = editor.timeline, selection = editor.selectedClipIds
        for focus in [EditorViewModel.WorkspaceFocus.media, .production, .postproduction, .export, .edit] {
            try await NativeEditingOwnerAcceptance.workspace(focus, editor: editor, window: window, driver: driver)
            guard !editor.hasProductionPipeline, editor.timeline == timeline else { throw GateBlocked("Workspace navigation enrolled a pipeline or changed the edited film.") }
        }
        let sidebar = editor.isSidebarPresented, inspector = editor.isInspectorPresented
        try await driver.click("editor.panel.sidebar", in: window, enabled: false)
        try await driver.wait("independent sidebar toggle") { editor.isSidebarPresented != sidebar && editor.isInspectorPresented == inspector }
        try await driver.click("editor.panel.sidebar", in: window, enabled: false)
        try await driver.wait("sidebar restored") { editor.isSidebarPresented == sidebar && editor.isInspectorPresented == inspector }
        try await driver.click("editor.panel.inspector", in: window, enabled: false)
        try await driver.wait("independent inspector toggle") { editor.isInspectorPresented != inspector && editor.isSidebarPresented == sidebar }
        try await driver.click("editor.panel.inspector", in: window, enabled: false)
        try await driver.wait("inspector restored") { editor.isInspectorPresented == inspector && editor.isSidebarPresented == sidebar }
        for preset in LayoutPreset.allCases {
            try await AppNativeMenuAcceptance.choose(["View", "Layout", preset.label], in: window, driver: driver)
            try await driver.wait("native layout " + preset.label) { editor.layoutPreset == preset }
            try driver.visible(["editor.panel.sidebar", "editor.panel.inspector", "preview.canvas"], in: window)
            try driver.capture("layout-" + preset.rawValue, target: window)
        }
        try await AppNativeMenuAcceptance.choose(["View", "Layout", "Default"], in: window, driver: driver)
        try await driver.wait("default layout") { editor.layoutPreset == .default }
        guard let root = window.contentView,
              let split = AppNativeMenuAcceptance.views(root).compactMap({ $0 as? NSSplitView }).first(where: {
                  $0.isVertical && !$0.isHiddenOrHasHiddenAncestor && $0.subviews.count >= 3 && $0.subviews.allSatisfy { $0.frame.width > 80 }
              }) else { throw GateBlocked("The actual three-panel divider is unavailable.") }
        let originalWidth = split.subviews[0].frame.width
        let point = NSPoint(x: split.subviews[0].frame.maxX + split.dividerThickness / 2, y: split.bounds.midY)
        try await AppNativeMenuAcceptance.drag(from: point, to: .init(x: point.x + 32, y: point.y), in: split,
            window: window, driver: driver, label: "editor.splitter")
        try await driver.wait("actual divider resize") { split.subviews[0].frame.width > originalWidth + 8 }
        let resized = split.subviews.map(\.frame)
        try await driver.click("preview.canvas", in: window)
        try await driver.wait("preview keyboard focus") { editor.focusedPanel == .preview }
        try await AppNativeMenuAcceptance.choose(["View", "Maximize Focused Panel"], in: window, driver: driver)
        try await driver.wait("native maximized viewer") { editor.maximizedPanel == .preview }
        try driver.capture("viewer-maximized", target: window)
        try driver.pressKey(53, characters: "\u{1b}", in: window)
        try await driver.wait("native maximize restored") { editor.maximizedPanel == nil }
        let frame = editor.currentFrame
        try await AppNativeMenuAcceptance.choose(["View", "Theater"], in: window, driver: driver)
        try await driver.wait("actual theater presentation") { editor.theaterActive }
        try driver.capture("theater", target: window)
        try driver.pressKey(53, characters: "\u{1b}", in: window)
        try await driver.wait("theater restores exact editor context") {
            !editor.theaterActive && editor.currentFrame == frame && editor.selectedClipIds == selection
                && editor.isSidebarPresented == sidebar && editor.isInspectorPresented == inspector
                && editor.activePreviewTab == .timeline && editor.timeline == timeline
                && currentDefaultSplit(window).map { current in
                    current.subviews.count == resized.count && zip(current.subviews.map(\.frame), resized).allSatisfy {
                        abs($0.0.minX - $0.1.minX) < 2 && abs($0.0.width - $0.1.width) < 2
                    }
                } == true
        }
        try await AppNativeMenuAcceptance.choose(["View", "Enter Full Screen"], in: window, driver: driver)
        try await driver.wait("native full screen", seconds: 20) { window.styleMask.contains(.fullScreen) }
        try driver.capture("full-screen", target: window)
        try driver.pressKey(3, characters: "f", modifiers: .command, in: window)
        try await driver.wait("native full-screen restoration", seconds: 20) {
            !window.styleMask.contains(.fullScreen) && abs(window.contentView!.bounds.width - 960) < 2
                && abs(window.contentView!.bounds.height - 640) < 2 && editor.timeline == timeline && editor.currentFrame == frame
        }
        try await driver.menu("preview.zoom", title: "200%", in: window)
        try await driver.wait("actual canvas zoom") { editor.canvasZoom == 2 }
        try driver.capture("viewer-zoom", target: window)
        try await driver.menu("preview.zoom", title: "Fit", in: window)
        try await driver.wait("actual canvas fit") { editor.canvasZoom == 1 && editor.canvasOffset == .zero }
        guard let currentRoot = window.contentView,
              let preview = AppNativeMenuAcceptance.views(currentRoot).compactMap({ $0 as? PreviewNSView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
              let screen = NSScreen.screens.first else { throw GateBlocked("The actual video canvas is unavailable for anchored zoom.") }
        let local = NSPoint(x: preview.bounds.width * 0.3, y: preview.bounds.height * 0.6)
        let global = window.convertPoint(toScreen: preview.convert(local, to: nil))
        guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0) else {
            throw GateBlocked("The actual anchored canvas wheel event is unavailable.")
        }
        wheel.location = CGPoint(x: global.x, y: screen.frame.height - global.y)
        try await ProductionNativeReadingAcceptance.movePointer(to: wheel.location, window: window, driver: driver)
        wheel.flags = .maskCommand; wheel.post(tap: .cghidEventTap)
        try await driver.wait("actual anchored canvas wheel") { editor.canvasZoom > 1 && editor.canvasOffset != .zero }
        let anchoredZoom = editor.canvasZoom, anchoredOffset = editor.canvasOffset
        guard let pan = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 8, wheel2: 6, wheel3: 0) else {
            throw GateBlocked("The actual canvas pan wheel event is unavailable.")
        }
        pan.location = wheel.location; pan.post(tap: .cghidEventTap)
        try await driver.wait("actual free canvas pan") { editor.canvasOffset != anchoredOffset && editor.canvasZoom == anchoredZoom }
        let panned = editor.canvasOffset
        guard editor.timeline == timeline && editor.selectedClipIds == selection else { throw GateBlocked("Canvas Pan changed clip geometry or selection.") }
        try driver.capture("viewer-panned", target: window)
        try driver.record("native-viewer-wheel", fields: ["zoom": anchoredZoom,
            "anchoredOffset": [anchoredOffset.width, anchoredOffset.height], "pannedOffset": [panned.width, panned.height],
            "input": "command-wheel-then-plain-wheel", "timelineUnchanged": true])
        try await driver.menu("preview.zoom", title: "Fit", in: window)
        try await driver.wait("Fit clears actual zoom and offset") { editor.canvasZoom == 1 && editor.canvasOffset == .zero && editor.timeline == timeline }
        try await overlayDrag(clip: clip, editor: editor, window: window, driver: driver)
        try await driver.click("preview.canvas", in: window)
        try driver.pressKey(124, characters: "\u{f703}", in: window)
        try await driver.wait("one-frame forward transport") { editor.currentFrame == frame + 1 }
        try driver.pressKey(123, characters: "\u{f702}", in: window)
        try await driver.wait("one-frame backward transport") { editor.currentFrame == frame }
        try await driver.click("preview.transport.play.fill", in: window)
        try await driver.wait("actual timeline playback advances", seconds: 10) { editor.isPlaying && editor.currentFrame > frame + 2 }
        try await driver.click("preview.transport.pause.fill", in: window)
        try await driver.wait("actual timeline playback paused") { !editor.isPlaying }
        let zoom = editor.zoomScale
        try await driver.click("timeline.zoom.in", in: window)
        try await driver.wait("native timeline zoom") { editor.zoomScale > zoom }
        try await driver.click("timeline.zoom.out", in: window)
        try await driver.wait("native timeline zoom restored") { abs(editor.zoomScale - zoom) < 0.001 }
        guard editor.timeline == timeline, editor.selectedClipIds == selection else { throw GateBlocked("Viewing and layout controls changed edited project truth.") }
        try driver.capture("view-restored", target: window)
        return ["nativeWorkspaces": ["media", "production", "postproduction", "export", "edit"], "independentPanels": true, "nativeLayouts": LayoutPreset.allCases.map(\.rawValue), "nativeSplitter": true,
            "maximizedViewerRestored": true, "theaterRestored": true, "fullScreenRestored": true,
            "viewerZoomFit": true, "anchoredCanvasWheel": true, "freePanPreservesOutput": true, "transformAndCropRemainInteractive": true, "frameStepPlayback": true, "timelineZoom": true,
            "unchangedTimelineSHA256": try ExportArtwork.timelineHash(timeline)]
    }

    private static func overlayDrag(clip: Clip, editor: EditorViewModel, window: NSWindow,
                                    driver: ProductionVisualSourcesDriver) async throws {
        let before = editor.timeline
        guard let root = window.contentView else { throw GateBlocked("The actual canvas root disappeared.") }
        try await driver.menu("preview.zoom", title: "50%", in: window)
        try await driver.wait("native overlay at visible half size") { editor.canvasZoom == 0.5 }
        let moveID = "preview.transform.move." + clip.id
        try await driver.wait("actual transform gesture surface") { driver.state(moveID, in: window) == true }
        guard let move = WorkspaceUIAcceptance.probeFrame(identifier: moveID, in: window) else { throw GateBlocked("The actual transform gesture frame is missing.") }
        let start = NSPoint(x: move.midX, y: move.midY)
        try await AppNativeMenuAcceptance.drag(from: start, to: .init(x: start.x + 18, y: start.y), in: root,
            window: window, driver: driver, label: "preview.transform.move")
        try await driver.wait("native transform drag passes wheel surface") { editor.timeline != before }
        guard editor.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clip.id })?.transformAt(frame: editor.activeFrame) != clip.transformAt(frame: editor.activeFrame) else {
            throw GateBlocked("The native transform gesture did not change the selected clip.")
        }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("native transform drag Undo") { editor.timeline == before }
        try await driver.click("inspector.tab.Video", in: window, enabled: false)
        try await driver.wait("actual Video inspector") { driver.state("inspector.tab.Video", in: window) == true }
        try await driver.click("inspector.crop.edit", in: window)
        try await driver.wait("actual canvas crop mode") { editor.cropEditingActive && driver.text("inspector.crop.edit", in: window) == "editing" }
        let cropID = "preview.crop.topLeft." + clip.id
        try await driver.wait("actual crop corner") { driver.state(cropID, in: window) == true }
        guard let crop = WorkspaceUIAcceptance.probeFrame(identifier: cropID, in: window) else { throw GateBlocked("The actual crop corner is missing.") }
        let corner = NSPoint(x: crop.midX, y: crop.midY)
        try await AppNativeMenuAcceptance.drag(from: corner,
            to: .init(x: corner.x + 8, y: corner.y + (root.isFlipped ? 8 : -8)), in: root,
            window: window, driver: driver, label: "preview.crop.corner")
        try await driver.wait("native crop drag passes wheel surface") { editor.timeline != before }
        guard editor.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clip.id })?.cropAt(frame: editor.activeFrame) != clip.cropAt(frame: editor.activeFrame) else {
            throw GateBlocked("The actual Crop gesture did not edit the selected source crop.")
        }
        try driver.capture("canvas-crop-interactive", target: window)
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("native crop Undo") { editor.timeline == before }
        try await driver.click("inspector.crop.edit", in: window)
        try await driver.wait("actual crop mode closed") { !editor.cropEditingActive }
        try await driver.menu("preview.zoom", title: "Fit", in: window)
        try await driver.wait("overlay checks restore Fit") { editor.canvasZoom == 1 && editor.canvasOffset == .zero && editor.timeline == before }
        try driver.record("native-pan-overlay-isolation", fields: ["transformDragged": true, "cropDragged": true,
            "exactUndo": true, "restoredTimelineSHA256": try ExportArtwork.timelineHash(before)])
    }
}
