import AppKit

enum TimelineMarkerRenderer {
    struct Hit {
        let marker: TimelineMarker
        let resizesEnd: Bool
    }

    static func draw(
        markers: [TimelineMarker],
        selectedIDs: Set<String>,
        geometry: TimelineGeometry,
        scrollOffsetY: CGFloat,
        viewHeight: CGFloat,
        context: CGContext
    ) {
        for marker in markers {
            let startX = geometry.xForFrame(marker.startFrame)
            let endX = geometry.xForFrame(marker.endFrame)
            let color = marker.color?.nsColor ?? AppTheme.Timeline.markerDefault
            let selected = selectedIDs.contains(marker.id)

            context.setStrokeColor(color.withAlphaComponent(
                selected ? AppTheme.Opacity.opaque : AppTheme.Opacity.prominent
            ).cgColor)
            context.setLineWidth(selected ? AppTheme.BorderWidth.medium : AppTheme.Timeline.markerLineWidth)
            context.move(to: CGPoint(x: startX, y: scrollOffsetY + AppTheme.Timeline.markerFlagHeight))
            context.addLine(to: CGPoint(x: startX, y: viewHeight))
            context.strokePath()

            let flag = CGRect(
                x: startX,
                y: scrollOffsetY,
                width: AppTheme.Timeline.markerFlagWidth,
                height: AppTheme.Timeline.markerFlagHeight
            )
            context.setFillColor(color.cgColor)
            context.fill(flag)

            if marker.durationFrames > 0 {
                context.fill(CGRect(
                    x: startX,
                    y: scrollOffsetY + geometry.rulerHeight - AppTheme.Timeline.markerRangeHeight,
                    width: max(AppTheme.BorderWidth.thin, endX - startX),
                    height: AppTheme.Timeline.markerRangeHeight
                ))
            }
        }
    }

    static func hitTest(
        point: CGPoint,
        markers: [TimelineMarker],
        geometry: TimelineGeometry,
        scrollOffsetY: CGFloat
    ) -> Hit? {
        guard point.y >= scrollOffsetY, point.y < scrollOffsetY + geometry.rulerHeight else { return nil }
        for marker in markers.reversed() {
            let startX = geometry.xForFrame(marker.startFrame)
            let flagRect = CGRect(
                x: startX - AppTheme.Timeline.markerHitSlop,
                y: scrollOffsetY,
                width: AppTheme.Timeline.markerFlagWidth + AppTheme.Timeline.markerHitSlop * 2,
                height: geometry.rulerHeight
            )
            if flagRect.contains(point) { return Hit(marker: marker, resizesEnd: false) }
            guard marker.durationFrames > 0 else { continue }
            let endX = geometry.xForFrame(marker.endFrame)
            if abs(point.x - endX) <= AppTheme.Timeline.markerHitSlop {
                return Hit(marker: marker, resizesEnd: true)
            }
            let rangeRect = CGRect(
                x: startX,
                y: scrollOffsetY + geometry.rulerHeight - AppTheme.Timeline.markerFlagHeight,
                width: max(0, endX - startX),
                height: AppTheme.Timeline.markerFlagHeight
            )
            if rangeRect.contains(point) { return Hit(marker: marker, resizesEnd: false) }
        }
        return nil
    }
}
