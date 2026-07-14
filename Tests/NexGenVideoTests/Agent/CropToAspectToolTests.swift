import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NexGenVideo
import NexGenEngine

/// #199: the crop_to_aspect tool — the deterministic render-larger-then-crop invocation surface for
/// the ported CropPlanner/FrameRasterizer (previously test-only).
@MainActor
@Suite("crop_to_aspect tool")
struct CropToAspectToolTests {
    private func scaffold() throws -> (ToolHarness, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crop-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        return (ToolHarness(), dataRoot, tmp)
    }

    private func writePNG(_ w: Int, _ h: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test("crops a 2000x1000 master to 16:9 with exact centered geometry")
    func crop16x9() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = FrameInventory.projectHome(of: dataRoot)
        let master = home.appendingPathComponent("media/master.png")
        try writePNG(2000, 1000, to: master)

        let res = try await h.runOK("crop_to_aspect", args: [
            "project_dir": dataRoot.path, "aspect": "16:9", "path": master.path,
        ]) as? [String: Any]

        // 2000x1000 (aspect 2.0) wider than 16:9 → full height 1000, width = round(1000*16/9)=1778, centered.
        let size = try #require(res?["target_size"] as? [String: Any])
        #expect(size["width"] as? Int == 1778)
        #expect(size["height"] as? Int == 1000)
        let box = try #require(res?["box"] as? [String: Any])
        #expect(box["left"] as? Int == 111)
        #expect(box["right"] as? Int == 1889)
        // The cropped file was written into the media library and its pixels match the plan.
        let outRel = try #require(res?["output"] as? String)
        let outURL = home.appendingPathComponent(outRel)
        #expect(FileManager.default.fileExists(atPath: outURL.path))
        #expect(FrameRasterizer.pixelSize(of: outURL).map { $0.width } == 1778)
    }

    @Test("an unknown source errors, not crashes")
    func missingSource() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let raw = await h.runRaw("crop_to_aspect", args: ["project_dir": dataRoot.path, "aspect": "16:9"])
        #expect(raw.isError)
    }
}
