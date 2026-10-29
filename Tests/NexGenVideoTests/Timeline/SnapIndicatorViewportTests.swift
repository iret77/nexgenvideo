import AppKit
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Snap guide follows viewport changes without a new snap position")
struct SnapIndicatorViewportTests {
    @Test func actualScrollCallerRefreshesTheUnchangedSnapGuide() throws {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let timeline = TimelineView(editor: editor)
        timeline.frame = NSRect(x: 0, y: 0, width: 4000, height: 3000)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scroll.documentView = timeline
        scroll.layoutSubtreeIfNeeded()
        timeline.snapOverlay.setLocalX(300)
        let layer = try #require(timeline.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.lineDashPattern != nil })
        let before = layer.frame
        scroll.contentView.setBoundsOrigin(NSPoint(x: 100, y: 200))
        #expect(timeline.visibleRect != before)
        let caller = TimelineContainerView.Coordinator()
        caller.timelineView = timeline
        caller.scrollView = scroll
        caller.scrollViewBoundsChanged(Notification(name: NSView.boundsDidChangeNotification, object: scroll.contentView))
        #expect(layer.frame == timeline.visibleRect)
        #expect(!layer.isHidden)
        let path = try #require(layer.path)
        #expect(path.boundingBox.minX == 300 - timeline.visibleRect.minX)
        #expect(path.boundingBox.height == timeline.bounds.height - CGFloat(timeline.geometry.rulerHeight))
    }
}
