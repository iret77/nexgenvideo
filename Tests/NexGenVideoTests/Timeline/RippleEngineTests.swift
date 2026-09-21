import Testing
@testable import NexGenVideo

@Suite("RippleEngine")
struct RippleEngineTests {

    // MARK: - computeRippleShifts (delete + close gap)

    @Test func emptyRemovedIdsProducesNoShifts() {
        let a = Fixtures.clip(id: "a", start: 0, duration: 50)
        let b = Fixtures.clip(id: "b", start: 100, duration: 50)
        #expect(RippleEngine.computeRippleShifts(clips: [a, b], removedIds: []).isEmpty)
    }

    @Test func removingMiddleClipShiftsTrailingClipsLeft() {
        // Remove [50, 100). The clip at [200, 250) should shift left by 50 → [150, 200).
        let removed = Fixtures.clip(id: "r", start: 50, duration: 50)
        let trailing = Fixtures.clip(id: "t", start: 200, duration: 50)
        let head = Fixtures.clip(id: "h", start: 0, duration: 50)

        let shifts = RippleEngine.computeRippleShifts(clips: [head, removed, trailing], removedIds: ["r"])
        #expect(shifts == [ClipShift(clipId: "t", newStartFrame: 150)])
    }

    @Test func clipsBeforeRemovedRangeDoNotShift() {
        let head = Fixtures.clip(id: "h", start: 0, duration: 50)
        let removed = Fixtures.clip(id: "r", start: 100, duration: 50)
        let shifts = RippleEngine.computeRippleShifts(clips: [head, removed], removedIds: ["r"])
        #expect(shifts.isEmpty)
    }

    @Test func removingMultipleClipsShiftsByMergedTotal() {
        // Remove [0, 50) and [100, 150). Clip at [200, 250) shifts left by 100 → [100, 200).
        let r1 = Fixtures.clip(id: "r1", start: 0, duration: 50)
        let r2 = Fixtures.clip(id: "r2", start: 100, duration: 50)
        let tail = Fixtures.clip(id: "t", start: 200, duration: 50)
        let shifts = RippleEngine.computeRippleShifts(clips: [r1, r2, tail], removedIds: ["r1", "r2"])
        #expect(shifts == [ClipShift(clipId: "t", newStartFrame: 100)])
    }

    // MARK: - computeRippleShiftsForRanges (merge + shift)

    @Test func overlappingRangesMergeBeforeShifting() {
        // Ranges [0, 100) and [50, 200) → merged [0, 200). Clip at [300, 400) shifts by 200 → [100, ...).
        let clip = Fixtures.clip(id: "c", start: 300, duration: 100)
        let shifts = RippleEngine.computeRippleShiftsForRanges(
            clips: [clip],
            removedRanges: [FrameRange(start: 0, end: 100), FrameRange(start: 50, end: 200)]
        )
        #expect(shifts == [ClipShift(clipId: "c", newStartFrame: 100)])
    }

    @Test func touchingRangesMergeBeforeShifting() {
        // [0, 50) touching [50, 100) → merged [0, 100). Clip at [200) shifts by 100.
        let clip = Fixtures.clip(id: "c", start: 200, duration: 50)
        let shifts = RippleEngine.computeRippleShiftsForRanges(
            clips: [clip],
            removedRanges: [FrameRange(start: 0, end: 50), FrameRange(start: 50, end: 100)]
        )
        #expect(shifts == [ClipShift(clipId: "c", newStartFrame: 100)])
    }

    @Test func rangeWhollyBeforeClipShiftsClip_rangeAfterDoesNot() {
        // Range [0, 50) shifts both clips. Range [400, 500) is after both → ignored.
        let a = Fixtures.clip(id: "a", start: 100, duration: 50)
        let b = Fixtures.clip(id: "b", start: 200, duration: 50)
        let shifts = RippleEngine.computeRippleShiftsForRanges(
            clips: [a, b],
            removedRanges: [FrameRange(start: 0, end: 50), FrameRange(start: 400, end: 500)]
        )
        #expect(shifts == [
            ClipShift(clipId: "a", newStartFrame: 50),
            ClipShift(clipId: "b", newStartFrame: 150),
        ])
    }

    @Test func rangeMustEndAtOrBeforeClipStartToShift() {
        // Range [0, 100) — clip at frame 100 has `range.end <= clip.startFrame` → shifts.
        // Range [0, 101) — clip at frame 100 fails the predicate → does NOT shift.
        let clip = Fixtures.clip(id: "c", start: 100, duration: 50)

        let exactlyAtStart = RippleEngine.computeRippleShiftsForRanges(
            clips: [clip],
            removedRanges: [FrameRange(start: 0, end: 100)]
        )
        #expect(exactlyAtStart == [ClipShift(clipId: "c", newStartFrame: 0)])

        let overlapping = RippleEngine.computeRippleShiftsForRanges(
            clips: [clip],
            removedRanges: [FrameRange(start: 0, end: 101)]
        )
        #expect(overlapping.isEmpty)
    }

    // MARK: - computeRipplePush (insert + push forward)

    @Test func pushMovesClipsAtOrAfterInsertFrame() {
        let a = Fixtures.clip(id: "a", start: 0, duration: 50)    // before insert
        let b = Fixtures.clip(id: "b", start: 100, duration: 50)  // at insert
        let c = Fixtures.clip(id: "c", start: 200, duration: 50)  // after insert
        let shifts = RippleEngine.computeRipplePush(clips: [a, b, c], insertFrame: 100, pushAmount: 30)
        #expect(shifts == [
            ClipShift(clipId: "b", newStartFrame: 130),
            ClipShift(clipId: "c", newStartFrame: 230),
        ])
    }

    @Test func pushSkipsExcludedIds() {
        let a = Fixtures.clip(id: "a", start: 100, duration: 50)
        let b = Fixtures.clip(id: "b", start: 200, duration: 50)
        let shifts = RippleEngine.computeRipplePush(
            clips: [a, b],
            insertFrame: 0,
            pushAmount: 25,
            excludeIds: ["a"]
        )
        #expect(shifts == [ClipShift(clipId: "b", newStartFrame: 225)])
    }

    @Test func rippleDeleteMapsPointAndRangeMarkersWithHalfOpenEdges() {
        let markers = [
            TimelineMarker(id: "inside", startFrame: 45, title: "Inside"),
            TimelineMarker(id: "edge", startFrame: 50, title: "Edge"),
            TimelineMarker(id: "after", startFrame: 80, title: "After"),
            TimelineMarker(id: "range", startFrame: 10, durationFrames: 40, title: "Range"),
            TimelineMarker(id: "consumed", startFrame: 40, durationFrames: 10, title: "Consumed"),
        ]

        let mapped = RippleEngine.rippleMarkers(
            markers,
            closing: [[FrameRange(start: 40, end: 50)]]
        )

        #expect(mapped.first { $0.id == "inside" } == nil)
        #expect(mapped.first { $0.id == "edge" }?.startFrame == 40)
        #expect(mapped.first { $0.id == "after" }?.startFrame == 70)
        #expect(mapped.first { $0.id == "range" }?.durationFrames == 30)
        #expect(mapped.first { $0.id == "consumed" } == nil)
    }

    @Test func markersSurviveWhenOneRippleTrackStillRetainsTheirTime() {
        let marker = TimelineMarker(id: "shared", startFrame: 45, title: "Shared")
        let mapped = RippleEngine.rippleMarkers(
            [marker],
            closing: [
                [FrameRange(start: 40, end: 50)],
                [FrameRange(start: 0, end: 10)],
            ]
        )

        #expect(mapped.first?.startFrame == 35)
    }

    @Test func multiTrackRippleUsesTheEarliestSurvivingRangeEnd() {
        let marker = TimelineMarker(id: "range", startFrame: 300, durationFrames: 50, title: "Range")
        let mapped = RippleEngine.rippleMarkers(
            [marker],
            closing: [
                [FrameRange(start: 0, end: 50)],
                [FrameRange(start: 100, end: 120)],
            ]
        )

        #expect(mapped.first?.startFrame == 250)
        #expect(mapped.first?.durationFrames == 50)
    }

    @Test func positiveTimelineOffsetMovesPointsAndExtendsSpanningRanges() {
        let markers = [
            TimelineMarker(id: "point", startFrame: 50, title: "Point"),
            TimelineMarker(id: "span", startFrame: 20, durationFrames: 40, title: "Span"),
        ]
        let mapped = RippleEngine.rippleMarkers(markers, openingAt: 50, by: 20)

        #expect(mapped[0].startFrame == 70)
        #expect(mapped[1].startFrame == 20)
        #expect(mapped[1].durationFrames == 60)
    }

    @Test func negativeTimelineOffsetUsesRippleTrimTailSemantics() {
        let markers = [
            TimelineMarker(id: "removed", startFrame: 45, title: "Removed"),
            TimelineMarker(id: "boundary", startFrame: 50, title: "Boundary"),
            TimelineMarker(id: "after", startFrame: 70, title: "After"),
        ]
        let mapped = RippleEngine.rippleMarkers(markers, openingAt: 50, by: -10)

        #expect(mapped.first { $0.id == "removed" } == nil)
        #expect(mapped.first { $0.id == "boundary" }?.startFrame == 40)
        #expect(mapped.first { $0.id == "after" }?.startFrame == 60)
    }
}

// MARK: - Adversarial

@Suite("RippleEngine — adversarial")
struct RippleEngineAdversarialTests {

    @Test func shiftsPreserveStartFrameOrder() {
        let clips = [
            Fixtures.clip(id: "a", start: 0, duration: 50),
            Fixtures.clip(id: "b", start: 100, duration: 50),
            Fixtures.clip(id: "c", start: 200, duration: 50),
            Fixtures.clip(id: "d", start: 300, duration: 50),
        ]
        let shifts = RippleEngine.computeRippleShifts(clips: clips, removedIds: ["b", "c"])
        var newStarts: [(String, Int)] = clips
            .filter { !["b", "c"].contains($0.id) }
            .map { ($0.id, $0.startFrame) }
        for shift in shifts {
            if let idx = newStarts.firstIndex(where: { $0.0 == shift.clipId }) {
                newStarts[idx] = (shift.clipId, shift.newStartFrame)
            }
        }
        let aIdx = newStarts.firstIndex { $0.0 == "a" }!
        let dIdx = newStarts.firstIndex { $0.0 == "d" }!
        #expect(aIdx < dIdx)
        let starts = newStarts.map(\.1)
        #expect(starts == starts.sorted())
    }

    @Test func pushDoesNotMakeClipsCollide() {
        let clips = [
            Fixtures.clip(id: "anchor", start: 0, duration: 50),
            Fixtures.clip(id: "follower", start: 100, duration: 50),
        ]
        let shifts = RippleEngine.computeRipplePush(clips: clips, insertFrame: 100, pushAmount: 30)
        let followerNewStart = shifts.first { $0.clipId == "follower" }?.newStartFrame
        #expect(followerNewStart == 130)
        #expect(50 <= followerNewStart!) // anchor ends at 50, no overlap
    }
}
