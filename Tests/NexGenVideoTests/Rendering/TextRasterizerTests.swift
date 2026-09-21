import AppKit
import AVFoundation
import CoreImage
import QuartzCore
import Testing
@testable import NexGenVideo

@Suite("Text rasterizer — bounded tiles and style equivalence")
@MainActor
struct TextRasterizerTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func clip() -> Clip {
        var clip = Fixtures.clip(id: "text", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        clip.textContent = ""
        var style = TextStyle()
        style.fontName = "bounded-\(UUID().uuidString)"
        style.background = TextStyle.Fill(enabled: true, color: TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1))
        style.shadow.enabled = false
        clip.textStyle = style
        return clip
    }

    private func pixels(_ image: CIImage, bounds: CGRect) -> [Float] {
        var result = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        context.render(image, toBitmap: &result, rowBytes: Int(bounds.width) * 16,
                       bounds: bounds, format: .RGBAf, colorSpace: nil)
        return result
    }

    @Test(arguments: [CGSize(width: 320, height: 180), CGSize(width: 4096, height: 2160)])
    func oversizedBoxesAndLargeCanvasesOnlyRasterizeRequestedTiles(canvas: CGSize) throws {
        var text = clip()
        text.transform = Transform(centerX: 0.5, centerY: 0.5, width: 100, height: 100)
        var budget = TextRasterizer.preparationBudget
        let plan = try #require(TextRasterizer.prepare(for: text, renderSize: canvas, budget: &budget))
        let source = try #require(plan.textSource)
        #expect(plan.stillImage == nil)
        #expect(budget == TextRasterizer.preparationBudget)
        #expect(source.rasterizedTileCount == 0)
        let image = try #require(source.image())
        let requested = CGRect(x: plan.natSize.width / 2, y: plan.natSize.height / 2, width: 64, height: 64)
        let visible = image.cropped(to: requested)
        #expect(visible.extent == requested)
        let actual = pixels(visible, bounds: requested)
        for index in stride(from: 0, to: actual.count, by: 4) {
            #expect(actual[index + 1] > 0.99 && actual[index + 3] > 0.99)
        }
        #expect(source.rasterizedTileCount > 0 && source.rasterizedTileCount <= 4)
        #expect(source.maximumRasterizedTileBytes <= TextRasterizer.maximumRasterBytes)
    }

    @Test func oversizedAnimatedTextIsNotCroppedToItsInitialPlacement() async throws {
        var text = clip()
        text.transform = Transform(centerX: 0.5, centerY: 0.5, width: 100, height: 100)
        text.positionTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: -101, b: -101), interpolationOut: .linear),
            Keyframe(frame: 30, value: AnimPair(a: -49.5, b: -49.5), interpolationOut: .linear),
        ])
        text.rotationTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .linear),
            Keyframe(frame: 30, value: 30.0, interpolationOut: .linear),
        ])
        let timeline = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [text])])
        let before = try await CompositorRenderTests.render(timeline, frame: 0)
        let after = try await CompositorRenderTests.render(timeline, frame: 30)
        #expect(before.center.g < 10)
        #expect(after.center.g > 245 && after.center.r < 10 && after.center.b < 10)
    }

    @Test(arguments: 0..<4)
    func tiledDrawingMatchesLayerReferenceForTypographyAndDecoration(variant: Int) throws {
        let canvas = CGSize(width: 1920, height: 1080)
        var text = clip()
        text.transform = Transform(topLeft: (0, 0), width: 1.0 / 6, height: 1.0 / 6)
        text.textContent = "Fg pq\nAsymmetric text"
        text.textStyle?.fontName = "Helvetica-Bold"
        text.textStyle?.fontSize = 38
        text.textStyle?.fontScale = 1.15
        text.textStyle?.color = TextStyle.RGBA(r: 0.8, g: 0.2, b: 0.1, a: 0.8)
        text.textStyle?.alignment = [.left, .center, .right, .left][variant]
        text.textStyle?.background.enabled = variant % 2 == 1
        text.textStyle?.background.color.a = 0.5
        text.textStyle?.border = TextStyle.Fill(enabled: variant > 0, color: TextStyle.RGBA(r: 0, g: 0, b: 1, a: 1))
        text.textStyle?.shadow = TextStyle.Shadow(enabled: variant > 1,
            color: TextStyle.RGBA(r: 0.2, g: 0, b: 0.7, a: 0.6), offsetX: 5, offsetY: 12,
            blur: variant == 3 ? 4 : 0)
        var budget = 0
        let plan = try #require(TextRasterizer.prepare(for: text, renderSize: canvas, budget: &budget))
        let image = try #require(plan.textSource?.image())
        let bounds = CGRect(x: -32, y: -32, width: 384, height: 244)
        let reference = try layerReference(text, canvas: canvas, bounds: bounds)
        let actual = pixels(image, bounds: bounds)
        let expected = pixels(reference, bounds: bounds)
        let errors = zip(actual, expected).map { abs($0 - $1) }
        #expect((errors.max() ?? 0) < 0.08)
        #expect(errors.reduce(0, +) / Float(errors.count) < 0.005)
    }

    private func layerReference(_ text: Clip, canvas: CGSize, bounds: CGRect) throws -> CIImage {
        let bitmap = try #require(CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
            bitsPerComponent: 8, bytesPerRow: Int(bounds.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let layer = TextLayerStyle.makeLayer(clip: text, containerSize: canvas)
        layer.frame.origin = CGPoint(x: -bounds.minX, y: -bounds.minY)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: bounds.size)
        root.isGeometryFlipped = true
        root.addSublayer(layer)
        layer.displayIfNeeded()
        bitmap.translateBy(x: 0, y: bounds.height)
        bitmap.scaleBy(x: 1, y: -1)
        root.render(in: bitmap)
        return CIImage(cgImage: try #require(bitmap.makeImage()), options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    @Test func glyphsAcrossTileSeamsMatchLayerReference() throws {
        let canvas = CGSize(width: 1536, height: 1152)
        var text = clip()
        text.textContent = String(repeating: "Fg asymmetric text near a tile seam\n", count: 16)
        text.textStyle?.fontSize = 80
        text.textStyle?.alignment = .left
        text.textStyle?.color = TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1)
        var budget = 0
        let plan = try #require(TextRasterizer.prepare(for: text, renderSize: canvas, budget: &budget))
        let source = try #require(plan.textSource)
        let image = try #require(source.image())
        let reference = try layerReference(text, canvas: canvas,
            bounds: CGRect(x: -32, y: -32, width: canvas.width + 64, height: canvas.height + 64))
        let seam = CGRect(x: 1000, y: canvas.height - 1048, width: 48, height: 48)
        let actual = pixels(image, bounds: seam)
        let expected = pixels(reference, bounds: seam)
        #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.03 })
        #expect(source.rasterizedTileCount >= 4)
        #expect(source.maximumRasterizedTileBytes <= TextRasterizer.maximumRasterBytes)
    }
}
