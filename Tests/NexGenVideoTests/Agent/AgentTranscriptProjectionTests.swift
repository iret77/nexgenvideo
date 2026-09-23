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

        let turns = AgentTranscriptProjection.turns(
            messages: [user, first, firstResult, second, secondResult, final],
            isStreaming: false
        )

        #expect(turns.count == 1)
        #expect(turns[0].items.count == 3)
        guard case .assistantResult = turns[0].items[1] else {
            Issue.record("the result must precede completed activity detail")
            return
        }
        guard case .activity(let activity) = turns[0].items[2] else {
            Issue.record("the completed activity must follow the result")
            return
        }
        #expect(activity.statuses == ["Reading the storage contract", "Checking recovery behavior"])
        #expect(activity.steps.map(\.id) == ["t1", "t2"])
        #expect(activity.currentStatus == "Checking recovery behavior")
        #expect(activity.operationLabel == "Searching files")
        #expect(activity.isRunning == false)
    }

    @Test("the activity identity stays anchored while its inline status changes")
    func activityIdentityIsStable() {
        let user = AgentMessage(role: .user, blocks: [.text("Work.")])
        let first = AgentMessage(role: .assistant, blocks: [
            .text("First status"),
            .toolUse(id: "t1", name: "Read", inputJSON: "{}"),
        ])
        let initial = AgentTranscriptProjection.turns(messages: [user, first], isStreaming: true)

        let result = AgentMessage(role: .user, blocks: [
            .toolResult(toolUseId: "t1", content: [.text("ok")], isError: false),
        ])
        let second = AgentMessage(role: .assistant, blocks: [
            .text("Second status"),
            .toolUse(id: "t2", name: "Grep", inputJSON: "{}"),
        ])
        let updated = AgentTranscriptProjection.turns(
            messages: [user, first, result, second],
            isStreaming: true
        )

        let initialActivity = initial.flatMap(\.items).compactMap(\.activity).first
        let updatedActivity = updated.flatMap(\.items).compactMap(\.activity).first
        #expect(initialActivity?.id == user.id)
        #expect(updatedActivity?.id == user.id)
        #expect(updatedActivity?.currentStatus == "Second status")
        #expect(updatedActivity?.operationLabel == "Searching files")
    }

    @Test("show_blocks remains durable transcript content")
    func showBlocksIsNotActivity() {
        let assistant = AgentMessage(role: .assistant, blocks: [
            .toolUse(
                id: "show",
                name: ToolName.showBlocks.rawValue,
                inputJSON: #"{"version":"1","blocks":[{"type":"text","body":"Ready"}]}"#
            ),
        ])

        let turns = AgentTranscriptProjection.turns(messages: [assistant], isStreaming: false)

        #expect(turns.count == 1)
        guard case .assistantResult(let message)? = turns[0].items.first else {
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

        let turns = AgentTranscriptProjection.turns(messages: [kickoff, work], isStreaming: true)

        #expect(turns.count == 1)
        guard case .activity(let activity)? = turns[0].items.first else {
            Issue.record("hidden kickoff should leave only its activity")
            return
        }
        #expect(activity.id == kickoff.id)
    }

    @Test("workflow intake records remain visible without becoming activity")
    func workflowRecordIsDurableContent() {
        let record = AgentWorkflowRecord(
            title: "Prepared character 1",
            symbol: "person",
            detail: "Claude Mouse",
            attachmentNames: ["character-sheet.png"],
            outcome: .attached
        )
        let message = AgentMessage(
            role: .user,
            blocks: [],
            userPresentation: AgentUserPresentation(
                choiceRecord: nil,
                typedText: nil,
                workflowRecord: record
            )
        )

        let turns = AgentTranscriptProjection.turns(
            messages: [message],
            isStreaming: false
        )

        #expect(turns.count == 1)
        guard case .receipts(let group)? = turns[0].items.first else {
            Issue.record("workflow record must become a compact receipt")
            return
        }
        #expect(group.receipts.count == 1)
        guard case .workflow(let projected) = group.receipts[0].content else {
            Issue.record("workflow receipt content is missing")
            return
        }
        #expect(projected == record)
    }

    @Test("result, activity, receipts, and notices follow the semantic reading order")
    func semanticReadingOrder() {
        let user = AgentMessage(role: .user, blocks: [.text("Build the look.")])
        let work = AgentMessage(role: .assistant, blocks: [
            .text("Reading references"),
            .toolUse(id: "work", name: "Read", inputJSON: "{}"),
        ])
        let result = AgentMessage(role: .assistant, blocks: [.text("The look is ready.")])
        let receipt = AgentMessage(
            role: .user,
            blocks: [],
            userPresentation: .init(
                choiceRecord: nil,
                typedText: nil,
                notice: "Saved",
                workflowRecord: AgentWorkflowRecord(
                    title: "Style references",
                    symbol: "photo",
                    phase: "brief",
                    detail: nil,
                    attachmentNames: ["reference.png"],
                    outcome: .attached
                )
            )
        )

        let turns = AgentTranscriptProjection.turns(
            messages: [user, work, result, receipt],
            isStreaming: false
        )

        #expect(turns.count == 1)
        let items = turns[0].items
        #expect(items.count == 5)
        if case .userIntent = items[0] {} else { Issue.record("user intent order") }
        if case .assistantResult = items[1] {} else { Issue.record("result order") }
        if case .activity = items[2] {} else { Issue.record("activity order") }
        if case .receipts = items[3] {} else { Issue.record("receipt order") }
        if case .notice = items[4] {} else { Issue.record("notice order") }
    }

    @Test("host records do not become user intents")
    func hostRecordsAreNotAuthoredTurns() {
        let choice = AgentChoiceRecord(
            selections: [.init(label: "Lighting anchor", values: ["Generate"])],
            attachmentNames: [],
            confirmed: false
        )
        let message = AgentMessage(
            role: .user,
            blocks: [.text("internal control command")],
            userPresentation: .init(
                choiceRecord: choice,
                typedText: nil,
                notice: "Saved"
            )
        )

        let turns = AgentTranscriptProjection.turns(messages: [message], isStreaming: false)

        #expect(turns.count == 1)
        #expect(turns[0].items.count == 2)
        #expect(!turns[0].items.contains(where: {
            if case .userIntent = $0 { return true }
            return false
        }))
    }

    @Test("plain streaming prose remains the turn's single primary result")
    func plainStreamingResult() {
        let user = AgentMessage(role: .user, blocks: [.text("Summarize the cut.")])
        let partial = AgentMessage(role: .assistant, blocks: [.text("The opening is clear")])

        let turns = AgentTranscriptProjection.turns(
            messages: [user, partial],
            isStreaming: true
        )

        #expect(turns.count == 1)
        #expect(turns[0].items.count == 2)
        guard case .assistantResult(let result) = turns[0].items[1] else {
            Issue.record("streaming prose must remain a primary result")
            return
        }
        #expect(result.id == partial.id)
        #expect(result.blocks.count == 1)
    }

    @Test("assistant prose and rich output fold into one result")
    func richOutputUsesOneResult() {
        let user = AgentMessage(role: .user, blocks: [.text("Report the project state.")])
        let prose = AgentMessage(role: .assistant, blocks: [.text("The cut is ready.")])
        let rich = AgentMessage(role: .assistant, blocks: [
            .toolUse(
                id: "report",
                name: ToolName.showBlocks.rawValue,
                inputJSON: #"{"version":"1","blocks":[{"type":"status","badges":[{"label":"Cut","value":"Ready"}]}]}"#
            ),
        ])

        let turns = AgentTranscriptProjection.turns(
            messages: [user, prose, rich],
            isStreaming: false
        )

        #expect(turns.count == 1)
        #expect(turns[0].items.count == 2)
        guard case .assistantResult(let result) = turns[0].items[1] else {
            Issue.record("the turn must contain one primary result")
            return
        }
        #expect(result.id == prose.id)
        #expect(result.blocks.count == 2)
    }

    @Test("consecutive workflow receipts from one phase form one durable group")
    func groupsWorkflowReceiptsByPhase() {
        let first = AgentMessage(
            role: .user,
            blocks: [],
            userPresentation: .init(
                choiceRecord: nil,
                typedText: nil,
                workflowRecord: .init(
                    title: "Prepared character 1",
                    symbol: "person",
                    phase: "brief",
                    detail: "Claude Mouse",
                    attachmentNames: ["claude-front.png"],
                    outcome: .attached
                )
            )
        )
        let second = AgentMessage(
            role: .user,
            blocks: [],
            userPresentation: .init(
                choiceRecord: nil,
                typedText: nil,
                workflowRecord: .init(
                    title: "Prepared character 2",
                    symbol: "person",
                    phase: "brief",
                    detail: "AI Cat",
                    attachmentNames: [],
                    outcome: .skipped
                )
            )
        )

        let turns = AgentTranscriptProjection.turns(
            messages: [first, second],
            isStreaming: false
        )

        #expect(turns.count == 1)
        #expect(turns[0].items.count == 1)
        guard case .receipts(let group) = turns[0].items[0] else {
            Issue.record("workflow records must remain receipts")
            return
        }
        #expect(group.phase == "brief")
        #expect(group.receipts.count == 2)
    }

    @Test("versionless saved rich output preserves its stored result order")
    func legacySavedResultOrdering() {
        let rich = AgentMessage(role: .assistant, blocks: [
            .toolUse(
                id: "legacy",
                name: ToolName.showBlocks.rawValue,
                inputJSON: #"{"blocks":[{"type":"text","body":"Saved report"}]}"#
            ),
        ])
        let prose = AgentMessage(role: .assistant, blocks: [.text("Saved conclusion")])

        let turns = AgentTranscriptProjection.turns(
            messages: [rich, prose],
            isStreaming: false
        )

        #expect(turns.count == 1)
        #expect(turns[0].items.count == 1)
        guard case .assistantResult(let result) = turns[0].items[0] else {
            Issue.record("legacy content must remain a readable result")
            return
        }
        #expect(result.id == rich.id)
        #expect(result.blocks.count == 2)
    }

    @Test("resume recovery projects only the latest host artifact state")
    func resumeRecoveryUsesLatestHostState() throws {
        let resume = AgentMessage(
            role: .user,
            blocks: [.text("Resume the storyboard phase.")],
            hidden: true
        )
        let copiedReference = AgentMessage(role: .assistant, blocks: [
            .text("Checking the resumed reference."),
            .toolUse(id: "copy", name: "copy_project_file", inputJSON: "{}"),
        ])
        let copiedReferenceResult = AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "copy",
                content: [.text("reference copied")],
                isError: false
            ),
        ])
        let rejectedWrite = AgentMessage(role: .assistant, blocks: [
            .text("The storyboard is written and ready."),
            .toolUse(id: "rejected", name: "write_storyboard", inputJSON: "{}"),
        ])
        let draftState = hostStateMessage(.init(
            state: .draft,
            phase: "storyboard",
            toolName: "write_storyboard",
            action: .none,
            artifactPath: "storyboard/current.yaml",
            byteComparison: nil,
            previousSHA256: String(repeating: "a", count: 64),
            currentSHA256: nil
        ))
        let rejectedState = hostStateMessage(.init(
            state: .writeRejected,
            phase: "storyboard",
            toolName: "write_storyboard",
            action: .reviewChangedSource,
            artifactPath: "storyboard/current.yaml",
            byteComparison: nil,
            previousSHA256: String(repeating: "a", count: 64),
            currentSHA256: nil
        ))
        let rejectedResult = AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "rejected",
                content: [.text("Approved source lineage changed.")],
                isError: true
            ),
        ])
        let zoneRepair = AgentMessage(role: .assistant, blocks: [
            .text("Repairing visible zones."),
            .toolUse(id: "zone", name: "write_storyboard", inputJSON: "{}"),
        ])
        let zoneState = hostStateMessage(.init(
            state: .writeRejected,
            phase: "storyboard",
            toolName: "write_storyboard",
            action: .agentCorrection,
            artifactPath: "storyboard/current.yaml",
            byteComparison: nil,
            previousSHA256: nil,
            currentSHA256: nil
        ))
        let zoneResult = AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "zone",
                content: [.text("visible_zones needs a blocking anchor.")],
                isError: true
            ),
        ])
        let successfulWrite = AgentMessage(role: .assistant, blocks: [
            .text("The recovery is complete."),
            .toolUse(id: "written", name: "write_storyboard", inputJSON: "{}"),
            .toolUse(id: "checked", name: "approve_gate", inputJSON: #"{"phase":"storyboard"}"#),
        ])
        let persistedState = hostStateMessage(.init(
            state: .persisted,
            phase: "storyboard",
            toolName: "write_storyboard",
            action: .reviewForApproval,
            artifactPath: "storyboard/current.yaml",
            byteComparison: .changed,
            previousSHA256: String(repeating: "a", count: 64),
            currentSHA256: String(repeating: "b", count: 64)
        ))
        let checkedState = hostStateMessage(.init(
            state: .checked,
            phase: "storyboard",
            toolName: "approve_gate",
            action: .reviewForApproval,
            artifactPath: nil,
            byteComparison: nil,
            previousSHA256: nil,
            currentSHA256: nil
        ))
        let unpricedBatch = AgentMessage(role: .assistant, blocks: [
            .text("Preparing the next generation batch."),
            .toolUse(id: "batch", name: "prepare_generation_batch", inputJSON: "{}"),
        ])
        let unpricedBatchResult = AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "batch",
                content: [.text("Generation batch review is open.")],
                isError: false
            ),
        ])

        let turns = AgentTranscriptProjection.turns(
            messages: [
                resume, copiedReference, copiedReferenceResult,
                rejectedWrite, draftState, rejectedState, rejectedResult,
                zoneRepair, zoneState, zoneResult, successfulWrite,
                persistedState, checkedState, unpricedBatch, unpricedBatchResult,
            ],
            isStreaming: false
        )

        #expect(turns.count == 1)
        let items = turns[0].items
        let states = items.compactMap { item -> AgentHostStateRecord? in
            guard case .hostState(let state) = item else { return nil }
            return state.record
        }
        #expect(states.count == 1)
        #expect(states.first?.state == .checked)
        #expect(!items.contains {
            if case .assistantResult = $0 { return true }
            return false
        })
        let activity = try #require(items.compactMap(\.activity).first)
        #expect(activity.steps.map(\.id) == [
            "copy", "rejected", "zone", "written", "checked", "batch",
        ])
    }

    @Test("host state records never become authored user turns")
    func hostStateIsNotAUserIntent() {
        let message = hostStateMessage(.init(
            state: .persisted,
            phase: "brief",
            toolName: "write_brief",
            action: .reviewForApproval,
            artifactPath: "brief.yaml",
            byteComparison: .unchanged,
            previousSHA256: String(repeating: "a", count: 64),
            currentSHA256: String(repeating: "a", count: 64)
        ))

        let turns = AgentTranscriptProjection.turns(messages: [message], isStreaming: false)

        #expect(turns.count == 1)
        #expect(turns[0].items.count == 1)
        guard case .hostState(let state) = turns[0].items[0] else {
            Issue.record("host state must use its own projection")
            return
        }
        #expect(state.record.byteComparison == .unchanged)
    }

    private func hostStateMessage(_ record: AgentHostStateRecord) -> AgentMessage {
        AgentMessage(
            role: .user,
            blocks: [],
            userPresentation: .init(
                choiceRecord: nil,
                typedText: nil,
                hostStateRecord: record
            )
        )
    }
}

private extension AgentTranscriptItem {
    var activity: AgentActivity? {
        guard case .activity(let activity) = self else { return nil }
        return activity
    }
}
