import AppKit

enum WindowGeometry {
    nonisolated static func restoredFrame(_ frame: NSRect, minimum: NSSize, visible: NSRect) -> NSRect {
        var fitted = frame
        fitted.size.width = max(fitted.width, min(minimum.width, visible.width))
        fitted.size.height = max(fitted.height, min(minimum.height, visible.height))
        return clampToScreen(fitted, visible: visible)
    }

    nonisolated static func clampToScreen(_ frame: NSRect, visible: NSRect) -> NSRect {
        var fitted = frame
        fitted.size.width = min(fitted.width, visible.width)
        fitted.size.height = min(fitted.height, visible.height)
        fitted.origin.x = min(max(fitted.origin.x, visible.minX), visible.maxX - fitted.width)
        fitted.origin.y = min(max(fitted.origin.y, visible.minY), visible.maxY - fitted.height)
        return fitted
    }
}
