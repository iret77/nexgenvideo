import AVFoundation
import CoreGraphics
import BpyRuntimeProtocol
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Actual encoded blockout pixel orientation; requires CI")
struct NativeBlockoutOrientationTests {
    @Test func blenderPositiveAxesPassThroughTheCanonicalProjectionAndPointRightAndUpInDecodedPixels() async throws {
        let positions: [[Double]] = [[3, 0, 5], [-3, 0, 5], [0, 3, 5], [0, -3, 5], [0, 0, 8], [0, 0, 2]]
        let identity = [1.0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let object: [String: Any] = ["id": "mesh", "name": "Fixed geometry", "kind": "MESH", "matrixWorld": identity]
        let camera: [String: Any] = ["id": "camera", "name": "Camera", "kind": "CAMERA", "matrixWorld": identity]
        let snapshotBytes = try JSONSerialization.data(withJSONObject: ["schema": "nexgenvideo/bpy-spatial-snapshot/1",
            "units": "meters", "metersPerUnit": 0.5, "frame": 0, "restFrame": 0, "framesPerSecond": 24,
            "timebaseNumerator": 24, "timebaseDenominator": 1, "objects": [object, camera], "cameras": [], "meshes": [], "externalPaths": []])
        let snapshot = try JSONDecoder().decode(BpySpatialSnapshot.self, from: snapshotBytes)
        let state = SpatialClayState(sceneManifestSHA256: String(repeating: "a", count: 64), cameraID: "camera",
            frames: positions.enumerated().map { frame, position in
                var matrix = identity; matrix[3] = position[0]; matrix[7] = position[1]; matrix[11] = position[2]
                return .init(frame: frame, objects: [.init(objectID: "mesh", matrixWorld: identity), .init(objectID: "camera", matrixWorld: matrix)],
                    cameraVerticalFieldOfView: 1)
            })
        let geometry = SpatialEvaluatedGeometryV1(schema: "spatial-evaluated-geometry/v1", sceneManifestSHA256: state.sceneManifestSHA256,
            sceneSHA256: "", stateSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(state)), workerSHA256: "", scriptSHA256: "",
            runtimeLockSHA256: "", runtimeBinarySHA256: "", chunks: [], frames: state.frames.map {
                .init(frame: $0.frame, meshes: [.init(id: "mesh-instance", objectID: "mesh", minimum: [-5, -5, 0], maximum: [5, 5, 10])],
                    cameraMatrix: $0.objects[1].matrixWorld, metersPerUnit: 0.5, objects: $0.objects)
            }, snapshotSHA256: SpatialSceneStore.digest(snapshotBytes))
        let projection = try NativeBlockoutPlanProjection(snapshot: snapshot, snapshotData: snapshotBytes, state: state, geometry: geometry, locationID: "room")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orientation-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try NativeBlockoutExporter.export(width: 640, height: 480, frameCount: positions.count,
            presentation: { CMTime(value: Int64($0), timescale: 24) }, duration: CMTime(value: Int64(positions.count), timescale: 24),
            to: url, frame: projection.frame)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var markers: [[CGPoint]] = []
        for index in positions.indices {
            let image = try await generator.image(at: CMTime(value: Int64(index), timescale: 24)).image
            markers.append(try markerClusters(image))
        }
        try #require(markers.allSatisfy { $0.count == 2 })
        for index in 0..<2 { #expect(markers[0][index].x > markers[1][index].x + 20) }
        let plan = abs(markers[2][0].y - markers[3][0].y) > 10 ? 0 : 1
        let elevation = 1 - plan
        #expect(markers[2][plan].y < markers[3][plan].y - 10)
        #expect(abs(markers[2][elevation].y - markers[3][elevation].y) < 3)
        #expect(markers[4][elevation].y < markers[5][elevation].y - 10)
        #expect(abs(markers[4][plan].y - markers[5][plan].y) < 3)
    }

    private func markerClusters(_ image: CGImage) throws -> [CGPoint] {
        var pixels: [CGPoint] = []
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { continue }
                var bytes = [UInt8](repeating: 0, count: 4)
                try bytes.withUnsafeMutableBytes { memory in
                    guard let context = CGContext(data: memory.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                if Double(bytes[2]) > Double(bytes[0]) * 1.4, Double(bytes[1]) > Double(bytes[0]) * 1.2 {
                    pixels.append(CGPoint(x: x, y: y))
                }
            }
        }
        var groups: [[CGPoint]] = []
        for pixel in pixels.sorted(by: { $0.y < $1.y }) {
            if let last = groups.last?.last, pixel.y - last.y <= 20 { groups[groups.count - 1].append(pixel) }
            else { groups.append([pixel]) }
        }
        try #require(groups.count == 2 && groups.allSatisfy { $0.count > 5 })
        return groups.map { group in
            CGPoint(x: group.reduce(0) { $0 + $1.x } / CGFloat(group.count), y: group.reduce(0) { $0 + $1.y } / CGFloat(group.count))
        }
    }
}
