import AppKit
import AVFoundation
import CoreText
import ImageIO
import UniformTypeIdentifiers
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Encoded compact blockout legend cases; requires CI")
struct NativeBlockoutLegendTests {
    @Test func directionLegendsIncludeSmallPathsAndKeepTheMixedQualifierAtTheMiddlePose() async throws {
        let evidence = ProcessInfo.processInfo.environment["NGV_BLOCKOUT_ORIENTATION_EVIDENCE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let evidence { try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true) }
        for mixed in [false, true] {
            let small = [SpatialVector3V1(x: -2, y: 3, z: 2), .init(x: -1.75, y: 3, z: 2)]
            let crossing = [SpatialVector3V1(x: -0.95, y: 1.5, z: -1), .init(x: 0, y: 1.5, z: -1),
                .init(x: 0.95, y: 1.5, z: -1)]
            let paths = mixed ? [small, crossing] : [small]
            let cameras = paths.enumerated().map { index, points in
                NativeBlockoutExporter.CameraProjection(id: "camera-\(index)", locationID: "room", position: points[0],
                    path: points.enumerated().map { pointIndex, point in
                        .init(timeSeconds: Double(pointIndex) / Double(points.count - 1), position: point,
                            lookAt: .init(x: point.x, y: point.y + 0.25, z: point.z))
                    })
            }
            let plan = NativeBlockoutExporter.PlanFrame(cameras: cameras,
                layouts: [.init(locationID: "room", widthMeters: 8, depthMeters: 6, heightMeters: 4,
                    setupIDs: cameras.map(\.id))], shapes: [], metric: true, arrangement: .bestFit)
            let name = mixed ? "legend-mixed-direction-320" : "legend-small-direction-320"
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID()).mov")
            defer { try? FileManager.default.removeItem(at: output) }
            let count = mixed ? 3 : 1
            try NativeBlockoutExporter.export(width: 320, height: 180, frameCount: count,
                presentation: { CMTime(value: Int64($0), timescale: 4) }, duration: CMTime(value: Int64(count), timescale: 4),
                to: output, frame: { _ in plan })
            if let evidence { try FileManager.default.copyItem(at: output, to: evidence.appendingPathComponent(name + ".mov")) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            for index in 0..<(mixed ? 2 : 1) {
                let image = try await generator.image(at: CMTime(value: Int64(index), timescale: 4)).image
                #expect(image.width == 320 && image.height == 180)
                if let evidence {
                    let suffix = mixed ? (index == 0 ? "-start" : "-midpoint") : ""
                    let destination = try #require(CGImageDestinationCreateWithURL(
                        evidence.appendingPathComponent(name + suffix + ".png") as CFURL,
                        UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    try #require(CGImageDestinationFinalize(destination))
                }
            }
        }
        let font = NSFont.systemFont(ofSize: 11, weight: AppTheme.AppKitFontWeight.semibold) as CTFont
        let labels = ["Plan (X/Z) · No direction", "Elev. (X/Y) · Direction",
            "Path (small)", "Path (incl. small)"]
        for text in labels {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            print("BLOCKOUT_LEGEND_FONT_BUDGET \(text): width=\(width), available=148, font=11")
            #expect(width <= 148, "The complete compact words and axes must fit the 320px pane at 11pt.")
        }
    }
}
