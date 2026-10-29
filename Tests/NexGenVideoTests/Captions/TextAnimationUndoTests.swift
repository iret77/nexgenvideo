import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Text property editing keeps the actual animation")
struct TextAnimationUndoTests {
    @Test func animatedOpacityAddsCurrentKeyAndUndoRestoresTheWholeTrack() throws {
        let editor = EditorViewModel()
        var title = Fixtures.clip(id: "title", mediaType: .text, start: 0, duration: 120)
        title.opacity = 0.9
        title.opacityTrack = .init(keyframes: [.init(frame: 10, value: 0.2), .init(frame: 90, value: 0.8)])
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [title])])
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        editor.currentFrame = 60
        undo.beginUndoGrouping(); editor.commitOpacity(clipId: title.id, value: 0.4); undo.endUndoGrouping()
        let changed = try #require(editor.clipFor(id: title.id))
        #expect(changed.opacity == 0.9)
        #expect(changed.opacityTrack?.keyframes.map(\.frame) == [10, 60, 90])
        #expect(changed.opacityTrack?.keyframes.map(\.value) == [0.2, 0.4, 0.8])
        undo.undo(); #expect(editor.clipFor(id: title.id) == title)
        undo.redo(); #expect(editor.clipFor(id: title.id) == changed)
    }
}
