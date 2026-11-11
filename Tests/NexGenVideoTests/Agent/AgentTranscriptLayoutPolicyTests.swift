import Testing
@testable import NexGenVideo

@Suite("Agent transcript activity")
@MainActor
struct AgentTranscriptLayoutPolicyTests {
    @Test func runningTranscriptActivityIsPassedToTheSurfaceState() {
        let editor = EditorViewModel()
        for hasActivity in [false, true] {
            let input = AgentSurfaceState.Input.current(editor: editor, hasTranscriptActivity: hasActivity)
            #expect(input.streamHasTranscriptActivity == hasActivity)
            #expect(input.phaseHasTranscriptActivity == hasActivity)
        }
    }
}
