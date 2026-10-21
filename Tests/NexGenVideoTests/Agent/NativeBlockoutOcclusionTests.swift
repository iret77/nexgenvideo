import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Encoded blockout travel under the Look; requires CI")
struct NativeBlockoutOcclusionTests {
    @Test(arguments: [false, true])
    func nearCollinearTravelAndItsNaturalTerminalDashRemainVisible(terminal: Bool) async throws {
        for width in [320, 1280] {
            let height = width * 9 / 16
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("occluded-path-\(UUID()).mov")
            defer { try? FileManager.default.removeItem(at: output) }
            let position = SpatialVector3V1(x: -2, y: 1.5, z: 0)
            let look = SpatialVector3V1(x: 3, y: 1.55, z: 0)
            let points = [position, SpatialVector3V1(x: terminal ? -0.9 : -0.8, y: 1.52, z: 0),
                SpatialVector3V1(x: terminal ? -0.75 : 0, y: 1.53, z: 0)]
            let plan = NativeBlockoutExporter.PlanFrame(cameras: [.init(id: "camera", locationID: "room",
                position: position, path: points.enumerated().map {
                    .init(timeSeconds: Double($0.offset) / Double(points.count - 1), position: $0.element, lookAt: look)
                })], layouts: [.init(locationID: "room", widthMeters: 8, depthMeters: 6, heightMeters: 4,
                    setupIDs: ["camera"])], shapes: [], metric: true, arrangement: .bestFit)
            try NativeBlockoutExporter.export(width: width, height: height, frameCount: 4,
                presentation: { CMTime(value: Int64($0), timescale: 4) }, duration: CMTime(value: 1, timescale: 1),
                to: output, frame: { _ in plan })
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: .zero).image
            if let path = ProcessInfo.processInfo.environment["NGV_BLOCKOUT_ORIENTATION_EVIDENCE_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = "occluded-path-\(terminal ? "terminal" : "bent")-\(width)"
                try FileManager.default.copyItem(at: output, to: directory.appendingPathComponent(name + ".mov"))
                let destination = try #require(CGImageDestinationCreateWithURL(directory.appendingPathComponent(name + ".png") as CFURL,
                    UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                try #require(CGImageDestinationFinalize(destination))
            }
            let bitmap = NSBitmapImageRep(cgImage: image), scale = width / 320
            var whitePixels = 0
            // This interior Elevation region precedes the Look target and excludes titles and room edges.
            for y in (104 * scale)..<(130 * scale) {
                for x in (218 * scale)..<(244 * scale) {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8 { whitePixels += 1 }
                }
            }
            #expect(whitePixels >= 3 * scale * scale, "The true Travel dash must remain visible where the longer Look covers its thin stroke.")
        }
    }
}
