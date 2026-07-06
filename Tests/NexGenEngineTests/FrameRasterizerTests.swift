import CoreGraphics
import Foundation
import Testing
@testable import NexGenEngine

@Suite("FrameRasterizer")
struct FrameRasterizerTests {
    /// A solid-color 64x36 in-memory CGImage — enough to exercise crop + PNG
    /// encode without depending on a bundled fixture image.
    static func solidColorImage(width: Int = 64, height: Int = 36) throws -> CGImage {
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(ctx.makeImage())
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexgen-frame-rasterizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("crops a solid-color master and writes a PNG with the planned dimensions")
    func generateCropWritesPNGWithPlannedDimensions() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let master = dir.appendingPathComponent("master.png")
        try FrameRasterizer.savePNG(Self.solidColorImage(), to: master)

        let dest = dir.appendingPathComponent("out/crop.png")
        let plan = try FrameRasterizer.generateCrop(masterPath: master, dest: dest, targetAspect: "16:9")

        #expect(FileManager.default.fileExists(atPath: dest.path))
        let output = try FrameRasterizer.loadImage(at: dest)
        #expect(output.width == plan.targetSize.width)
        #expect(output.height == plan.targetSize.height)
        // 64x36 is already 16:9 — full take, no scaling.
        #expect(plan.targetSize == (64, 36))
    }

    @Test("generates a pan pair with both crops present at the planned size")
    func generatePanPairWritesBothPNGs() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let master = dir.appendingPathComponent("master.png")
        try FrameRasterizer.savePNG(Self.solidColorImage(width: 128, height: 36), to: master)

        let startDest = dir.appendingPathComponent("start.png")
        let endDest = dir.appendingPathComponent("end.png")
        let plan = try FrameRasterizer.generatePanPair(
            masterPath: master, startDest: startDest, endDest: endDest, targetAspect: "16:9",
            direction: .right, travelPct: 100.0
        )

        #expect(FileManager.default.fileExists(atPath: startDest.path))
        #expect(FileManager.default.fileExists(atPath: endDest.path))
        let start = try FrameRasterizer.loadImage(at: startDest)
        let end = try FrameRasterizer.loadImage(at: endDest)
        #expect(start.width == plan.targetSize.width && start.height == plan.targetSize.height)
        #expect(end.width == plan.targetSize.width && end.height == plan.targetSize.height)
    }

    @Test("missing master file raises masterNotFound")
    func generateCropMissingMasterThrows() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.png")
        let dest = dir.appendingPathComponent("out.png")
        #expect(throws: FrameRasterizerError.self) {
            try FrameRasterizer.generateCrop(masterPath: missing, dest: dest, targetAspect: "16:9")
        }
    }
}
