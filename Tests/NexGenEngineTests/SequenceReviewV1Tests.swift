import Foundation
import Testing
@testable import NexGenEngine

@Suite("Sequence review V1")
struct SequenceReviewV1Tests {
    @Test("whole and adjacent review bind actual reel and selected order")
    func bindsReelAndSelection() throws {
        let selected = [selection("s001", "a"), selection("s002", "b")]
        let reel = ReviewReelV1(path: "reviews/sequence/reel.mov", sha256: hash("reel"),
            byteCount: 100, fps: 24, durationFrames: 48,
            edlPath: "reviews/sequence/reel.edl.json", edlSHA256: hash("edl"), entries: [
                entry(selected[0], start: 0, end: 24),
                entry(selected[1], start: 24, end: 48),
            ])
        let review = SequenceReviewV1(projectID: "fixture", selectedMedia: selected,
            reviewReel: reel, executionPlanSHA256: hash("execution"),
            canonSHA256: hash("canon"), referencePlanSHA256: hash("reference"),
            adjacentPairCompleted: true, wholePlaybackCompleted: true,
            findings: [SequenceReviewFindingV1(id: "timing-1", scope: .adjacentPair,
                category: .timingAndPacing, severity: .warning, shotIDs: ["s001", "s002"],
                startFrame: 20, endFrame: 28, evidence: "The transition is four frames late.",
                recommendedAction: .localRepair,
                provenance: .init(kind: .deterministicEngine, reviewerID: "review-reel-timing/v1"))],
            reviewedAt: "2026-09-09T00:00:00Z")
        try SequenceReviewValidatorV1.validate(review, selectedMedia: selected,
            executionPlanSHA256: hash("execution"), canonSHA256: hash("canon"),
            referencePlanSHA256: hash("reference"))

        #expect(throws: SequenceReviewValidationErrorV1.self) {
            try SequenceReviewValidatorV1.validate(review,
                selectedMedia: Array(selected.reversed()), executionPlanSHA256: hash("execution"),
                canonSHA256: hash("canon"), referencePlanSHA256: hash("reference"))
        }
    }

    @Test("deterministic review cannot fabricate visual findings")
    func rejectsFabricatedVisualClaim() {
        let selected = [selection("s001", "a")]
        let reel = ReviewReelV1(path: "reviews/sequence/reel.mov", sha256: hash("reel"),
            byteCount: 100, fps: 24, durationFrames: 24,
            edlPath: "reviews/sequence/reel.edl.json", edlSHA256: hash("edl"),
            entries: [entry(selected[0], start: 0, end: 24)])
        let review = SequenceReviewV1(projectID: "fixture", selectedMedia: selected,
            reviewReel: reel, executionPlanSHA256: hash("execution"), canonSHA256: hash("canon"),
            referencePlanSHA256: hash("reference"), adjacentPairCompleted: true,
            wholePlaybackCompleted: true,
            findings: [.init(id: "prop-1", scope: .wholePlayback, category: .stateAndProps,
                severity: .blocking, shotIDs: ["s001"], startFrame: 0, endFrame: 24,
                evidence: "The prop changed.", recommendedAction: .reroll,
                provenance: .init(kind: .deterministicEngine, reviewerID: "metadata/v1"))],
            reviewedAt: "2026-09-09T00:00:00Z")
        #expect(throws: SequenceReviewValidationErrorV1.self) {
            try SequenceReviewValidatorV1.validate(review, selectedMedia: selected,
                executionPlanSHA256: hash("execution"), canonSHA256: hash("canon"),
                referencePlanSHA256: hash("reference"))
        }
    }

    private func selection(_ shot: String, _ suffix: String) -> SelectedShotMediaV1 {
        SelectedShotMediaV1(shotID: shot, sourceKind: .generatedTake,
            sourcePath: "renders/\(suffix).mov", sourceSHA256: hash("source-\(suffix)"),
            sourceByteCount: 100, sourceFPS: 24, sourceStartFrame: 0, sourceEndFrame: 24,
            takeID: hash("take-\(suffix)"), reviewPath: "reviews/\(suffix).json",
            reviewSHA256: hash("review-\(suffix)"))
    }

    private func entry(_ source: SelectedShotMediaV1, start: Int, end: Int) -> ReviewReelEDLEntryV1 {
        ReviewReelEDLEntryV1(shotID: source.shotID, sourcePath: source.sourcePath,
            sourceSHA256: source.sourceSHA256, sourceStartFrame: source.sourceStartFrame,
            sourceEndFrame: source.sourceEndFrame, reelStartFrame: start, reelEndFrame: end,
            transitionIn: .init(kind: .cut))
    }

    private func hash(_ value: String) -> String { FileDigest.sha256(of: Data(value.utf8)) }
}
