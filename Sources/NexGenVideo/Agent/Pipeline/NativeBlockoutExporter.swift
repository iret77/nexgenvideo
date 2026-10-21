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

    enum ViewArrangement: Sendable, Equatable { case stacked, bestFit }

    struct PlanFrame: Sendable {
        let cameras: [CameraProjection]
        let layouts: [SpatialLayoutV1]
        let shapes: [BlockoutShapeV1]
        let metric: Bool
        let arrangement: ViewArrangement

        init(cameras: [CameraProjection], layouts: [SpatialLayoutV1], shapes: [BlockoutShapeV1], metric: Bool = false,
             arrangement: ViewArrangement = .stacked) {
            self.cameras = cameras; self.layouts = layouts; self.shapes = shapes; self.metric = metric
            self.arrangement = arrangement
        }
    }

    static func export(setups: [CameraSetupV1], layouts: [SpatialLayoutV1], shapes: [BlockoutShapeV1],
                       request: BlockoutRequestV1, to url: URL) throws {
        let count = max(1, Int((request.durationSeconds * Double(request.fps)).rounded()))
        try export(width: request.width, height: request.height, frameCount: count,
            presentation: { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(request.fps)) },
            duration: CMTime(value: CMTimeValue(count), timescale: CMTimeScale(request.fps)), to: url) { _ in
                PlanFrame(cameras: setups.map { .init(id: $0.id, locationID: $0.locationID, position: $0.position, path: $0.path) },
                    layouts: layouts, shapes: shapes, metric: true, arrangement: .bestFit)
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
                arrangement: plan.arrangement,
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
        arrangement: ViewArrangement,
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
        let diagramScale = max(1, min(bounds.width / AppTheme.Layout.blockoutReferenceSize.width,
                                      bounds.height / AppTheme.Layout.blockoutReferenceSize.height))
        let spacingScale = arrangement == .bestFit ? diagramScale : 1
        let lineScale = arrangement == .bestFit ? diagramScale : previewScale
        let font = NSFont.systemFont(ofSize: AppTheme.FontSize.xs * lineScale,
            weight: AppTheme.AppKitFontWeight.semibold) as CTFont
        let labelHeight = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            + AppTheme.Spacing.xxs * spacingScale * 2)
            * (arrangement == .bestFit ? 2 : 1)
        let symbolScale = arrangement == .bestFit
            ? AppTheme.IconSize.smMd / AppTheme.IconSize.xs * diagramScale
            : max(previewScale, AppTheme.IconSize.lgXl / AppTheme.IconSize.xs)
        let markerClearance = (AppTheme.IconSize.xs + AppTheme.BorderWidth.medium) * symbolScale / 2
        let viewports = makeViewports(layouts: layouts, bounds: bounds, metric: metric,
            labelHeight: labelHeight, markerClearance: markerClearance, spacingScale: spacingScale,
            arrangement: arrangement)
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

        var drawings: [CameraDrawing] = []
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
                let radius = markerExclusionRadius(scale: markerScale)
                drawings.append(CameraDrawing(locationID: setup.locationID, projection: projection,
                    movement: movement, travelPoints: projected, camera: camera, lookAt: lookAt, color: color, scale: markerScale,
                    hasVisibleTravel: projected.contains { hypot($0.x - camera.x, $0.y - camera.y) > radius }))
            }
        }
        context.saveGState()
        for drawing in drawings {
            let radius = markerExclusionRadius(scale: drawing.scale)
            context.beginPath()
            context.addRect(bounds)
            context.addEllipse(in: CGRect(x: drawing.camera.x - radius, y: drawing.camera.y - radius,
                width: radius * 2, height: radius * 2))
            context.clip(using: .evenOdd)
        }
        for drawing in drawings {
            strokeTravel(drawing, excluding: drawings, previewScale: lineScale, referenceScale: symbolScale,
                arrangement: arrangement, bounds: bounds, context: context)
        }
        for drawing in drawings {
            if let direction = drawing.lookPath {
                stroke(direction, color: drawing.color, dashed: false,
                    previewScale: lineScale, markerScale: drawing.scale, referenceScale: symbolScale,
                    arrangement: arrangement, context: context)
            }
        }
        context.restoreGState()
        for drawing in drawings {
            drawCamera(at: drawing.camera, lookAt: drawing.lookAt, size: AppTheme.IconSize.xs * drawing.scale,
                color: drawing.color, previewScale: drawing.scale, arrangement: arrangement, context: context)
        }
        for (locationID, viewport) in viewports {
            let suffix = viewport.locationNumber.map { " · \($0)" } ?? ""
            for (projection, label, title, shortTitle, axes) in [
                (Projection.plan, viewport.planLabel, "Plan", "Plan", "X/Z"),
                (Projection.elevation, viewport.elevationLabel, "Elevation", "Elev.", "X/Y"),
            ] {
                let roles = legend(for: drawings.filter { $0.locationID == locationID && $0.projection == projection },
                    arrangement: arrangement)
                let titles = [title + " (" + axes + ")" + suffix, shortTitle + " (" + axes + ")" + suffix,
                    shortTitle + suffix]
                if arrangement == .bestFit {
                    let minimum = roles.heading.isEmpty ? 0 : AppTheme.FontSize.minimumReadable * lineScale
                    let headings = titles.map { $0 + (roles.heading.isEmpty ? "" : " · " + roles.heading) }
                    drawLabel(headings, in: CGRect(x: label.minX, y: label.midY, width: label.width, height: label.height / 2),
                        font: font, insetScale: spacingScale, minimumFontSize: minimum, context: context)
                    drawLabel(roles.lines, in: CGRect(x: label.minX, y: label.minY, width: label.width, height: label.height / 2),
                        font: font, insetScale: spacingScale, minimumFontSize: minimum, context: context)
                } else {
                    let full = roles.lines.first.map { $0.isEmpty ? "" : " · " + $0 } ?? ""
                    let compact = roles.lines.last.map { $0.isEmpty ? "" : " · " + $0 } ?? ""
                    drawLabel([titles[0] + full, shortTitle + suffix + compact] + titles,
                        in: label, font: font, context: context)
                }
            }
        }
    }

    private static func markerExclusionRadius(scale: CGFloat) -> CGFloat {
        ((AppTheme.IconSize.xs + AppTheme.BorderWidth.medium) / 2 + AppTheme.Spacing.xs) * scale
    }

    private static func legend(for drawings: [CameraDrawing], arrangement: ViewArrangement) -> (heading: String, lines: [String]) {
        guard !drawings.isEmpty else { return ("", [""]) }
        let hasLook = drawings.contains { $0.hasVisibleLook }
        let hasHeading = drawings.contains { $0.hasHeading }
        let hasTravel = drawings.contains { $0.hasVisibleTravel }
        let direction = hasLook ? "— Look" : hasHeading ? "Camera direction" : "No projected direction"
        let compact = hasLook ? "Look" : hasHeading ? "Direction" : "No direction in view"
        if arrangement == .bestFit, drawings.contains(where: { $0.hasSmallProjectedTravel }) {
            let heading = hasLook ? "Look" : hasHeading ? "Direction" : "No direction"
            let mixed = drawings.contains { $0.hasProjectedTravel && !$0.hasSmallProjectedTravel }
            return (heading, ["Path (" + (mixed ? "incl. small in view" : "small in view") + ")",
                "Path (" + (mixed ? "incl. small" : "small") + ")"])
        }
        return ("", [direction + (hasTravel ? " · - - Path" : ""), compact + (hasTravel ? " / Path" : "")])
    }

    private static func strokeTravel(_ drawing: CameraDrawing, excluding drawings: [CameraDrawing], previewScale: CGFloat,
                                     referenceScale: CGFloat, arrangement: ViewArrangement, bounds: CGRect, context: CGContext) {
        stroke(drawing.movement, color: AppTheme.Text.primary.cgColor, dashed: true,
            previewScale: previewScale, markerScale: drawing.scale, referenceScale: referenceScale,
            arrangement: arrangement, context: context)
        guard drawing.hasVisibleTravel, let direction = drawing.lookPath else { return }
        if arrangement == .bestFit {
            let widths = strokeWidths(dashed: true, overlappingLook: true, previewScale: previewScale,
                markerScale: drawing.scale, referenceScale: referenceScale, arrangement: arrangement)
            let look = strokeWidths(dashed: false, overlappingLook: false, previewScale: previewScale,
                markerScale: drawing.scale, referenceScale: referenceScale, arrangement: arrangement)
            let travel = strokeWidths(dashed: true, overlappingLook: false, previewScale: previewScale,
                markerScale: drawing.scale, referenceScale: referenceScale, arrangement: arrangement)
            let overlaps = overlappingTravelDashes(drawing, excluding: drawings, casingWidth: widths.casing,
                overlapRadius: (look.casing + travel.casing) / 2, bounds: bounds)
            stroke(overlaps, color: AppTheme.Text.primary.cgColor, dashed: true, overlappingLook: true, preDashed: true,
                previewScale: previewScale, markerScale: drawing.scale, referenceScale: referenceScale,
                arrangement: arrangement, context: context)
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        let widths = strokeWidths(dashed: true, overlappingLook: true, previewScale: previewScale,
            markerScale: drawing.scale, referenceScale: referenceScale, arrangement: arrangement)
        context.addPath(direction)
        context.setLineDash(phase: 0, lengths: [])
        context.setLineCap(.butt)
        context.setLineJoin(.round)
        context.setLineWidth(widths.casing)
        context.replacePathWithStrokedPath()
        context.clip()
        stroke(drawing.movement, color: AppTheme.Text.primary.cgColor, dashed: true, overlappingLook: true,
            previewScale: previewScale, markerScale: drawing.scale, referenceScale: referenceScale,
            arrangement: arrangement, context: context)
    }

    private static func overlappingTravelDashes(_ drawing: CameraDrawing, excluding drawings: [CameraDrawing],
                                                casingWidth: CGFloat, overlapRadius: CGFloat, bounds: CGRect) -> CGPath {
        let result = CGMutablePath()
        guard let lookAt = drawing.lookAt else { return result }
        let lookLength = hypot(lookAt.x - drawing.camera.x, lookAt.y - drawing.camera.y)
        guard lookLength.isFinite, lookLength > CGFloat.ulpOfOne else { return result }
        let forward = CGPoint(x: (lookAt.x - drawing.camera.x) / lookLength,
            y: (lookAt.y - drawing.camera.y) / lookLength)
        let lookBounds = CGRect(x: min(drawing.camera.x, lookAt.x), y: min(drawing.camera.y, lookAt.y),
            width: abs(lookAt.x - drawing.camera.x), height: abs(lookAt.y - drawing.camera.y))
            .insetBy(dx: -overlapRadius, dy: -overlapRadius)
        let searchBounds = bounds.insetBy(dx: -casingWidth / 2, dy: -casingWidth / 2).intersection(lookBounds)
        guard !searchBounds.isNull, !searchBounds.isEmpty else { return result }
        func overlapsLook(_ point: CGPoint) -> Bool {
            let x = point.x - drawing.camera.x, y = point.y - drawing.camera.y
            let along = x * forward.x + y * forward.y
            let closest = min(lookLength, max(0, along))
            return hypot(x - closest * forward.x, y - closest * forward.y) <= overlapRadius
        }
        func clearsMarkers(_ points: [CGPoint]) -> Bool {
            return drawings.allSatisfy { marker in
                let radius = markerExclusionRadius(scale: marker.scale)
                for (start, end) in zip(points, points.dropFirst()) {
                    let length = hypot(end.x - start.x, end.y - start.y)
                    guard length > CGFloat.ulpOfOne else { return false }
                    let direction = CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length)
                    let x = marker.camera.x - start.x, y = marker.camera.y - start.y
                    let along = x * direction.x + y * direction.y
                    let across = x * direction.y - y * direction.x
                    let outsideEnd = max(0, -along, along - length)
                    let outsideSide = max(0, abs(across) - casingWidth / 2)
                    if hypot(outsideEnd, outsideSide) <= radius { return false }
                }
                for index in 1..<(points.count - 1) {
                    let vertex = points[index]
                    let incomingLength = hypot(vertex.x - points[index - 1].x, vertex.y - points[index - 1].y)
                    let outgoingLength = hypot(points[index + 1].x - vertex.x, points[index + 1].y - vertex.y)
                    guard incomingLength > 0, outgoingLength > 0 else { return false }
                    let incoming = CGPoint(x: (vertex.x - points[index - 1].x) / incomingLength,
                        y: (vertex.y - points[index - 1].y) / incomingLength)
                    let outgoing = CGPoint(x: (points[index + 1].x - vertex.x) / outgoingLength,
                        y: (points[index + 1].y - vertex.y) / outgoingLength)
                    let turn = incoming.x * outgoing.y - incoming.y * outgoing.x
                    if turn == 0 && incoming.x * outgoing.x + incoming.y * outgoing.y >= 0 { continue }
                    let sign: CGFloat = turn < 0 ? -1 : 1
                    let firstNormal = CGPoint(x: incoming.y * sign, y: -incoming.x * sign)
                    let lastNormal = CGPoint(x: outgoing.y * sign, y: -outgoing.x * sign)
                    let x = marker.camera.x - vertex.x, y = marker.camera.y - vertex.y
                    let afterFirst = (firstNormal.x * y - firstNormal.y * x) * sign >= 0
                    let beforeLast = (x * lastNormal.y - y * lastNormal.x) * sign >= 0
                    if afterFirst && beforeLast && hypot(x, y) <= radius + casingWidth / 2 { return false }
                }
                return true
            }
        }
        var segments: [TravelSegment] = []
        var distance: CGFloat = 0
        for (start, end) in zip(drawing.travelPoints, drawing.travelPoints.dropFirst()) {
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length.isFinite else { return result }
            guard length > 0 else { continue }
            segments.append(TravelSegment(start: start, end: end, startDistance: distance, endDistance: distance + length))
            distance += length
        }
        let pattern = AppTheme.Border.longDash.map { $0 * drawing.scale }
        guard distance.isFinite, pattern.count == 2, let on = pattern.first, on > 0 else { return result }
        let period = pattern.reduce(0, +)
        guard period.isFinite, period > 0 else { return result }
        var ranges: [(first: CGFloat, last: CGFloat)] = []
        for segment in segments {
            let length = segment.endDistance - segment.startDistance
            guard length > 0 else { continue }
            var entry: CGFloat = 0
            var exit = length
            for (origin, direction, lower, upper) in [
                (segment.start.x, (segment.end.x - segment.start.x) / length, searchBounds.minX, searchBounds.maxX),
                (segment.start.y, (segment.end.y - segment.start.y) / length, searchBounds.minY, searchBounds.maxY),
            ] {
                if direction == 0 {
                    if origin < lower || origin > upper { exit = -1; break }
                } else {
                    let first = (lower - origin) / direction, last = (upper - origin) / direction
                    entry = max(entry, min(first, last))
                    exit = min(exit, max(first, last))
                }
            }
            guard entry.isFinite, exit.isFinite, entry <= exit else { continue }
            let from = segment.startDistance + entry, to = segment.startDistance + exit
            guard from.isFinite, to.isFinite else { continue }
            let phase = from.truncatingRemainder(dividingBy: period)
            var first = from - phase
            if phase > on { first += period }
            let last = to - to.truncatingRemainder(dividingBy: period)
            guard first.isFinite, last.isFinite, first <= last else { continue }
            if let prior = ranges.last, first <= prior.last + period {
                ranges[ranges.count - 1].last = max(prior.last, last)
            } else {
                ranges.append((first, last))
            }
        }
        var firstSegment = 0
        // Hidden spans and turns must not restart the source path's dash phase.
        for range in ranges {
            var dashOffset: CGFloat = 0
            var dashStart = range.first
            while dashStart <= range.last && dashStart < distance {
                let dashEnd = min(range.first + (dashOffset + on), distance)
                guard dashEnd.isFinite, dashEnd > dashStart else { break }
                while firstSegment < segments.count && segments[firstSegment].endDistance <= dashStart {
                    firstSegment += 1
                }
                var index = firstSegment
                var points: [CGPoint] = []
                var valid = true
                while index < segments.count && segments[index].startDistance < dashEnd {
                    let segment = segments[index]
                    let length = segment.endDistance - segment.startDistance
                    guard length > 0 else { index += 1; continue }
                    let from = max(dashStart, segment.startDistance), to = min(dashEnd, segment.endDistance)
                    let dx = segment.end.x - segment.start.x, dy = segment.end.y - segment.start.y
                    let first = from == segment.startDistance ? segment.start
                        : CGPoint(x: segment.start.x + dx * ((from - segment.startDistance) / length),
                            y: segment.start.y + dy * ((from - segment.startDistance) / length))
                    let last = to == segment.endDistance ? segment.end
                        : CGPoint(x: segment.start.x + dx * ((to - segment.startDistance) / length),
                            y: segment.start.y + dy * ((to - segment.startDistance) / length))
                    if !overlapsLook(first) || !overlapsLook(last) {
                        valid = false
                        break
                    }
                    if points.isEmpty { points.append(first) }
                    points.append(last)
                    index += 1
                }
                if valid, points.count > 1, let start = points.first, clearsMarkers(points) {
                    result.move(to: start)
                    for point in points.dropFirst() { result.addLine(to: point) }
                }
                let nextOffset = dashOffset + period
                let next = range.first + nextOffset
                guard nextOffset.isFinite, nextOffset > dashOffset, next.isFinite, next > dashStart else { break }
                dashOffset = nextOffset
                dashStart = next
            }
        }
        return result
    }

    private static func strokeWidths(dashed: Bool, overlappingLook: Bool, previewScale: CGFloat,
                                     markerScale: CGFloat, referenceScale: CGFloat,
                                     arrangement: ViewArrangement) -> (line: CGFloat, casing: CGFloat) {
        let fitScale = markerScale / referenceScale
        let lineScale = previewScale * fitScale
        let lookWidth = arrangement == .bestFit ? AppTheme.BorderWidth.blockoutLookMinimum * lineScale
            : max(AppTheme.BorderWidth.thick * lineScale, AppTheme.BorderWidth.blockoutLookMinimum * fitScale)
        let halo = arrangement == .bestFit ? AppTheme.BorderWidth.thin * lineScale
            : max(AppTheme.BorderWidth.thin * fitScale, AppTheme.BorderWidth.hairline * lineScale)
        let lookCasing = lookWidth + halo * 2
        let travelWidth = lookCasing + AppTheme.BorderWidth.thick * lineScale * 2
        let width = dashed ? (overlappingLook ? travelWidth : AppTheme.BorderWidth.thick * lineScale) : lookWidth
        let casing = dashed ? width + halo * 2 : lookCasing
        return (width, casing)
    }

    private static func stroke(_ path: CGPath, color: CGColor, dashed: Bool, overlappingLook: Bool = false,
                               preDashed: Bool = false, previewScale: CGFloat, markerScale: CGFloat,
                               referenceScale: CGFloat, arrangement: ViewArrangement, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(dashed ? .butt : .round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: dashed && !preDashed ? AppTheme.Border.longDash.map { $0 * markerScale } : [])
        let widths = strokeWidths(dashed: dashed, overlappingLook: overlappingLook,
            previewScale: previewScale, markerScale: markerScale, referenceScale: referenceScale, arrangement: arrangement)
        for (color, width) in [
            (AppTheme.Background.surface.cgColor, widths.casing),
            (color, widths.line),
        ] {
            context.addPath(path)
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.strokePath()
        }
    }

    private static func drawCamera(at camera: CGPoint, lookAt: CGPoint?, size: CGFloat,
                                   color: CGColor, previewScale: CGFloat, arrangement: ViewArrangement, context: CGContext) {
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
            if arrangement == .bestFit {
                let inset = radius * AppTheme.ComponentSize.blockoutMarkerNotchInsetRatio
                marker.addLine(to: CGPoint(x: camera.x - forward.x * inset, y: camera.y - forward.y * inset))
            }
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
        context.strokePath()
        context.addPath(marker)
        context.fillPath()
    }

    private static func drawLabel(_ variants: [String], in rect: CGRect, font: CTFont,
                                  insetScale: CGFloat = 1, minimumFontSize: CGFloat = 0, context: CGContext) {
        guard rect.width > 0, rect.height > 0, let fallback = variants.last else { return }
        func makeLine(_ text: String, _ font: CTFont) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: AppTheme.Text.primary.cgColor,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        let horizontalInset = min(AppTheme.Spacing.xs * insetScale, rect.width / 4)
        let verticalInset = min(AppTheme.Spacing.xxs * insetScale, rect.height / 4)
        let width = rect.width - horizontalInset * 2
        let height = rect.height - verticalInset * 2
        let textHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let heightScale = min(1, height / max(CGFloat.ulpOfOne, textHeight))
        let heightFont = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * heightScale, nil, nil)
        let selectionFont = minimumFontSize > 0
            ? CTFontCreateCopyWithAttributes(heightFont, minimumFontSize, nil, nil) : heightFont
        let text = variants.first {
            CGFloat(CTLineGetTypographicBounds(makeLine($0, selectionFont), nil, nil, nil)) <= width
        } ?? fallback
        let textWidth = CGFloat(CTLineGetTypographicBounds(makeLine(text, heightFont), nil, nil, nil))
        let widthScale = min(1, width / max(CGFloat.ulpOfOne, textWidth))
        let fittedFont = CTFontCreateCopyWithAttributes(heightFont,
            max(minimumFontSize, CTFontGetSize(heightFont) * widthScale), nil, nil)
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

    private enum Projection: Equatable {
        case plan
        case elevation
    }

    private struct TravelSegment {
        let start: CGPoint
        let end: CGPoint
        let startDistance: CGFloat
        let endDistance: CGFloat
    }

    private struct CameraDrawing {
        let locationID: String
        let projection: Projection
        let movement: CGPath
        let travelPoints: [CGPoint]
        let camera: CGPoint
        let lookAt: CGPoint?
        let color: CGColor
        let scale: CGFloat
        let hasVisibleTravel: Bool

        var projectedTravelExtent: CGFloat {
            let bounds = movement.boundingBoxOfPath
            return hypot(bounds.width, bounds.height)
        }

        var hasProjectedTravel: Bool {
            projectedTravelExtent > CGFloat.ulpOfOne
        }

        var hasSmallProjectedTravel: Bool {
            let radius = NativeBlockoutExporter.markerExclusionRadius(scale: scale)
                + AppTheme.Border.longDash[0] * scale
            return hasProjectedTravel && projectedTravelExtent <= radius
        }

        var lookPath: CGPath? {
            guard let lookAt else { return nil }
            let path = CGMutablePath()
            path.move(to: camera)
            path.addLine(to: lookAt)
            return path
        }

        var hasHeading: Bool {
            guard let lookAt else { return false }
            return hypot(lookAt.x - camera.x, lookAt.y - camera.y) > CGFloat.ulpOfOne
        }

        var hasVisibleLook: Bool {
            guard let lookAt else { return false }
            return hypot(lookAt.x - camera.x, lookAt.y - camera.y) > NativeBlockoutExporter.markerExclusionRadius(scale: scale)
        }
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
        markerClearance: CGFloat,
        spacingScale: CGFloat,
        arrangement: ViewArrangement
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
                dx: AppTheme.Spacing.xs * spacingScale,
                dy: AppTheme.Spacing.xs * spacingScale
            )
            let planHeight = cell.height / 2
            func labeled(_ rect: CGRect) -> (plot: CGRect, label: CGRect) {
                let height = min(labelHeight, rect.height / 2)
                let gap = min(markerClearance + AppTheme.Spacing.xxs * spacingScale, (rect.height - height) / 3)
                let horizontalGap = min(markerClearance, rect.width / 3)
                return (
                    CGRect(x: rect.minX + horizontalGap, y: rect.minY + gap,
                        width: rect.width - horizontalGap * 2, height: rect.height - height - gap * 2),
                    CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
                )
            }
            var plan = labeled(CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: planHeight))
            var elevation = labeled(CGRect(x: cell.minX, y: cell.minY + planHeight,
                width: cell.width, height: cell.height - planHeight))
            func metricScale(_ plan: CGRect, _ elevation: CGRect) -> CGFloat {
                min(plan.width / layout.widthMeters, plan.height / layout.depthMeters,
                    elevation.width / layout.widthMeters, elevation.height / layout.heightMeters)
            }
            if arrangement == .bestFit {
                let sidePlan = labeled(CGRect(x: cell.minX, y: cell.minY, width: cell.width / 2, height: cell.height))
                let sideElevation = labeled(CGRect(x: cell.midX, y: cell.minY, width: cell.width / 2, height: cell.height))
                if metricScale(sidePlan.plot, sideElevation.plot) > metricScale(plan.plot, elevation.plot) {
                    plan = sidePlan; elevation = sideElevation
                }
            }
            var planRect = plan.plot
            var elevationRect = elevation.plot
            if metric {
                let scale = metricScale(planRect, elevationRect)
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
