import Foundation
import Testing
@testable import NexGenVideo

@MainActor
private func rippleEditor(_ tracks: [Track], markers: [TimelineMarker] = []) -> EditorViewModel {
    let editor = EditorViewModel()
    editor.timeline = Timeline(tracks: tracks, markers: markers)
    return editor
}

private func rippleSpans(_ track: Track) -> [[Int]] {
    track.clips.sorted { $0.startFrame < $1.startFrame }.map { [$0.startFrame, $0.endFrame] }
}

@MainActor
@Suite("Ripple trim")
struct RippleTrimTests {
    @Test("right extension shifts followers and markers without changing selection")
    func rightExtension() throws {
        var lead = Fixtures.clip(id: "lead", start: 0, duration: 100, trimEnd: 30)
        lead.fadeOutFrames = 12
        let editor = rippleEditor(
            [Fixtures.videoTrack(clips: [
                lead,
                Fixtures.clip(id: "next", start: 100, duration: 40),
            ])],
            markers: [
                TimelineMarker(id: "point", startFrame: 100, title: "Cut"),
                TimelineMarker(id: "range", startFrame: 90, durationFrames: 20, title: "Beat"),
            ]
        )
        editor.selectedClipIds = ["lead"]

        let plan = try #require(editor.rippleTrimClip(
            clipId: "lead",
            edge: .right,
            deltaFrames: 20,
            propagateToLinked: false
        ))

        #expect(plan.durationDelta == 20)
        #expect(rippleSpans(editor.timeline.tracks[0]) == [[0, 120], [120, 160]])
        #expect(editor.timeline.tracks[0].clips.first { $0.id == "lead" }?.trimEndFrame == 10)
        #expect(editor.timeline.tracks[0].clips.first { $0.id == "lead" }?.fadeOutFrames == 12)
        #expect(editor.timeline.markers.first { $0.id == "point" }?.startFrame == 120)
        #expect(editor.timeline.markers.first { $0.id == "range" }?.durationFrames == 40)
        #expect(editor.selectedClipIds == ["lead"])
    }

    @Test("left extension anchors the clip and ripples its followers")
    func leftExtension() throws {
        let editor = rippleEditor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "lead", start: 20, duration: 80, trimStart: 25),
            Fixtures.clip(id: "next", start: 100, duration: 30),
        ])])

        let plan = try #require(editor.rippleTrimClip(
            clipId: "lead",
            edge: .left,
            deltaFrames: -15,
            propagateToLinked: false
        ))

        #expect(plan.durationDelta == 15)
        #expect(rippleSpans(editor.timeline.tracks[0]) == [[20, 115], [115, 145]])
        #expect(editor.timeline.tracks[0].clips.first { $0.id == "lead" }?.trimStartFrame == 10)
    }

    @Test("linked media uses the tightest exact source handle at fractional speed")
    func linkedExactSourceHandles() throws {
        var video = Fixtures.clip(
            id: "video",
            start: 0,
            duration: 100,
            trimEnd: 40,
            speed: 1.5
        )
        var audio = Fixtures.clip(
            id: "audio",
            mediaType: .audio,
            start: 0,
            duration: 100,
            trimEnd: 16,
            speed: 1.5
        )
        video.linkGroupId = "linked"
        audio.linkGroupId = "linked"
        let videoSourceFrames = video.sourceDurationFrames
        let audioSourceFrames = audio.sourceDurationFrames
        let editor = rippleEditor([
            Fixtures.videoTrack(clips: [
                video,
                Fixtures.clip(id: "video-next", start: 100, duration: 20),
            ]),
            Fixtures.audioTrack(clips: [
                audio,
                Fixtures.clip(id: "audio-next", mediaType: .audio, start: 100, duration: 20),
            ]),
        ])

        let plan = try #require(editor.rippleTrimClip(
            clipId: "video",
            edge: .right,
            deltaFrames: 20,
            propagateToLinked: true
        ))

        #expect(plan.durationDelta == 10)
        let updatedVideo = try #require(editor.timeline.tracks[0].clips.first { $0.id == "video" })
        let updatedAudio = try #require(editor.timeline.tracks[1].clips.first { $0.id == "audio" })
        #expect(updatedVideo.sourceDurationFrames == videoSourceFrames)
        #expect(updatedAudio.sourceDurationFrames == audioSourceFrames)
        #expect(updatedAudio.trimEndFrame == 1)
        #expect(rippleSpans(editor.timeline.tracks[0]) == [[0, 110], [110, 130]])
        #expect(rippleSpans(editor.timeline.tracks[1]) == [[0, 110], [110, 130]])
    }

    @Test("unlinked override leaves the partner unchanged")
    func unlinkedOverride() throws {
        var video = Fixtures.clip(id: "video", start: 0, duration: 40, trimEnd: 20)
        var audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 40, trimEnd: 20)
        video.linkGroupId = "linked"
        audio.linkGroupId = "linked"
        let editor = rippleEditor([
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])

        _ = try #require(editor.rippleTrimClip(
            clipId: "video",
            edge: .right,
            deltaFrames: 10,
            propagateToLinked: false
        ))

        #expect(editor.timeline.tracks[0].clips[0].durationFrames == 50)
        #expect(editor.timeline.tracks[1].clips[0] == audio)
    }

    @Test("shrink clamps to one frame, clamps fades, and honors a sync-lock wall")
    func shrinkBounds() throws {
        var lead = Fixtures.clip(id: "lead", start: 0, duration: 100)
        lead.fadeInFrames = 60
        lead.fadeOutFrames = 30
        let editor = rippleEditor([
            Fixtures.videoTrack(clips: [lead]),
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "wall", start: 60, duration: 30),
                Fixtures.clip(id: "follower", start: 120, duration: 30),
            ]),
        ])

        let plan = try #require(editor.rippleTrimClip(
            clipId: "lead",
            edge: .right,
            deltaFrames: -200,
            propagateToLinked: false
        ))

        #expect(plan.durationDelta == -30)
        #expect(plan.blockedAtFrame == 90)
        #expect(editor.timeline.tracks[0].clips[0].durationFrames == 70)
        #expect(editor.timeline.tracks[0].clips[0].fadeInFrames == 60)
        #expect(editor.timeline.tracks[0].clips[0].fadeOutFrames == 10)
        #expect(rippleSpans(editor.timeline.tracks[1]) == [[60, 90], [90, 120]])

        editor.timeline.tracks[1].syncLocked = false
        _ = try #require(editor.rippleTrimClip(
            clipId: "lead",
            edge: .right,
            deltaFrames: -200,
            propagateToLinked: false
        ))
        #expect(editor.timeline.tracks[0].clips[0].durationFrames == 1)
        #expect(editor.timeline.tracks[0].clips[0].fadeInFrames == 1)
        #expect(editor.timeline.tracks[0].clips[0].fadeOutFrames == 0)
    }

    @Test("commit is one atomic undo and redo")
    func atomicUndoRedo() throws {
        let editor = rippleEditor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "lead", start: 0, duration: 60, trimEnd: 20),
            Fixtures.clip(id: "next", start: 60, duration: 20),
        ])])
        let undo = UndoManager()
        editor.undoManager = undo
        let before = editor.timeline

        _ = try #require(editor.rippleTrimClip(
            clipId: "lead",
            edge: .right,
            deltaFrames: 10,
            propagateToLinked: false
        ))
        let after = editor.timeline

        #expect(undo.undoActionName == "Ripple Trim")
        undo.undo()
        #expect(editor.timeline == before)
        undo.redo()
        #expect(editor.timeline == after)
    }
}
