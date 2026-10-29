import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Agent grading preserves existing animation")
struct ColorAnimationPreservationTests {
    @Test func mergedGradePreservesUntouchedParametersEffectIdentityOrderAndUndo() async throws {
        let exposure = Effect(id: "exposure", type: "color.exposure", params: ["ev": animated(0, 2)])
        let temperature = Effect(id: "temperature", type: "color.temperature", enabled: false,
            params: ["temperature": .init(value: 6500), "tint": animated(0, 30)])
        let blur = Effect(id: "blur", type: "blur.gaussian", params: ["radius": .init(value: 4)])
        let unknown = Effect(id: "future", type: "color.future", params: ["amount": animated(1, 2)])
        var clip = Fixtures.clip(id: "c1", start: 20, duration: 120)
        clip.effects = [blur, exposure, temperature, unknown]
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let undo = UndoManager(); undo.groupsByEvent = false; harness.editor.undoManager = undo
        let before = harness.editor.timeline
        let result = await harness.runRaw("apply_color", args: ["clipIds": [clip.id], "temperature": 7200.0])
        #expect(!result.isError)
        let effects = try #require(harness.editor.clipFor(id: clip.id)?.effects)
        #expect(effects.map(\.id) == ["blur", "exposure", "temperature", "future"])
        #expect(effects[0] == blur && effects[1] == exposure && effects[3] == unknown)
        #expect(effects[2].enabled == false)
        #expect(effects[2].params["tint"] == temperature.params["tint"])
        #expect(effects[2].params["temperature"]?.value == 7200)
        let after = harness.editor.timeline
        undo.undo(); #expect(harness.editor.timeline == before)
        undo.redo(); #expect(harness.editor.timeline == after)
    }

    @Test func staticAnimatedEditRejectsWholeBatchBeforeAnyMutation() async throws {
        let first = Fixtures.clip(id: "first", start: 0, duration: 120)
        var second = Fixtures.clip(id: "second", start: 120, duration: 120)
        second.effects = [.init(type: "color.exposure", params: ["ev": animated(0, 2)])]
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [first, second])]))
        let before = harness.editor.timeline
        let result = await harness.runRaw("apply_color", args: ["clipIds": [first.id, second.id], "exposure": 1.0])
        #expect(result.isError)
        #expect(harness.editor.timeline == before)
        let reset = await harness.runRaw("apply_color", args: ["clipIds": [second.id], "reset": true, "exposure": 1.0])
        #expect(!reset.isError)
        let effect = try #require(harness.editor.clipFor(id: second.id)?.effects?.first)
        #expect(effect.type == "color.exposure" && effect.params["ev"]?.value == 1)
        #expect(effect.params["ev"]?.track == nil)
    }

    @Test func wheelMasterChangePreservesAnimatedXYAndLUTIntensity() async throws {
        let wheels = Effect(id: "wheels", type: "color.wheels", params: [
            "lift_x": animated(0, 0.25), "lift_y": animated(0.1, 0.2), "lift_m": .init(value: 0)])
        let lut = Effect(id: "lut", type: "color.lut", params: [
            "path": .init(string: "fixture.cube"), "name": .init(string: "Look.cube"), "intensity": animated(0, 1)])
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 120); clip.effects = [wheels, lut]
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let result = await harness.runRaw("apply_color", args: ["clipIds": [clip.id], "shadowsLum": 0.2])
        #expect(!result.isError)
        let effects = try #require(harness.editor.clipFor(id: clip.id)?.effects)
        #expect(effects[0].id == wheels.id && effects[0].params["lift_m"]?.value == 0.2)
        #expect(effects[0].params["lift_x"] == wheels.params["lift_x"])
        #expect(effects[0].params["lift_y"] == wheels.params["lift_y"])
        #expect(effects[1] == lut)
        let before = harness.editor.timeline
        #expect(await harness.runRaw("apply_color", args: ["clipIds": [clip.id], "shadowsHue": 120.0]).isError)
        #expect(await harness.runRaw("apply_color", args: ["clipIds": [clip.id], "lut": ["strength": 0.5]]).isError)
        #expect(harness.editor.timeline == before)
    }

    @Test func choosingAnotherLUTPreservesAnimatedIntensityUnlessExplicitlyReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("color-lut-\(UUID().uuidString)")
        try Fixtures.prepareProjectPackage(at: root)
        let source = root.appendingPathComponent("New Look.cube")
        try Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8).write(to: source)
        let intensity = animated(0.2, 0.8)
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 120)
        clip.effects = [.init(id: "existing-lut", type: "color.lut", params: [
            "path": .init(string: "previous.cube"), "name": .init(string: "Previous.cube"), "intensity": intensity])]
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        harness.editor.projectURL = root
        let result = await harness.runRaw("apply_color", args: ["clipIds": [clip.id], "lut": ["path": source.path]])
        #expect(!result.isError)
        let effect = try #require(harness.editor.clipFor(id: clip.id)?.effects?.first)
        #expect(effect.id == "existing-lut")
        #expect(effect.params["intensity"] == intensity)
        #expect(effect.params["name"]?.string == "New Look.cube")
        #expect(effect.params["path"]?.string != "previous.cube")
    }

    private func animated(_ start: Double, _ end: Double) -> EffectParam {
        .init(value: start, track: .init(keyframes: [
            .init(frame: 10, value: start, interpolationOut: .hold),
            .init(frame: 90, value: end, interpolationOut: .linear)]))
    }
}
