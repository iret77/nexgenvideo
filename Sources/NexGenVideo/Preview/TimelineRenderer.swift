import AVFoundation
import Foundation

/// Renders a frame range of the timeline to a temp mp4
/// Caller owns the temp file.
enum TimelineRenderer {
    static func sourceTimeline(_ timeline: Timeline, startFrame: Int, endFrame: Int) -> Timeline {
        var source = timeline
        for index in source.tracks.indices {
            source.tracks[index].clips.removeAll { $0.startFrame >= endFrame || $0.endFrame <= startFrame }
        }
        return source
    }

    struct RenderError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Could not render selection: \(reason)" }
    }

    /// Exports frames [startFrame, startFrame + frameCount) of timeline.
    @MainActor
    static func render(
        timeline: Timeline,
        resolver: MediaResolver,
        startFrame: Int,
        frameCount: Int,
        shortSide: Int? = nil,
        includeAudio: Bool = true,
        preset: String = AVAssetExportPresetMediumQuality
    ) async throws -> URL {
        guard timeline.fps > 0, timeline.fps <= Int(Int32.max) else { throw RenderError(reason: "invalid fps") }
        let end = startFrame.addingReportingOverflow(frameCount)
        guard startFrame >= 0, frameCount > 0, !end.overflow else { throw RenderError(reason: "invalid selection") }

        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = Self.renderSize(canvas: canvas, shortSide: shortSide)

        let result = try await CompositionBuilder.build(
            timeline: sourceTimeline(timeline, startFrame: startFrame, endFrame: end.partialValue),
            resolveURL: { resolver.resolveURL(for: $0) },
            renderSize: renderSize,
            minimumDurationFrames: end.partialValue
        )

        guard let session = AVAssetExportSession(asset: result.composition, presetName: preset) else {
            throw RenderError(reason: "export preset unsupported")
        }
        if includeAudio {
            session.audioMix = result.audioMix
        } else {
            for track in result.composition.tracks(withMediaType: .audio) {
                result.composition.removeTrack(track)
            }
        }

        session.videoComposition = result.videoComposition

        let timescale = CMTimeScale(timeline.fps)
        session.timeRange = CMTimeRange(
            start: CMTime(value: CMTimeValue(startFrame), timescale: timescale),
            duration: CMTime(value: CMTimeValue(frameCount), timescale: timescale)
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-render-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        Log.generation.notice("timeline-render start frames=\(startFrame)..<\(startFrame + frameCount) fps=\(timeline.fps)")
        try await session.export(to: outputURL, as: .mp4)
        Log.generation.notice("timeline-render ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }

    /// Render size for the given short side
    private static func renderSize(canvas: CGSize, shortSide: Int?) -> CGSize {
        guard let shortSide, canvas.width > 0, canvas.height > 0 else {
            return CGSize(width: even(canvas.width), height: even(canvas.height))
        }
        let canvasShort = min(canvas.width, canvas.height)
        let scale = min(1.0, Double(shortSide) / canvasShort)
        return CGSize(width: even(canvas.width * scale), height: even(canvas.height * scale))
    }

    private static func even(_ value: Double) -> Int { max(2, (Int(value.rounded()) / 2) * 2) }
}
