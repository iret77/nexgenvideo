import Foundation

public struct CoverageIntervalV1: Sendable, Equatable {
    public let id: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(id: String, startSeconds: Double, endSeconds: Double) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public enum CoverageIntervalsV1 {
    public static func findings(_ intervals: [CoverageIntervalV1], mode: Mode,
                                rangeStartSeconds: Double = 0, rangeEndSeconds: Double) -> [Finding] {
        guard mode == .beat || mode == .section else { return [] }
        let shots = intervals.enumerated().sorted {
            $0.element.startSeconds == $1.element.startSeconds ? $0.offset < $1.offset : $0.element.startSeconds < $1.element.startSeconds
        }.map(\.element)
        var out: [Finding] = []
        var lastEnd = rangeStartSeconds
        for shot in shots {
            if shot.startSeconds > lastEnd + 0.5 {
                out.append(.init(level: .info, code: "UNCOVERED_GAP", message: String(
                    format: "gap with no shot: %.2fs -> %.2fs (%.2fs)", lastEnd, shot.startSeconds, shot.startSeconds - lastEnd)))
            }
            lastEnd = max(lastEnd, shot.endSeconds)
        }
        if lastEnd < rangeEndSeconds - 0.5 {
            out.append(.init(level: .info, code: "UNCOVERED_TAIL", message: String(
                format: "timeline ends at %.2fs, last shot ends at %.2fs", rangeEndSeconds, lastEnd)))
        }
        var longest: CoverageIntervalV1?
        for shot in shots {
            if let first = longest, shot.startSeconds < first.endSeconds - 0.01 {
                out.append(.init(level: .warn, code: "SHOT_OVERLAP", shotId: shot.id, message: String(
                    format: "overlaps %@ (%.2fs vs %.2fs)", first.id, first.endSeconds, shot.startSeconds)))
            }
            if longest.map({ shot.endSeconds > $0.endSeconds }) ?? true { longest = shot }
        }
        return out
    }
}
