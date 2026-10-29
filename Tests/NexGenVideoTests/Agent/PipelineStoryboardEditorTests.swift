import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
struct PipelineStoryboardEditorTests {
    @Test func splitPreservesHeadIdentityAndRequiresExplicitTailImageAssignment() throws {
        let state = fixture()
        let plan = try PipelineStoryboardEditor.preview(.split(shotID: firstID, offsetTicks: 48), state: state)
        #expect(plan.state.timing.shots.count == 3)
        #expect(plan.state.timing.shots[0].id == firstID)
        #expect(plan.state.timing.shots[0].durationTicks == 48)
        #expect(plan.state.timing.shots[0].moments[0].asset != nil)
        #expect(plan.state.timing.shots[1].id != firstID)
        #expect(plan.state.timing.shots[1].startTicks == 48)
        #expect(plan.state.timing.shots[1].moments[0].offsetTicks == 0)
        #expect(plan.state.timing.shots[1].moments.allSatisfy { $0.asset == nil })
        #expect(plan.identities.count == 1)
        #expect(plan.assignments.isEmpty)
    }

    @Test func duplicateDoesNotClaimTheOriginalSketchProof() throws {
        let plan = try PipelineStoryboardEditor.preview(.duplicate(shotID: firstID, startTicks: 48), state: fixture())
        let duplicate = try #require(plan.state.timing.shots.first { $0.id != firstID && $0.id != secondID })
        #expect(duplicate.moments.allSatisfy { $0.asset == nil })
        #expect(duplicate.moments[0].id != "moment-first")
        #expect(plan.state.timing.shots.first { $0.id == secondID }?.startTicks == 96)
    }

    @Test func timingEditLeavesNeighbouringCutsUnchanged() throws {
        let plan = try PipelineStoryboardEditor.preview(.setTiming(shotID: firstID, startTicks: 0, durationTicks: 72), state: fixture())
        #expect(plan.state.timing.shots[0].durationTicks == 72)
        #expect(plan.state.timing.shots[1].startTicks == 96)
        #expect(throws: PipelineStoryboardEditor.EditError.self) {
            try PipelineStoryboardEditor.preview(.setTiming(shotID: firstID, startTicks: 1, durationTicks: 48), state: fixture())
        }
        #expect(throws: PipelineStoryboardEditor.EditError.self) {
            try PipelineStoryboardEditor.preview(.setDuration(shotID: secondID, durationTicks: 200), state: fixture())
        }
    }

    @Test func removingTheOnlyShotForAStoryStepFails() throws {
        #expect(throws: PipelineStoryboardEditor.EditError.self) {
            try PipelineStoryboardEditor.preview(.delete(shotID: firstID), state: fixture())
        }
    }

    @Test func framingOrIntentRevisionClearsOnlyAffectedProof() throws {
        let framing = StoryboardTimingV1.FramingIntent(scale: "close", composition: "centred", cameraView: "eye level")
        let plan = try PipelineStoryboardEditor.preview(.setFraming(shotID: firstID, framing: framing), state: fixture())
        #expect(plan.state.timing.shots[0].moments.allSatisfy { $0.asset == nil })
        #expect(plan.state.timing.shots[1].moments[0].asset != nil)
        let intent = try PipelineStoryboardEditor.preview(.setMomentIntent(shotID: firstID, momentID: "moment-first", intent: "Turn to the door"), state: fixture())
        #expect(intent.state.timing.shots[0].moments[0].asset == nil)
        #expect(intent.state.timing.shots[0].moments[1].asset != nil)
    }

    @Test func replacingPrimaryActionRetiresItsShotIdentity() throws {
        let step = StoryboardV2.StoryStep(id: "step-a", sceneID: "scene", eventIDs: ["event-a"], function: .story, action: "Leaves")
        let plan = try PipelineStoryboardEditor.preview(.replaceStep(step, binding: .init(stepID: "step-a", beatIDs: ["beat-a"], reason: "Direct adaptation")), state: fixture())
        #expect(plan.state.timing.shots[0].id != firstID)
        #expect(plan.state.timing.shots[0].moments.allSatisfy { $0.asset == nil })
        #expect(plan.state.timing.shots[1].id == secondID)
    }

    @Test func momentOrderUsesExistingOffsetsAndRejectsMissingStartingMoment() throws {
        let plan = try PipelineStoryboardEditor.preview(.reorderMoments(shotID: firstID, momentIDs: ["moment-second", "moment-first"]), state: fixture())
        #expect(plan.state.timing.shots[0].moments.map(\.id) == ["moment-second", "moment-first"])
        #expect(plan.state.timing.shots[0].moments.map(\.offsetTicks) == [0, 48])
        #expect(throws: PipelineStoryboardEditor.EditError.self) {
            try PipelineStoryboardEditor.preview(.setMomentOffset(shotID: firstID, momentID: "moment-first", offsetTicks: 4), state: fixture())
        }
    }

    @Test func explicitImageSelectionIsASeparateNativeAssignment() throws {
        let asset = try #require(fixture().timing.shots[0].moments[0].asset)
        let plan = try PipelineStoryboardEditor.preview(.assignExistingSketch(shotID: secondID, momentID: "moment-third", asset: asset), state: fixture())
        #expect(plan.assignments.count == 1)
        #expect(plan.assignments[0].shotID == secondID)
        #expect(plan.state.timing.shots[1].moments[0].asset == nil)
    }

    @Test func undoRestorationNeverReusesRetiredIdentityOrOldAssignmentProof() throws {
        let state = fixture()
        let identity = StoryboardIdentityV1(header: .init(projectID: state.timing.header.projectID,
            revision: 2, origin: .userRevision, inputs: []), entries: [
            .init(shotID: firstID, primaryStepID: "step-a", actionSHA256: FileDigest.sha256(of: Data("Enters".utf8)), introducedRevision: 1, retiredRevision: 2),
            .init(shotID: secondID, primaryStepID: "step-b", actionSHA256: FileDigest.sha256(of: Data("Waits".utf8)), introducedRevision: 1)])
        let plan = try PipelineStoryboardEditor.restoration(state, identity: identity)
        #expect(plan.state.timing.shots[0].id != firstID)
        #expect(plan.state.timing.shots[1].id == secondID)
        #expect(plan.identities.count == 1)
        #expect(plan.assignments.count == 3)
        #expect(plan.state.timing.shots.flatMap(\.moments).allSatisfy { $0.asset == nil })
        #expect(plan.assignments[0].shotID == plan.state.timing.shots[0].id)
    }

    @Test func nativeMomentCanRepairAnEmptyDraftShot() throws {
        var state = fixture()
        let shot = state.timing.shots[0]
        state.timing = .init(header: state.timing.header, timebase: state.timing.timebase, mode: .generic,
            rangeDurationTicks: state.timing.rangeDurationTicks,
            shots: [.init(id: shot.id, primaryStepID: shot.primaryStepID, startTicks: shot.startTicks,
                durationTicks: shot.durationTicks, framing: shot.framing, moments: []), state.timing.shots[1]])
        let plan = try PipelineStoryboardEditor.preview(.insertMoment(shotID: firstID, offsetTicks: 0, intent: "Enter"), state: state)
        #expect(plan.state.timing.shots[0].moments.count == 1)
    }

    private var firstID: String { "shot-00000000-0000-0000-0000-000000000001" }
    private var secondID: String { "shot-00000000-0000-0000-0000-000000000002" }

    private func fixture() -> PipelineStoryboardEditor.State {
        let hash = String(repeating: "a", count: 64)
        let asset = StoryboardTimingV1.SketchAsset(image: .init(id: "image", role: "sketch", path: "storyboard/sketches/image.png", sha256: hash),
            proof: .init(id: "proof", role: "proof", path: "storyboard/proofs/image.json", sha256: hash))
        let framing = StoryboardTimingV1.FramingIntent(scale: "wide", composition: "centred", cameraView: "eye level")
        return .init(summary: "Story", steps: [
            .init(id: "step-a", sceneID: "scene", eventIDs: ["event-a"], function: .story, action: "Enters"),
            .init(id: "step-b", sceneID: "scene", eventIDs: ["event-b"], function: .story, action: "Waits")],
            bindings: [.init(stepID: "step-a", beatIDs: ["beat-a"], reason: "Direct adaptation"),
                       .init(stepID: "step-b", beatIDs: ["beat-b"], reason: "Direct adaptation")],
            timing: .init(header: .init(projectID: "Fixture", revision: 1, origin: .userRevision, inputs: []),
                timebase: .init(ticksPerSecond: 48, fpsNumerator: 24), mode: .generic, rangeDurationTicks: 192,
                shots: [.init(id: firstID, primaryStepID: "step-a", startTicks: 0, durationTicks: 96, framing: framing,
                    moments: [.init(id: "moment-first", offsetTicks: 0, intent: "Enter", asset: asset),
                              .init(id: "moment-second", offsetTicks: 48, intent: "Look", asset: asset)]),
                        .init(id: secondID, primaryStepID: "step-b", startTicks: 96, durationTicks: 96, framing: framing,
                    moments: [.init(id: "moment-third", offsetTicks: 0, intent: "Wait", asset: asset)])]))
    }
}
