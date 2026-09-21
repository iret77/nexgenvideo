import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Timeline gesture tools")
struct TimelineGestureToolTests {
    @Test("ripple_trim uses the canonical mutation and returns its applied delta")
    func rippleTrim() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "lead", start: 0, duration: 60, trimEnd: 12),
                Fixtures.clip(id: "next", start: 60, duration: 20),
            ]),
        ]))
        let undo = UndoManager()
        harness.editor.undoManager = undo

        let payload = try await harness.runOK("ripple_trim", args: [
            "clipId": "lead",
            "edge": "right",
            "deltaFrames": 20,
        ]) as? [String: Any]

        #expect(payload?["appliedDurationDelta"] as? Int == 12)
        #expect(payload?["shiftedClipCount"] as? Int == 1)
        #expect(rippleSpansForTool(harness.editor.timeline.tracks[0]) == [[0, 72], [72, 92]])
        #expect(undo.undoActionName == "Ripple Trim")
    }

    @Test("ripple_trim rejects invalid and unavailable edits without mutation")
    func rippleTrimValidation() async {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "lead", start: 0, duration: 20)]),
        ]))
        let before = harness.editor.timeline

        let zero = await harness.runRaw("ripple_trim", args: [
            "clipId": "lead",
            "edge": "right",
            "deltaFrames": 0,
        ])
        #expect(zero.isError)

        let noHandle = await harness.runRaw("ripple_trim", args: [
            "clipId": "lead",
            "edge": "right",
            "deltaFrames": 10,
            "includeLinked": false,
        ])
        #expect(noHandle.isError)
        #expect(harness.editor.timeline == before)
    }

    @Test("reorder_track moves a stable track ID through the canonical zone clamp")
    func reorderTrack() async throws {
        var first = Fixtures.videoTrack(
            id: "visual-first",
            clips: [Fixtures.clip(id: "selected", start: 0, duration: 20)]
        )
        first.hidden = true
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            first,
            Fixtures.videoTrack(id: "visual-second"),
            Fixtures.audioTrack(id: "audio"),
        ]))
        harness.editor.selectedClipIds = ["selected"]
        let undo = UndoManager()
        harness.editor.undoManager = undo

        let payload = try await harness.runOK("reorder_track", args: [
            "trackId": "visual-first",
            "toIndex": 99,
        ]) as? [String: Any]

        #expect(payload?["fromIndex"] as? Int == 0)
        #expect(payload?["toIndex"] as? Int == 1)
        #expect(harness.editor.timeline.tracks.map(\.id) == ["visual-second", "visual-first", "audio"])
        #expect(harness.editor.timeline.tracks[1].hidden)
        #expect(harness.editor.selectedClipIds == ["selected"])
        #expect(undo.undoActionName == "Reorder Track")
    }

    @Test("reorder_track rejects an unknown stable track ID")
    func reorderTrackValidation() async {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "visual"),
        ]))
        let before = harness.editor.timeline

        let result = await harness.runRaw("reorder_track", args: [
            "trackId": "missing",
            "toIndex": 0,
        ])

        #expect(result.isError)
        #expect(harness.editor.timeline == before)
    }

    @Test("slip_clip uses the same exact source-handle plan as native editing")
    func slipClip() async throws {
        let clip = Fixtures.clip(
            id: "clip",
            start: 40,
            duration: 30,
            trimStart: 1,
            trimEnd: 8,
            speed: 0.6
        )
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))
        let undo = UndoManager()
        harness.editor.undoManager = undo

        let payload = try await harness.runOK("slip_clip", args: [
            "clipId": "clip",
            "deltaFrames": 20,
        ]) as? [String: Any]
        let updated = try #require(harness.editor.clipFor(id: "clip"))

        #expect(payload?["appliedTimelineDelta"] as? Int == 2)
        #expect(updated.startFrame == 40)
        #expect(updated.durationFrames == 30)
        #expect(updated.trimStartFrame == 0)
        #expect(updated.trimEndFrame == 9)
        #expect(undo.undoActionName == "Slip Clip")
    }

    @Test("slip_clip refuses source types without bounded temporal handles")
    func slipClipValidation() async {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "image", mediaType: .image, start: 0, duration: 10),
            ]),
        ]))
        let before = harness.editor.timeline

        let result = await harness.runRaw("slip_clip", args: [
            "clipId": "image",
            "deltaFrames": 1,
        ])

        #expect(result.isError)
        #expect(harness.editor.timeline == before)
    }
}

private func rippleSpansForTool(_ track: Track) -> [[Int]] {
    track.clips.sorted { $0.startFrame < $1.startFrame }.map { [$0.startFrame, $0.endFrame] }
}
