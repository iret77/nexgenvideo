import AppKit

/// Fixed track header column drawn to the left of the scrollable timeline.
final class TimelineHeaderView: NSView {
    unowned var editor: EditorViewModel

    private static let headerBg = AppTheme.Background.surface.cgColor
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: AppTheme.FontSize.sm, weight: AppTheme.AppKitFontWeight.medium),
        .foregroundColor: AppTheme.Text.secondary,
    ]

    /// Rects for mute/hide/sync-lock buttons, indexed by track. Used for hit testing.
    var muteButtonRects: [Int: NSRect] = [:]
    var hideButtonRects: [Int: NSRect] = [:]
    var syncLockButtonRects: [Int: NSRect] = [:]

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.headerBg
    }

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

            // Color-coded left border strip
            ctx.setFillColor(track.type.themeColor.cgColor)
            ctx.fill(NSRect(x: AppTheme.Spacing.none, y: y, width: stripWidth, height: h))

            // Track label
            let str = NSAttributedString(string: editor.timelineTrackDisplayLabel(at: i), attributes: Self.labelAttrs)
            let labelSize = str.size()
            let labelY = y + (h - labelSize.height) / 2
            str.draw(at: NSPoint(x: stripWidth + AppTheme.Spacing.sm, y: labelY))


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
            : AppTheme.Text.secondary.withAlphaComponent(AppTheme.Opacity.shadow)
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

    // MARK: - Input handling (mute/hide/resize)

    private var resizeDrag: (trackIndex: Int, originalHeight: CGFloat)?

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
        case mute(Bool), visibility(Bool), syncLock(Bool), remove(Track)
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
            let item = NSMenuItem(title: title, action: #selector(performTrackCommand(_:)), keyEquivalent: "")
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
        let contents = track.clips.count == 1 ? "1 Clip" : "\(track.clips.count) Clips"
        let removal = track.clips.isEmpty ? "Remove Empty Track \(label)"
            : "Remove Track \(label) and \(contents)"
        add(removal, .remove(track), enabled: editor.allowsTimelineEditChrome)
        return menu
    }

    @objc private func performTrackCommand(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TrackCommandTarget,
              let index = editor.timeline.tracks.firstIndex(where: { $0.id == target.id }) else { return }
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
        let point = convert(event.locationInWindow, from: nil)

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

        if let ti = hitTestResizeHandle(at: point) {
            resizeDrag = (ti, editor.timeline.tracks[ti].displayHeight)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = resizeDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let geo = TimelineGeometry(editor: editor, bounds: bounds)
        let trackTop = geo.trackY(at: drag.trackIndex)
        let newHeight = max(AppTheme.Timeline.trackMinHeight, min(AppTheme.Timeline.trackMaxHeight, point.y - trackTop))
        if editor.timeline.tracks[drag.trackIndex].displayHeight != newHeight {
            editor.timeline.tracks[drag.trackIndex].displayHeight = newHeight
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
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
        if hitTestResizeHandle(at: point) != nil {
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
}
