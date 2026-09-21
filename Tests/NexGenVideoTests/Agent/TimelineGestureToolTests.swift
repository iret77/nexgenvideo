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
}

private func rippleSpansForTool(_ track: Track) -> [[Int]] {
    track.clips.sorted { $0.startFrame < $1.startFrame }.map { [$0.startFrame, $0.endFrame] }
}
