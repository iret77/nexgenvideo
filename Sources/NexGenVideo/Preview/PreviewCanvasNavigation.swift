import AppKit
import SwiftUI

struct PreviewCanvasNavigation: NSViewRepresentable {
    let editor: EditorViewModel
    let contentSize: CGSize
    let enabled: Bool

    func makeNSView(context: Context) -> WheelSurface { WheelSurface() }

    func updateNSView(_ view: WheelSurface, context: Context) {
        let owner = editor, allowed = enabled, size = contentSize
        view.canNavigate = { [weak owner] event in
            guard allowed, let editor = owner, event.modifierFlags.intersection([.control, .option]).isEmpty else { return false }
            return event.modifierFlags.contains(.command) || editor.canvasZoom > 1
        }
        view.navigate = { [weak owner] event, point, viewport in
            guard let editor = owner, viewport.width > 0, viewport.height > 0 else { return }
            let oldZoom = editor.canvasZoom
            if event.modifierFlags.contains(.command) {
                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.05
                let zoom = min(max(oldZoom * exp(event.scrollingDeltaY * sensitivity), 0.1), 8)
                guard zoom.isFinite, oldZoom > 0, abs(zoom - oldZoom) > 0.0001 else { return }
                let factor = 1 - zoom / oldZoom
                editor.canvasOffset = CGSize(
                    width: editor.canvasOffset.width + (point.x - viewport.width / 2 - editor.canvasOffset.width) * factor,
                    height: editor.canvasOffset.height + (point.y - viewport.height / 2 - editor.canvasOffset.height) * factor)
                editor.canvasZoom = zoom
            } else if oldZoom > 1 {
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                let x = editor.canvasOffset.width + event.scrollingDeltaX * step
                let y = editor.canvasOffset.height + event.scrollingDeltaY * step
                guard x.isFinite, y.isFinite else { return }
                let limitX = max(0, (size.width * oldZoom - viewport.width) / 2)
                let limitY = max(0, (size.height * oldZoom - viewport.height) / 2)
                editor.canvasOffset = CGSize(width: min(max(x, -limitX), limitX), height: min(max(y, -limitY), limitY))
            }
        }
    }

    final class WheelSurface: NSView {
        var canNavigate: ((NSEvent) -> Bool)?
        var navigate: ((NSEvent, CGPoint, CGSize) -> Void)?
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .scrollWheel, canNavigate?(event) == true else { return nil }
            return super.hitTest(point)
        }

        override func scrollWheel(with event: NSEvent) {
            guard canNavigate?(event) == true else { super.scrollWheel(with: event); return }
            navigate?(event, convert(event.locationInWindow, from: nil), bounds.size)
        }
    }
}
