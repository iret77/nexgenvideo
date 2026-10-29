import Foundation
import Testing
@testable import NexGenEngine

@Suite("Production projection and render review")
struct ProductionProjectionReviewV1Tests {
    private let shotID = "shot-00000000-0000-0000-0000-000000000001"

    @Test func importedProjectionUsesUUIDWithoutInventedFrames() throws {
        let value = projection()
        try ProductionPlanProjectionValidatorV1.validate(value)
        #expect(value.shots.first?.id == shotID)
        #expect(value.requiredFrameRoles(for: shotID).isEmpty)
        #expect(value.source(for: shotID)?.path == "import/source.mov")
        #expect(try value.timing(for: shotID)?.endTicks() == 72)
    }

    @Test func nativeTrimCannotExceedActualGeneration() throws {
        #expect(throws: ProductionPlanningError.self) {
            try ProductionPlanProjectionValidatorV1.validate(projection(nativeDuration: 80, sourceIn: 9))
        }
        try ProductionPlanProjectionValidatorV1.validate(projection(nativeDuration: 80, sourceIn: 8))
        #expect(throws: ProductionPlanningError.self) {
            try ProductionPlanProjectionValidatorV1.validate(projection(sourceIn: 1))
        }
    }

    @Test func reviewCannotWaiveStructuralOrUnknownStateFindings() throws {
        for kind in [RenderReviewV1.Finding.Kind.structuralError, .unresolved] {
            let blocker = RenderReviewV1.Finding(id: "blocker", kind: kind, category: .stateAndProps,
                shotIDs: [shotID], message: "The source state is unresolved", evidence: [source()])
            #expect(throws: ProductionPlanningError.self) {
                try RenderReviewValidatorV1.validate(review(findings: [blocker]), projection: projection(), approval: true)
            }
            let fakeAcceptance = RenderReviewV1.Finding(id: "fake", kind: kind, category: .stateAndProps,
                shotIDs: [shotID], message: "Structural issue", evidence: [source()],
                acceptance: reference("receipt", path: "render-review/receipts/receipt.json"), acceptanceReason: "Ignore it")
            #expect(throws: ProductionPlanningError.self) {
                try RenderReviewValidatorV1.validate(review(findings: [fakeAcceptance]), projection: projection())
            }
        }
    }

    @Test func importedReviewNeedsTheActualSourceAndNoGenerationPackage() throws {
        try RenderReviewValidatorV1.validate(review(), projection: projection(), approval: true)
        let sourceMissing = RenderReviewV1(header: header(inputs: [planReference()]), productionPlan: planReference(),
            reviewer: .init(kind: .nativeUser, reviewerID: "fixture"), reviewEvidence: reference("review", path: "render-review/evidence.json"),
            shots: [.init(shotID: shotID, evidence: [reference("other", path: "import/other.mov")])], findings: [])
        #expect(throws: ProductionPlanningError.self) {
            try RenderReviewValidatorV1.validate(sourceMissing, projection: projection(), approval: true)
        }
    }

    @Test func renderReadinessFailsClosedWithoutHostEvidenceVerifier() throws {
        #expect(throws: ProductionPlanningError.invalid("renderReview.hostEvidenceVerifier")) {
            try review().requireCurrentEvidence(dataRoot: URL(fileURLWithPath: "/unused"), projection: projection())
        }
    }

    @Test func audioOffsetHasOneSignedSourceMapping() throws {
        let delayed = StoryboardTimingV1.AudioBinding(source: source(), offsetTicks: 24, durationTicks: 72)
        #expect(delayed.sourceTick(atTimelineTick: 23) == nil)
        #expect(delayed.sourceTick(atTimelineTick: 24) == 0)
        #expect(delayed.sourceTick(atTimelineTick: 95) == 71)
        #expect(delayed.sourceTick(atTimelineTick: 96) == nil)
        let early = StoryboardTimingV1.AudioBinding(source: source(), offsetTicks: -24, durationTicks: 72)
        #expect(early.sourceTick(atTimelineTick: 0) == 24)
        #expect(early.sourceTick(atTimelineTick: Int64.max) == nil)
    }

    @Test func submissionPreservesRepeatedAssetBindingsAndTheirOrder() throws {
        let base = projection(nativeDuration: 72), original = base.shots[0]
        let generated = ExecutionShotV1(id: shotID, sourceMode: .generated, startState: original.startState,
            endState: original.endState, primaryAction: original.primaryAction, camera: original.camera,
            renderability: original.renderability, acceptance: original.acceptance,
            generationRequirement: .init(modalityID: "video", modeIDs: ["text-to-video"], visibleEntityCount: 0))
        let plan = ProductionPlanProjectionV1(header: base.header, timebase: base.timebase, mode: base.mode,
            executionPlan: .init(id: "execution", projectID: "fixture", creativeContext: base.executionPlan.creativeContext, shots: [generated]),
            timings: base.timings, sourceBindings: [], draftReference: base.draftReference,
            storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings)
        let identity = CanonicalArtifactReferenceV1(id: "shared-asset", role: "identity", path: "bible/shared.png", sha256: String(repeating: "0", count: 64))
        let style = CanonicalArtifactReferenceV1(id: identity.id, role: "style", path: identity.path, sha256: identity.sha256)
        let prompt = reference("prompt", path: "execution/compiled/prompt.json")
        let route = reference("route", path: "execution/planning/v1/route.json")
        let reviewed = RenderReviewV1(header: header(inputs: [planReference()]), productionPlan: planReference(),
            reviewer: .init(kind: .nativeUser, reviewerID: "fixture"), reviewEvidence: reference("evidence", path: "render-review/evidence.json"),
            shots: [.init(shotID: shotID, evidence: [identity], compiledPrompt: prompt,
                promptIRSHA256: String(repeating: "0", count: 64), route: route, conditioning: [identity, style])], findings: [])
        let reviewReference = reference("review", path: RenderReviewV1.versionPath(1))
        let submission = RenderSubmissionBindingV1(projectID: "fixture", requestID: "request", shotID: shotID,
            review: reviewReference, compiledPrompt: prompt, route: route, promptIRSHA256: String(repeating: "0", count: 64), inputs: [identity, style])
        try submission.validate(review: reviewed, projection: plan)
        let reordered = RenderSubmissionBindingV1(projectID: "fixture", requestID: "request", shotID: shotID,
            review: reviewReference, compiledPrompt: prompt, route: route, promptIRSHA256: String(repeating: "0", count: 64), inputs: [style, identity])
        #expect(throws: ProductionPlanningError.self) { try reordered.validate(review: reviewed, projection: plan) }
    }

    @Test func sourceMediaClockHasNoFrameRateClaim() throws {
        let clock = SourceMediaTimebaseV1(ticksPerSecond: 90_000)
        try clock.validate()
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clock)) as? [String: Any])
        #expect(Set(object.keys) == ["ticksPerSecond"])
        #expect(clock.seconds(for: 3_003) == 3_003.0 / 90_000.0)
        #expect(throws: ProductionPlanningError.self) { try SourceMediaTimebaseV1(ticksPerSecond: 0).validate() }
    }

    @Test func sourceFrameMustLieInsideItsSourceDuration() throws {
        let image = reference("image", path: "storyboard/sketches/image.png")
        let proof = StoryboardSketchProofV1(projectID: "fixture", shotID: shotID, momentID: "moment",
            intentSHA256: String(repeating: "0", count: 64), framingSHA256: String(repeating: "0", count: 64), image: image,
            source: .sourceFrame(video: source(), timebase: .init(ticksPerSecond: 24),
                                 sourceTick: 72, sourceDurationTicks: 72, selectionReceiptID: "host-receipt"))
        #expect(throws: ProductionPlanningError.self) { try proof.validate() }
    }

    private func reference(_ id: String, path: String) -> CanonicalArtifactReferenceV1 {
        .init(id: id, role: "core.fixture", path: path, sha256: String(repeating: "0", count: 64))
    }

    private func source() -> CanonicalArtifactReferenceV1 { reference("source", path: "import/source.mov") }
    private func planReference() -> CanonicalArtifactReferenceV1 { reference("plan", path: ProductionPlanProjectionV1.versionPath(1)) }

    private func header(inputs: [CanonicalArtifactReferenceV1]) -> PlanningArtifactHeaderV1 {
        .init(projectID: "fixture", revision: 1, origin: .userRevision, inputs: inputs)
    }

    private func projection(nativeDuration: Int64? = nil, sourceIn: Int64 = 0) -> ProductionPlanProjectionV1 {
        let draft = reference("draft", path: ShotPlanningDraftV1.versionPath(1))
        let storyboard = reference("storyboard", path: StoryboardTimingV1.versionPath(1))
        let context = CanonicalArtifactReferenceV1(id: ExecutionPlanV1.creativeContextArtifactID,
            role: ExecutionPlanV1.creativeContextArtifactRole, path: ShotPlanningPromotionV1.creativeContextPath(revision: 1),
            sha256: String(repeating: "0", count: 64))
        let shot = ExecutionShotV1(id: shotID, sourceMode: .imported, sourceAssetID: "source",
            startState: .init(summary: "Start"), endState: .init(summary: "End"), primaryAction: "Use the source",
            camera: .init(movementID: "core.source"), renderability: .green,
            acceptance: [.init(id: "source-acceptance", requirement: "Use the selected footage", severity: "blocking")])
        let execution = ExecutionPlanV1(id: "execution", projectID: "fixture", creativeContext: context, shots: [shot])
        return ProductionPlanProjectionV1(header: header(inputs: [draft, storyboard]),
            timebase: .init(ticksPerSecond: 24, fpsNumerator: 24), mode: .generic, executionPlan: execution,
            timings: [.init(shotID: shotID, startTicks: 0, durationTicks: 72, nativeDurationTicks: nativeDuration, sourceInTicks: sourceIn)],
            sourceBindings: [source()], draftReference: draft, storyboardReference: storyboard,
            editorialBindings: [.init(shotID: shotID, sceneID: "scene")])
    }

    private func review(findings: [RenderReviewV1.Finding] = []) -> RenderReviewV1 {
        .init(header: header(inputs: [planReference()]), productionPlan: planReference(),
            reviewer: .init(kind: .nativeUser, reviewerID: "fixture"), reviewEvidence: reference("review", path: "render-review/evidence.json"),
            shots: [.init(shotID: shotID, evidence: [source()])], findings: findings)
    }
}
