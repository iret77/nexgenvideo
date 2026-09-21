import CoreGraphics
import Foundation

struct SubtitleCaptionPlan: Sendable {
    let specs: [EditorViewModel.TextClipSpec]
    let trackCount: Int
    let cueCount: Int
    let overlappingCueCount: Int
}

enum SubtitleCaptionBuilder {
    private struct TimedCue: Sendable {
        let cue: SubtitleCue
        let startFrame: Int
        let endFrame: Int
        let lane: Int
    }

    @concurrent
    static func build(
        document: SubtitleDocument,
        fps: Int,
        canvasWidth: Int,
        canvasHeight: Int,
        style: TextStyle,
        center: CGPoint,
        provenance: CaptionProvenance
    ) async throws -> SubtitleCaptionPlan {
        try Task.checkCancellation()
        var laneEndFrames: [Int] = []
        var timed: [TimedCue] = []
        var overlapCount = 0

        for cue in document.cues {
            try Task.checkCancellation()
            let startFrame = try cue.start.frame(at: fps)
            let authoredEndFrame = try cue.end.frame(at: fps)
            let endFrame = max(startFrame + 1, authoredEndFrame)
            if laneEndFrames.contains(where: { $0 > startFrame }) {
                overlapCount += 1
            }
            let lane: Int
            if let available = laneEndFrames.firstIndex(where: { $0 <= startFrame }) {
                lane = available
                laneEndFrames[available] = endFrame
            } else {
                lane = laneEndFrames.count
                laneEndFrames.append(endFrame)
            }
            timed.append(TimedCue(
                cue: cue,
                startFrame: startFrame,
                endFrame: endFrame,
                lane: lane
            ))
        }

        let groupID = UUID().uuidString
        let width = Double(canvasWidth)
        let height = Double(canvasHeight)
        let specs = timed.map { item in
            let natural = TextLayout.naturalSize(
                content: item.cue.text,
                style: style,
                maxWidth: CGFloat(width) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio,
                canvasHeight: CGFloat(height)
            )
            return EditorViewModel.TextClipSpec(
                trackIndex: item.lane,
                startFrame: item.startFrame,
                durationFrames: item.endFrame - item.startFrame,
                content: item.cue.text,
                style: style,
                transform: Transform(
                    center: (Double(center.x), Double(center.y)),
                    width: Double(natural.width) / width,
                    height: Double(natural.height) / height
                ),
                captionGroupId: groupID,
                captionProvenance: provenance
            )
        }
        return SubtitleCaptionPlan(
            specs: specs,
            trackCount: laneEndFrames.count,
            cueCount: specs.count,
            overlappingCueCount: overlapCount
        )
    }
}
