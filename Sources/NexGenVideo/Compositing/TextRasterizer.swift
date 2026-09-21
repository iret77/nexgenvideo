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

    // Provider tiles, never full text boxes, enter the shared cache.
    private final class RasterCache: @unchecked Sendable {
        let tiles = NSCache<NSData, NSData>()
        init() { tiles.totalCostLimit = preparationBudget }
    }
    private static let cache = RasterCache()
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    static let preparationBudget = 64 * 1024 * 1024
    static let tileSide = 1024
    static let maximumRasterBytes = tileSide * tileSide * 4

    struct Source: Sendable {
        fileprivate let provider: TileProvider
        fileprivate let recipe: CIImage

        func image() -> CIImage? { recipe }
        var rasterizedTileCount: Int { provider.statistics.count }
        var maximumRasterizedTileBytes: Int { provider.statistics.bytes }
    }

    fileprivate final class TileProvider: NSObject, @unchecked Sendable {
        let key: CacheKey
        let keyData: Data
        let renderSize: CGSize
        private let lock = NSLock()
        private var count = 0
        private var bytes = 0

        var statistics: (count: Int, bytes: Int) { lock.withLock { (count, bytes) } }

        init(key: CacheKey, keyData: Data, renderSize: CGSize) {
            self.key = key
            self.keyData = keyData
            self.renderSize = renderSize
            super.init()
        }

        override func provideImageData(_ data: UnsafeMutableRawPointer, bytesPerRow rowbytes: Int,
            origin originx: Int, _ originy: Int, size width: Int, _ height: Int, userInfo info: Any?) {
            var tileKey = keyData
            for var value in [originx, originy, width, height, rowbytes] {
                withUnsafeBytes(of: &value) { tileKey.append(contentsOf: $0) }
            }
            if let cached = cache.tiles.object(forKey: tileKey as NSData) {
                data.copyMemory(from: cached.bytes, byteCount: cached.length)
                return
            }
            let byteCount = rowbytes * height
            data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            guard let bitmap = CGContext(data: data, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: rowbytes, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            var clip = Clip(mediaRef: "", mediaType: .text, startFrame: 0, durationFrames: 1)
            clip.textContent = key.content
            clip.textStyle = key.style
            clip.transform = Transform(topLeft: (0, 0), width: key.width / renderSize.width,
                                       height: key.height / renderSize.height)
            let layer = TextLayerStyle.makeLayer(clip: clip, containerSize: renderSize)
            // Provider origins and bitmap rows are top-left; CATextLayer draws in layer coordinates.
            bitmap.translateBy(x: -CGFloat(originx), y: CGFloat(height + originy))
            bitmap.scaleBy(x: 1, y: -1)
            let bounds = CGRect(x: 0, y: 0, width: key.width, height: key.height)
            if let fill = layer.backgroundColor {
                bitmap.setFillColor(fill)
                bitmap.fill(bounds)
            }
            bitmap.saveGState()
            bitmap.clip(to: bounds)
            layer.draw(in: bitmap)
            bitmap.restoreGState()
            if layer.borderWidth > 0, let border = layer.borderColor {
                bitmap.setStrokeColor(border)
                bitmap.setLineWidth(layer.borderWidth)
                bitmap.stroke(bounds.insetBy(dx: layer.borderWidth / 2, dy: layer.borderWidth / 2))
            }
            lock.withLock {
                count += 1
                bytes = max(bytes, byteCount)
            }
            cache.tiles.setObject(NSData(bytes: data, length: byteCount), forKey: tileKey as NSData, cost: byteCount)
        }
    }

    static func naturalSize(for clip: Clip, renderSize: CGSize) -> CGSize {
        CGSize(width: max(1, ceil(clip.transform.width * renderSize.width)),
               height: max(1, ceil(clip.transform.height * renderSize.height)))
    }

    static func prepare(for clip: Clip, renderSize: CGSize, budget: inout Int) -> LayerPlan? {
        let size = naturalSize(for: clip, renderSize: renderSize)
        let width = size.width, height = size.height
        guard width.isFinite, height.isFinite, width < CGFloat(Int.max), height < CGFloat(Int.max) else { return nil }
        let key = CacheKey(content: clip.textContent ?? "", style: clip.textStyle ?? TextStyle(),
                           width: width, height: height, canvasHeight: renderSize.height)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let keyData = try? encoder.encode(key) else { return nil }
        let provider = TileProvider(key: key, keyData: keyData, renderSize: renderSize)
        let pixels = CIImage(imageProvider: provider, size: Int(width), Int(height), format: .RGBA8,
            colorSpace: nil, options: [.providerTileSize: [tileSide, tileSide]])
        var recipe = pixels
        let shadow = key.style.shadow
        if shadow.enabled {
            let scale = renderSize.height / 1080
            let radius = max(0, shadow.blur) * scale
            let padding = ceil((max(abs(shadow.offsetX), abs(shadow.offsetY)) + max(0, shadow.blur) * 3) * scale)
            guard padding.isFinite else { return nil }
            var shade = pixels.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: shadow.color.a),
                "inputBiasVector": CIVector(x: shadow.color.r, y: shadow.color.g, z: shadow.color.b, w: 0),
            ])
            if radius > 0 { shade = shade.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]) }
            shade = shade.transformed(by: CGAffineTransform(translationX: shadow.offsetX * scale, y: -shadow.offsetY * scale))
            recipe = pixels.composited(over: shade).cropped(to: pixels.extent.insetBy(dx: -padding, dy: -padding))
        }
        let source = Source(provider: provider, recipe: recipe)
        var plan = LayerPlan(trackID: kCMPersistentTrackID_Invalid, clip: clip, natSize: size,
                             preferredTransform: .identity, textSource: source)
        let cost = recipe.extent.width * recipe.extent.height * 4
        // Large virtual sources stay tiled; only small images consume the eager instruction budget.
        if recipe.extent.width <= CGFloat(tileSide), recipe.extent.height <= CGFloat(tileSide),
           cost <= CGFloat(min(budget, maximumRasterBytes)),
           let image = context.createCGImage(recipe, from: recipe.extent, format: .RGBA8, colorSpace: nil),
           image.bytesPerRow * image.height <= budget {
            plan.stillImage = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
                .transformed(by: CGAffineTransform(translationX: recipe.extent.minX, y: recipe.extent.minY))
            budget -= image.bytesPerRow * image.height
        }
        return plan
    }
}
