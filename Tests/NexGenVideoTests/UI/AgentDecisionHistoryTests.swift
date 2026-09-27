import Foundation
import Testing
@testable import NexGenVideo

@Suite("Agent decision history")
@MainActor
struct AgentDecisionHistoryTests {
    @Test func persistedDecisionsRemainReadableWithoutIncludingRawCommands() throws {
        let receipt = AgentWorkflowRecord(title: "Lyrics", symbol: "doc.text", phase: "init",
            detail: "No lyrics supplied", attachmentNames: [], outcome: .skipped)
        let decision = AgentMessage(role: .user, blocks: [.text("internal workflow command")], hidden: true,
            userPresentation: .init(choiceRecord: nil, typedText: nil, workflowRecord: receipt))
        let plain = AgentMessage(role: .assistant, blocks: [.text("Working")])
        let restored = try JSONDecoder().decode([AgentMessage].self,
            from: JSONEncoder().encode([plain, decision]))
        let records = AgentDecisionHistoryView.records(in: restored)
        #expect(records.map(\.id) == [decision.id])
        #expect(records.first?.userPresentation?.workflowRecord?.outcome == .skipped)
        #expect(records.first?.userPresentation?.workflowRecord?.title == "Lyrics")
        #expect(records.first?.userPresentation?.typedText == nil)
    }

    @Test func requiredDirectionRejectsWhitespaceWithoutConsumingDraft() {
        let harness = ToolHarness()
        let service = harness.editor.agentService
        let task = AgentService.PendingFunction(title: "Revise section", systemImage: "pencil",
            prompt: "Revise the selected section.", requiresDirection: true)
        service.pendingFunction = task
        service.draft = "  \n "
        let messageIDs = service.messages.map(\.id)

        #expect(!service.sendWorkOrder(task, direction: service.draft, mentions: []))
        #expect(service.pendingFunction == task)
        #expect(service.draft == "  \n ")
        #expect(service.messages.map(\.id) == messageIDs)
    }

}
