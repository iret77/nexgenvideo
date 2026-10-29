import AppKit
import NexGenEngine

@MainActor
enum ProductionFeedbackBannerAcceptance {
    static func run(editor: EditorViewModel, driver: ProductionVisualSourcesDriver) async throws {
        let window = driver.window
        guard editor.workspaceFocus == .production, let root = window.contentView,
              let original = editor.mediaPanelToast, let generation = editor.openWorkingCopyGeneration else {
            throw GateBlocked("The feedback layout check needs the actual Production Undo message.")
        }
        let message = (1...80).map { "Feedback layout fixture line \($0): details remain available by scrolling." }.joined(separator: "\n")
        let fixture = MediaPanelToast(message: message)
        let replacement = MediaPanelToast(message: (1...100).map {
            "New feedback fixture line \($0): a different message must start at its beginning."
        }.joined(separator: "\n"))
        defer {
            if editor.openWorkingCopyGeneration == generation,
               editor.mediaPanelToast == fixture || editor.mediaPanelToast == replacement {
                editor.mediaPanelToast = original
            }
        }
        editor.mediaPanelToast = fixture
        let cap = AppTheme.ComponentSize.previewErrorMaxHeight
        func geometry() -> (NSRect, NSRect, NSRect, NSScrollView)? {
            root.layoutSubtreeIfNeeded()
            guard let viewport = WorkspaceUIAcceptance.probeFrame(identifier: "production.feedback.viewport", in: window),
                  let text = WorkspaceUIAcceptance.findProbe(in: root, identifier: "production.feedback"),
                  let dismiss = WorkspaceUIAcceptance.probeFrame(identifier: "production.feedback.dismiss", in: window) else { return nil }
            var ancestor: NSView? = text
            while let current = ancestor {
                if let scroll = current as? NSScrollView {
                    let nativeViewport = scroll.convert(scroll.bounds, to: root)
                    guard abs(nativeViewport.minX - viewport.minX) < 1,
                          abs(nativeViewport.minY - viewport.minY) < 1,
                          abs(nativeViewport.width - viewport.width) < 1,
                          abs(nativeViewport.height - viewport.height) < 1 else { return nil }
                    return (viewport, text.convert(text.bounds, to: root), dismiss, scroll)
                }
                ancestor = current.superview
            }
            return nil
        }
        try await driver.wait("long feedback has a bounded native scroll viewport") {
            guard editor.openWorkingCopyGeneration == generation, editor.mediaPanelToast == fixture,
                  let (viewport, content, dismiss, scroll) = geometry() else { return false }
            return viewport.width.isFinite && viewport.width > 0
                && viewport.height.isFinite && viewport.height > 0 && viewport.height <= cap + 1
                && abs(viewport.height - cap) < 1 && content.height > viewport.height * 2
                && root.bounds.contains(viewport) && root.bounds.contains(dismiss)
                && !viewport.intersects(dismiss) && scroll.contentView.bounds.height.isFinite
                && scroll.contentView.bounds.height > 0 && scroll.contentView.bounds.height <= cap + 1
        }
        guard let (viewport, content, dismiss, scroll) = geometry(), let screen = NSScreen.screens.first else {
            throw GateBlocked("The bounded feedback scroll view disappeared.")
        }
        try driver.visible(["production.feedback.viewport", "production.feedback.dismiss"], in: window)
        try driver.capture("production-feedback-long-before-scroll", target: window)
        let before = scroll.contentView.bounds.origin
        let contentInClip = root.convert(content, to: scroll.contentView)
        let below = contentInClip.midY > scroll.contentView.bounds.midY
        let point = root.convert(NSPoint(x: viewport.midX, y: viewport.midY), to: nil)
        let screenPoint = window.convertPoint(toScreen: point)
        try await driver.postWheel(delta: below == scroll.contentView.isFlipped ? -100 : 100,
            at: CGPoint(x: screenPoint.x, y: screen.frame.height - screenPoint.y), in: window)
        var lastOrigin = before
        var stableSince: TimeInterval?
        try await driver.wait("long feedback settles inside its content after actual wheel input") {
            guard editor.openWorkingCopyGeneration == generation, editor.mediaPanelToast == fixture,
                  let document = scroll.documentView else { return false }
            let clip = scroll.contentView
            let bounds = clip.bounds
            let documentBounds = document.convert(document.bounds, to: clip)
            let displacement = (bounds.origin.y - before.y) * (below ? 1 : -1)
            guard displacement > 1, abs(bounds.origin.x - before.x) < 1,
                  bounds.minY >= documentBounds.minY, bounds.maxY <= documentBounds.maxY else {
                stableSince = nil
                return false
            }
            let now = ProcessInfo.processInfo.systemUptime
            if abs(bounds.origin.y - lastOrigin.y) > 0.25 || stableSince == nil {
                lastOrigin = bounds.origin; stableSince = now
                return false
            }
            return now - (stableSince ?? now) >= 0.25
        }
        let after = scroll.contentView.bounds.origin
        guard let (afterViewport, _, afterDismiss, afterScroll) = geometry(),
              afterScroll === scroll, afterViewport == viewport, afterDismiss == dismiss else {
            throw GateBlocked("Scrolling long feedback changed its viewport or displaced Dismiss.")
        }
        try driver.capture("production-feedback-long-after-scroll", target: window)
        func rect(_ frame: NSRect) -> [Double] { [frame.minX, frame.minY, frame.width, frame.height].map(Double.init) }
        try driver.record("production feedback bounded scrolling", fields: ["uiStateFixture": true,
            "viewport": rect(viewport), "content": rect(content), "dismiss": rect(dismiss),
            "maximumHeight": Double(cap), "before": [before.x, before.y],
            "after": [after.x, after.y]])
        editor.mediaPanelToast = replacement
        try await driver.wait("a different overflowing feedback message starts at its beginning") {
            guard editor.openWorkingCopyGeneration == generation, editor.mediaPanelToast == replacement,
                  driver.text("production.feedback", in: window) == replacement.message,
                  let (viewport, content, dismiss, current) = geometry(),
                  content.height > viewport.height * 2, abs(viewport.height - cap) < 1,
                  root.bounds.contains(dismiss), !viewport.intersects(dismiss) else { return false }
            let clip = current.contentView
            let textBounds = root.convert(content, to: clip)
            let leadingEdge = clip.isFlipped ? textBounds.minY : textBounds.maxY
            let viewportEdge = clip.isFlipped ? clip.bounds.minY : clip.bounds.maxY
            return abs(leadingEdge - viewportEdge) < 1
        }
        try driver.capture("production-feedback-new-long-message-start", target: window)
        guard let (newViewport, newContent, newDismiss, _) = geometry() else {
            throw GateBlocked("The replacement feedback disappeared before its evidence was recorded.")
        }
        try driver.record("new overflowing feedback starts visibly", fields: ["uiStateFixture": true,
            "viewport": rect(newViewport), "content": rect(newContent), "dismiss": rect(newDismiss)])
        editor.mediaPanelToast = original
        try await driver.wait("actual Undo error restored after layout fixture") {
            guard editor.openWorkingCopyGeneration == generation, editor.mediaPanelToast == original,
                  driver.text("production.feedback", in: window) == original.message,
                  let (_, content, _, restored) = geometry() else { return false }
            let clip = restored.contentView
            let textBounds = root.convert(content, to: clip)
            let leadingEdge = clip.isFlipped ? textBounds.minY : textBounds.maxY
            let viewportEdge = clip.isFlipped ? clip.bounds.minY : clip.bounds.maxY
            return abs(leadingEdge - viewportEdge) < 1
        }
    }
}
