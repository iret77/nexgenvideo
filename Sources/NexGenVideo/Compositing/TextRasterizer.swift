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
        let tiles = NSCache<TileKey, NSData>()
        init() { tiles.totalCostLimit = preparationBudget }
    }
    private static let cache = RasterCache()
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    static let preparationBudget = 64 * 1024 * 1024
    static let tileSide = 512
    static let maximumRasterBytes = tileSide * tileSide * 4

    final class TileKey: NSObject {
        let style: Data
        let coordinates: [Int]
        private let combinedHash: Int

        init(style: Data, styleHash: Int, coordinates: [Int]) {
            self.style = style
            self.coordinates = coordinates
            var hasher = Hasher()
            hasher.combine(styleHash)
            hasher.combine(coordinates)
            combinedHash = hasher.finalize()
            super.init()
        }

        override var hash: Int { combinedHash }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? TileKey else { return false }
            return combinedHash == other.combinedHash && coordinates == other.coordinates && style == other.style
        }
    }

    struct Source: Sendable {
        fileprivate let provider: TileProvider
        fileprivate let recipe: CIImage

        func image() -> CIImage? { recipe }
        var rasterizedTileCount: Int { provider.statistics.count }
        var maximumRasterizedTileBytes: Int { provider.statistics.bytes }
        var tileCacheHitCount: Int { provider.statistics.hits }
        var tileCacheWriteCount: Int { provider.statistics.writes }
    }

    fileprivate final class TileProvider: NSObject, @unchecked Sendable {
        let key: CacheKey
        let keyData: Data
        let styleHash: Int
        let renderSize: CGSize
        let padding: CGFloat
        let providerSize: CGSize
        private let lock = NSLock()
        private var count = 0
        private var bytes = 0
        private var hits = 0
        private var writes = 0
        private var cacheWritesEnabled = true

        var statistics: (count: Int, bytes: Int, hits: Int, writes: Int) {
            lock.withLock { (count, bytes, hits, writes) }
        }

        func withoutCacheWrites<T>(_ work: () -> T) -> T {
            lock.withLock { cacheWritesEnabled = false }
            defer { lock.withLock { cacheWritesEnabled = true } }
            return work()
        }

        init(key: CacheKey, keyData: Data, renderSize: CGSize, padding: CGFloat) {
            self.key = key
            self.keyData = keyData
            self.styleHash = keyData.hashValue
            self.renderSize = renderSize
            self.padding = padding
            self.providerSize = CGSize(width: key.width + padding * 2, height: key.height + padding * 2)
            super.init()
        }

        override func provideImageData(_ data: UnsafeMutableRawPointer, bytesPerRow rowbytes: Int,
            origin originx: Int, _ originy: Int, size width: Int, _ height: Int, userInfo info: Any?) {
            let tileKey = TileKey(style: keyData, styleHash: styleHash,
                                  coordinates: [originx, originy, width, height, rowbytes])
            if let cached = cache.tiles.object(forKey: tileKey) {
                data.copyMemory(from: cached.bytes, byteCount: cached.length)
                lock.withLock { hits += 1 }
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
            layer.frame.origin = CGPoint(x: padding, y: padding)
            let root = CALayer()
            root.frame = CGRect(origin: .zero, size: providerSize)
            root.isGeometryFlipped = true
            root.addSublayer(layer)
            // Provider origins and bitmap rows are top-left; mirror the host layer tree.
            bitmap.translateBy(x: -CGFloat(originx), y: CGFloat(height + originy))
            bitmap.scaleBy(x: 1, y: -1)
            root.render(in: bitmap)
            lock.withLock {
                count += 1
                bytes = max(bytes, byteCount)
            }
            let shouldCache = lock.withLock {
                if cacheWritesEnabled { writes += 1 }
                return cacheWritesEnabled
            }
            if shouldCache {
                cache.tiles.setObject(NSData(bytes: data, length: byteCount), forKey: tileKey, cost: byteCount)
            }
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
        let shadow = key.style.shadow
        let scale = renderSize.height / 1080
        let padding = shadow.enabled
            ? ceil((max(abs(shadow.offsetX), abs(shadow.offsetY)) + max(0, shadow.blur) * 3) * scale)
            : 0
        guard padding.isFinite,
              width + padding * 2 < CGFloat(Int.max),
              height + padding * 2 < CGFloat(Int.max) else { return nil }
        let provider = TileProvider(key: key, keyData: keyData, renderSize: renderSize, padding: padding)
        let pixels = CIImage(imageProvider: provider,
            size: Int(provider.providerSize.width), Int(provider.providerSize.height), format: .RGBA8,
            colorSpace: nil, options: [.providerTileSize: [tileSide, tileSide]])
        let recipe = pixels.transformed(by: CGAffineTransform(translationX: -padding, y: -padding))
        let source = Source(provider: provider, recipe: recipe)
        var plan = LayerPlan(trackID: kCMPersistentTrackID_Invalid, clip: clip, natSize: size,
                             preferredTransform: .identity, textSource: source)
        let cost = recipe.extent.width * recipe.extent.height * 4
        // Large virtual sources stay tiled; only small images consume the eager instruction budget.
        if recipe.extent.width <= CGFloat(tileSide), recipe.extent.height <= CGFloat(tileSide),
           cost <= CGFloat(min(budget, maximumRasterBytes)),
           let image = provider.withoutCacheWrites({
               context.createCGImage(recipe, from: recipe.extent, format: .RGBA8, colorSpace: nil)
           }),
           image.bytesPerRow * image.height <= budget {
            plan.stillImage = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
                .transformed(by: CGAffineTransform(translationX: recipe.extent.minX, y: recipe.extent.minY))
            budget -= image.bytesPerRow * image.height
        }
        return plan
    }
}
