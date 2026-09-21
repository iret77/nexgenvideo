import Foundation
import Testing
@testable import NexGenVideo

@Suite("set_clip_properties static crop")
@MainActor
struct StaticCropContractTests {
    @Test func partialCropUsesPlayheadValueBeforeTimingClampAndClearsAnimation() async throws {
        var clip = Fixtures.clip(id: "visual", start: 0, duration: 60)
        clip.transform = Transform(centerX: 0.5, centerY: 0.5, width: 0.8, height: 0.6, rotation: 15)
        clip.cropTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: Crop(), interpolationOut: .linear),
            Keyframe(
                frame: 40,
                value: Crop(left: 0.4, top: 0.2, right: 0.2, bottom: 0.2),
                interpolationOut: .linear
            ),
        ])
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        harness.editor.currentFrame = 20

        let result = await harness.runRaw("set_clip_properties", args: [
            "clipIds": [clip.id],
            "durationFrames": 30,
            "transform": ["centerX": 0.4],
            "crop": ["left": 0.25],
        ])

        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let updated = try #require(harness.editor.clipFor(id: clip.id))
        #expect(updated.durationFrames == 30)
        #expect(updated.crop == Crop(left: 0.25, top: 0.1, right: 0.1, bottom: 0.1))
        #expect(updated.cropTrack == nil)
        #expect(updated.transform.centerX == 0.4)
        #expect(updated.transform.width == 0.8)
        #expect(updated.transform.height == 0.6)
        #expect(updated.transform.rotation == 15)
    }

    @Test func validatesEveryTargetBeforeMutation() async {
        let visual = Fixtures.clip(id: "visual", start: 0, duration: 30)
        let audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 30)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [visual]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
        let undoManager = UndoManager()
        harness.editor.undoManager = undoManager
        let before = harness.editor.timeline

        let result = await harness.runRaw("set_clip_properties", args: [
            "clipIds": [visual.id, audio.id],
            "opacity": 0.4,
            "crop": ["left": 0.2],
        ])

        #expect(result.isError)
        #expect(harness.editor.timeline == before)
        #expect(undoManager.canUndo == false)
    }

    @Test func oneUndoRestoresTheWholeCropBatch() async throws {
        let first = Fixtures.clip(id: "first", start: 0, duration: 30)
        let second = Fixtures.clip(id: "second", start: 30, duration: 30)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [first, second]),
        ]))
        let undoManager = UndoManager()
        harness.editor.undoManager = undoManager

        let mutation = await harness.runRaw("set_clip_properties", args: [
            "clipIds": [first.id, second.id],
            "crop": ["left": 0.1, "top": 0.2, "right": 0.3, "bottom": 0.1],
        ])
        #expect(mutation.isError == false, "\(ToolHarness.textOf(mutation))")
        #expect(harness.editor.clipFor(id: first.id)?.crop.left == 0.1)
        #expect(harness.editor.clipFor(id: second.id)?.crop.left == 0.1)

        let undo = await harness.runRaw("undo")
        #expect(undo.isError == false, "\(ToolHarness.textOf(undo))")
        #expect(harness.editor.clipFor(id: first.id)?.crop.isIdentity == true)
        #expect(harness.editor.clipFor(id: second.id)?.crop.isIdentity == true)
        #expect(undoManager.canUndo == false)
    }

    @Test func partialCropClampsThePlayheadIntoEachTargetClip() async throws {
        var first = Fixtures.clip(id: "first", start: 0, duration: 60)
        first.cropTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: Crop(top: 0.05), interpolationOut: .linear),
            Keyframe(frame: 40, value: Crop(top: 0.25), interpolationOut: .linear),
        ])
        var second = Fixtures.clip(id: "second", start: 100, duration: 60)
        second.cropTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: Crop(top: 0.2), interpolationOut: .linear),
            Keyframe(frame: 40, value: Crop(top: 0.4), interpolationOut: .linear),
        ])
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [first, second]),
        ]))
        harness.editor.currentFrame = 20

        let result = await harness.runRaw("set_clip_properties", args: [
            "clipIds": [first.id, second.id],
            "crop": ["left": 0.1],
        ])

        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let firstCrop = try #require(harness.editor.clipFor(id: first.id)?.crop)
        #expect(firstCrop.left == 0.1)
        #expect(abs(firstCrop.top - 0.15) < 1e-9)
        #expect(harness.editor.clipFor(id: second.id)?.crop == Crop(left: 0.1, top: 0.2))
    }

    @Test func zeroCropRestoresSourceAndBoundaryCropSurvivesRoundTrip() async throws {
        var clip = Fixtures.clip(id: "visual", start: 0, duration: 30)
        clip.crop = Crop(left: 0.2, top: 0.1, right: 0.2, bottom: 0.1)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))

        let result = await harness.runRaw("set_clip_properties", args: [
            "clipIds": [clip.id],
            "crop": ["left": 0, "top": 0, "right": 0, "bottom": 0],
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        #expect(harness.editor.clipFor(id: clip.id)?.crop.isIdentity == true)

        harness.editor.timeline.tracks[0].clips[0].crop = Crop(left: 0.95, top: 0, right: 0, bottom: 0.95)
        let data = try JSONEncoder().encode(harness.editor.timeline)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(decoded.tracks[0].clips[0].crop == Crop(left: 0.95, top: 0, right: 0, bottom: 0.95))
        #expect(decoded.tracks[0].clips[0].crop.isValid)
    }

    @Test func staticAndAnimatedCropRejectCollapsedSource() async {
        let clip = Fixtures.clip(id: "visual", start: 0, duration: 30)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))

        let staticResult = await harness.runRaw("set_clip_properties", args: [
            "clipIds": [clip.id],
            "crop": ["left": 0.5, "right": 0.46],
        ])
        #expect(staticResult.isError)
        #expect(harness.editor.clipFor(id: clip.id)?.crop.isIdentity == true)

        let animatedResult = await harness.runRaw("set_keyframes", args: [
            "clipId": clip.id,
            "property": "crop",
            "keyframes": [[0, 0, 0.46, 0, 0.5]],
        ])
        #expect(animatedResult.isError)
        #expect(harness.editor.clipFor(id: clip.id)?.cropTrack == nil)

        let audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 30)
        let audioHarness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [audio])]))
        let audioKeyframes = await audioHarness.runRaw("set_keyframes", args: [
            "clipId": audio.id,
            "property": "crop",
            "keyframes": [[0, 0, 0, 0, 0]],
        ])
        #expect(audioKeyframes.isError)
        #expect(audioHarness.editor.clipFor(id: audio.id)?.cropTrack == nil)

        let emptyCrop = await harness.runRaw("set_clip_properties", args: [
            "clipIds": [clip.id],
            "opacity": 0.5,
            "crop": [:],
        ])
        #expect(emptyCrop.isError)
        #expect(harness.editor.clipFor(id: clip.id)?.opacity == 1)

        let negativeEdge = await harness.runRaw("set_clip_properties", args: [
            "clipIds": [clip.id],
            "crop": ["top": -0.1],
        ])
        #expect(negativeEdge.isError)

        let unknownEdge = await harness.runRaw("set_clip_properties", args: [
            "clipIds": [clip.id],
            "crop": ["anchorX": 0.2],
        ])
        #expect(unknownEdge.isError)
        #expect(harness.editor.clipFor(id: clip.id)?.crop.isIdentity == true)
    }
}
