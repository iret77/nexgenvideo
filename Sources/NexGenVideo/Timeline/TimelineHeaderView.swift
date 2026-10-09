import AppKit

extension Notification.Name {
    static let cancelTimelineInteraction = Notification.Name("NexGenVideo.cancelTimelineInteraction")
}

/// Fixed track header column drawn to the left of the scrollable timeline.
final class TimelineHeaderView: NSView {
    unowned var editor: EditorViewModel
    var requestCanvasRedraw: (() -> Void)?

    private static let headerBg = AppTheme.Background.surface.cgColor
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: AppTheme.FontSize.sm, weight: AppTheme.AppKitFontWeight.medium),
        .foregroundColor: AppTheme.Text.secondary,
    ]

    /// Rects for mute/hide/sync-lock buttons, indexed by track. Used for hit testing.
    var muteButtonRects: [Int: NSRect] = [:]
    var hideButtonRects: [Int: NSRect] = [:]
    var syncLockButtonRects: [Int: NSRect] = [:]
    var dragHandleRects: [Int: NSRect] = [:]

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Track controls")
        setAccessibilityHelp("Use Up and Down to choose a track, then Return to open its actions.")
        wantsLayer = true
        layer?.backgroundColor = Self.headerBg
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cancelTimelineInteraction(_:)),
            name: .cancelTimelineInteraction,
            object: editor
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(Self.headerBg)
        ctx.fill(bounds)

        let rulerBottom =
            bounds.origin.y + AppTheme.Layout.rulerHeight - AppTheme.BorderWidth.hairline
        ctx.setFillColor(AppTheme.Border.primary.cgColor)
        ctx.fill(
            NSRect(
                x: AppTheme.Spacing.none,
                y: rulerBottom,
                width: bounds.width,
                height: AppTheme.BorderWidth.thin
            )
        )

        // Clip drawing below the ruler so headers don't overlap it when scrolled
        let clipTop = bounds.origin.y + AppTheme.Layout.rulerHeight
        ctx.clip(to: NSRect(x: bounds.origin.x, y: clipTop, width: bounds.width, height: bounds.height))

        muteButtonRects.removeAll()
        hideButtonRects.removeAll()
        syncLockButtonRects.removeAll()
        dragHandleRects.removeAll()
        let stripWidth = AppTheme.Timeline.headerTypeStripWidth
        let iconSize = AppTheme.Timeline.headerIconSize
        let iconConfig = NSImage.SymbolConfiguration(
            pointSize: AppTheme.FontSize.sm,
            weight: AppTheme.AppKitFontWeight.regular
        )
        let headerWidth = bounds.width

        let geo = TimelineGeometry(editor: editor, bounds: bounds)

        for (i, track) in editor.timeline.tracks.enumerated() {
            let y = geo.trackY(at: i)
            let h = geo.trackHeight(at: i)

            if reorderDrag?.id == track.id {
                ctx.setFillColor(AppTheme.Background.prominent.cgColor)
                ctx.fill(NSRect(x: AppTheme.Spacing.none, y: y, width: headerWidth, height: h))
            }

            if showsKeyboardFocus && window?.firstResponder === self && i == keyboardTrackIndex {
                ctx.setStrokeColor(AppTheme.Border.primary.cgColor)
                ctx.setLineWidth(AppTheme.BorderWidth.medium)
                ctx.stroke(NSRect(x: bounds.minX, y: y, width: headerWidth, height: h).insetBy(
                    dx: AppTheme.BorderWidth.thin, dy: AppTheme.BorderWidth.thin
                ))
            }

            // Color-coded left border strip
            ctx.setFillColor(track.type.themeColor.cgColor)
            ctx.fill(NSRect(x: AppTheme.Spacing.none, y: y, width: stripWidth, height: h))

            let gripX = stripWidth + AppTheme.Spacing.sm
            if editor.allowsTimelineEditChrome {
                let gripRect = NSRect(
                    x: gripX,
                    y: y + (h - iconSize) / 2,
                    width: iconSize,
                    height: iconSize
                )
                drawSymbol(
                    "line.3.horizontal",
                    in: gripRect,
                    tint: AppTheme.Text.secondary.withAlphaComponent(AppTheme.Opacity.dim),
                    config: iconConfig,
                    context: ctx
                )
                dragHandleRects[i] = gripRect.insetBy(
                    dx: -AppTheme.Spacing.xs,
                    dy: -AppTheme.Spacing.xs
                )
            }

            // Track label
            let str = NSAttributedString(string: editor.timelineTrackDisplayLabel(at: i), attributes: Self.labelAttrs)
            let labelSize = str.size()
            let labelY = y + (h - labelSize.height) / 2
            let labelX = editor.allowsTimelineEditChrome
                ? gripX + iconSize + AppTheme.Spacing.sm
                : stripWidth + AppTheme.Spacing.sm
            str.draw(at: NSPoint(x: labelX, y: labelY))


            let iconY = y + (h - iconSize) / 2
            let rightmostX = headerWidth - iconSize - AppTheme.Spacing.sm
            let syncX = rightmostX - iconSize - AppTheme.Spacing.xs

            syncLockButtonRects[i] = drawToggleIcon(
                x: syncX, y: iconY, size: iconSize, config: iconConfig, context: ctx,
                active: track.syncLocked, onSymbol: "link", offSymbol: "personalhotspot.slash"
            )
            if track.type == .audio {
                muteButtonRects[i] = drawToggleIcon(
                    x: rightmostX, y: iconY, size: iconSize, config: iconConfig, context: ctx,
                    active: !track.muted, onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash.fill"
                )
            } else {
                hideButtonRects[i] = drawToggleIcon(
                    x: rightmostX, y: iconY, size: iconSize, config: iconConfig, context: ctx,
                    active: !track.hidden, onSymbol: "eye", offSymbol: "eye.slash"
                )
            }

            // White border at top of first track and bottom of every track
            if i == 0 {
                ctx.setFillColor(AppTheme.Border.primary.cgColor)
                ctx.fill(
                    NSRect(
                        x: AppTheme.Spacing.none,
                        y: y,
                        width: headerWidth,
                        height: AppTheme.BorderWidth.thin
                    )
                )
            }
            let handleY = y + h - AppTheme.BorderWidth.thin
            ctx.setFillColor(AppTheme.Border.primary.cgColor)
            ctx.fill(
                NSRect(
                    x: AppTheme.Spacing.none,
                    y: handleY,
                    width: headerWidth,
                    height: AppTheme.BorderWidth.thin
                )
            )
        }

        // Thick divider between the video zone and the audio zone,
        let z = editor.zones
        if z.videoTrackCount > 0, z.audioTrackCount > 0 {
            let dividerY = geo.trackY(at: z.firstAudioIndex)
            ctx.setFillColor(AppTheme.Border.divider.cgColor)
            ctx.fill(
                NSRect(
                    x: AppTheme.Spacing.none,
                    y: dividerY - AppTheme.BorderWidth.thin,
                    width: headerWidth,
                    height: AppTheme.BorderWidth.thick
                )
            )
        }
    }

    /// Draw a toggleable SF Symbol button; returns the hit-test rect (padded).
    private func drawToggleIcon(
        x: CGFloat, y: CGFloat, size: CGFloat,
        config: NSImage.SymbolConfiguration, context: CGContext,
        active: Bool, onSymbol: String, offSymbol: String
    ) -> NSRect {
        let rect = NSRect(x: x, y: y, width: size, height: size)
        let tint = active
            ? AppTheme.Text.secondary
            : AppTheme.Text.tertiary
        drawSymbol(active ? onSymbol : offSymbol, in: rect, tint: tint, config: config, context: context)
        return rect.insetBy(dx: -AppTheme.Spacing.xs, dy: -AppTheme.Spacing.xs)
    }

    private func drawSymbol(_ name: String, in rect: NSRect, tint: NSColor, config: NSImage.SymbolConfiguration, context: CGContext) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let symbolSize = img.size
        let drawRect = NSRect(x: rect.midX - symbolSize.width / 2, y: rect.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height)
        let tinted = NSImage(size: drawRect.size, flipped: true) { drawRect in
            tint.set()
            img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            drawRect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    // MARK: - Input handling

    private var keyboardTrackIndex = 0
    private var showsKeyboardFocus = false
    private struct ActionKey: Hashable { let trackID: String; let kind: String }
    private var accessibleActions: [ActionKey: TrackActionElement] = [:]
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        showsKeyboardFocus = accepted
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { showsKeyboardFocus = false }
        needsDisplay = true
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        guard !editor.timeline.tracks.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 125, 126:
            showsKeyboardFocus = true
            keyboardTrackIndex = min(editor.timeline.tracks.count - 1,
                                     max(0, keyboardTrackIndex + (event.keyCode == 125 ? 1 : -1)))
            needsDisplay = true
        case 36:
            let index = min(keyboardTrackIndex, editor.timeline.tracks.count - 1)
            let geometry = TimelineGeometry(editor: editor, bounds: bounds)
            trackContextMenu(id: editor.timeline.tracks[index].id)?.popUp(
                positioning: nil,
                at: NSPoint(x: bounds.midX, y: geometry.trackY(at: index)),
                in: self
            )
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let geometry = TimelineGeometry(editor: editor, bounds: bounds)
        var currentKeys: Set<ActionKey> = []
        let children = editor.timeline.tracks.enumerated().flatMap { index, track -> [TrackActionElement] in
            let label = editor.timelineTrackDisplayLabel(at: index)
            var actions: [(String, TrackCommand)] = [
                ("\(track.syncLocked ? "Unlock Sync" : "Sync Lock") Track \(label)", .syncLock(!track.syncLocked))
            ]
            actions.append(track.type == .audio
                ? ("\(track.muted ? "Unmute" : "Mute") Track \(label)", .mute(!track.muted))
                : ("\(track.hidden ? "Show" : "Hide") Track \(label)", .visibility(!track.hidden)))
            if editor.allowsTimelineEditChrome {
                if editor.trackReorderDestination(from: index, requested: index - 1) != index { actions.append(("Move Track \(label) Up", .move(-1))) }
                if editor.trackReorderDestination(from: index, requested: index + 1) != index { actions.append(("Move Track \(label) Down", .move(1))) }
            }
            return actions.map { title, command in
                let key = ActionKey(trackID: track.id, kind: command.accessibilityKey)
                currentKeys.insert(key)
                let element = accessibleActions[key] ?? TrackActionElement()
                accessibleActions[key] = element
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(title)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(NSRect(
                    x: bounds.minX, y: geometry.trackY(at: index),
                    width: bounds.width, height: geometry.trackHeight(at: index)
                ))
                element.press = { [weak self] in
                    self?.performTrackCommand(TrackCommandTarget(id: track.id, command: command))
                    return self != nil
                }
                return element
            }
        }
        accessibleActions = accessibleActions.filter { currentKeys.contains($0.key) }
        return children
    }

    private final class TrackActionElement: NSAccessibilityElement {
        var press: (() -> Bool)?
        override func accessibilityPerformPress() -> Bool { press?() ?? false }
    }

    private var resizeDrag: (trackIndex: Int, originalHeight: CGFloat)?
    private var reorderDrag: (id: String, before: Timeline)?

    private func hitTestResizeHandle(at point: NSPoint) -> Int? {
        let geo = TimelineGeometry(editor: editor, bounds: bounds)
        for i in editor.timeline.tracks.indices {
            let trackBottom = geo.trackY(at: i) + geo.trackHeight(at: i)
            if abs(point.y - trackBottom) <= AppTheme.Timeline.trackResizeHandleZone {
                return i
            }
        }
        return nil
    }

    private enum TrackCommand {
        case mute(Bool), visibility(Bool), syncLock(Bool), move(Int), remove(Track)

        var accessibilityKey: String {
            switch self {
            case .mute: "mute"
            case .visibility: "visibility"
            case .syncLock: "syncLock"
            case .move(let offset): "move\(offset)"
            case .remove: "remove"
            }
        }
    }

    private struct TrackCommandTarget {
        let id: String
        let command: TrackCommand
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = TimelineGeometry(editor: editor, bounds: bounds)
        guard point.y >= bounds.minY + geometry.rulerHeight,
              let index = editor.timeline.tracks.indices.first(where: {
                point.y >= geometry.trackY(at: $0)
                    && point.y < geometry.trackY(at: $0) + geometry.trackHeight(at: $0)
              }) else { return nil }
        editor.focusedPanel = .timeline
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        return trackContextMenu(id: editor.timeline.tracks[index].id)
    }

    func trackContextMenu(id: String) -> NSMenu? {
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == id }) else { return nil }
        let track = editor.timeline.tracks[index]
        let label = editor.timelineTrackDisplayLabel(at: index)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ command: TrackCommand, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(performTrackMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TrackCommandTarget(id: id, command: command)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if track.type == .audio {
            add("\(track.muted ? "Unmute" : "Mute") Track \(label)", .mute(!track.muted))
        } else {
            add("\(track.hidden ? "Show" : "Hide") Track \(label)", .visibility(!track.hidden))
        }
        add("\(track.syncLocked ? "Unlock Sync for" : "Sync Lock") Track \(label)", .syncLock(!track.syncLocked))
        menu.addItem(.separator())
        add("Move Track Up", .move(-1), enabled: editor.allowsTimelineEditChrome && editor.trackReorderDestination(from: index, requested: index - 1) != index)
        add("Move Track Down", .move(1), enabled: editor.allowsTimelineEditChrome && editor.trackReorderDestination(from: index, requested: index + 1) != index)
        let contents = track.clips.count == 1 ? "1 Clip" : "\(track.clips.count) Clips"
        let removal = track.clips.isEmpty ? "Remove Empty Track \(label)"
            : "Remove Track \(label) and \(contents)"
        add(removal, .remove(track), enabled: editor.allowsTimelineEditChrome)
        return menu
    }

    @objc private func performTrackMenuCommand(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TrackCommandTarget else { return }
        performTrackCommand(target)
    }

    private func performTrackCommand(_ target: TrackCommandTarget) {
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == target.id }) else { return }
        switch target.command {
        case .mute(let value):
            guard editor.timeline.tracks[index].muted != value else { return }
            editor.toggleTrackMute(trackIndex: index)
        case .visibility(let value):
            guard editor.timeline.tracks[index].hidden != value else { return }
            editor.toggleTrackHidden(trackIndex: index)
        case .syncLock(let value):
            guard editor.timeline.tracks[index].syncLocked != value else { return }
            editor.toggleTrackSyncLock(trackIndex: index)
        case .move(let offset):
            guard editor.allowsTimelineEditChrome else { return }
            editor.reorderTrack(id: target.id, to: index + offset)
            requestCanvasRedraw?()
        case .remove(let expected):
            guard editor.allowsTimelineEditChrome else { return }
            guard editor.timeline.tracks[index] == expected else {
                editor.mediaPanelToast = MediaPanelToast(message: "Track changed. Open its menu again before removing it.")
                return
            }
            editor.removeTrack(id: target.id)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        showsKeyboardFocus = false
        needsDisplay = true
        let point = convert(event.locationInWindow, from: nil)
        let geometry = TimelineGeometry(editor: editor, bounds: bounds)
        keyboardTrackIndex = max(0, min(editor.timeline.tracks.count - 1, geometry.trackAt(y: Double(point.y))))

        for (ti, rect) in muteButtonRects {
            if rect.contains(point) {
                editor.toggleTrackMute(trackIndex: ti)
                needsDisplay = true
                return
            }
        }
        for (ti, rect) in hideButtonRects {
            if rect.contains(point) {
                editor.toggleTrackHidden(trackIndex: ti)
                needsDisplay = true
                return
            }
        }
        for (ti, rect) in syncLockButtonRects {
            if rect.contains(point) {
                editor.toggleTrackSyncLock(trackIndex: ti)
                needsDisplay = true
                return
            }
        }

        if editor.allowsTimelineEditChrome {
            for (trackIndex, rect) in dragHandleRects where rect.contains(point) {
                reorderDrag = (editor.timeline.tracks[trackIndex].id, editor.timeline)
                NSCursor.closedHand.set()
                return
            }
        }

        if let ti = hitTestResizeHandle(at: point) {
            resizeDrag = (ti, editor.timeline.tracks[ti].displayHeight)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let drag = reorderDrag {
            let geo = TimelineGeometry(editor: editor, bounds: bounds)
            editor.reorderTrackLive(id: drag.id, to: geo.trackAt(y: Double(point.y)))
            NSCursor.closedHand.set()
            needsDisplay = true
            requestCanvasRedraw?()
            return
        }

        guard let drag = resizeDrag else { return }
        let geo = TimelineGeometry(editor: editor, bounds: bounds)
        let trackTop = geo.trackY(at: drag.trackIndex)
        let newHeight = max(AppTheme.Timeline.trackMinHeight, min(AppTheme.Timeline.trackMaxHeight, point.y - trackTop))
        if editor.timeline.tracks[drag.trackIndex].displayHeight != newHeight {
            editor.timeline.tracks[drag.trackIndex].displayHeight = newHeight
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = reorderDrag {
            reorderDrag = nil
            _ = editor.commitTrackReorder(id: drag.id, before: drag.before)
            NSCursor.arrow.set()
            needsDisplay = true
            requestCanvasRedraw?()
            return
        }

        guard let drag = resizeDrag else { return }
        let finalHeight = editor.timeline.tracks[drag.trackIndex].displayHeight
        if finalHeight != drag.originalHeight {
            editor.timeline.tracks[drag.trackIndex].displayHeight = drag.originalHeight
            editor.setTrackHeight(trackIndex: drag.trackIndex, height: finalHeight)
        }
        resizeDrag = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if editor.allowsTimelineEditChrome,
           dragHandleRects.values.contains(where: { $0.contains(point) }) {
            NSCursor.openHand.set()
        } else if hitTestResizeHandle(at: point) != nil {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    @objc private func cancelTimelineInteraction(_ notification: Notification) {
        guard let drag = reorderDrag else { return }
        reorderDrag = nil
        editor.timeline = drag.before
        NSCursor.arrow.set()
        needsDisplay = true
        requestCanvasRedraw?()
    }
}
