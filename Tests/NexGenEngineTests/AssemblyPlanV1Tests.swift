import Foundation
import Testing
@testable import NexGenEngine

@Suite("Assembly plan V1")
struct AssemblyPlanV1Tests {
    @Test("two shots may bind separate reviewed ranges from one take")
    func reviewedRangesRemainDistinct() throws {
        let policy = AssemblyPolicyV1(
            id: "fixture.freeform",
            version: "1.0.0",
            timing: .freeform,
            timelineFPS: 24
        )
        let source = hash("source")
        let selected = [
            selection(shot: "s001", source: source, start: 0, end: 48, review: hash("review-a")),
            selection(shot: "s002", source: source, start: 60, end: 108, review: hash("review-b")),
        ]
        let placements = [
            AssemblyPlacementV1(shotID: "s001", trackID: "v1", timelineStartFrame: 0,
                sourceStartFrame: 0, sourceEndFrame: 48),
            AssemblyPlacementV1(shotID: "s002", trackID: "v1", timelineStartFrame: 48,
                sourceStartFrame: 60, sourceEndFrame: 108,
                transitionIn: .init(kind: .dissolve, durationFrames: 4)),
        ]
        let plan = AssemblyPlanV1(projectID: "fixture", phase: "render", selectedMedia: selected,
            placements: placements, existingRegionFingerprint: hash("old-region"),
            policyPath: "pack/assembly-policy.json", policySHA256: hash("policy"))
        try AssemblyValidatorV1.validate(plan: plan, policy: policy)

        #expect(plan.selectedMedia[0].sourceSHA256 == plan.selectedMedia[1].sourceSHA256)
        #expect(plan.selectedMedia[0].reviewSHA256 != plan.selectedMedia[1].reviewSHA256)
        #expect(plan.placements[0].sourceStartFrame != plan.placements[1].sourceStartFrame)
    }

    @Test("manifest binds exact plan, policy and timeline")
    func manifestBinding() throws {
        let policy = AssemblyPolicyV1(id: "fixture.freeform", version: "1.0.0",
            timing: .freeform, timelineFPS: 24)
        let selected = [selection(shot: "s001", source: hash("source"), start: 0, end: 48,
            review: hash("review"))]
        let placements = [AssemblyPlacementV1(shotID: "s001", trackID: "v1",
            timelineStartFrame: 0, sourceStartFrame: 0, sourceEndFrame: 48)]
        let plan = AssemblyPlanV1(projectID: "fixture", phase: "render", selectedMedia: selected,
            placements: placements, existingRegionFingerprint: nil,
            policyPath: "pack/assembly-policy.json", policySHA256: hash("policy"))
        let manifest = AssemblyManifestV1(projectID: "fixture", phase: "render",
            planSHA256: hash("plan"), policyID: policy.id, policyVersion: policy.version,
            policySHA256: plan.policySHA256, priorRegionFingerprint: nil,
            appliedRegionFingerprint: hash("region"), timelineFingerprint: hash("timeline"),
            idempotencyKey: hash("idempotency"),
            placements: [.init(selected: selected[0], placement: placements[0], clipIDs: ["clip-1"])])
        try AssemblyValidatorV1.validate(manifest: manifest, plan: plan,
            planSHA256: hash("plan"), policy: policy)
        #expect(throws: AssemblyValidationErrorV1.self) {
            try AssemblyValidatorV1.validate(manifest: manifest, plan: plan,
                planSHA256: hash("changed-plan"), policy: policy)
        }
    }

    private func selection(shot: String, source: String, start: Int, end: Int, review: String) -> SelectedShotMediaV1 {
        SelectedShotMediaV1(shotID: shot, sourceKind: .reviewedTakeRange,
            sourcePath: "renders/take.mov", sourceSHA256: source, sourceByteCount: 256,
            sourceFPS: 24, sourceStartFrame: start, sourceEndFrame: end,
            takeID: hash("take"), reviewPath: "renders/coverage/\(review).v1.json", reviewSHA256: review)
    }

    private func hash(_ value: String) -> String { FileDigest.sha256(of: Data(value.utf8)) }
}
