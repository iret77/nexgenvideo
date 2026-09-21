import Foundation
import Testing
@testable import NexGenVideo

@MainActor
private func slipEditor(_ tracks: [Track], markers: [TimelineMarker] = []) -> EditorViewModel {
    let editor = EditorViewModel()
    editor.timeline = Timeline(tracks: tracks, markers: markers)
    return editor
}

@MainActor
@Suite("Slip edit")
struct SlipEditTests {
    @Test("slip changes only the source range and persists it")
    func fixedTimelineFootprint() throws {
        var clip = Fixtures.clip(
            id: "clip",
            start: 100,
            duration: 60,
            trimStart: 30,
            trimEnd: 20
        )
        clip.fadeInFrames = 8
        clip.fadeOutFrames = 12
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1),
            Keyframe(frame: 30, value: 0.5),
        ])
        let marker = TimelineMarker(id: "marker", startFrame: 110, title: "Beat")
        let editor = slipEditor([Fixtures.videoTrack(clips: [clip])], markers: [marker])
        editor.selectedClipIds = ["clip"]
        let sourceFrames = clip.sourceDurationFrames

        let plan = try #require(editor.slipClip(
            clipId: "clip",
            deltaFrames: 10,
            propagateToLinked: true
        ))
        let updated = try #require(editor.clipFor(id: "clip"))

        #expect(plan.appliedTimelineDelta == 10)
        #expect(updated.startFrame == 100)
        #expect(updated.durationFrames == 60)
        #expect(updated.trimStartFrame == 20)
        #expect(updated.trimEndFrame == 30)
        #expect(updated.sourceDurationFrames == sourceFrames)
        #expect(updated.fadeInFrames == 8)
        #expect(updated.fadeOutFrames == 12)
        #expect(updated.opacityTrack == clip.opacityTrack)
        #expect(editor.timeline.markers == [marker])
        #expect(editor.selectedClipIds == ["clip"])

        let decoded = try JSONDecoder().decode(
            Timeline.self,
            from: JSONEncoder().encode(editor.timeline)
        )
        #expect(decoded.tracks[0].clips[0].trimStartFrame == 20)
        #expect(decoded.tracks[0].clips[0].trimEndFrame == 30)
    }

    @Test("negative slip reveals later source material")
    func negativeDelta() throws {
        let editor = slipEditor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "clip", start: 12, duration: 40, trimStart: 15, trimEnd: 8),
        ])])

        let plan = try #require(editor.slipClip(
            clipId: "clip",
            deltaFrames: -5,
            propagateToLinked: true
        ))
        let updated = try #require(editor.clipFor(id: "clip"))

        #expect(plan.appliedTimelineDelta == -5)
        #expect(updated.trimStartFrame == 20)
        #expect(updated.trimEndFrame == 3)
        #expect(updated.startFrame == 12)
        #expect(updated.durationFrames == 40)
    }

    @Test("fractional speed uses every exact source handle frame")
    func fractionalSpeedHandle() throws {
        let clip = Fixtures.clip(
            id: "clip",
            start: 0,
            duration: 40,
            trimStart: 1,
            trimEnd: 10,
            speed: 0.6
        )
        let editor = slipEditor([Fixtures.videoTrack(clips: [clip])])
        let sourceFrames = clip.sourceDurationFrames

        let limits = try #require(editor.slipTimelineLimits(
            clipId: "clip",
            propagateToLinked: true
        ))
        let plan = try #require(editor.slipClip(
            clipId: "clip",
            deltaFrames: 20,
            propagateToLinked: true
        ))
        let updated = try #require(editor.clipFor(id: "clip"))

        #expect(limits.right == 2)
        #expect(plan.appliedTimelineDelta == 2)
        #expect(updated.trimStartFrame == 0)
        #expect(updated.trimEndFrame == 11)
        #expect(updated.sourceDurationFrames == sourceFrames)
    }

    @Test("linked video and audio use their tightest shared limit")
    func linkedMedia() throws {
        var video = Fixtures.clip(
            id: "video",
            start: 0,
            duration: 1,
            trimStart: 30,
            trimEnd: 30
        )
        var audio = Fixtures.clip(
            id: "audio",
            mediaType: .audio,
            start: 0,
            duration: 1,
            trimStart: 1,
            trimEnd: 8,
            speed: 0.6
        )
        video.linkGroupId = "linked"
        audio.linkGroupId = "linked"
        let videoSourceFrames = video.sourceDurationFrames
        let audioSourceFrames = audio.sourceDurationFrames
        let editor = slipEditor([
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])

        let plan = try #require(editor.slipClip(
            clipId: "video",
            deltaFrames: 20,
            propagateToLinked: true
        ))
        let updatedVideo = try #require(editor.clipFor(id: "video"))
        let updatedAudio = try #require(editor.clipFor(id: "audio"))

        #expect(plan.appliedTimelineDelta == 2)
        #expect(plan.targetIds == ["video", "audio"])
        #expect(updatedVideo.trimStartFrame == 28)
        #expect(updatedVideo.trimEndFrame == 32)
        #expect(updatedAudio.trimStartFrame == 0)
        #expect(updatedAudio.trimEndFrame == 9)
        #expect(updatedVideo.sourceDurationFrames == videoSourceFrames)
        #expect(updatedAudio.sourceDurationFrames == audioSourceFrames)
        #expect(updatedVideo.durationFrames == 1)
        #expect(updatedAudio.durationFrames == 1)
    }

    @Test("unlinked override changes only the lead clip")
    func unlinkedOverride() throws {
        var video = Fixtures.clip(id: "video", start: 0, duration: 30, trimStart: 10, trimEnd: 10)
        var audio = Fixtures.clip(
            id: "audio",
            mediaType: .audio,
            start: 0,
            duration: 30,
            trimStart: 10,
            trimEnd: 10
        )
        video.linkGroupId = "linked"
        audio.linkGroupId = "linked"
        let editor = slipEditor([
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])

        _ = try #require(editor.slipClip(
            clipId: "video",
            deltaFrames: 4,
            propagateToLinked: false
        ))

        #expect(editor.clipFor(id: "video")?.trimStartFrame == 6)
        #expect(editor.clipFor(id: "audio") == audio)
    }

    @Test("unbounded and invalid clips refuse without an undo entry")
    func ineligibleClips() {
        var invalid = Fixtures.clip(
            id: "invalid",
            mediaType: .audio,
            start: 20,
            duration: 10,
            trimStart: 5,
            trimEnd: 5
        )
        invalid.speed = .infinity
        let editor = slipEditor([
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "image", mediaType: .image, start: 0, duration: 10),
            ]),
            Fixtures.audioTrack(clips: [invalid]),
        ])
        let undo = UndoManager()
        editor.undoManager = undo
        let before = editor.timeline

        #expect(editor.slipClip(clipId: "image", deltaFrames: 1, propagateToLinked: true) == nil)
        #expect(editor.slipClip(clipId: "invalid", deltaFrames: 1, propagateToLinked: true) == nil)
        #expect(editor.timeline == before)
        #expect(undo.canUndo == false)
    }

    @Test("linked slip is one atomic undo and redo")
    func atomicUndoRedo() throws {
        var video = Fixtures.clip(id: "video", start: 0, duration: 30, trimStart: 10, trimEnd: 10)
        var audio = Fixtures.clip(
            id: "audio",
            mediaType: .audio,
            start: 0,
            duration: 30,
            trimStart: 10,
            trimEnd: 10
        )
        video.linkGroupId = "linked"
        audio.linkGroupId = "linked"
        let editor = slipEditor([
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])
        let undo = UndoManager()
        editor.undoManager = undo
        let before = editor.timeline

        _ = try #require(editor.slipClip(
            clipId: "video",
            deltaFrames: -4,
            propagateToLinked: true
        ))
        let after = editor.timeline

        #expect(undo.undoActionName == "Slip Clips")
        undo.undo()
        #expect(editor.timeline == before)
        undo.redo()
        #expect(editor.timeline == after)
    }
}
