import Foundation
import Testing
@testable import NexGenVideo

@MainActor
private func trackReorderEditor(_ tracks: [Track]) -> EditorViewModel {
    let editor = EditorViewModel()
    editor.timeline = Fixtures.timeline(tracks: tracks)
    return editor
}

@MainActor
@Suite("Track reordering")
struct TrackReorderTests {
    @Test("visual and audio tracks stay in their routing zones")
    func zoneClamping() throws {
        var visualA = Fixtures.videoTrack(
            id: "visual-a",
            clips: [Fixtures.clip(id: "selected-video", start: 0, duration: 20)]
        )
        visualA.hidden = true
        visualA.syncLocked = false
        var visualB = Track(
            id: "visual-b",
            type: .image,
            clips: [Fixtures.clip(id: "image", mediaType: .image, start: 0, duration: 20)]
        )
        visualB.displayHeight = 88
        var audioA = Fixtures.audioTrack(
            id: "audio-a",
            clips: [Fixtures.clip(id: "audio-1", mediaType: .audio, start: 0, duration: 20)]
        )
        audioA.muted = true
        var audioB = Fixtures.audioTrack(
            id: "audio-b",
            clips: [Fixtures.clip(id: "selected-audio", mediaType: .audio, start: 0, duration: 20)]
        )
        audioB.syncLocked = false
        let editor = trackReorderEditor([visualA, visualB, audioA, audioB])
        editor.selectedClipIds = ["selected-video", "selected-audio"]

        let visualResult = try #require(editor.reorderTrack(id: "visual-a", to: 99))
        #expect(visualResult == .init(trackId: "visual-a", fromIndex: 0, toIndex: 1))
        #expect(editor.timeline.tracks.map(\.id) == ["visual-b", "visual-a", "audio-a", "audio-b"])
        #expect(editor.timeline.tracks[1] == visualA)

        let audioResult = try #require(editor.reorderTrack(id: "audio-b", to: 0))
        #expect(audioResult == .init(trackId: "audio-b", fromIndex: 3, toIndex: 2))
        #expect(editor.timeline.tracks.map(\.id) == ["visual-b", "visual-a", "audio-b", "audio-a"])
        #expect(editor.timeline.tracks[2] == audioB)
        #expect(editor.selectedClipIds == ["selected-video", "selected-audio"])
    }

    @Test("live drag commits through one canonical undo transaction")
    func liveCommitIsAtomic() throws {
        let editor = trackReorderEditor([
            Fixtures.videoTrack(id: "v1"),
            Fixtures.videoTrack(id: "v2"),
            Fixtures.videoTrack(id: "v3"),
        ])
        let undo = UndoManager()
        editor.undoManager = undo
        let before = editor.timeline

        _ = try #require(editor.reorderTrackLive(id: "v1", to: 2))
        #expect(editor.timeline.tracks.map(\.id) == ["v2", "v3", "v1"])
        _ = try #require(editor.commitTrackReorder(id: "v1", before: before))
        let after = editor.timeline

        #expect(undo.undoActionName == "Reorder Track")
        undo.undo()
        #expect(editor.timeline == before)
        undo.redo()
        #expect(editor.timeline == after)
    }

    @Test("a reordered timeline persists stable track identities and state")
    func persistentRoundTrip() throws {
        var first = Fixtures.videoTrack(
            id: "first",
            clips: [Fixtures.clip(id: "clip-1", start: 12, duration: 30)]
        )
        first.hidden = true
        first.syncLocked = false
        var second = Fixtures.videoTrack(
            id: "second",
            clips: [Fixtures.clip(id: "clip-2", start: 4, duration: 18)]
        )
        second.syncLocked = true
        let editor = trackReorderEditor([first, second])

        _ = try #require(editor.reorderTrack(id: "first", to: 1))
        let decoded = try JSONDecoder().decode(
            Timeline.self,
            from: JSONEncoder().encode(editor.timeline)
        )

        #expect(decoded.tracks.map(\.id) == ["second", "first"])
        #expect(decoded.tracks[1].type == .video)
        #expect(decoded.tracks[1].hidden)
        #expect(decoded.tracks[1].syncLocked == false)
        #expect(decoded.tracks[1].clips.map(\.id) == ["clip-1"])
    }

    @Test("missing and same-position requests are no-ops")
    func noOpRequests() throws {
        let editor = trackReorderEditor([Fixtures.videoTrack(id: "v1")])
        let undo = UndoManager()
        editor.undoManager = undo
        let before = editor.timeline

        #expect(editor.reorderTrack(id: "missing", to: 0) == nil)
        let result = try #require(editor.reorderTrack(id: "v1", to: 0))

        #expect(result.fromIndex == result.toIndex)
        #expect(editor.timeline == before)
        #expect(undo.canUndo == false)
    }
}
