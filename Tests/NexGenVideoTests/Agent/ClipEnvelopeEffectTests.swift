import Foundation
import Testing
@testable import NexGenVideo

@Suite("Retained clip envelope is protected from image effect edits")
@MainActor
struct ClipEnvelopeEffectTests {
    @Test func reservedCarrierCannotBeAddedRemovedOrBypassedAsAnEffect() async {
        var clip = Fixtures.clip(id: "clip", start: 0, duration: 100)
        clip.fadeInFrames = 40
        clip = clip.animationWindow(originOffset: 20, duration: 80)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let before = harness.editor.timeline
        let attempts: [[String: Any]] = [
            ["clipIds": ["clip"], "remove": [ClipAnimationEnvelope.effectType]],
            ["clipIds": ["clip"], "effects": [["type": ClipAnimationEnvelope.effectType, "enabled": false]]],
        ]
        for request in attempts {
            #expect(await harness.runRaw("apply_effect", args: request).isError)
            #expect(harness.editor.timeline == before)
        }
    }

    @Test func colorResetRemovesTheGradeAndPreservesEnvelopeAndOtherEffects() async throws {
        var clip = Fixtures.clip(id: "clip", start: 0, duration: 100)
        clip.fadeInFrames = 40
        let untouched = Effect(type: "blur.gaussian", params: ["radius": .init(value: 7), "retained": .init(value: 0.25)])
        clip.effects = [Effect(type: "color.exposure", params: ["ev": .init(value: 1)]), untouched]
        clip = clip.animationWindow(originOffset: 20, duration: 80)
        let before = clip.animationEnvelope
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        _ = try await harness.runOK("apply_color", args: ["clipIds": ["clip"], "reset": true])
        let result = harness.editor.timeline.tracks[0].clips[0]
        #expect(result.animationEnvelope == before)
        #expect(result.effects?.contains(where: { $0.type.hasPrefix("color.") }) == false)
        #expect(result.effects?.first(where: { $0.type == untouched.type }) == untouched)
    }
}
