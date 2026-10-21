import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Native blockout exporter")
struct NativeBlockoutExporterTests {
    @Test("exports metric shapes and a camera path as playable video")
    func exportsPlayableGraybox() async throws {
        try await verifyGraybox(width: 320, height: 180, evidenceName: "graybox")
    }

    @Test("collinear viewing direction and movement remain visible at normal export size")
    func collinearLookAndPathRemainVisibleAtNormalExportSize() async throws {
        try await verifyGraybox(width: 1280, height: 720, evidenceName: "graybox-1280x720")
    }

    private func verifyGraybox(width: Int, height: Int, evidenceName: String) async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("blockout-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let layout = SpatialLayoutV1(
            locationID: "room",
            widthMeters: 8,
            depthMeters: 6,
            heightMeters: 4,
            setupIDs: ["wide"]
        )
        let shape = BlockoutShapeV1(
            id: "room-floor",
            entityID: "room",
            entityStateIDs: ["room-v1"],
            locationID: "room",
            primitive: .box,
            center: SpatialVector3V1(x: 0, y: 0.05, z: 0),
            size: SpatialVector3V1(x: 8, y: 0.1, z: 6),
            headingDegrees: 0
        )
        let setup = CameraSetupV1(
            id: "wide",
            locationID: "room",
            position: SpatialVector3V1(x: -2, y: 1.5, z: -2),
            orientationDegrees: SpatialVector3V1(x: 0, y: 0, z: 0),
            axisID: "room-axis",
            axisSide: .positive,
            heightMeters: 1.5,
            focalLengthMM: 35,
            horizontalFOVDegrees: 54,
            lookTarget: "room center",
            path: [
                CameraPathKeyframeV1(
                    timeSeconds: 0,
                    position: SpatialVector3V1(x: -2, y: 1.5, z: -2),
                    lookAt: SpatialVector3V1(x: 0, y: 1, z: 0)
                ),
                CameraPathKeyframeV1(
                    timeSeconds: 1,
                    position: SpatialVector3V1(x: 2, y: 2.5, z: 2),
                    lookAt: SpatialVector3V1(x: 0, y: 1, z: 0)
                ),
            ]
        )
        try NativeBlockoutExporter.export(
            setups: [setup],
            layouts: [layout],
            shapes: [shape],
            request: BlockoutRequestV1(
                mode: .native,
                width: width,
                height: height,
                fps: 4,
                durationSeconds: 1
            ),
            to: output
        )

        let evidence = ProcessInfo.processInfo.environment["NGV_BLOCKOUT_ORIENTATION_EVIDENCE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let evidence {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: output, to: evidence.appendingPathComponent(evidenceName + ".mov"))
        }
        let asset = AVURLAsset(url: output)
        let track = try #require(
            try await asset.loadTracks(withMediaType: .video).first
        )
        #expect(try await track.load(.naturalSize) == CGSize(width: CGFloat(width), height: CGFloat(height)))
        #expect(try await asset.load(.duration).seconds >= 0.75)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: .zero).image
        if let evidence {
            let destination = try #require(CGImageDestinationCreateWithURL(
                evidence.appendingPathComponent(evidenceName + ".png") as CFURL,
                UTType.png.identifier as CFString, 1, nil
            ))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let pixel = try #require(bitmap.colorAt(x: image.width / 4, y: image.height / 2))
        #expect(pixel.brightnessComponent > 0.4)
        let floor = try #require(pixel.usingColorSpace(.deviceRGB))
        let extent = try #require(floorExtent(in: bitmap, floor: floor))
        #expect(abs(Double(extent.width) * layout.depthMeters - Double(extent.height) * layout.widthMeters)
            <= 2 * (layout.widthMeters + layout.depthMeters))
        let marks = try planMarks(in: bitmap)
        let pixelScale = max(1, width / 320)
        #expect(abs(marks.direction.dx + marks.direction.dy) <= CGFloat(2 * pixelScale))
        #expect(markerFacesLook(marks))
        #expect(simultaneousLookAndPathColumns(in: bitmap, marks: marks) >= 3 * pixelScale)
        #expect(markerBackgroundGapColumns(in: bitmap, floor: floor, marks: marks) >= 2 * pixelScale)
    }

    private struct PixelPoint {
        let x: Int
        let y: Int
    }

    private struct PlanMarks {
        let marker: [PixelPoint]
        let look: [PixelPoint]
        let anchor: CGPoint
        let direction: CGVector

        var normal: CGVector {
            let length = hypot(direction.dx, direction.dy)
            return CGVector(dx: -direction.dy / length, dy: direction.dx / length)
        }
    }

    private func components(in bitmap: NSBitmapImageRep, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat)? {
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
              let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    private func isLook(_ color: (CGFloat, CGFloat, CGFloat)) -> Bool {
        color.2 - color.0 > 0.1 && color.1 - color.0 > 0.07
    }

    private func isFloor(_ color: (CGFloat, CGFloat, CGFloat), floor: NSColor) -> Bool {
        abs(color.0 - floor.redComponent) < 0.08 && abs(color.1 - floor.greenComponent) < 0.08
            && abs(color.2 - floor.blueComponent) < 0.08
    }

    private func floorExtent(in bitmap: NSBitmapImageRep, floor: NSColor) -> (width: Int, height: Int)? {
        var columns = Array(repeating: 0, count: bitmap.pixelsWide / 2)
        var rows = Array(repeating: 0, count: bitmap.pixelsHigh)
        for x in columns.indices {
            for y in rows.indices {
                guard let color = components(in: bitmap, x: x, y: y), isFloor(color, floor: floor) else { continue }
                columns[x] += 1; rows[y] += 1
            }
        }
        guard let maxColumn = columns.max(), maxColumn > 0, let maxRow = rows.max(), maxRow > 0 else { return nil }
        let occupiedX = columns.indices.filter { columns[$0] * 2 >= maxColumn }
        let occupiedY = rows.indices.filter { rows[$0] * 2 >= maxRow }
        guard let minX = occupiedX.first, let maxX = occupiedX.last,
              let minY = occupiedY.first, let maxY = occupiedY.last else { return nil }
        return (maxX - minX + 1, maxY - minY + 1)
    }

    private func planMarks(in bitmap: NSBitmapImageRep) throws -> PlanMarks {
        let width = bitmap.pixelsWide
        var remaining: Set<Int> = []
        for x in 0..<(width / 2) {
            for y in 0..<bitmap.pixelsHigh {
                if let color = components(in: bitmap, x: x, y: y), isLook(color) {
                    remaining.insert(y * width + x)
                }
            }
        }
        var groups: [[PixelPoint]] = []
        while let seed = remaining.popFirst() {
            var pending = [seed], group: [PixelPoint] = []
            while let encoded = pending.popLast() {
                let point = PixelPoint(x: encoded % width, y: encoded / width)
                group.append(point)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let x = point.x + dx, y = point.y + dy
                        guard x >= 0, x < width / 2, y >= 0, y < bitmap.pixelsHigh else { continue }
                        let neighbor = y * width + x
                        if remaining.remove(neighbor) != nil { pending.append(neighbor) }
                    }
                }
            }
            if group.count >= 3 * max(1, width / 320) { groups.append(group) }
        }
        groups.sort { ($0.map { $0.x }.min() ?? width) < ($1.map { $0.x }.min() ?? width) }
        try #require(groups.count == 2, "The Plan must contain a distinct cyan marker and Look segment.")
        let marker = groups[0], look = groups[1]
        let minX = try #require(look.map { $0.x }.min())
        let maxX = try #require(look.map { $0.x }.max())
        let inset = max(1, (maxX - minX) / 4)
        let firstX = minX + inset, lastX = maxX - inset
        try #require(lastX > firstX)
        func centerY(at x: Int) throws -> CGFloat {
            let rows = look.filter { $0.x == x }.map { $0.y }
            try #require(!rows.isEmpty)
            return CGFloat(rows.reduce(0, +)) / CGFloat(rows.count)
        }
        let firstY = try centerY(at: firstX), lastY = try centerY(at: lastX)
        return PlanMarks(marker: marker, look: look, anchor: CGPoint(x: CGFloat(firstX), y: firstY),
            direction: CGVector(dx: CGFloat(lastX - firstX), dy: lastY - firstY))
    }

    private func markerFacesLook(_ marks: PlanMarks) -> Bool {
        let center = CGPoint(x: CGFloat(marks.marker.map { $0.x }.reduce(0, +)) / CGFloat(marks.marker.count),
            y: CGFloat(marks.marker.map { $0.y }.reduce(0, +)) / CGFloat(marks.marker.count))
        let projected = marks.marker.map {
            (CGFloat($0.x) - center.x) * marks.direction.dx + (CGFloat($0.y) - center.y) * marks.direction.dy
        }
        guard let front = projected.max(), let rear = projected.min() else { return false }
        return front > -rear * 1.3
    }

    private func markerBackgroundGapColumns(in bitmap: NSBitmapImageRep, floor: NSColor, marks: PlanMarks) -> Int {
        guard let lastMarkerX = marks.marker.map({ $0.x }).max(), let firstLookX = marks.look.map({ $0.x }).min(),
              firstLookX > lastMarkerX else { return 0 }
        var consecutive = 0, longest = 0
        for x in (lastMarkerX + 1)..<firstLookX {
            let y = Int((marks.anchor.y + marks.direction.dy * (CGFloat(x) - marks.anchor.x) / marks.direction.dx).rounded())
            let background = components(in: bitmap, x: x, y: y).map { isFloor($0, floor: floor) } ?? false
            consecutive = background ? consecutive + 1 : 0
            longest = max(longest, consecutive)
        }
        return longest
    }

    private func simultaneousLookAndPathColumns(in bitmap: NSBitmapImageRep, marks: PlanMarks) -> Int {
        let pixelScale = max(1, bitmap.pixelsWide / 320)
        let normal = marks.normal
        func travel(from point: PixelPoint, sign: Int) -> Bool {
            (2 * pixelScale...4 * pixelScale).contains { offset in
                let x = Int((CGFloat(point.x) + CGFloat(sign * offset) * normal.dx).rounded())
                let y = Int((CGFloat(point.y) + CGFloat(sign * offset) * normal.dy).rounded())
                guard let color = components(in: bitmap, x: x, y: y) else { return false }
                return min(color.0, color.1, color.2) > 0.8
            }
        }
        let sharedColumns = Set(marks.look.filter { travel(from: $0, sign: -1) && travel(from: $0, sign: 1) }.map { $0.x })
        var consecutive = 0, longest = 0
        for x in sharedColumns.sorted() {
            consecutive = sharedColumns.contains(x - 1) ? consecutive + 1 : 1
            longest = max(longest, consecutive)
        }
        return longest
    }
}
