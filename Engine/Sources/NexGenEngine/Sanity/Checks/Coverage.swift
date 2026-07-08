import Foundation

/// Timeline coverage: gaps and overlaps between shots.
///
/// - `UNCOVERED_GAP` (info): a stretch of the timeline with no shot covering it.
/// - `UNCOVERED_TAIL` (info): the timeline ends after the last shot.
/// - `SHOT_OVERLAP` (warn): two shots overlap in time.
///
/// Only meaningful for timeline-laid-out modes (`.beat`, `.section`) where
/// shots tile a continuous duration; modes like `.multicam` (every shot spans
/// the whole duration) are skipped. Port of `sanity/checks/coverage.py::check`.
public let coverageCheck: SanityCheck = { ctx in
    var out: [Finding] = []
    let shotlist = ctx.shotlist
    guard shotlist.mode == .beat || shotlist.mode == .section else { return out }

    let sortedShots = shotlist.shots.sorted { $0.timeStart < $1.timeStart }

    var lastEnd = 0.0
    for shot in sortedShots {
        if shot.timeStart > lastEnd + 0.5 {
            out.append(
                Finding(
                    level: .info,
                    code: "UNCOVERED_GAP",
                    message: String(
                        format: "gap with no shot: %.2fs -> %.2fs (%.2fs)",
                        lastEnd, shot.timeStart, shot.timeStart - lastEnd
                    )
                )
            )
        }
        lastEnd = max(lastEnd, shot.timeEnd)
    }

    let timelineEnd = shotlist.song.durationS
    if lastEnd < timelineEnd - 0.5 {
        out.append(
            Finding(
                level: .info,
                code: "UNCOVERED_TAIL",
                message: String(
                    format: "timeline ends at %.2fs, last shot ends at %.2fs", timelineEnd, lastEnd
                )
            )
        )
    }

    for (a, b) in zip(sortedShots, sortedShots.dropFirst()) {
        if b.timeStart < a.timeEnd - 0.01 {
            out.append(
                Finding(
                    level: .warn,
                    code: "SHOT_OVERLAP",
                    shotId: b.id,
                    message: String(
                        format: "overlaps %@ (%.2fs vs %.2fs)", a.id, a.timeEnd, b.timeStart
                    )
                )
            )
        }
    }

    return out
}
