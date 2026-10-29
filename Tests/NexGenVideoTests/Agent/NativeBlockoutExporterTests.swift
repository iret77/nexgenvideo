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
        let pixel = try #require(bitmap.colorAt(x: image.width * 3 / 4, y: image.height * 3 / 4))
        #expect(pixel.brightnessComponent > 0.4)
        #expect(simultaneousLookAndPathColumns(in: bitmap) >= 3 * max(1, width / 320))
    }

    private func simultaneousLookAndPathColumns(in bitmap: NSBitmapImageRep) -> Int {
        func components(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat)? {
            guard y >= 0, y < bitmap.pixelsHigh,
                  let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        func travel(_ x: Int, _ y: Int) -> Bool {
            guard let (red, green, blue) = components(x, y) else { return false }
            return min(red, green, blue) > 0.8
        }
        let pixelScale = max(1, bitmap.pixelsWide / 320)
        var consecutive = 0, longest = 0
        for x in (bitmap.pixelsWide / 3)..<(bitmap.pixelsWide / 2) {
            let shared = ((bitmap.pixelsHigh / 2)..<bitmap.pixelsHigh).contains { y in
                guard let (red, green, blue) = components(x, y),
                      blue - red > 0.1, green - red > 0.07 else { return false }
                return (2 * pixelScale...4 * pixelScale).contains { travel(x, y - $0) }
                    && (2 * pixelScale...4 * pixelScale).contains { travel(x, y + $0) }
            }
            consecutive = shared ? consecutive + 1 : 0
            longest = max(longest, consecutive)
        }
        return longest
    }
}
