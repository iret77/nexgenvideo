import AVFoundation
import AppKit
import CoreImage
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NexGenVideo

@Suite("Blend modes — shared rendering pipeline")
@MainActor
struct ClipBlendPipelineTests {
    private let size = CompositorFixtures.renderSize

    @Test(arguments: [ClipType.image, .video])
    func mediaBlendAndKeyedMatteUseSameLayerStage(type: ClipType) async throws {
        let png = try CompositorFixtures.patternPNG(size: size)
        let url: URL
        if type == .image { url = png } else { url = try await CompositorFixtures.patternVideoURL() }
        var upper = Fixtures.clip(id: "upper", mediaRef: "upper", mediaType: type, start: 0, duration: 30)
        upper.transform.flipHorizontal = true
        upper.blendMode = .screen
        upper.opacity = 0.5
        let lower = CompositorFixtures.patternClip(id: "lower", duration: 30)
        func timeline(_ upper: Clip) -> Timeline {
            CompositorFixtures.timeline([Fixtures.videoTrack(clips: [upper]), Fixtures.videoTrack(clips: [lower])])
        }
        let blended = try await CompositorRenderTests.render(timeline(upper), frame: 10, imageURLs: ["upper": url])
        #expect(blended.tl.r > 220 && (90...165).contains(blended.tl.g) && blended.tl.b < 35)
        upper.effects = [Effect.make("key.chroma", ["keyHue": 0.333, "tolerance": 0.5, "spill": 0])]
        let keyed = try await CompositorRenderTests.render(timeline(upper), frame: 10, imageURLs: ["upper": url])
        #expect(keyed.tl.r > 220 && keyed.tl.g < 35 && keyed.tl.b < 35)
        upper.effects = nil
        upper.opacity = 1
        upper.compositing = ClipCompositingV1(version: 99, blendMode: "screen")
        let fallback = try await CompositorRenderTests.render(timeline(upper), frame: 10, imageURLs: ["upper": url])
        #expect(fallback.tl.g > 220 && fallback.tl.r < 35 && fallback.tl.b < 35)
    }

    private func textClip() -> Clip {
        var clip = Fixtures.clip(id: "text", mediaRef: "", mediaType: .text, start: 0, duration: 30)
        clip.textContent = ""
        var style = TextStyle()
        style.shadow.enabled = false
        style.background = TextStyle.Fill(enabled: true, color: TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1))
        clip.textStyle = style
        clip.transform = Transform(centerX: 0.25, centerY: 0.25, width: 0.5, height: 0.5)
        clip.blendMode = .screen
        return clip
    }

    @Test(arguments: [ClipType.image, .video])
    func semitransparentMediaMultipliesSourceAlphaAndClipOpacity(type: ClipType) async throws {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("blend-alpha-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let context = try #require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 90, width: 160, height: 90))
        let destination = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        let url: URL
        if type == .image { url = png }
        else { url = try await ImageVideoGenerator.stillVideo(for: png, mediaRef: png.lastPathComponent, size: size) }
        var upper = Fixtures.clip(id: "alpha", mediaRef: "alpha", mediaType: type, start: 0, duration: 30)
        upper.blendMode = .screen
        upper.opacity = 0.5
        let timeline = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [upper]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(duration: 30)])])
        let frame = try await CompositorRenderTests.render(timeline, frame: 10, imageURLs: ["alpha": url])
        #expect(frame.tl.r > 220 && (40...90).contains(frame.tl.g) && frame.tl.b < 30)
        #expect(frame.bl.b > 220 && frame.bl.r < 30 && frame.bl.g < 30)
    }

    @Test func semitransparentTextFillUsesSourceAlpha() async throws {
        var text = textClip()
        text.textStyle?.background.color.a = 0.5
        text.opacity = 0.5
        let timeline = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [text]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(duration: 30)])])
        let frame = try await CompositorRenderTests.render(timeline, frame: 10)
        #expect(frame.tl.r > 220 && (40...90).contains(frame.tl.g) && frame.tl.b < 30)
    }

    @Test func textBlendUsesTrackOrderCropFadeAndKeyframes() async throws {
        var text = textClip()
        text.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: 0.0), Keyframe(frame: 20, value: 1.0)])
        text.fadeOutFrames = 10
        text.crop.right = 0.5
        let lower = CompositorFixtures.patternClip(duration: 30)
        let timeline = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [text]), Fixtures.videoTrack(clips: [lower])])
        let first = try await CompositorRenderTests.render(timeline, frame: 0)
        let middle = try await CompositorRenderTests.render(timeline, frame: 10)
        let end = try await CompositorRenderTests.render(timeline, frame: 25)
        #expect(first.at(40, 45).g < 30)
        #expect((90...165).contains(middle.at(40, 45).g))
        #expect((90...165).contains(end.at(40, 45).g))
        #expect(middle.at(120, 45).g < 30)
        #expect(middle.at(40, 135).b > 220)
        let reversed = CompositorFixtures.timeline(Array(timeline.tracks.reversed()))
        let covered = try await CompositorRenderTests.render(reversed, frame: 10)
        #expect(covered.at(40, 45).g < 30)
    }

    @Test func textOnlyTimelineRendersGlyphsAndBackgroundThroughCompositor() async throws {
        var text = textClip()
        text.transform = Transform()
        text.textContent = "MMMM"
        text.textStyle?.fontSize = 200
        text.textStyle?.color = TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1)
        text.textStyle?.alignment = .left
        text.blendMode = .normal
        let frame = try await CompositorRenderTests.render(CompositorFixtures.timeline([Fixtures.videoTrack(clips: [text])]), frame: 0)
        var red = 0
        for i in stride(from: 0, to: frame.bytes.count, by: 4) {
            if frame.bytes[i] > 180 && frame.bytes[i + 1] < 80 { red += 1 }
        }
        #expect(red > 100)
        #expect(frame.br.g > 220)
    }

    @Test func previewFinalAndExportHaveMatchingTextBlendPixels() async throws {
        let source = try await CompositorFixtures.patternVideoURL()
        let lower = CompositorFixtures.patternClip(duration: 30)
        let timeline = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [textClip()]), Fixtures.videoTrack(clips: [lower])])
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "pattern", name: "Pattern", type: .video,
            source: .external(absolutePath: source.path), duration: 1)]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        let preview = try await CompositorRenderTests.render(timeline, frame: 10)
        let finalURL = try await TimelineRenderer.render(timeline: timeline, resolver: resolver, startFrame: 0,
            frameCount: 30, includeAudio: false, preset: AVAssetExportPresetHighestQuality)
        defer { try? FileManager.default.removeItem(at: finalURL) }
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("blend-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        let service = ExportService()
        await service.export(timeline: timeline, resolver: resolver, format: .h264, resolution: .r720p, outputURL: exportURL)
        try #require(service.error == nil, "\(service.error ?? "")")
        for url in [finalURL, exportURL] {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = size
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try await generator.image(at: CMTime(value: 10, timescale: 30)).image
            let rendered = CompositorRenderTests.Frame(bytes: ColorProbeHelpers.srgbBytes(cg, size: size), w: Int(size.width))
            #expect(rendered.tl.r > 215 && rendered.tl.g > 215 && rendered.tl.b < 40)
            #expect(abs(rendered.tl.r - preview.tl.r) < 30)
            #expect(abs(rendered.tl.g - preview.tl.g) < 30)
            #expect(rendered.bl.b > 215 && rendered.bl.r < 40 && rendered.bl.g < 40)
        }
    }
}
