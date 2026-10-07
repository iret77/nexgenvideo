import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NexGenVideo

@Suite("inspect_media coordinate grid")
struct InspectFrameGridTests {
    @Test func overlayIsASeparateSameSizeImageWithTopLeftCoordinates() throws {
        let source = solidImage(width: 200, height: 100)
        let sourcePixels = NSBitmapImageRep(cgImage: source)
        let overlaid = InspectFrameGrid.apply(to: source)
        let overlayPixels = NSBitmapImageRep(cgImage: overlaid)

        #expect(overlaid.width == source.width)
        #expect(overlaid.height == source.height)
        #expect(luma(sourcePixels, x: 100, y: 50) < 0.05)
        #expect(luma(overlayPixels, x: 100, y: 50) > 1.5)
        #expect(luma(sourcePixels, x: 100, y: 50) < 0.05, "the source image remains unchanged")

        #expect(InspectFrameGrid.metadata["space"] as? String == Crop.coordinateSpace)
        #expect(InspectFrameGrid.metadata["origin"] as? String == "topLeft")
        #expect(InspectFrameGrid.drawingY(forTopOriginFraction: 0, height: 100) == 100)
        #expect(InspectFrameGrid.drawingY(forTopOriginFraction: 1, height: 100) == 0)
        #expect(InspectFrameGrid.labels == ["0", "0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.7", "0.8", "0.9", "1"])
        #expect(
            InspectFrameGrid.metadata["cropMapping"] as? String
                == "left=x0, top=y0, right=1-x1, bottom=1-y1"
        )
    }

    @Test @MainActor func toolGridIsOptInAndDoesNotRewriteTheAsset() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inspect-grid-\(UUID().uuidString).png")
        try writePNG(solidImage(width: 200, height: 100), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        let harness = ToolHarness()
        harness.editor.mediaAssets.append(MediaAsset(
            id: "grid-image",
            url: url,
            type: .image,
            name: "Grid image",
            duration: 0
        ))

        let plain = await harness.runRaw("inspect_media", args: ["mediaRef": "grid-image"])
        #expect(plain.isError == false, "\(ToolHarness.textOf(plain))")
        let plainMeta = try metadata(from: plain)
        #expect(plainMeta["coordinateGrid"] == nil)
        let plainImage = try imageData(from: plain)

        let gridded = await harness.runRaw("inspect_media", args: [
            "mediaRef": "grid-image",
            "coordinateGrid": true,
        ])
        #expect(gridded.isError == false, "\(ToolHarness.textOf(gridded))")
        let gridMeta = try metadata(from: gridded)
        let contract = try #require(gridMeta["coordinateGrid"] as? [String: Any])
        #expect(contract["space"] as? String == Crop.coordinateSpace)
        #expect(contract["origin"] as? String == "topLeft")
        #expect(try imageData(from: gridded) != plainImage)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test @MainActor func gridRejectsSurfacesWithoutOneSourceCoordinateSpace() async {
        let harness = ToolHarness()
        let missing = URL(fileURLWithPath: "/tmp/missing-audio.wav")
        harness.editor.mediaAssets.append(MediaAsset(
            id: "audio",
            url: missing,
            type: .audio,
            name: "Audio",
            duration: 1
        ))
        let audio = await harness.runRaw("inspect_media", args: [
            "mediaRef": "audio",
            "coordinateGrid": true,
        ])
        #expect(audio.isError)
        #expect(ToolHarness.textOf(audio).contains("requires image, video, or Lottie"))
    }

    @Test @MainActor func videoAndLottieFramesUseTheSameOptInGridContract() async throws {
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inspect-grid-video-\(UUID().uuidString).png")
        try writePNG(solidImage(width: 200, height: 100), to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let videoURL = try await ImageVideoGenerator.stillVideo(
            for: pngURL,
            mediaRef: "inspect-grid-\(UUID().uuidString)",
            size: CGSize(width: 200, height: 100)
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let lottieURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inspect-grid-\(UUID().uuidString).json")
        try Self.lottie.write(to: lottieURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: lottieURL) }

        let harness = ToolHarness()
        let video = MediaAsset(id: "video", url: videoURL, type: .video, name: "Video", duration: 1)
        video.hasAudio = false
        harness.editor.mediaAssets.append(video)
        harness.editor.mediaAssets.append(MediaAsset(
            id: "lottie",
            url: lottieURL,
            type: .lottie,
            name: "Lottie",
            duration: 1
        ))

        for mediaRef in ["video", "lottie"] {
            let result = await harness.runRaw("inspect_media", args: [
                "mediaRef": mediaRef,
                "coordinateGrid": true,
                "maxFrames": 1,
            ])
            #expect(result.isError == false, "\(mediaRef): \(ToolHarness.textOf(result))")
            let resultMetadata = try metadata(from: result)
            let contract = try #require(resultMetadata["coordinateGrid"] as? [String: Any])
            #expect(contract["space"] as? String == Crop.coordinateSpace)
            let frameData = try imageData(from: result)
            #expect(!frameData.isEmpty)
        }
    }

    private static let lottie = """
    {"v":"5.7.0","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"grid","ddd":0,"assets":[],"layers":[
    {"ddd":0,"ind":1,"ty":1,"nm":"red","sr":1,"sw":50,"sh":50,"sc":"#ff0000","ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[25,25,0]},"a":{"a":0,"k":[25,25,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,"ip":0,"op":30,"st":0,"bm":0}
    ]}
    """

    private func metadata(from result: ToolResult) throws -> [String: Any] {
        for block in result.content {
            guard case .text(let text) = block else { continue }
            return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        Issue.record("inspect_media returned no metadata")
        return [:]
    }

    private func imageData(from result: ToolResult) throws -> Data {
        for block in result.content {
            guard case .image(let base64, _) = block else { continue }
            return try #require(Data(base64Encoded: base64))
        }
        Issue.record("inspect_media returned no image")
        return Data()
    }

    private func solidImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func luma(_ pixels: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        guard let color = pixels.colorAt(x: x, y: y) else { return 0 }
        return color.redComponent + color.greenComponent + color.blueComponent
    }
}
