import Foundation

/// A proposed new start frame for a single clip, produced by the ripple engine
/// and applied by the caller.
struct ClipShift: Equatable, Sendable {
    let clipId: String
    let newStartFrame: Int
}

/// A half-open `[start, end)` frame interval on a single track. Used to describe
/// the gaps that a ripple edit needs to close.
struct FrameRange: Equatable, Sendable {
    let start: Int
    let end: Int
    var length: Int { end - start }
}

/// A user-selected empty gap on a single track
struct GapSelection: Equatable, Sendable {
    let trackIndex: Int
    let range: FrameRange
}

/// Pure functions for ripple editing: computing how clips shift after
/// insertions or deletions.
enum RippleEngine {

    /// After removing clips from a track, compute new start frames for
    /// remaining clips that should shift backward to close the gap.
    static func computeRippleShifts(clips: [Clip], removedIds: Set<String>) -> [ClipShift] {
        let removedRanges = clips
            .filter { removedIds.contains($0.id) }
            .map { FrameRange(start: $0.startFrame, end: $0.endFrame) }
        return computeRippleShiftsForRanges(
            clips: clips.filter { !removedIds.contains($0.id) },
            removedRanges: removedRanges
        )
    }

    /// Shift clips leftward to close the gaps defined by `removedRanges`.
    /// Used when ranges come from a different track (sync-locked ripple).
    static func computeRippleShiftsForRanges(clips: [Clip], removedRanges: [FrameRange]) -> [ClipShift] {
        let merged = mergeRanges(removedRanges)
        guard !merged.isEmpty else { return [] }

        var shifts: [ClipShift] = []
        for clip in clips.sorted(by: { $0.startFrame < $1.startFrame }) {
            let shift = merged
                .filter { $0.end <= clip.startFrame }
                .reduce(0) { $0 + $1.length }
            if shift > 0 {
                shifts.append(ClipShift(clipId: clip.id, newStartFrame: clip.startFrame - shift))
            }
        }
        return shifts
    }

    /// Push all clips at or after `insertFrame` forward by `pushAmount` frames.
    static func computeRipplePush(
        clips: [Clip],
        insertFrame: Int,
        pushAmount: Int,
        excludeIds: Set<String> = []
    ) -> [ClipShift] {
        clips
            .filter { !excludeIds.contains($0.id) && $0.startFrame >= insertFrame }
            .map { ClipShift(clipId: $0.id, newStartFrame: $0.startFrame + pushAmount) }
    }

    /// Maps markers through deletions, preserving one when any affected track retains it.
    static func rippleMarkers(
        _ markers: [TimelineMarker],
        closing trackRanges: [[FrameRange]]
    ) -> [TimelineMarker] {
        let mergedByTrack = trackRanges
            .map { mergeRanges($0.filter { $0.length > 0 }) }
            .filter { !$0.isEmpty }
        guard !mergedByTrack.isEmpty else { return markers }

        return markers.compactMap { marker in
            let mapped = mergedByTrack.compactMap { ranges -> TimelineMarker? in
                mapMarker(marker, closing: ranges)
            }
            guard var result = mapped.min(by: { $0.startFrame < $1.startFrame }) else { return nil }
            if marker.durationFrames > 0 {
                let earliestEnd = mapped.map(\.endFrame).min() ?? result.endFrame
                guard earliestEnd > result.startFrame else { return nil }
                result.durationFrames = earliestEnd - result.startFrame
            }
            return result
        }
    }

    /// Opens for inserts or closes the tail removed by a ripple trim.
    static func rippleMarkers(
        _ markers: [TimelineMarker],
        openingAt frame: Int,
        by delta: Int
    ) -> [TimelineMarker] {
        guard delta != 0 else { return markers }
        if delta < 0 {
            return rippleMarkers(
                markers,
                closing: [[FrameRange(start: max(0, frame + delta), end: frame)]]
            )
        }

        return markers.map { marker in
            var result = marker
            if marker.startFrame >= frame {
                result.startFrame += delta
            } else if marker.durationFrames > 0, marker.endFrame > frame {
                result.durationFrames += delta
            }
            return result
        }
    }

    // MARK: - Helpers

    static func mergeRanges(_ ranges: [FrameRange]) -> [FrameRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [FrameRange] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = FrameRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func mapMarker(
        _ marker: TimelineMarker,
        closing ranges: [FrameRange]
    ) -> TimelineMarker? {
        if marker.durationFrames == 0 {
            guard !ranges.contains(where: { $0.start <= marker.startFrame && marker.startFrame < $0.end }) else {
                return nil
            }
            var result = marker
            result.startFrame = mapFrame(marker.startFrame, closing: ranges)
            return result
        }

        let survivingLength = ranges.reduce(marker.durationFrames) { length, range in
            let overlapStart = max(marker.startFrame, range.start)
            let overlapEnd = min(marker.endFrame, range.end)
            return length - max(0, overlapEnd - overlapStart)
        }
        guard survivingLength > 0 else { return nil }

        var result = marker
        result.startFrame = mapFrame(marker.startFrame, closing: ranges)
        result.durationFrames = survivingLength
        return result
    }

    private static func mapFrame(_ frame: Int, closing ranges: [FrameRange]) -> Int {
        var removedBefore = 0
        for range in ranges {
            if frame < range.start { break }
            if frame < range.end { return range.start - removedBefore }
            removedBefore += range.length
        }
        return frame - removedBefore
    }
}
