import Foundation
import Testing
@testable import NexGenVideo

@Suite("Agent transcript projection")
struct AgentTranscriptProjectionTests {
    @Test("a tool loop renders as one replaceable activity row plus the final answer")
    func collapsesToolLoop() {
        let user = AgentMessage(role: .user, blocks: [.text("Review the project.")])
        let first = AgentMessage(role: .assistant, blocks: [
            .text("Reading the storage contract"),
            .toolUse(id: "t1", name: "Read", inputJSON: #"{"path":"PROJECT_STORAGE.md"}"#),
        ])
        let firstResult = AgentMessage(role: .user, blocks: [
            .toolResult(toolUseId: "t1", content: [.text("ok")], isError: false),
        ])
        let second = AgentMessage(role: .assistant, blocks: [
            .text("Checking recovery behavior"),
            .toolUse(id: "t2", name: "Grep", inputJSON: #"{"pattern":"workingRoot"}"#),
        ])
        let secondResult = AgentMessage(role: .user, blocks: [
            .toolResult(toolUseId: "t2", content: [.text("ok")], isError: false),
        ])
        let final = AgentMessage(role: .assistant, blocks: [.text("The package is not release-ready.")])

        let entries = AgentTranscriptProjection.entries(
            messages: [user, first, firstResult, second, secondResult, final],
            isStreaming: false
        )

        #expect(entries.count == 3)
        guard case .activity(let activity) = entries[1] else {
            Issue.record("the middle row must be the consolidated activity")
            return
        }
        #expect(activity.statuses == ["Reading the storage contract", "Checking recovery behavior"])
        #expect(activity.steps.map(\.id) == ["t1", "t2"])
        #expect(activity.currentStatus == "Checking recovery behavior")
        #expect(activity.isRunning == false)
    }

    @Test("the activity identity stays anchored while its inline status changes")
    func activityIdentityIsStable() {
        let user = AgentMessage(role: .user, blocks: [.text("Work.")])
        let first = AgentMessage(role: .assistant, blocks: [
            .text("First status"),
            .toolUse(id: "t1", name: "Read", inputJSON: "{}"),
        ])
        let initial = AgentTranscriptProjection.entries(messages: [user, first], isStreaming: true)

        let result = AgentMessage(role: .user, blocks: [
            .toolResult(toolUseId: "t1", content: [.text("ok")], isError: false),
        ])
        let second = AgentMessage(role: .assistant, blocks: [
            .text("Second status"),
            .toolUse(id: "t2", name: "Grep", inputJSON: "{}"),
        ])
        let updated = AgentTranscriptProjection.entries(
            messages: [user, first, result, second],
            isStreaming: true
        )

        let initialActivity = initial.compactMap(\.activity).first
        let updatedActivity = updated.compactMap(\.activity).first
        #expect(initialActivity?.id == user.id)
        #expect(updatedActivity?.id == user.id)
        #expect(updatedActivity?.currentStatus == "Second status")
    }

    @Test("show_blocks remains durable transcript content")
    func showBlocksIsNotActivity() {
        let assistant = AgentMessage(role: .assistant, blocks: [
            .toolUse(
                id: "show",
                name: ToolName.showBlocks.rawValue,
                inputJSON: #"{"blocks":[{"type":"text","text":"Ready"}]}"#
            ),
        ])

        let entries = AgentTranscriptProjection.entries(messages: [assistant], isStreaming: false)

        #expect(entries.count == 1)
        guard case .message(let message) = entries[0] else {
            Issue.record("show_blocks must remain a transcript message")
            return
        }
        #expect(message.blocks.count == 1)
    }

    @Test("hidden kickoffs stay hidden while their activity remains visible")
    func hiddenKickoffDoesNotBecomeUserTurn() {
        let kickoff = AgentMessage(role: .user, blocks: [.text("Start.")], hidden: true)
        let work = AgentMessage(role: .assistant, blocks: [
            .text("Preparing the workflow"),
            .toolUse(id: "t1", name: "get_project_state", inputJSON: "{}"),
        ])

        let entries = AgentTranscriptProjection.entries(messages: [kickoff, work], isStreaming: true)

        #expect(entries.count == 1)
        guard case .activity(let activity) = entries[0] else {
            Issue.record("hidden kickoff should leave only its activity")
            return
        }
        #expect(activity.id == kickoff.id)
    }
}

private extension AgentTranscriptEntry {
    var activity: AgentActivity? {
        guard case .activity(let activity) = self else { return nil }
        return activity
    }
}
