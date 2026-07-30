import Testing
@testable import NexGenVideo

@Suite("Agent transcript revision")
@MainActor
struct AgentTranscriptRevisionTests {
    @Test func advancesForReplacementAndInPlaceGrowth() {
        let service = AgentService()
        let initialRevision = service.transcriptRevision

        service.messages = [
            AgentMessage(role: .assistant, blocks: [.text("Working")]),
        ]

        #expect(service.transcriptRevision == initialRevision &+ 1)
        let replacementRevision = service.transcriptRevision

        service.messages[0].blocks.append(.text("Still working"))

        #expect(service.transcriptRevision == replacementRevision &+ 1)
    }

    @Test func runningToolTurnFollowsItsPersistentTail() {
        let activityMessage = AgentMessage(
            role: .assistant,
            blocks: [
                .text("Preparing"),
                .toolUse(id: "run", name: "mcp__nexgen__run_phase", inputJSON: "{}"),
            ]
        )
        let reportMessage = AgentMessage(
            role: .assistant,
            blocks: [
                .toolUse(id: "report", name: "mcp__nexgen__show_blocks", inputJSON: "{}"),
            ]
        )
        let entries = AgentTranscriptProjection.entries(
            messages: [activityMessage, reportMessage],
            isStreaming: true
        )

        #expect(entries.contains {
            if case .activity(let activity) = $0 { return activity.isRunning }
            return false
        })
        #expect(AgentTranscriptScrollPolicy.targetID(
            entries: entries,
            isStreaming: true
        ) == entries.last?.id)
    }

    @Test func plainStreamingTurnFollowsTheIndicator() {
        let entries = AgentTranscriptProjection.entries(
            messages: [
                AgentMessage(role: .assistant, blocks: [.text("Preparing")]),
            ],
            isStreaming: true
        )

        #expect(AgentTranscriptScrollPolicy.targetID(
            entries: entries,
            isStreaming: true
        ) == "streaming-indicator")
    }

    @Test func scrollDistanceOnlyPinsAwayBeyondTheThreshold() {
        #expect(!AgentTranscriptScrollPolicy.isAwayFromBottom(
            contentHeight: 1_000,
            contentOffsetY: 700,
            containerHeight: 250,
            threshold: 60
        ))
        #expect(AgentTranscriptScrollPolicy.isAwayFromBottom(
            contentHeight: 1_000,
            contentOffsetY: 680,
            containerHeight: 250,
            threshold: 60
        ))
    }
}
