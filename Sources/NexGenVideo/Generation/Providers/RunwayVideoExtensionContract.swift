import AVFoundation
import Foundation

enum RunwayVideoExtensionContract {
    nonisolated static func requireSource(_ url: URL, aspectRatio: String) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.value > 0, duration.timescale > 0,
              CMTimeCompare(duration, CMTime(seconds: 30, preferredTimescale: 1)) <= 0,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw GenerationBackendError.transport("Runway extension requires an actual video of at most 30 seconds.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let width = abs(bounds.width), height = abs(bounds.height)
        guard width.isFinite, height.isFinite, min(width, height) >= 480 else {
            throw GenerationBackendError.transport("Runway extension requires a source video of at least 480 pixels on its short side.")
        }
        if !aspectRatio.isEmpty {
            let parts = aspectRatio.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts.allSatisfy({ $0.isFinite && $0 > 0 }),
                  abs(Double(width) * parts[1] - Double(height) * parts[0]) <= max(parts[0], parts[1]) else {
                throw GenerationBackendError.transport("Runway extension keeps the source video's aspect ratio. Choose the same aspect ratio as the source.")
            }
        }
    }
}
