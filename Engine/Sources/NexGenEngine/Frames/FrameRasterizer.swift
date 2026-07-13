import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pixel-level crop execution for `CropPlanner`/`PanPairPlanner`, using
/// CGImage/ImageIO instead of the Python engine's Pillow. Geometry planning
/// stays pure (no image I/O); this is only the raster step.
public enum FrameRasterizerError: Swift.Error, Sendable, Equatable {
    case masterNotFound(String)
    case decodeFailed(String)
    case cropFailed
    case encodeFailed(String)
}

public enum FrameRasterizer {
    /// Loads `masterPath`, plans a static crop via `planCrop`, and writes the
    /// cropped PNG to `dest`. Port of `crop_from_master.py::generate_crop`.
    @discardableResult
    public static func generateCrop(
        masterPath: URL, dest: URL, targetAspect: String, anchor: CropAnchor = .center
    ) throws -> CropPlan {
        guard FileManager.default.fileExists(atPath: masterPath.path) else {
            throw FrameRasterizerError.masterNotFound(masterPath.path)
        }
        let image = try loadImage(at: masterPath)
        let plan = try planCrop(
            masterSize: (image.width, image.height), targetAspect: targetAspect, anchor: anchor
        )
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try cropAndSavePNG(image, box: plan.box, to: dest)
        return plan
    }

    /// Loads `masterPath`, plans a pan pair via `planPanPair`, and writes both
    /// crops as PNGs. Port of `pan_pair.py::generate_pan_pair`.
    @discardableResult
    public static func generatePanPair(
        masterPath: URL, startDest: URL, endDest: URL, targetAspect: String, direction: PanDirection,
        travelPct: Double = 80.0
    ) throws -> PanPairPlan {
        guard FileManager.default.fileExists(atPath: masterPath.path) else {
            throw FrameRasterizerError.masterNotFound(masterPath.path)
        }
        let image = try loadImage(at: masterPath)
        let plan = try planPanPair(
            masterSize: (image.width, image.height), targetAspect: targetAspect, direction: direction,
            travelPct: travelPct
        )
        try FileManager.default.createDirectory(
            at: startDest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: endDest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try cropAndSavePNG(image, box: plan.startBox, to: startDest)
        try cropAndSavePNG(image, box: plan.endBox, to: endDest)
        return plan
    }

    static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw FrameRasterizerError.decodeFailed(url.path)
        }
        return image
    }

    /// Pixel dimensions of an image file, read from its metadata without a full
    /// decode. Nil if the file is missing / undecodable. Used by the frame_ratio /
    /// frame_size sanity checks (keeps ImageIO in the engine, off the format packs).
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// Crops `image` to `box` (left, top, right, bottom — PIL convention) and
    /// writes the result as PNG to `dest`. CGImage's origin is bottom-left,
    /// so the PIL top-down box is flipped vertically before cropping.
    static func cropAndSavePNG(
        _ image: CGImage, box: (left: Int, top: Int, right: Int, bottom: Int), to dest: URL
    ) throws {
        let width = box.right - box.left
        let height = box.bottom - box.top
        let flippedY = image.height - box.bottom
        let rect = CGRect(x: box.left, y: flippedY, width: width, height: height)
        guard let cropped = image.cropping(to: rect) else {
            throw FrameRasterizerError.cropFailed
        }
        try savePNG(cropped, to: dest)
    }

    static func savePNG(_ image: CGImage, to dest: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            dest as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw FrameRasterizerError.encodeFailed(dest.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FrameRasterizerError.encodeFailed(dest.path)
        }
    }
}
