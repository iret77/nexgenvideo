import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import NexGenEngine

enum NativeBlockoutExporter {
    static func export(
        setups: [CameraSetupV1],
        layouts: [SpatialLayoutV1],
        shapes: [BlockoutShapeV1],
        request: BlockoutRequestV1,
        to url: URL
    ) throws {
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
                AVVideoWidthKey: request.width,
                AVVideoHeightKey: request.height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: request.width,
                kCVPixelBufferHeightKey as String: request.height,
            ]
        )
        guard writer.canAdd(input) else {
            throw ToolError("The native blockout video encoder is unavailable.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ToolError(writer.error?.localizedDescription ?? "The native blockout could not start.")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw ToolError("The native blockout pixel-buffer pool is unavailable.")
        }
        let frameCount = max(1, Int((request.durationSeconds * Double(request.fps)).rounded()))
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
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
            try draw(
                setups: setups,
                layouts: layouts,
                shapes: shapes,
                progress: Double(frameIndex) / Double(max(1, frameCount - 1)),
                in: buffer
            )
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(request.fps))
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                writer.cancelWriting()
                throw ToolError(writer.error?.localizedDescription ?? "The native blockout frame could not be written.")
            }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ToolError(writer.error?.localizedDescription ?? "The native blockout export failed.")
        }
    }

    private static func draw(
        setups: [CameraSetupV1],
        layouts: [SpatialLayoutV1],
        shapes: [BlockoutShapeV1],
        progress: Double,
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
        context.setStrokeColor(CGColor(gray: 0.38, alpha: 1))
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

        let viewports = makeViewports(layouts: layouts, bounds: bounds)
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
            let hue = CGFloat(index % 5) / 5
            let color = CGColor(
                red: 0.45 + hue * 0.3,
                green: 0.72 - hue * 0.18,
                blue: 0.85 - hue * 0.08,
                alpha: 1
            )
            context.setStrokeColor(color)
            context.setFillColor(color)
            context.setLineWidth(AppTheme.BorderWidth.thick)
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
                let projected = points.map {
                    project($0, in: rect, layout: viewport.layout, projection: projection)
                }
                guard let first = projected.first else { continue }
                context.move(to: first)
                for point in projected.dropFirst() { context.addLine(to: point) }
                context.strokePath()
                let camera = projected[targetIndex]
                let markerSize = max(
                    AppTheme.IconSize.xs / 2,
                    min(rect.width, rect.height) / 18
                )
                context.fillEllipse(in: CGRect(
                    x: camera.x - markerSize / 2,
                    y: camera.y - markerSize / 2,
                    width: markerSize,
                    height: markerSize
                ))
                if !setup.path.isEmpty {
                    let lookAt = project(
                        setup.path[targetIndex].lookAt,
                        in: rect,
                        layout: viewport.layout,
                        projection: projection
                    )
                    context.move(to: camera)
                    context.addLine(to: lookAt)
                    context.strokePath()
                }
            }
        }
    }

    private enum Projection {
        case plan
        case elevation
    }

    private struct Viewport {
        let layout: SpatialLayoutV1
        let plan: CGRect
        let elevation: CGRect
    }

    private static func makeViewports(
        layouts: [SpatialLayoutV1],
        bounds: CGRect
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
            let planHeight = cell.height * 0.67
            result[layout.locationID] = Viewport(
                layout: layout,
                plan: CGRect(
                    x: cell.minX,
                    y: cell.minY,
                    width: cell.width,
                    height: planHeight
                ),
                elevation: CGRect(
                    x: cell.minX,
                    y: cell.minY + planHeight,
                    width: cell.width,
                    height: cell.height - planHeight
                )
            )
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
