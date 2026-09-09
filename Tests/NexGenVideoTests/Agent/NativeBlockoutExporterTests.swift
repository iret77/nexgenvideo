import AppKit
import AVFoundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Native blockout exporter")
struct NativeBlockoutExporterTests {
    @Test("exports metric shapes and a camera path as playable video")
    func exportsPlayableGraybox() async throws {
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
        NativeBlockoutExporter.export(
            setups: [setup],
            layouts: [layout],
            shapes: [shape],
            request: BlockoutRequestV1(
                mode: .native,
                width: 320,
                height: 180,
                fps: 4,
                durationSeconds: 1
            ),
            to: output
        )

        let asset = AVURLAsset(url: output)
        let track = try #require(
            try await asset.loadTracks(withMediaType: .video).first
        )
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
        #expect(try await asset.load(.duration).seconds >= 0.75)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: .zero).image
        let bitmap = NSBitmapImageRep(cgImage: image)
        let pixel = try #require(bitmap.colorAt(x: image.width / 2, y: image.height / 3))
        #expect(pixel.brightnessComponent > 0.4)
    }
}
