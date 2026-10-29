import Foundation
import Testing
@testable import NexGenEngine

@Suite("Production planning v2")
struct ProductionPlanningV1Tests {
    private let shotID = "shot-00000000-0000-0000-0000-000000000001"
    private let projectID = "planning-fixture"

    @Test func rationalTimebaseRejectsUnrepresentableFramesAndOverflow() throws {
        try RationalTimebaseV1(ticksPerSecond: 24_000, fpsNumerator: 24_000, fpsDenominator: 1_001).validate()
        #expect(throws: ProductionPlanningError.self) {
            try RationalTimebaseV1(ticksPerSecond: 24, fpsNumerator: 25).validate()
        }
        #expect(throws: ProductionPlanningError.self) {
            try RationalTimebaseV1(ticksPerSecond: 24, fpsNumerator: 24, fpsDenominator: Int64.max).validate()
        }
        #expect(throws: ProductionPlanningError.self) {
            try PlanningValidation.end(start: Int64.max, duration: 1)
        }
    }

    @Test func threeMomentsRemainOneShotWithHalfOpenBoundaries() throws {
        let timing = timing(moments: [moment("m1", at: 0), moment("m2", at: 24), moment("m3", at: 48)])
        try validate(timing)
        #expect(timing.shots.count == 1)
        #expect(timing.activeShot(at: 0)?.id == shotID)
        #expect(timing.activeShot(at: 71)?.id == shotID)
        #expect(timing.activeShot(at: 72) == nil)
        #expect(timing.activeMoment(shotID: shotID, at: 23)?.id == "m1")
        #expect(timing.activeMoment(shotID: shotID, at: 24)?.id == "m2")
        #expect(timing.activeMoment(shotID: shotID, at: 48)?.id == "m3")
        #expect(timing.activeMoment(shotID: shotID, at: 72) == nil)
    }

    @Test func draftCanBeEmptyButVisualApprovalCannot() throws {
        try validate(timing(moments: []))
        #expect(throws: ProductionPlanningError.self) {
            try validate(timing(moments: []), requireVisuals: true)
        }
        #expect(throws: ProductionPlanningError.self) {
            try validate(timing(moments: [moment("missing", at: 0)]), requireVisuals: true)
        }
    }

    @Test func duplicateAndOutsideMomentsAreRejected() throws {
        for moments in [[moment("m1", at: 0), moment("m2", at: 0)],
                        [moment("m1", at: 0), moment("m2", at: 72)],
                        [moment("m1", at: 1)],
                        [moment("same", at: 0), moment("same", at: 24)]] {
            #expect(throws: ProductionPlanningError.self) { try validate(timing(moments: moments)) }
        }
    }

    @Test func storyAdaptationCannotInventOrOmitTreatmentBeats() throws {
        let invalid = StoryboardCausalityV2(header: header(), bindings: [
            .init(stepID: "step-a", beatIDs: ["invented"], reason: "Unapproved cause"),
        ])
        #expect(throws: ProductionPlanningError.self) {
            try StoryboardValidatorV2.validate(board(), causality: invalid, script: script())
        }
        let missing = StoryboardCausalityV2(header: header(), bindings: [])
        #expect(throws: ProductionPlanningError.self) {
            try StoryboardValidatorV2.validate(board(), causality: missing, script: script())
        }
    }

    @Test func draftCannotSilentlyChangeApprovedSketchFraming() throws {
        let value = timing(moments: [])
        let wrong = ShotPlanningDraftV1(header: header(), storyboardRevision: 1, shots: [
            .init(shotID: shotID, sourceMode: .generated,
                camera: .init(framing: .init(scale: "close-up", composition: "face", cameraView: "front"), movement: .static),
                obligations: []),
        ])
        #expect(throws: ProductionPlanningError.self) {
            try ShotPlanningValidatorV1.validate(wrong, timing: value)
        }
        let matching = ShotPlanningDraftV1(header: header(), storyboardRevision: 1, shots: [
            .init(shotID: shotID, sourceMode: .generated, camera: .init(framing: framing(), movement: .static), obligations: []),
        ])
        try ShotPlanningValidatorV1.validate(matching, timing: value)
    }

    @Test func importedDraftMustDeclareARealSourceOrRequiredSourceObligation() throws {
        let absent = ShotPlanningDraftV1(header: header(), storyboardRevision: 1, shots: [
            .init(shotID: shotID, sourceMode: .imported, camera: .init(framing: framing(), movement: .static), obligations: []),
        ])
        #expect(throws: ProductionPlanningError.self) {
            try ShotPlanningValidatorV1.validate(absent, timing: timing(moments: []))
        }
        let planned = ShotPlanningDraftV1(header: header(), storyboardRevision: 1, shots: [
            .init(shotID: shotID, sourceMode: .imported, sourceObligationID: "source",
                camera: .init(framing: framing(), movement: .static), obligations: [
                    .init(id: "source", kind: .sourceFootage, subject: "Performance", requirement: "Assign the recorded performance", required: true),
                ]),
        ])
        try ShotPlanningValidatorV1.validate(planned, timing: timing(moments: []))
    }

    @Test func existingShotIdentityCannotBeReassigned() throws {
        let first = identity()
        let second = StoryboardIdentityV1(header: header(revision: 2), entries: [
            .init(shotID: shotID, primaryStepID: "step-a", actionSHA256: String(repeating: "0", count: 64), introducedRevision: 1),
        ])
        #expect(throws: ProductionPlanningError.self) {
            try StoryboardBundleValidator.validate(storyboard: board(revision: 2),
                causality: causality(revision: 2), timing: timing(moments: [], revision: 2),
                identity: second, script: script(), priorIdentity: first, requireVisuals: false)
        }
    }

    private func header(revision: Int = 1) -> PlanningArtifactHeaderV1 {
        .init(projectID: projectID, revision: revision, origin: .agentProposal, inputs: [])
    }

    private func script() -> ScriptV1 {
        .init(header: header(), summary: "A crossing", scenes: [
            .init(id: "scene-a", title: "Crossing", adaptation: "The approved crossing", events: [
                .init(id: "event-a", action: "The figure crosses the room", treatmentBeatIDs: ["beat-a"]),
            ]),
        ])
    }

    private func board(revision: Int = 1) -> StoryboardV2 {
        .init(header: header(revision: revision), summary: "One shot", steps: [
            .init(id: "step-a", sceneID: "scene-a", eventIDs: ["event-a"], function: .story, action: "The figure crosses the room"),
        ])
    }

    private func causality(revision: Int = 1) -> StoryboardCausalityV2 {
        .init(header: header(revision: revision), bindings: [.init(stepID: "step-a", beatIDs: ["beat-a"], reason: "Show the crossing")])
    }

    private func framing() -> StoryboardTimingV1.FramingIntent {
        .init(scale: "wide", composition: "Figure left, doorway right", cameraView: "eye-level front")
    }

    private func moment(_ id: String, at tick: Int64) -> StoryboardTimingV1.Moment {
        .init(id: id, offsetTicks: tick, intent: "The figure at \(tick)")
    }

    private func timing(moments: [StoryboardTimingV1.Moment], revision: Int = 1) -> StoryboardTimingV1 {
        .init(header: header(revision: revision), timebase: .init(ticksPerSecond: 24, fpsNumerator: 24),
            mode: .generic, rangeDurationTicks: 72, shots: [
                .init(id: shotID, primaryStepID: "step-a", startTicks: 0, durationTicks: 72, framing: framing(), moments: moments),
            ])
    }

    private func identity() -> StoryboardIdentityV1 {
        .init(header: header(), entries: [.init(shotID: shotID, primaryStepID: "step-a",
            actionSHA256: FileDigest.sha256(of: Data("The figure crosses the room".utf8)), introducedRevision: 1)])
    }

    private func validate(_ timing: StoryboardTimingV1, requireVisuals: Bool = false) throws {
        try StoryboardBundleValidator.validate(storyboard: board(), causality: causality(), timing: timing,
            identity: identity(), script: script(), requireVisuals: requireVisuals)
    }
}
