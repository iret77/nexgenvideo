import AppKit
import AVFoundation
import CoreImage
import QuartzCore

enum TextRasterizer {
    private struct CacheKey: Encodable {
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

    static func naturalSize(for clip: Clip, renderSize: CGSize) -> CGSize {
        CGSize(width: max(1, ceil(clip.transform.width * renderSize.width)),
               height: max(1, ceil(clip.transform.height * renderSize.height)))
    }

    static func layer(for clip: Clip, renderSize: CGSize) -> LayerPlan? {
        let size = naturalSize(for: clip, renderSize: renderSize)
        let width = size.width, height = size.height
        guard width.isFinite, height.isFinite, width <= 16384, height <= 16384 else { return nil }
        let key = CacheKey(content: clip.textContent ?? "", style: clip.textStyle ?? TextStyle(),
                           width: width, height: height, canvasHeight: renderSize.height)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let keyData = try? encoder.encode(key) else { return nil }
        if let image = cache.images.object(forKey: keyData as NSData) {
            return LayerPlan(trackID: kCMPersistentTrackID_Invalid, clip: clip, natSize: size,
                             preferredTransform: .identity, stillImage: image)
        }
        let shadow = (clip.textStyle ?? TextStyle()).shadow
        let scale = renderSize.height / 1080
        let padding = shadow.enabled
            ? ceil((max(abs(shadow.offsetX), abs(shadow.offsetY)) + max(0, shadow.blur) * 3) * scale) : 0
        guard padding.isFinite, padding >= 0, padding <= 4096 else { return nil }
        let rasterSize = CGSize(width: width + 2 * padding, height: height + 2 * padding)
        guard let context = CGContext(
            data: nil, width: Int(rasterSize.width), height: Int(rasterSize.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        var rasterClip = clip
        rasterClip.transform = Transform(topLeft: (0, 0), width: width / renderSize.width, height: height / renderSize.height)
        let layer = TextLayerController.makeTextLayer()
        TextLayerController.applyStyle(to: layer, clip: rasterClip, containerSize: renderSize)
        layer.frame.origin = CGPoint(x: padding, y: padding)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: rasterSize)
        root.isGeometryFlipped = true
        root.addSublayer(layer)
        layer.displayIfNeeded()
        root.render(in: context)
        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: -padding, y: -padding))
        cache.images.setObject(image, forKey: keyData as NSData, cost: cgImage.bytesPerRow * cgImage.height)
        return LayerPlan(trackID: kCMPersistentTrackID_Invalid, clip: clip, natSize: size,
                         preferredTransform: .identity, stillImage: image)
    }
}
