import AppKit
import NexGenEngine

@MainActor
enum ProductionNativeReadingAcceptance {
    static func read(_ id: String, expected: String, driver: ProductionVisualSourcesDriver) async throws {
        let window = driver.window
        try await driver.wait("locate readable text " + id) { driver.text(id, in: window) == expected }
        guard let root = window.contentView, let view = WorkspaceUIAcceptance.findProbe(in: root, identifier: id) else {
            throw GateBlocked("The actual text view disappeared: " + id)
        }
        var ancestor = view.superview
        var scroll: NSScrollView?
        while let current = ancestor {
            if let candidate = current as? NSScrollView { scroll = candidate; break }
            ancestor = current.superview
        }
        guard let scroll else {
            try await driver.reveal(id, in: window)
            try driver.visible([id], in: window)
            try driver.capture("read-direction", target: window)
            try driver.record("complete compiled direction inspected", fields: ["id": id,
                "textSHA256": FileDigest.sha256(of: Data(expected.utf8)), "height": view.bounds.height,
                "coveredHeight": view.bounds.height, "visiblePages": 1])
            return
        }
        root.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        var ranges: [ClosedRange<CGFloat>] = []
        var didReachTop = false
        let expectedHeight = view.bounds.height
        let viewport = clip.bounds.intersection(root.convert(root.bounds, to: clip))
        let page = floor(viewport.height / 2)
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        guard expectedHeight.isFinite, documentHeight.isFinite, page.isFinite,
              expectedHeight > 0, documentHeight >= expectedHeight, page >= 1, page <= CGFloat(Int32.max),
              view.bounds.width <= viewport.width else {
            throw GateBlocked("The compiled direction has no readable horizontal layout.")
        }
        let steps = ceil((documentHeight + expectedHeight) / page) + 4
        guard steps < CGFloat(Int.max) else { throw GateBlocked("The compiled direction has invalid scroll geometry.") }
        for step in 0..<Int(steps) {
            root.layoutSubtreeIfNeeded()
            guard driver.text(id, in: window) == expected, view.bounds.height == expectedHeight else {
                throw GateBlocked("The compiled direction changed while reading its visible pages.")
            }
            let frame = view.convert(view.bounds, to: clip)
            let windowClip = root.convert(root.bounds, to: clip)
            let visible = frame.intersection(clip.bounds).intersection(windowClip)
            if !visible.isEmpty && visible.width >= frame.width - 1 {
                let portion = view.convert(visible, from: clip)
                let first = view.isFlipped ? portion.minY : expectedHeight - portion.maxY
                let last = view.isFlipped ? portion.maxY : expectedHeight - portion.minY
                if first <= 1 { didReachTop = true }
                if didReachTop {
                    ranges.append(max(0, first)...min(expectedHeight, last))
                    try driver.capture("direction-page-\(step)", target: window)
                    var covered: CGFloat = 0
                    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                        guard range.lowerBound <= covered + 1 else { break }
                        covered = max(covered, range.upperBound)
                    }
                    if covered >= expectedHeight - 1 {
                        try driver.record("complete compiled direction inspected", fields: ["id": id,
                            "textSHA256": FileDigest.sha256(of: Data(expected.utf8)), "height": expectedHeight,
                            "coveredHeight": covered, "visiblePages": ranges.count])
                        return
                    }
                }
            }
            let down = didReachTop || (clip.isFlipped ? frame.minY >= clip.bounds.maxY : frame.maxY <= clip.bounds.minY)
            let delta = Int32(page) * (down ? -1 : 1)
            guard let screen = NSScreen.screens.first else { throw GateBlocked("The native screen is unavailable.") }
            let local = NSPoint(x: scroll.visibleRect.midX, y: scroll.visibleRect.midY)
            guard window.isKeyWindow, scroll.window === window, !scroll.isHiddenOrHasHiddenAncestor,
                  !scroll.visibleRect.isEmpty, let hit = root.hitTest(scroll.convert(local, to: root.superview)),
                  hit === scroll || hit.isDescendant(of: scroll) else {
                throw GateBlocked("The compiled direction wheel target is clipped or covered.")
            }
            let point = window.convertPoint(toScreen: scroll.convert(local, to: nil))
            let location = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
            try await movePointer(to: location, window: window, driver: driver)
            let before = clip.bounds.origin
            for event in try HangDiagnosticReplay.scrollGestureEvents(delta: delta,
                location: location) {
                guard let cg = event.cgEvent else { throw GateBlocked("The native text wheel event is unavailable.") }
                cg.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(20))
            }
            try await driver.wait("actual compiled direction wheel delivery") { clip.bounds.origin != before }
            try driver.record("compiled direction wheel", fields: ["id": id, "delta": delta,
                "before": [before.x, before.y], "after": [clip.bounds.origin.x, clip.bounds.origin.y],
                "documentHeight": documentHeight, "viewportHeight": viewport.height, "targetHeight": expectedHeight])
        }
        throw GateBlocked("Native wheel input did not expose every line of the compiled direction: " + id)
    }

    @MainActor private final class PointerDelivery {
        var expected = NSPoint.zero
        var matched = false
    }

    static func movePointer(to location: CGPoint, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard window.isKeyWindow, let screen = NSScreen.screens.first else {
            throw GateBlocked("The native wheel pointer cannot reach the active window.")
        }
        let accepted = window.acceptsMouseMovedEvents, number = window.windowNumber
        window.acceptsMouseMovedEvents = true
        let delivery = PointerDelivery()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            let eventWindow = event.windowNumber, point = event.locationInWindow
            MainActor.assumeIsolated {
                if eventWindow == number,
                   abs(point.x - delivery.expected.x) < 0.5,
                   abs(point.y - delivery.expected.y) < 0.5 { delivery.matched = true }
            }
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            window.acceptsMouseMovedEvents = accepted
        }
        func post(_ point: CGPoint) async throws {
            delivery.matched = false
            delivery.expected = window.convertPoint(fromScreen: NSPoint(x: point.x, y: screen.frame.maxY - point.y))
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
                throw GateBlocked("The actual pointer move could not be created.")
            }
            event.post(tap: .cghidEventTap)
            try await driver.wait("actual wheel pointer delivery") { delivery.matched }
        }
        let current = NSEvent.mouseLocation
        if abs(current.x - location.x) < 0.5, abs(current.y - (screen.frame.maxY - location.y)) < 0.5 {
            let offset: CGFloat = location.x + 2 < window.frame.maxX ? 2 : -2
            try await post(CGPoint(x: location.x + offset, y: location.y))
        }
        try await post(location)
    }
}
