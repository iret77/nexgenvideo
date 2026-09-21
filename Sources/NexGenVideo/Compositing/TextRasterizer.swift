import AppKit
import AVFoundation
import CoreImage
import QuartzCore

enum TextRasterizer {
    fileprivate struct CacheKey: Encodable, Sendable {
        let content: String
        let style: TextStyle
        let width: Double
        let height: Double
        let canvasHeight: Double
    }

    // NSCache synchronizes access; cached CIImages are immutable.
    private final class RasterCache: @unchecked Sendable {
        let images = NSCache<NSData, CIImage>()
        init() { images.totalCostLimit = 64 * 1024 * 1024 }
    }
    private static let cache = RasterCache()
    static let preparationBudget = 64 * 1024 * 1024

    struct Source: Sendable {
        fileprivate let key: CacheKey
        fileprivate let keyData: Data
        fileprivate let renderSize: CGSize
        fileprivate let padding: CGFloat
        fileprivate let rasterSize: CGSize
        fileprivate let byteCost: Int

        func image() -> CIImage? {
            if let image = TextRasterizer.cache.images.object(forKey: keyData as NSData) { return image }
            return TextRasterizer.rasterize(self)
        }
    }

    static func naturalSize(for clip: Clip, renderSize: CGSize) -> CGSize {
        CGSize(width: max(1, ceil(clip.transform.width * renderSize.width)),
               height: max(1, ceil(clip.transform.height * renderSize.height)))
    }

    static func prepare(for clip: Clip, renderSize: CGSize, budget: inout Int) -> LayerPlan? {
        let size = naturalSize(for: clip, renderSize: renderSize)
        let width = size.width, height = size.height
        guard width.isFinite, height.isFinite, width <= 16384, height <= 16384 else { return nil }
        let key = CacheKey(content: clip.textContent ?? "", style: clip.textStyle ?? TextStyle(),
                           width: width, height: height, canvasHeight: renderSize.height)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let keyData = try? encoder.encode(key) else { return nil }
        let shadow = (clip.textStyle ?? TextStyle()).shadow
        let scale = renderSize.height / 1080
        let padding = shadow.enabled
            ? ceil((max(abs(shadow.offsetX), abs(shadow.offsetY)) + max(0, shadow.blur) * 3) * scale) : 0
        guard padding.isFinite, padding >= 0, padding <= 4096 else { return nil }
        let rasterSize = CGSize(width: width + 2 * padding, height: height + 2 * padding)
        let source = Source(key: key, keyData: keyData, renderSize: renderSize, padding: padding,
                            rasterSize: rasterSize, byteCost: Int(rasterSize.width) * Int(rasterSize.height) * 4)
        var plan = LayerPlan(trackID: kCMPersistentTrackID_Invalid, clip: clip, natSize: size,
                             preferredTransform: .identity, textSource: source)
        // Strong instruction images share a bounded budget; long caption timelines remain cache-backed.
        if source.byteCost <= budget, let image = source.image() {
            plan.stillImage = image
            budget -= source.byteCost
        }
        return plan
    }

    private static func rasterize(_ source: Source) -> CIImage? {
        let rasterSize = source.rasterSize
        guard let context = CGContext(
            data: nil, width: Int(rasterSize.width), height: Int(rasterSize.height),
            bitsPerComponent: 8, bytesPerRow: Int(rasterSize.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        var rasterClip = Clip(mediaRef: "", mediaType: .text, startFrame: 0, durationFrames: 1)
        rasterClip.textContent = source.key.content
        rasterClip.textStyle = source.key.style
        rasterClip.transform = Transform(topLeft: (0, 0), width: source.key.width / source.renderSize.width,
                                          height: source.key.height / source.renderSize.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let layer = TextLayerStyle.makeLayer(clip: rasterClip, containerSize: source.renderSize)
        layer.frame.origin = CGPoint(x: source.padding, y: source.padding)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: rasterSize)
        root.isGeometryFlipped = true
        root.addSublayer(layer)
        layer.displayIfNeeded()
        // CALayer.render ignores isGeometryFlipped; draw in top-left coordinates explicitly.
        context.translateBy(x: 0, y: rasterSize.height)
        context.scaleBy(x: 1, y: -1)
        root.render(in: context)
        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: -source.padding, y: -source.padding))
        cache.images.setObject(image, forKey: source.keyData as NSData, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}
