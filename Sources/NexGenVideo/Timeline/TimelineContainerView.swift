import SwiftUI

struct TimelineContainerView: NSViewRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let headerView = TimelineHeaderView(editor: editor)
        headerView.frame = NSRect(x: 0, y: 0, width: AppTheme.Layout.trackHeaderWidth, height: 0)
        headerView.autoresizingMask = [.height]
        container.addSubview(headerView)

        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScroller?.controlSize = .mini
        scrollView.verticalScroller?.controlSize = .mini

        let timelineView = TimelineView(editor: editor)
        timelineView.autoresizingMask = []
        scrollView.documentView = timelineView
        headerView.requestCanvasRedraw = { [weak timelineView] in
            timelineView?.updateContentSize()
            timelineView?.needsDisplay = true
        }

        scrollView.frame = NSRect(x: AppTheme.Layout.trackHeaderWidth, y: 0, width: 0, height: 0)
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = AppTheme.Border.primary.cgColor
        border.frame = NSRect(
            x: AppTheme.Layout.trackHeaderWidth - AppTheme.BorderWidth.thin,
            y: AppTheme.Spacing.none,
            width: AppTheme.BorderWidth.thin,
            height: AppTheme.Spacing.none
        )
        border.autoresizingMask = [.height]
        container.addSubview(border)

        context.coordinator.headerView = headerView
        context.coordinator.timelineView = timelineView
        context.coordinator.scrollView = scrollView
        context.coordinator.editor = editor

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let renderState = RenderState(
            revision: editor.timelineRenderRevision,
            zoomScale: editor.zoomScale,
            allowsTimelineEditChrome: editor.allowsTimelineEditChrome,
            selectedClipIds: editor.selectedClipIds,
            selectedTimelineRange: editor.selectedTimelineRange,
            selectedTimelineMarkerIds: editor.selectedTimelineMarkerIds,
            timelineMarkerPreview: editor.timelineMarkerPreview,
            pendingReplacements: editor.pendingReplacements,
            generatingAssetIds: Set(editor.mediaAssets.lazy.filter(\.isGenerating).map(\.id)),
            dialogProjection: editor.agentService.pendingDialogProjection,
            selectedDialogRangeId: editor.agentService.selectedDialogRangeId
        )

        if context.coordinator.needsRender(for: renderState) {
            context.coordinator.timelineView?.updateContentSize()
            context.coordinator.timelineView?.needsDisplay = true
            context.coordinator.headerView?.needsDisplay = true
        }
        context.coordinator.revealFinding()

        if editor.isPlaying,
           let timelineView = context.coordinator.timelineView,
           let scrollView = context.coordinator.scrollView {
            let geo = timelineView.geometry
            let playheadX = geo.xForFrame(editor.activeFrame)
            let visibleRect = scrollView.contentView.bounds
            let margin = AppTheme.Timeline.playbackFollowMargin

            if playheadX < visibleRect.origin.x + margin ||
               playheadX > visibleRect.origin.x + visibleRect.width - margin {
                let newOriginX = max(0, playheadX - visibleRect.width * 0.25)
                scrollView.contentView.setBoundsOrigin(
                    NSPoint(x: newOriginX, y: visibleRect.origin.y)
                )
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct RenderState: Equatable {
        let revision: Int
        let zoomScale: Double
        let allowsTimelineEditChrome: Bool
        let selectedClipIds: Set<String>
        let selectedTimelineRange: TimelineRangeSelection?
        let selectedTimelineMarkerIds: Set<String>
        let timelineMarkerPreview: TimelineMarker?
        let pendingReplacements: Set<String>
        let generatingAssetIds: Set<String>
        let dialogProjection: AgentDialog.Projection?
        let selectedDialogRangeId: String?
    }

    final class Coordinator: NSObject {
        weak var editor: EditorViewModel?
        private var revealedFinding: UUID?
        var headerView: TimelineHeaderView?
        var timelineView: TimelineView?
        var scrollView: NSScrollView?
        private var renderState: RenderState?

        func needsRender(for next: RenderState) -> Bool {
            defer { renderState = next }
            return renderState != next
        }

        @MainActor func revealFinding() {
            guard let editor, let request = editor.sequenceFindingNavigation,
                  request.home == editor.workingRoot, request.target.id != revealedFinding,
                  editor.selectedClipIds == request.target.clipIDs,
                  editor.selectedTimelineRange?.startFrame == request.target.startFrame,
                  editor.selectedTimelineRange?.endFrame == request.target.endFrame,
                  let timelineView, let scrollView,
                  scrollView.contentView.bounds.width > 0, scrollView.contentView.bounds.height > 0 else { return }
            let geometry = timelineView.geometry
            let bounds = scrollView.contentView.bounds
            let track = editor.timeline.tracks.firstIndex { $0.clips.contains { request.target.clipIDs.contains($0.id) } }
            let x = max(0, CGFloat(geometry.xForFrame(request.target.startFrame)) - AppTheme.Timeline.playbackFollowMargin)
            let y = track.map { max(0, geometry.trackY(at: $0) - geometry.rulerHeight) } ?? bounds.origin.y
            revealedFinding = request.target.id
            scrollView.contentView.scroll(to: NSPoint(x: min(x, max(0, timelineView.bounds.width - bounds.width)),
                y: min(y, max(0, timelineView.bounds.height - bounds.height))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async { [weak editor] in
                if editor?.sequenceFindingNavigation?.target.id == request.target.id {
                    editor?.sequenceFindingNavigation = nil
                }
            }
        }

        @MainActor @objc func scrollViewBoundsChanged(_ notification: Notification) {
            timelineView?.needsDisplay = true
            timelineView?.updatePlayheadLayer()
            timelineView?.snapOverlay.updateViewport()
            if let scrollY = scrollView?.contentView.bounds.origin.y {
                headerView?.setBoundsOrigin(NSPoint(x: 0, y: scrollY))
                headerView?.needsDisplay = true
            }
        }

        @MainActor @objc func clipViewFrameChanged(_ notification: Notification) {
            timelineView?.updateContentSize()
            revealFinding()
            timelineView?.updatePlayheadLayer()
            timelineView?.snapOverlay.updateViewport()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
