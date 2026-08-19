import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Keyframe lane actions")
struct KeyframesLaneActionTests {
    @Test func clearAnimationTargetsOnePropertyAndSupportsUndoRedo() {
        let opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 5, value: 0.25, interpolationOut: .linear),
            Keyframe(frame: 20, value: 0.75, interpolationOut: .hold),
        ])
        let rotationTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 10, value: 45.0),
        ])
        var clip = Fixtures.clip(id: "clip", start: 100, duration: 60)
        clip.opacityTrack = opacityTrack
        clip.rotationTrack = rotationTrack

        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let undoManager = UndoManager()
        editor.undoManager = undoManager

        editor.clearAnimation(clipId: clip.id, property: .opacity)

        #expect(editor.clipFor(id: clip.id)?.opacityTrack == nil)
        #expect(editor.clipFor(id: clip.id)?.rotationTrack == rotationTrack)
        #expect(undoManager.undoActionName == "Clear Animation")

        undoManager.undo()

        #expect(editor.clipFor(id: clip.id)?.opacityTrack == opacityTrack)
        #expect(editor.clipFor(id: clip.id)?.rotationTrack == rotationTrack)

        undoManager.redo()

        #expect(editor.clipFor(id: clip.id)?.opacityTrack == nil)
        #expect(editor.clipFor(id: clip.id)?.rotationTrack == rotationTrack)
    }
}
