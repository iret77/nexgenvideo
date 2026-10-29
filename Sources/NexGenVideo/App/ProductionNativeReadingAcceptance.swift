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
        var stalled = 0
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
            let point = window.convertPoint(toScreen: scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil))
            let before = clip.bounds.origin
            for event in try HangDiagnosticReplay.scrollGestureEvents(delta: delta,
                location: CGPoint(x: point.x, y: screen.frame.height - point.y)) {
                scroll.scrollWheel(with: event)
                try await Task.sleep(for: .milliseconds(20))
            }
            try driver.record("compiled direction wheel", fields: ["id": id, "delta": delta,
                "before": [before.x, before.y], "after": [clip.bounds.origin.x, clip.bounds.origin.y],
                "documentHeight": documentHeight, "viewportHeight": viewport.height, "targetHeight": expectedHeight])
            stalled = before == clip.bounds.origin ? stalled + 1 : 0
            guard stalled < 2 else {
                try driver.capture("direction-scroll-blocked", target: window)
                throw GateBlocked("Native wheel input stopped before every line was visible: " + id)
            }
        }
        throw GateBlocked("Native wheel input did not expose every line of the compiled direction: " + id)
    }
}
