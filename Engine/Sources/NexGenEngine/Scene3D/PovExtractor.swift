import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File-level POV extraction: an equirectangular panorama in, one rectilinear view per `PovSpec`
/// out. Port of `bible/scene3d/pov.py::extract_pov` / `extract_set`; the geometry itself lives in
/// `EquirectProjector`.
///
/// Deterministic and local — no provider, no cost. The extracted views are style-neutral when the
/// panorama came from a clay wide (the scene-3D pipeline's whole point: Marble supplies GEOMETRY,
/// the bible image model stays the style master).
public enum PovExtractor {

    public enum ExtractError: LocalizedError, Equatable {
        case panoramaMissing(String)
        case decodeFailed(String)
        case notEquirectangular(width: Int, height: Int)
        case encodeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .panoramaMissing(let path):
                return "Panorama not found: \(path)"
            case .decodeFailed(let path):
                return "Could not decode panorama: \(path)"
            case .notEquirectangular(let width, let height):
                return "Panorama must be equirectangular (2:1), got \(width)×\(height). "
                    + "A POV cut from a non-2:1 image would be geometrically wrong."
            case .encodeFailed(let path):
                return "Could not write POV: \(path)"
            }
        }
    }

    /// Extract one POV to `dest` (PNG). Returns `dest`, for pipeline composability.
    @discardableResult
    public static func extract(
        panorama: URL, pov: PovSpec, to dest: URL,
        width: Int = defaultPovSize.width, height: Int = defaultPovSize.height
    ) throws -> URL {
        let pano = try loadPanorama(panorama)
        let view = EquirectProjector.project(pano: pano, pov: pov, width: width, height: height)
        try writePNG(view, to: dest)
        return dest
    }

    /// Extract a POV set into `outDir` as `<name>.png`, returning `name → URL`. Defaults to the
    /// four cardinal wall POVs. The panorama is decoded ONCE for the whole set.
    ///
    /// The `name` is deliberately the sheet key: these paths go into
    /// `Location.sheets[name]`, which is what a shot's `locationView` then names.
    @discardableResult
    public static func extractSet(
        panorama: URL, to outDir: URL, povs: [PovSpec]? = nil,
        width: Int = defaultPovSize.width, height: Int = defaultPovSize.height
    ) throws -> [String: URL] {
        let specs = povs ?? defaultFourWallPovs
        let pano = try loadPanorama(panorama)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var out: [String: URL] = [:]
        for pov in specs {
            let dest = outDir.appendingPathComponent("\(pov.name).png")
            let view = EquirectProjector.project(pano: pano, pov: pov, width: width, height: height)
            try writePNG(view, to: dest)
            out[pov.name] = dest
        }
        return out
    }

    // MARK: - Image I/O

    static func loadPanorama(_ url: URL) throws -> EquirectProjector.PixelBuffer {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExtractError.panoramaMissing(url.path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ExtractError.decodeFailed(url.path) }

        // 2:1 is what "equirectangular" means. Anything else silently skews every POV, so it is a
        // hard error rather than a best-effort cut.
        guard image.width == image.height * 2 else {
            throw ExtractError.notEquirectangular(width: image.width, height: image.height)
        }
        return try pixels(of: image)
    }

    /// Decode into straight RGBA8, top-down — the layout `EquirectProjector` samples.
    static func pixels(of image: CGImage) throws -> EquirectProjector.PixelBuffer {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = buffer.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
        }) else { throw ExtractError.decodeFailed("<in-memory>") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return EquirectProjector.PixelBuffer(width: width, height: height, rgba: buffer)
    }

    static func writePNG(_ buffer: EquirectProjector.PixelBuffer, to dest: URL) throws {
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = buffer.rgba
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = bytes.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress, width: buffer.width, height: buffer.height,
                bitsPerComponent: 8, bytesPerRow: buffer.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
        }), let image = ctx.makeImage() else {
            throw ExtractError.encodeFailed(dest.path)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            dest as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExtractError.encodeFailed(dest.path) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExtractError.encodeFailed(dest.path)
        }
    }
}
