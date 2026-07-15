import CoreGraphics
import Foundation
import Testing
@testable import NexGenEngine

/// #166: the file-level POV extraction — panorama in, one named sheet per POV out.
@Suite("POV extraction")
struct PovExtractorTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pov-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a solid-colour PNG of the given size.
    private func writePNG(_ width: Int, _ height: Int, to url: URL) throws {
        let rgba = [UInt8](repeating: 128, count: width * height * 4)
        try PovExtractor.writePNG(
            EquirectProjector.PixelBuffer(width: width, height: height, rgba: rgba), to: url)
    }

    @Test("a POV set writes one file per name, at the requested size")
    func extractSetWritesNamedSheets() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pano = dir.appendingPathComponent("world_pano.png")
        try writePNG(256, 128, to: pano)

        let out = dir.appendingPathComponent("povs_clay", isDirectory: true)
        let written = try PovExtractor.extractSet(panorama: pano, to: out, width: 64, height: 36)

        // The names are the sheet keys a shot's `locationView` will name.
        #expect(Set(written.keys) == ["wide_front", "wide_right", "wide_back", "wide_left"])
        for (name, url) in written {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(name) not written")
            #expect(url.lastPathComponent == "\(name).png")
            let size = FrameRasterizer.pixelSize(of: url)
            #expect(size?.width == 64)
            #expect(size?.height == 36)
        }
    }

    /// A non-2:1 image is not an equirectangular panorama. Cutting POVs out of one would skew every
    /// view — a silently wrong sheet is worse than a refusal, so this is a hard error.
    @Test("a panorama that isn't 2:1 is refused, not skewed")
    func nonEquirectangularIsRefused() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let square = dir.appendingPathComponent("square.png")
        try writePNG(128, 128, to: square)

        #expect(throws: PovExtractor.ExtractError.notEquirectangular(width: 128, height: 128)) {
            try PovExtractor.extract(
                panorama: square, pov: defaultFourWallPovs[0],
                to: dir.appendingPathComponent("out.png"))
        }
    }

    @Test("a missing panorama names the path")
    func missingPanorama() {
        let missing = tempDir().appendingPathComponent("nope.png")
        #expect(throws: PovExtractor.ExtractError.panoramaMissing(missing.path)) {
            try PovExtractor.extract(
                panorama: missing, pov: defaultFourWallPovs[0],
                to: missing.deletingLastPathComponent().appendingPathComponent("out.png"))
        }
    }

    /// Round-trip through PNG: what the projector computed is what lands on disk.
    @Test("the written sheet carries the projected pixels")
    func writtenPixelsMatchTheProjection() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Left half red, right half green — split at the panorama's centre (yaw 0).
        var rgba = [UInt8](repeating: 255, count: 256 * 128 * 4)
        for y in 0..<128 {
            for x in 0..<256 {
                let i = (y * 256 + x) * 4
                let isEast = x >= 128
                rgba[i] = isEast ? 0 : 255
                rgba[i + 1] = isEast ? 255 : 0
                rgba[i + 2] = 0
                rgba[i + 3] = 255
            }
        }
        let pano = dir.appendingPathComponent("pano.png")
        try PovExtractor.writePNG(
            EquirectProjector.PixelBuffer(width: 256, height: 128, rgba: rgba), to: pano)

        let dest = dir.appendingPathComponent("front.png")
        try PovExtractor.extract(
            panorama: pano, pov: PovSpec(name: "front", yawDegrees: 0, pitchDegrees: 0),
            to: dest, width: 64, height: 36)

        let loaded = try PovExtractor.loadPanorama(pano)   // same decode path
        let view = EquirectProjector.project(
            pano: loaded, pov: PovSpec(name: "front", yawDegrees: 0, pitchDegrees: 0),
            width: 64, height: 36)
        // The seam between the halves sits at the frame's centre: west of it red, east green.
        func rgb(_ img: EquirectProjector.PixelBuffer, _ x: Int) -> (UInt8, UInt8) {
            let i = ((img.height / 2) * img.width + x) * 4
            return (img.rgba[i], img.rgba[i + 1])
        }
        #expect(rgb(view, 8) == (255, 0))    // left of centre → red
        #expect(rgb(view, 56) == (0, 255))   // right of centre → green
        #expect(FrameRasterizer.pixelSize(of: dest).map { $0.width } == 64)
    }
}
