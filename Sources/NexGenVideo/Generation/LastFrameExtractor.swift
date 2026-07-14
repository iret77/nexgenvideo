import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Extract the last frame of a rendered clip as a PNG — the start-frame condition for a chained
/// successor shot (`chain_with_previous_end`, #196). Port of `render/last_frame.py::extract_last_frame`,
/// using AVFoundation instead of a shelled-out ffmpeg: NexGenVideo is a self-contained macOS app and
/// AVAssetImageGenerator is the native, dependency-free equivalent (no `$PATH` ffmpeg requirement).
enum LastFrameExtractor {
    enum ExtractError: LocalizedError {
        case missingVideo(URL)
        case emptyOrUnreadable(URL)
        case writeFailed(URL)

        var errorDescription: String? {
            switch self {
            case .missingVideo(let u): return "Video for last-frame extraction is missing: \(u.path)"
            case .emptyOrUnreadable(let u): return "Video has no readable duration/frames: \(u.path)"
            case .writeFailed(let u): return "Could not write the extracted last frame to \(u.path)"
            }
        }
    }

    /// Write the video's final frame to `dest` (PNG). Seeks to ~40ms before the end (matching the
    /// Python `-sseof -0.04`): for 24/25/30fps material that lands on the last or second-to-last frame,
    /// which is indistinguishable for a continuity cut. Creates `dest`'s directory if needed.
    @discardableResult
    static func extractLastFrame(video videoURL: URL, dest: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw ExtractError.missingVideo(videoURL)
        }
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else {
            throw ExtractError.emptyOrUnreadable(videoURL)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Broad tolerance so we always land on a real decoded frame near the end rather than failing an
        // exact-time seek on a sparse keyframe layout.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let target = CMTimeSubtract(duration, CMTime(seconds: 0.04, preferredTimescale: 600))
        let seekTime = target.seconds > 0 ? target : .zero

        let cgImage: CGImage
        do {
            cgImage = try await generator.image(at: seekTime).image
        } catch {
            throw ExtractError.emptyOrUnreadable(videoURL)
        }

        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let out = CGImageDestinationCreateWithURL(
            dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExtractError.writeFailed(dest)
        }
        CGImageDestinationAddImage(out, cgImage, nil)
        guard CGImageDestinationFinalize(out) else { throw ExtractError.writeFailed(dest) }
        return dest
    }
}
