import Foundation
import Testing
@testable import NexGenVideo

@MainActor
private func makeEditor(_ tracks: [Track]) -> EditorViewModel {
    let editor = EditorViewModel()
    editor.timeline = Fixtures.timeline(tracks: tracks)
    return editor
}

@Suite("EditorViewModel — track display label")
@MainActor
struct TrackDisplayLabelTests {

    @Test func labelsVisualTracksTopToBottomThenAudio() {
        let editor = makeEditor([
            Fixtures.videoTrack(),
            Fixtures.videoTrack(),
            Fixtures.audioTrack(),
        ])
        #expect(editor.timelineTrackDisplayLabel(at: 0) == "V2")
        #expect(editor.timelineTrackDisplayLabel(at: 1) == "V1")
        #expect(editor.timelineTrackDisplayLabel(at: 2) == "A1")
    }

    @Test func outOfRangeIndexReturnsEmpty() {
        let editor = makeEditor([Fixtures.videoTrack()])
        #expect(editor.timelineTrackDisplayLabel(at: 5) == "")
    }

    @Test func visualTrackAfterAudioDoesNotTrap() {
        // Invariant-violating order (visual below audio) — must not crash on the empty range.
        var text = Fixtures.videoTrack()
        text.type = .text
        let editor = makeEditor([
            Fixtures.videoTrack(),
            Fixtures.audioTrack(),
            text,
        ])
        #expect(editor.timelineTrackDisplayLabel(at: 2) == "T1")
    }
}

@Suite("Track commands — undo and redo")
@MainActor
struct TrackCommandUndoTests {
    @Test func trackFlagsRoundTripThroughUndoAndRedo() {
        let commands: [(EditorViewModel) -> Void] = [
            { $0.toggleTrackMute(trackIndex: 1) },
            { $0.toggleTrackHidden(trackIndex: 0) },
            { $0.toggleTrackSyncLock(trackIndex: 0) },
        ]
        for command in commands {
            let editor = makeEditor([Fixtures.videoTrack(), Fixtures.audioTrack()])
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undoManager = undo
            let original = editor.timeline
            undo.beginUndoGrouping()
            command(editor)
            undo.endUndoGrouping()
            let changed = editor.timeline
            #expect(changed != original)
            undo.undo()
            #expect(editor.timeline == original)
            #expect(undo.canRedo)
            undo.redo()
            #expect(editor.timeline == changed)
            undo.undo()
            #expect(editor.timeline == original)
        }
    }

    @Test func resizeAndRemovalUndoInOrderAndInvalidSizesDoNothing() {
        let editor = makeEditor([Fixtures.videoTrack(), Fixtures.audioTrack()])
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let original = editor.timeline
        let trackID = original.tracks[0].id
        for value in [CGFloat.nan, .infinity, -.infinity] {
            editor.setTrackHeight(trackIndex: 0, height: value)
        }
        #expect(editor.timeline == original)
        #expect(!undo.canUndo)
        undo.beginUndoGrouping()
        editor.setTrackHeight(trackIndex: 0, height: AppTheme.Timeline.trackMaxHeight)
        undo.endUndoGrouping()
        let resized = editor.timeline
        #expect(resized.tracks[0].displayHeight == AppTheme.Timeline.trackMaxHeight)
        undo.beginUndoGrouping()
        editor.removeTrack(id: trackID)
        undo.endUndoGrouping()
        #expect(editor.timeline.tracks.count == 1)
        undo.undo()
        #expect(editor.timeline == resized)
        undo.undo()
        #expect(editor.timeline == original)
        undo.redo()
        #expect(editor.timeline == resized)
    }
}
