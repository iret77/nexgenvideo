import Foundation
import Testing
@testable import NexGenVideo

@Suite("Native effect keyframe edits preserve animation")
struct EffectKeyframeEditingTests {
    @Test func valuesUseClipTimeAndPreserveUneditedKeysAndInterpolation() {
        var clip = Clip(mediaRef: "source", startFrame: 100, durationFrames: 120)
        ClipEffectAnimation.edit(.stamp, type: "color.exposure", key: "ev", frame: 130, clip: &clip)
        ClipEffectAnimation.setValue(1, type: "color.exposure", key: "ev", frame: 130, clip: &clip)
        ClipEffectAnimation.edit(.stamp, type: "color.exposure", key: "ev", frame: 190, clip: &clip)
        ClipEffectAnimation.setValue(3, type: "color.exposure", key: "ev", frame: 190, clip: &clip)
        ClipEffectAnimation.edit(.interpolate(.linear), type: "color.exposure", key: "ev", frame: 130, clip: &clip)
        #expect(parameter(clip)?.track?.keyframes.map(\.frame) == [30, 90])
        #expect(parameter(clip)?.resolved(at: 60, default: 0) == 2)
        ClipEffectAnimation.setValue(0, type: "color.exposure", key: "ev", frame: 130, clip: &clip)
        #expect(parameter(clip)?.track?.keyframes.count == 2)
        #expect(parameter(clip)?.track?.keyframes[0].interpolationOut == .linear)
        #expect(parameter(clip)?.track?.keyframes[1].value == 3)
        #expect(parameter(clip)?.resolved(at: 60, default: 0) == 1.5)
        let before = clip
        ClipEffectAnimation.setValue(2, type: "color.exposure", key: "ev", frame: 220, clip: &clip)
        #expect(clip == before)
    }

    @Test func neutralOtherParameterNeverPrunesAnAnimatedEffect() {
        var clip = Clip(mediaRef: "source", startFrame: 0, durationFrames: 100)
        ClipEffectAnimation.edit(.stamp, type: "color.temperature", key: "tint", frame: 10, clip: &clip)
        ClipEffectAnimation.setValue(6500, type: "color.temperature", key: "temperature", frame: 10, clip: &clip)
        #expect(clip.effects?.first?.params["tint"]?.track?.keyframes.count == 1)
    }

    @Test func clearAndLastRemovalKeepTheDisplayedValue() {
        var clip = Clip(mediaRef: "source", startFrame: 0, durationFrames: 120)
        ClipEffectAnimation.edit(.stamp, type: "color.exposure", key: "ev", frame: 30, clip: &clip)
        ClipEffectAnimation.setValue(1, type: "color.exposure", key: "ev", frame: 30, clip: &clip)
        ClipEffectAnimation.edit(.stamp, type: "color.exposure", key: "ev", frame: 90, clip: &clip)
        ClipEffectAnimation.setValue(3, type: "color.exposure", key: "ev", frame: 90, clip: &clip)
        ClipEffectAnimation.edit(.clear, type: "color.exposure", key: "ev", frame: 60, clip: &clip)
        #expect(parameter(clip)?.track == nil)
        #expect(parameter(clip)?.value == 2)
        ClipEffectAnimation.edit(.stamp, type: "color.exposure", key: "ev", frame: 60, clip: &clip)
        ClipEffectAnimation.edit(.remove, type: "color.exposure", key: "ev", frame: 60, clip: &clip)
        #expect(parameter(clip)?.track == nil)
        #expect(parameter(clip)?.value == 2)
    }

    @Test func wheelXYEditPreservesBypassAndIdentityAcrossNeutralIntermediateValue() {
        let wheel = Effect(id: "bypassed-wheel", type: "color.wheels", enabled: false,
                           params: ["lift_x": .init(value: 0.5), "lift_y": .init(value: 0)])
        var clip = Clip(mediaRef: "source", startFrame: 100, durationFrames: 120)
        clip.effects = [wheel]
        ClipEffectAnimation.setValues(["lift_x": 0, "lift_y": 0.5], type: "color.wheels", frame: 130, clip: &clip)
        #expect(clip.effects?.first?.id == wheel.id)
        #expect(clip.effects?.first?.enabled == false)
        #expect(clip.effects?.first?.params["lift_x"]?.value == 0)
        #expect(clip.effects?.first?.params["lift_y"]?.value == 0.5)
        ClipEffectAnimation.setValues(["lift_x": 0, "lift_y": 0], type: "color.wheels", frame: 130, clip: &clip)
        #expect(clip.effects?.first?.id == wheel.id && clip.effects?.first?.enabled == false)
    }

    @Test(arguments: [("blur.gaussian", "radius", 10.0), ("blur.sharpen", "amount", 0.8)])
    @MainActor func activeDefaultsAndInspectorResetPreserveValuesAndUndo(type: String, key: String, stronger: Double) throws {
        let descriptor = try #require(EffectRegistry.descriptor(id: type))
        let spec = try #require(descriptor.params.first(where: { $0.key == key }))
        let defaultValue = spec.defaultValue
        let resetValue = EffectInspectorValues.resetValue(type: type, spec: spec)
        #expect(resetValue == 0)
        var clip = Fixtures.clip(id: "effect-reset", start: 0, duration: 120)
        #expect(EffectInspectorValues.value(clip: clip, type: type, spec: spec, frame: 0) == 0)
        var stampedClip = clip
        ClipEffectAnimation.edit(.stamp, type: type, key: key, frame: 0, clip: &stampedClip)
        let stamped = try #require(stampedClip.effects?.first)
        #expect(stamped.params[key]?.track?.keyframes.count == 1)
        #expect(stamped.params[key]?.track?.keyframes.first?.value == 0)
        #expect(descriptor.resolve(stamped, atOffset: 0).value(key) == 0)
        #expect(descriptor.resolve(stamped, atOffset: 60).value(key) == 0)
        var effect = descriptor.makeEffect()
        #expect(effect.params[key]?.value == defaultValue && defaultValue > 0)
        effect.params[key] = .init(value: stronger)
        clip.effects = [effect]
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let undo = UndoManager(); undo.groupsByEvent = false; harness.editor.undoManager = undo
        let original = harness.editor.timeline
        harness.editor.setEffectParameter(clipIDs: [clip.id], type: type, key: key, value: defaultValue, commit: false, action: "Change Effect")
        harness.editor.setEffectParameter(clipIDs: [clip.id], type: type, key: key, value: defaultValue, commit: true, action: "Change Effect")
        let reset = harness.editor.timeline
        let retained = try #require(harness.editor.clipFor(id: clip.id)?.effects?.first)
        #expect(retained.id == effect.id && retained.enabled)
        #expect(retained.params[key]?.value == defaultValue)
        #expect(EffectInspectorValues.value(clip: try #require(harness.editor.clipFor(id: clip.id)), type: type, spec: spec, frame: 0) == defaultValue)
        #expect(undo.canUndo)
        undo.undo()
        #expect(harness.editor.timeline == original)
        undo.redo()
        #expect(harness.editor.timeline == reset)
        harness.editor.setEffectParameter(clipIDs: [clip.id], type: type, key: key, value: resetValue, commit: true, action: "Reset Effect")
        let zero = harness.editor.timeline
        let neutral = try #require(harness.editor.clipFor(id: clip.id)?.effects?.first)
        #expect(neutral.id == effect.id && neutral.enabled)
        #expect(neutral.params[key]?.value == 0)
        #expect(EffectInspectorValues.value(clip: try #require(harness.editor.clipFor(id: clip.id)), type: type, spec: spec, frame: 0) == 0)
        undo.undo()
        #expect(harness.editor.timeline == reset)
        undo.redo()
        #expect(harness.editor.timeline == zero)
        undo.beginUndoGrouping()
        harness.editor.commitClipProperties(clipIds: [clip.id]) { $0.effects = nil }
        undo.endUndoGrouping()
        let cleared = try #require(harness.editor.clipFor(id: clip.id))
        #expect(EffectInspectorValues.value(clip: cleared, type: type, spec: spec, frame: 0) == 0)
        var partial = cleared
        partial.effects = [Effect(type: type)]
        #expect(EffectInspectorValues.value(clip: partial, type: type, spec: spec, frame: 0) == defaultValue)
    }

    @Test func zeroStrengthPreservesAuxiliarySettingsUntilEveryDisplayedValueIsDefault() throws {
        let descriptor = try #require(EffectRegistry.descriptor(id: "blur.noiseReduction"))
        var effect = descriptor.makeEffect()
        effect.params["amount"] = .init(value: 0.5)
        effect.params["chroma"] = .init(value: 0.9)
        effect.params["detail"] = .init(value: 0.2)
        var clip = Clip(mediaRef: "source", startFrame: 0, durationFrames: 120)
        clip.effects = [effect]
        ClipEffectAnimation.setValue(0, type: effect.type, key: "amount", frame: 0, clip: &clip)
        let retained = try #require(clip.effects?.first)
        #expect(retained.id == effect.id)
        #expect(retained.params["amount"]?.value == 0)
        #expect(retained.params["chroma"]?.value == 0.9)
        #expect(retained.params["detail"]?.value == 0.2)
        ClipEffectAnimation.setValues(["chroma": 0.6, "detail": 0.5], type: effect.type, frame: 0, clip: &clip)
        #expect(clip.effects == nil)
    }

    @Test @MainActor func animatedOutsideClipAndInvalidBatchAreAtomicWithoutUndo() {
        var clip = Fixtures.clip(id: "wheel", start: 100, duration: 120)
        clip.effects = [.init(type: "color.wheels", params: [
            "lift_x": .init(value: 0.2), "lift_y": .init(value: 0, track: .init(keyframes: [.init(frame: 30, value: 0.5)]))])]
        let original = clip
        ClipEffectAnimation.setValues(["lift_x": 0.9, "lift_y": 0], type: "color.wheels", frame: 0, clip: &clip)
        #expect(clip == original)
        ClipEffectAnimation.setValues(["lift_x": 0.9, "invalid": 0], type: "color.wheels", frame: 130, clip: &clip)
        #expect(clip == original)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let undo = UndoManager(); undo.groupsByEvent = false; harness.editor.undoManager = undo
        harness.editor.setEffectParameters(clipIDs: [clip.id], type: "color.wheels", values: ["lift_x": 0.9, "lift_y": 0], commit: true, action: "Wheel")
        #expect(harness.editor.clipFor(id: clip.id) == original)
        #expect(!undo.canUndo)
    }

    private func parameter(_ clip: Clip) -> EffectParam? {
        clip.effects?.first(where: { $0.type == "color.exposure" })?.params["ev"]
    }
}
