import Foundation

struct SourcePreviewState: Sendable, Equatable {
    var playheadFrame: Int = 0
    var inFrame: Int?
    var outFrame: Int?

    func clamped(to durationFrames: Int) -> SourcePreviewState {
        let duration = max(0, durationFrames)
        var result = self
        result.playheadFrame = min(max(0, playheadFrame), duration)
        result.inFrame = inFrame.map { min(max(0, $0), duration) }
        result.outFrame = outFrame.map { min(max(0, $0), duration) }
        if let lower = result.inFrame, let upper = result.outFrame, lower >= upper {
            result.outFrame = nil
        }
        return result
    }

    func selectedFrames(durationFrames: Int) -> Range<Int>? {
        let state = clamped(to: durationFrames)
        let lower = state.inFrame ?? 0
        let upper = state.outFrame ?? durationFrames
        guard lower < upper else { return nil }
        return lower..<upper
    }
}
