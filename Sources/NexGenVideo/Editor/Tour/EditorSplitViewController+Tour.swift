import AppKit

extension EditorSplitViewController {
    /// Publish the current tour step's target frame
    /// `stepIndex` selects the step. `anchorRevision` isn't read here — the caller
    /// passes it only so its read registers a SwiftUI observation dependency, so this
    /// re-runs when an anchored control re-lays out inside a panel
    func updateTourFrame(stepIndex: Int? = nil, anchorRevision: Int = 0) {
        let tour = editor.tour
        let index = stepIndex ?? tour.stepIndex
        guard let index, tour.steps.indices.contains(index),
              case .spotlight(let target) = tour.steps[index].kind,
              let frame = tourFrame(for: target) else {
            if tour.targetFrame != nil { tour.targetFrame = nil }
            return
        }
        if tour.targetFrame != frame { tour.targetFrame = frame }
    }

    private func tourFrame(for target: TourTarget) -> CGRect? {
        switch target {
        case .panel(.agent):
            return flippedFrame(of: leafItem(for: .inspector)?.viewController.view)
        case .panel(let panel):
            return flippedFrame(of: leafItem(for: panel)?.viewController.view)
        case .element(.timelineRuler):
            guard let timeline = flippedFrame(of: editor.tour.anchorViews[.timelineRuler]?.value) else { return nil }
            return CGRect(x: timeline.minX, y: timeline.minY,
                          width: timeline.width, height: AppTheme.Layout.rulerHeight)
        case .element(let id):
            return flippedFrame(of: editor.tour.anchorViews[id]?.value)
        }
    }

    /// Convert directly into the overlay's measured drawing surface.
    private func flippedFrame(of source: NSView?) -> CGRect? {
        guard let source, let window = source.window,
              let overlay = editor.tour.overlayCoordinateView, overlay.window === window,
              overlay.bounds.width > 1, overlay.bounds.height > 1,
              source.bounds.width > 1, source.bounds.height > 1 else { return nil }
        let r = source.convert(source.bounds, to: overlay)
        return CGRect(x: r.minX - overlay.bounds.minX,
                      y: overlay.isFlipped ? r.minY - overlay.bounds.minY : overlay.bounds.maxY - r.maxY,
                      width: r.width, height: r.height)
    }
}
