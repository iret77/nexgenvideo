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
    CoverageIntervalsV1.findings(ctx.shotlist.shots.map {
        CoverageIntervalV1(id: $0.id, startSeconds: $0.timeStart, endSeconds: $0.timeEnd)
    }, mode: ctx.shotlist.mode, rangeEndSeconds: ctx.shotlist.song.durationS)
}
