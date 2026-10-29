import Foundation
import Testing
@testable import NexGenEngine

struct ProductionSequenceReviewV2Tests {
    @Test func actualFilmReviewRequiresSeparateCutAndWholePlaybackObservations() throws {
        let value = fixture()
        try value.review.validate(edl: value.edl, shotIDs: ["shot"], rejectBlocking: true)
        for flags in [(false, true), (true, false)] {
            #expect(throws: ProductionPlanningError.self) {
                try fixture(adjacent: flags.0, whole: flags.1).review.validate(edl: value.edl, shotIDs: ["shot"], rejectBlocking: true)
            }
        }
    }

    @Test func blockingObservedFindingCanBeRecordedButCannotPassDelivery() throws {
        let finding = SequenceReviewFindingV1(id: "native-observation", scope: .adjacentPair, category: .audio,
            severity: .blocking, shotIDs: ["shot"], startFrame: 20, endFrame: 30, evidence: "The sound drops at the cut.",
            recommendedAction: .localRepair, provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review"))
        let value = fixture(findings: [finding])
        try value.review.validate(edl: value.edl, shotIDs: ["shot"], rejectBlocking: false)
        #expect(throws: ProductionPlanningError.invalid("sequenceReview.blocking")) {
            try value.review.validate(edl: value.edl, shotIDs: ["shot"], rejectBlocking: true)
        }
    }

    @Test func aNativeFindingResolutionRetainsTheOriginalEvidenceAndRequiresAReason() throws {
        let finding = SequenceReviewFindingV1(id: "opening", scope: .wholePlayback, category: .visualArtifact,
            severity: .blocking, shotIDs: ["shot"], startFrame: 0, endFrame: 10, evidence: "The opening is obscured.",
            recommendedAction: .localRepair, provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review"))
        let value = fixture(findings: [finding], resolutions: [.init(findingID: finding.id,
            reason: "The native reinspection confirms this intentional occlusion. Keep the original observation in history.")])
        try value.review.validate(edl: value.edl, shotIDs: ["shot"], rejectBlocking: true)
        #expect(value.review.findings == [finding])
        let invalid = fixture(findings: [finding], resolutions: [.init(findingID: finding.id, reason: " ")])
        #expect(throws: ProductionPlanningError.self) {
            try invalid.review.validate(edl: invalid.edl, shotIDs: ["shot"], rejectBlocking: true)
        }
    }

    @Test func aPlannedModelOrTechnicalCheckCannotPretendToHaveWatchedTheFilm() throws {
        for kind in [SequenceReviewerKindV1.model, .deterministicEngine] {
            let finding = SequenceReviewFindingV1(id: "observation", scope: .wholePlayback, category: .identity,
                severity: .info, shotIDs: ["shot"], startFrame: 0, endFrame: 20, evidence: "Identity is correct.",
                recommendedAction: .accept, provenance: .init(kind: kind, reviewerID: "native-sequence-review"))
            let value = fixture(findings: [finding])
            #expect(throws: ProductionPlanningError.self) {
                try value.review.validate(edl: value.edl, shotIDs: ["shot"], rejectBlocking: false)
            }
        }
    }

    @Test func cutFindingMustActuallyIntersectTheObservedCut() throws {
        let finding = SequenceReviewFindingV1(id: "wrong-range", scope: .adjacentPair, category: .actionAndTransition,
            severity: .warning, shotIDs: ["shot"], startFrame: 0, endFrame: 10, evidence: "The hand jumps.",
            recommendedAction: .localRepair, provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review"))
        let value = fixture(findings: [finding])
        #expect(throws: ProductionPlanningError.invalid("sequenceReview.cutFinding")) {
            try value.review.validate(edl: value.edl, shotIDs: ["shot"], rejectBlocking: false)
        }
    }

    @Test func exactPartialSongEndUsesVisualCoverageWithoutChangingCanonicalTicks() throws {
        let value = fixture(duration: 1_001)
        #expect(value.review.durationFrames == 51)
        #expect(value.edl.outputDurationTicks == 1_001)
        try value.review.validate(edl: value.edl, shotIDs: ["shot"], rejectBlocking: true)
    }

    @Test func requiredMusicRoleCannotBeReplacedByWholeFilmCheckbox() throws {
        let value = fixture()
        let role = ProductionMusicCoverageRequirementV2(id: "dance.full-body", roleID: "full-body", shotIDs: ["shot"],
            checks: ["Full body and floor contact remain visible."], minimumContinuousSeconds: 0.5)
        #expect(throws: ProductionPlanningError.invalid("sequenceReview.musicCoverageMissing")) {
            try value.review.validate(edl: value.edl, shotIDs: ["shot"], rejectBlocking: true, musicRequirements: [role])
        }
    }

    @Test func actualMusicObservationCanRecordMissingVisibilityButDeliveryRemainsBlocked() throws {
        let value = fixture()
        let role = ProductionMusicCoverageRequirementV2(id: "hands", roleID: "hands", shotIDs: ["shot"],
            checks: ["The hands remain visible."], minimumContinuousSeconds: 1)
        let observation = ProductionMusicCoverageObservationV2(id: "hands", visible: false, startFrame: 0, endFrame: 30,
            evidence: "An overlay hides the hands in the actual edited picture.")
        try ProductionMusicCoverageObservationV2.validate([observation], requirements: [role], edl: value.edl,
            durationFrames: 60, rejectBlocking: false)
        #expect(throws: ProductionPlanningError.invalid("sequenceReview.musicCoverageNotVisible")) {
            try ProductionMusicCoverageObservationV2.validate([observation], requirements: [role], edl: value.edl,
                durationFrames: 60, rejectBlocking: true)
        }
    }

    @Test func nativeMusicVisibilityMustCoverItsDeclaredContinuousInterval() throws {
        let value = fixture()
        let role = ProductionMusicCoverageRequirementV2(id: "mouth", roleID: "mouth", shotIDs: ["shot"],
            checks: ["Check the visible mouth."], minimumContinuousSeconds: 1)
        for frames in [15, 30] {
            let observation = ProductionMusicCoverageObservationV2(id: "mouth", visible: true, startFrame: 0, endFrame: frames,
                evidence: "The intended singer and mouth remain visible and aligned throughout this interval.")
            if frames == 15 {
                #expect(throws: ProductionPlanningError.invalid("sequenceReview.musicContinuousCoverage")) {
                    try ProductionMusicCoverageObservationV2.validate([observation], requirements: [role], edl: value.edl,
                        durationFrames: 60, rejectBlocking: true)
                }
            } else {
                try ProductionMusicCoverageObservationV2.validate([observation], requirements: [role], edl: value.edl,
                    durationFrames: 60, rejectBlocking: true)
            }
        }
    }

    private func fixture(adjacent: Bool = true, whole: Bool = true, findings: [SequenceReviewFindingV1] = [],
                         resolutions: [ProductionSequenceReviewV2.FindingResolution] = [], duration: Int64 = 1_200) -> (review: ProductionSequenceReviewV2, edl: ProductionSequenceEDLV2) {
        let source = ref("source", "reviews/sequence/sources/source.mov")
        let timeline = ref("timeline", "reviews/sequence/reels/example/timeline.v2.json")
        let edl = ProductionSequenceEDLV2(projectID: "film", timelineSHA256: timeline.sha256,
            timebase: .init(ticksPerSecond: 600, fpsNumerator: 30), outputStartTicks: 0, outputDurationTicks: duration,
            clips: [.init(trackID: "video", clipID: "clip", shotID: "shot", mediaID: "media", source: source,
                startFrame: 0, durationFrames: 60, sourceStartFrame: 12, speed: 1)], cutFrames: [24])
        let review = ProductionSequenceReviewV2(projectID: "film", assembly: ref("assembly", "execution/assembly.json"),
            projection: ref("projection", "execution/production.json"), inputFingerprint: String(repeating: "1", count: 64),
            timeline: timeline, edl: ref("edl", "reviews/sequence/reels/example/edl.v2.json"),
            reel: ref("reel", "reviews/sequence/reels/example/film.mp4"), reelByteCount: 200,
            durationFrames: Int((duration + 19) / 20), cutFrames: [24], inputs: [source], adjacentPairCompleted: adjacent,
            wholePlaybackCompleted: whole, findings: findings, reviewedAt: "2026-10-18T12:00:00Z", findingResolutions: resolutions)
        return (review, edl)
    }

    private func ref(_ id: String, _ path: String) -> CanonicalArtifactReferenceV1 {
        .init(id: id, role: "test", path: path, sha256: String(repeating: "0", count: 64))
    }
}
