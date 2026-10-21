import AppKit
import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import NexGenEngine

enum NativeBlockoutExporter {
    struct CameraProjection: Sendable {
        let id: String
        let locationID: String
        let position: SpatialVector3V1
        let path: [CameraPathKeyframeV1]
    }

    struct PlanFrame: Sendable {
        let cameras: [CameraProjection]
        let layouts: [SpatialLayoutV1]
        let shapes: [BlockoutShapeV1]
        let metric: Bool

        init(cameras: [CameraProjection], layouts: [SpatialLayoutV1], shapes: [BlockoutShapeV1], metric: Bool = false) {
            self.cameras = cameras; self.layouts = layouts; self.shapes = shapes; self.metric = metric
        }
    }

    static func export(setups: [CameraSetupV1], layouts: [SpatialLayoutV1], shapes: [BlockoutShapeV1],
                       request: BlockoutRequestV1, to url: URL) throws {
        let count = max(1, Int((request.durationSeconds * Double(request.fps)).rounded()))
        try export(width: request.width, height: request.height, frameCount: count,
            presentation: { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(request.fps)) },
            duration: CMTime(value: CMTimeValue(count), timescale: CMTimeScale(request.fps)), to: url) { _ in
                PlanFrame(cameras: setups.map { .init(id: $0.id, locationID: $0.locationID, position: $0.position, path: $0.path) },
                    layouts: layouts, shapes: shapes)
            }
    }

    static func export(width: Int, height: Int, frameCount: Int,
                       presentation: (Int) -> CMTime, duration: CMTime, to url: URL,
                       frame: (Int) throws -> PlanFrame) throws {
        guard width > 0, height > 0, frameCount > 0, duration.isNumeric, duration > .zero else {
            throw ToolError("The native plan export needs valid dimensions and exact timing.")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw ToolError("The native blockout video encoder is unavailable.")
        }
        writer.add(input)
        writer.movieTimeScale = duration.timescale
        guard writer.startWriting() else {
            throw ToolError(writer.error?.localizedDescription ?? "The native blockout could not start.")
        }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw ToolError("The native blockout pixel-buffer pool is unavailable.")
        }
        for frameIndex in 0..<frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed || writer.status == .cancelled {
                    throw ToolError(writer.error?.localizedDescription ?? "The native blockout export failed.")
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else {
                writer.cancelWriting()
                throw ToolError("The native blockout could not allocate a video frame.")
            }
            let plan = try frame(frameIndex)
            try draw(
                setups: plan.cameras,
                layouts: plan.layouts,
                shapes: plan.shapes,
                progress: Double(frameIndex) / Double(max(1, frameCount - 1)),
                metric: plan.metric,
                in: buffer
            )
            let presentationTime = presentation(frameIndex)
            guard presentationTime.isNumeric, presentationTime >= .zero, presentationTime < duration else {
                throw ToolError("The native plan frame lies outside its exact output interval.")
            }
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                writer.cancelWriting()
                throw ToolError(writer.error?.localizedDescription ?? "The native blockout frame could not be written.")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ToolError(writer.error?.localizedDescription ?? "The native blockout export failed.")
        }
    }

    private static func draw(
        setups: [CameraProjection],
        layouts: [SpatialLayoutV1],
        shapes: [BlockoutShapeV1],
        progress: Double,
        metric: Bool,
        in buffer: CVPixelBuffer
    ) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ToolError("The native blockout video frame is unavailable.")
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw ToolError("The native blockout drawing surface is unavailable.")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(bounds)
        context.setStrokeColor(AppTheme.Border.divider.cgColor)
        context.setLineWidth(AppTheme.BorderWidth.thin)
        let grid = max(24, min(width, height) / 10)
        for x in stride(from: 0, through: width, by: grid) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, through: height, by: grid) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()

        let previewScale = max(1, max(CGFloat(width) / AppTheme.Layout.productionInspectorMin,
                                      CGFloat(height) / AppTheme.Layout.previewMinHeight))
        let font = NSFont.systemFont(ofSize: AppTheme.FontSize.xs * previewScale,
            weight: AppTheme.AppKitFontWeight.semibold) as CTFont
        let labelHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font) + AppTheme.Spacing.xxs * 2
        let symbolScale = max(previewScale, AppTheme.IconSize.md / AppTheme.IconSize.xs)
        let markerClearance = (AppTheme.IconSize.xs + AppTheme.BorderWidth.medium) * symbolScale / 2
        let viewports = makeViewports(layouts: layouts, bounds: bounds, metric: metric,
            labelHeight: labelHeight, markerClearance: markerClearance)
        context.setStrokeColor(CGColor(gray: 0.58, alpha: 1))
        context.setLineWidth(AppTheme.BorderWidth.medium)
        for viewport in viewports.values {
            context.stroke(viewport.plan)
            context.stroke(viewport.elevation)
        }
        context.setFillColor(CGColor(gray: 0.62, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
        for shape in shapes.sorted(by: { $0.id < $1.id }) {
            guard let viewport = viewports[shape.locationID] else { continue }
            draw(
                shape: shape,
                in: viewport.plan,
                layout: viewport.layout,
                projection: .plan,
                context: context
            )
            draw(
                shape: shape,
                in: viewport.elevation,
                layout: viewport.layout,
                projection: .elevation,
                context: context
            )
        }

        let ordered = setups.sorted { $0.id < $1.id }
        for (index, setup) in ordered.enumerated() {
            guard let viewport = viewports[setup.locationID] else { continue }
            let colors = AppTheme.Text.blockoutCameraColors
            let color = colors[index % colors.count]
            let points = setup.path.isEmpty
                ? [setup.position]
                : setup.path.map(\.position)
            let targetIndex = min(
                points.count - 1,
                Int((Double(points.count - 1) * progress).rounded())
            )
            for (projection, rect) in [
                (Projection.plan, viewport.plan),
                (Projection.elevation, viewport.elevation),
            ] {
                let markerScale = min(symbolScale,
                    max(0, min(rect.width, rect.height)) / (AppTheme.IconSize.xs + AppTheme.BorderWidth.medium))
                guard markerScale > 0 else { continue }
                let projected = points.map {
                    project($0, in: rect, layout: viewport.layout, projection: projection)
                }
                guard let first = projected.first else { continue }
                let movement = CGMutablePath()
                movement.move(to: first)
                for point in projected.dropFirst() { movement.addLine(to: point) }
                let camera = projected[targetIndex]
                let lookAt = setup.path.isEmpty ? nil : project(
                    setup.path[targetIndex].lookAt, in: rect,
                    layout: viewport.layout, projection: projection
                )
                stroke(movement, color: AppTheme.Text.primary.cgColor, dashed: true,
                    previewScale: markerScale, referenceScale: symbolScale, context: context)
                if let lookAt {
                    let direction = CGMutablePath()
                    direction.move(to: camera)
                    direction.addLine(to: lookAt)
                    stroke(direction, color: color, dashed: false,
                        previewScale: markerScale, referenceScale: symbolScale, context: context)
                }
                drawCamera(at: camera, lookAt: lookAt, size: AppTheme.IconSize.xs * markerScale, color: color,
                    previewScale: markerScale, context: context)
            }
        }
        for viewport in viewports.values {
            let suffix = viewport.locationNumber.map { " · \($0)" } ?? ""
            drawLabel([
                "Plan (X/Z)" + suffix + " · — Look · - - Path",
                "Plan" + suffix + " · — Look · - - Path",
                "Plan (X/Z)" + suffix,
                "Plan" + suffix,
            ], in: viewport.planLabel, font: font, context: context)
            drawLabel([
                "Elevation (X/Y)" + suffix + " · — Look · - - Path",
                "Elev." + suffix + " · — Look · - - Path",
                "Elev. (X/Y)" + suffix,
                "Elev." + suffix,
            ], in: viewport.elevationLabel, font: font, context: context)
        }
    }

    private static func stroke(_ path: CGPath, color: CGColor, dashed: Bool,
                               previewScale: CGFloat, referenceScale: CGFloat, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(dashed ? .butt : .round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: dashed ? AppTheme.Border.longDash.map { $0 * previewScale } : [])
        let width = dashed ? AppTheme.BorderWidth.blockoutTravel : AppTheme.BorderWidth.thick
        let casing = dashed ? width + AppTheme.BorderWidth.thick
            : max(AppTheme.BorderWidth.heavy, width + AppTheme.BorderWidth.thin * 2 / referenceScale)
        for (color, width) in [
            (AppTheme.Background.surface.cgColor, casing),
            (color, width),
        ] {
            context.addPath(path)
            context.setStrokeColor(color)
            context.setLineWidth(width * previewScale)
            context.strokePath()
        }
    }

    private static func drawCamera(at camera: CGPoint, lookAt: CGPoint?, size: CGFloat,
                                   color: CGColor, previewScale: CGFloat, context: CGContext) {
        let radius = size / 2
        let marker = CGMutablePath()
        if let lookAt, hypot(lookAt.x - camera.x, lookAt.y - camera.y) > CGFloat.ulpOfOne {
            let distance = hypot(lookAt.x - camera.x, lookAt.y - camera.y)
            let forward = CGPoint(x: (lookAt.x - camera.x) / distance, y: (lookAt.y - camera.y) / distance)
            let side = CGPoint(x: -forward.y, y: forward.x)
            marker.move(to: CGPoint(x: camera.x + forward.x * radius, y: camera.y + forward.y * radius))
            let rearHalfWidth = radius * AppTheme.ComponentSize.blockoutMarkerRearHalfWidthRatio
            marker.addLine(to: CGPoint(x: camera.x - forward.x * radius / 2 + side.x * rearHalfWidth,
                y: camera.y - forward.y * radius / 2 + side.y * rearHalfWidth))
            marker.addLine(to: CGPoint(x: camera.x - forward.x * radius / 2 - side.x * rearHalfWidth,
                y: camera.y - forward.y * radius / 2 - side.y * rearHalfWidth))
            marker.closeSubpath()
        } else {
            marker.addEllipse(in: CGRect(x: camera.x - radius, y: camera.y - radius, width: size, height: size))
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(marker)
        context.setFillColor(color)
        context.setStrokeColor(AppTheme.Background.surface.cgColor)
        context.setLineWidth(AppTheme.BorderWidth.medium * previewScale)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
    }

    private static func drawLabel(_ variants: [String], in rect: CGRect, font: CTFont, context: CGContext) {
        guard rect.width > 0, rect.height > 0, let fallback = variants.last else { return }
        func makeLine(_ text: String, _ font: CTFont) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: AppTheme.Text.primary.cgColor,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        let horizontalInset = min(AppTheme.Spacing.xs, rect.width / 4)
        let verticalInset = min(AppTheme.Spacing.xxs, rect.height / 4)
        let width = rect.width - horizontalInset * 2
        let height = rect.height - verticalInset * 2
        let textHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let heightScale = min(1, height / max(CGFloat.ulpOfOne, textHeight))
        let heightFont = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * heightScale, nil, nil)
        let text = variants.first {
            CGFloat(CTLineGetTypographicBounds(makeLine($0, heightFont), nil, nil, nil)) <= width
        } ?? fallback
        let textWidth = CGFloat(CTLineGetTypographicBounds(makeLine(text, heightFont), nil, nil, nil))
        let widthScale = min(1, width / max(CGFloat.ulpOfOne, textWidth))
        let fittedFont = CTFontCreateCopyWithAttributes(heightFont, CTFontGetSize(heightFont) * widthScale, nil, nil)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.setFillColor(AppTheme.Background.surface.cgColor)
        context.fill(rect)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.minX + horizontalInset,
            y: rect.midY - (CTFontGetAscent(fittedFont) - CTFontGetDescent(fittedFont)) / 2)
        CTLineDraw(makeLine(text, fittedFont), context)
    }

    private enum Projection {
        case plan
        case elevation
    }

    private struct Viewport {
        let layout: SpatialLayoutV1
        let plan: CGRect
        let elevation: CGRect
        let planLabel: CGRect
        let elevationLabel: CGRect
        let locationNumber: Int?
    }

    private static func makeViewports(
        layouts: [SpatialLayoutV1],
        bounds: CGRect,
        metric: Bool,
        labelHeight: CGFloat,
        markerClearance: CGFloat
    ) -> [String: Viewport] {
        let ordered = layouts.sorted { $0.locationID < $1.locationID }
        let count = max(1, ordered.count)
        let columns = max(1, Int(ceil(sqrt(Double(count)))))
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)
        var result: [String: Viewport] = [:]
        for (index, layout) in ordered.enumerated() {
            let column = index % columns
            let row = index / columns
            let cell = CGRect(
                x: CGFloat(column) * cellWidth,
                y: CGFloat(row) * cellHeight,
                width: cellWidth,
                height: cellHeight
            ).insetBy(
                dx: AppTheme.Spacing.xs,
                dy: AppTheme.Spacing.xs
            )
            let planHeight = cell.height / 2
            func labeled(_ rect: CGRect) -> (plot: CGRect, label: CGRect) {
                let height = min(labelHeight, rect.height / 2)
                let gap = min(markerClearance + AppTheme.Spacing.xxs, (rect.height - height) / 3)
                let horizontalGap = min(markerClearance, rect.width / 3)
                return (
                    CGRect(x: rect.minX + horizontalGap, y: rect.minY + gap,
                        width: rect.width - horizontalGap * 2, height: rect.height - height - gap * 2),
                    CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
                )
            }
            let plan = labeled(CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: planHeight))
            let elevation = labeled(CGRect(x: cell.minX, y: cell.minY + planHeight,
                width: cell.width, height: cell.height - planHeight))
            var planRect = plan.plot
            var elevationRect = elevation.plot
            if metric {
                let scale = min(planRect.width / layout.widthMeters, planRect.height / layout.depthMeters,
                                elevationRect.width / layout.widthMeters, elevationRect.height / layout.heightMeters)
                func fitted(_ rect: CGRect, height: Double) -> CGRect {
                    let size = CGSize(width: layout.widthMeters * scale, height: height * scale)
                    return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
                }
                planRect = fitted(planRect, height: layout.depthMeters)
                elevationRect = fitted(elevationRect, height: layout.heightMeters)
            }
            result[layout.locationID] = Viewport(layout: layout, plan: planRect, elevation: elevationRect,
                planLabel: plan.label, elevationLabel: elevation.label, locationNumber: count > 1 ? index + 1 : nil)
        }
        return result
    }

    private static func draw(
        shape: BlockoutShapeV1,
        in rect: CGRect,
        layout: SpatialLayoutV1,
        projection: Projection,
        context: CGContext
    ) {
        let center = project(
            shape.center,
            in: rect,
            layout: layout,
            projection: projection
        )
        let width: CGFloat
        let height: CGFloat
        switch projection {
        case .plan:
            width = CGFloat(shape.size.x / layout.widthMeters) * rect.width
            height = CGFloat(shape.size.z / layout.depthMeters) * rect.height
        case .elevation:
            width = CGFloat(shape.size.x / layout.widthMeters) * rect.width
            height = CGFloat(shape.size.y / layout.heightMeters) * rect.height
        }
        let shapeRect = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(shape.headingDegrees * .pi / 180))
        context.translateBy(x: -center.x, y: -center.y)
        switch shape.primitive {
        case .box:
            context.fill(shapeRect)
            context.stroke(shapeRect)
        case .cylinder:
            context.fillEllipse(in: shapeRect)
            context.strokeEllipse(in: shapeRect)
        }
        context.restoreGState()
    }

    private static func project(
        _ point: SpatialVector3V1,
        in rect: CGRect,
        layout: SpatialLayoutV1,
        projection: Projection
    ) -> CGPoint {
        let x = (point.x + layout.widthMeters / 2) / layout.widthMeters
        let vertical = switch projection {
        case .plan: (point.z + layout.depthMeters / 2) / layout.depthMeters
        case .elevation: point.y / layout.heightMeters
        }
        return CGPoint(
            x: rect.minX + CGFloat(x) * rect.width,
            y: rect.minY + CGFloat(vertical) * rect.height
        )
    }
}
