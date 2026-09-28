import AppKit
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

@Suite("Track context commands")
@MainActor
struct TrackContextCommandTests {
    @Test func menuTargetsTrackIdentityAfterReorderingAndDoesNotMutateOnOpen() throws {
        let first = Fixtures.audioTrack()
        let second = Fixtures.audioTrack()
        let editor = makeEditor([first, second])
        let view = TimelineHeaderView(editor: editor)
        let original = editor.timeline
        let menu = try #require(view.trackContextMenu(id: first.id))
        #expect(editor.timeline == original)
        #expect(menu.items.first?.title.contains("A1") == true)
        editor.timeline.tracks.swapAt(0, 1)
        let mute = try #require(menu.items.first)
        let action = try #require(mute.action)
        _ = view.perform(action, with: mute)
        #expect(editor.timeline.tracks[1].id == first.id)
        #expect(editor.timeline.tracks[1].muted != first.muted)
        #expect(editor.timeline.tracks[0].muted == second.muted)
        let afterMute = editor.timeline
        _ = view.perform(action, with: mute)
        #expect(editor.timeline == afterMute)
        editor.timeline.tracks.removeAll { $0.id == first.id }
        let remaining = editor.timeline
        _ = view.perform(action, with: mute)
        #expect(editor.timeline == remaining)
        #expect(view.trackContextMenu(id: first.id) == nil)
    }

    @Test func removalRevalidatesWorkspaceAndUsesTimelineUndo() throws {
        let editor = makeEditor([Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])])
        let priorFocus = editor.workspaceFocus
        defer { editor.setWorkspaceFocus(priorFocus) }
        editor.setWorkspaceFocus(.edit)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let view = TimelineHeaderView(editor: editor)
        let original = editor.timeline
        let menu = try #require(view.trackContextMenu(id: original.tracks[0].id))
        let remove = try #require(menu.items.last)
        let action = try #require(remove.action)
        #expect(remove.isEnabled)
        editor.setWorkspaceFocus(.production)
        _ = view.perform(action, with: remove)
        #expect(editor.timeline == original)
        #expect(!undo.canUndo)
        let disabled = try #require(view.trackContextMenu(id: original.tracks[0].id))
        #expect(disabled.items.last?.isEnabled == false)
        editor.setWorkspaceFocus(.edit)
        editor.timeline.tracks[0].clips.append(Fixtures.clip(start: 30, duration: 30))
        let changedContents = editor.timeline
        _ = view.perform(action, with: remove)
        #expect(editor.timeline == changedContents)
        #expect(!undo.canUndo)
        #expect(editor.mediaPanelToast != nil)
        editor.timeline = original
        undo.beginUndoGrouping()
        _ = view.perform(action, with: remove)
        undo.endUndoGrouping()
        #expect(editor.timeline.tracks.isEmpty)
        undo.undo()
        #expect(editor.timeline == original)
        undo.redo()
        #expect(editor.timeline.tracks.isEmpty)
    }
}
