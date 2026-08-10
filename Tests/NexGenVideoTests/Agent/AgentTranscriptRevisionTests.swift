import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Agent transcript scrolling")
@MainActor
struct AgentTranscriptRevisionTests {
    @Test func runningToolTurnProjectsItsPersistentTail() {
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
    }

    @Test func plainStreamingTurnProjectsWithoutAnActivity() {
        let entries = AgentTranscriptProjection.entries(
            messages: [
                AgentMessage(role: .assistant, blocks: [.text("Preparing")]),
            ],
            isStreaming: true
        )

        #expect(!entries.contains {
            if case .activity = $0 { return true }
            return false
        })
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

    @Test func everyObservedUserScrollPhaseUsesMeasuredGeometry() {
        for phase in [ScrollPhase.interacting, .decelerating, .idle] {
            #expect(AgentTranscriptScrollPolicy.pinState(
                for: phase,
                contentHeight: 1_000,
                contentOffsetY: 700,
                containerHeight: 250,
                threshold: 60
            ) == false)
            #expect(AgentTranscriptScrollPolicy.pinState(
                for: phase,
                contentHeight: 1_000,
                contentOffsetY: 680,
                containerHeight: 250,
                threshold: 60
            ) == true)
        }
        #expect(AgentTranscriptScrollPolicy.pinState(
            for: .animating,
            contentHeight: 1_000,
            contentOffsetY: 680,
            containerHeight: 250,
            threshold: 60
        ) == nil)
    }
}
