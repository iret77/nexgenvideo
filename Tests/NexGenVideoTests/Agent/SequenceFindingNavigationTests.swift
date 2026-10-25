import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Film finding timeline navigation")
struct SequenceFindingNavigationTests {
    private func finding(start: Int = 5, end: Int = 15, shots: [String] = []) -> SequenceReviewFindingV1 {
        .init(id: "finding", scope: .wholePlayback, category: .timingAndPacing, severity: .warning,
            shotIDs: shots, startFrame: start, endFrame: end, evidence: "The cut needs inspection.",
            recommendedAction: .localRepair, provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review"))
    }

    @Test func reelOffsetAndBothSidesOfCutMapToActualClips() throws {
        let target = try SequenceFindingNavigation(finding: finding(), outputStart: 100, duration: 30, placements: [
            .init(clipID: "earlier", shotID: "a", startFrame: 90, durationFrames: 15),
            .init(clipID: "left", shotID: "b", startFrame: 100, durationFrames: 10),
            .init(clipID: "right", shotID: "c", startFrame: 110, durationFrames: 20),
            .init(clipID: "audio", shotID: nil, startFrame: 100, durationFrames: 30),
            .init(clipID: "later", shotID: "d", startFrame: 115, durationFrames: 10)])
        #expect(target.startFrame == 105 && target.endFrame == 115)
        #expect(target.clipIDs == ["left", "right", "audio"])
    }

    @Test func explicitShotsNeverSelectAnUnrelatedOverlappingClip() throws {
        let placements: [SequenceFindingNavigation.Placement] = [
            .init(clipID: "video", shotID: "a", startFrame: 0, durationFrames: 30),
            .init(clipID: "other", shotID: "b", startFrame: 0, durationFrames: 30)]
        let target = try SequenceFindingNavigation(finding: finding(shots: ["a"]), outputStart: 0, duration: 30, placements: placements)
        #expect(target.clipIDs == ["video"])
        let unmatched = try SequenceFindingNavigation(finding: finding(shots: ["missing"]), outputStart: 0, duration: 30, placements: placements)
        #expect(unmatched.clipIDs.isEmpty && unmatched.startFrame == 5 && unmatched.endFrame == 15)
        #expect(unmatched.notice != nil)
    }

    @Test func gapFindingKeepsItsRangeWithoutInventingAClip() throws {
        let target = try SequenceFindingNavigation(finding: finding(), outputStart: 100, duration: 30, placements: [])
        #expect(target.clipIDs.isEmpty)
        #expect(target.startFrame == 105 && target.endFrame == 115)
    }

    @Test func invalidAndOverflowingRangesAreRejected() {
        for value in [finding(start: -1), finding(start: 15), finding(end: 31)] {
            #expect(throws: (any Error).self) {
                _ = try SequenceFindingNavigation(finding: value, outputStart: 0, duration: 30, placements: [])
            }
        }
        #expect(throws: (any Error).self) {
            _ = try SequenceFindingNavigation(finding: finding(), outputStart: Int.max, duration: 30, placements: [])
        }
        #expect(throws: (any Error).self) {
            _ = try SequenceFindingNavigation(finding: finding(), outputStart: 0, duration: 30,
                placements: [.init(clipID: "overflow", shotID: nil, startFrame: Int.max, durationFrames: 1)])
        }
    }
}
