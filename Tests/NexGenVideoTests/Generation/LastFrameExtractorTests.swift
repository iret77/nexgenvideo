import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NexGenVideo

/// Last-frame extraction for chain-with-previous-end continuity (#196). Port of
/// `render/last_frame.py::extract_last_frame` via AVFoundation.
@Suite("last-frame extraction (#196)")
struct LastFrameExtractorTests {
    @Test("extracts the final frame — the last scene's color, not the first")
    func extractsLastScene() async throws {
        // Red then blue; the extracted last frame must be blue-dominant.
        let video = try await FixtureVideo.write(scenes: [
            .init(rgb: (220, 20, 20), seconds: 0.6),
            .init(rgb: (20, 20, 220), seconds: 0.6),
        ])
        defer { try? FileManager.default.removeItem(at: video) }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("lastframe-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: dest) }

        try await LastFrameExtractor.extractLastFrame(video: video, dest: dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))

        let (r, g, b) = try Self.averageColor(dest)
        #expect(b > r)
        #expect(b > g)
    }

    @Test("a missing input video throws")
    func missingThrows() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).mp4")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("x-\(UUID().uuidString).png")
        await #expect(throws: LastFrameExtractor.ExtractError.self) {
            try await LastFrameExtractor.extractLastFrame(video: missing, dest: dest)
        }
    }

    /// Average color of a PNG (whole image scaled to 1×1). For a solid-color frame this is that color.
    static func averageColor(_ url: URL) throws -> (UInt8, UInt8, UInt8) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "LastFrameExtractorTests", code: 1)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "LastFrameExtractorTests", code: 2)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }
}
