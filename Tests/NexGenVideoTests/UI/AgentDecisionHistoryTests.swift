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

    @Test func stagedRevisionKeepsTheExactAssetWhenAnotherSameNamedAssetIsSelected() throws {
        let service = AgentService(refreshBackendStatusOnInit: false)
        let editor = EditorViewModel(agentService: service)
        service.loadSessions(from: nil)
        let first = MediaAsset(id: "first-source", url: URL(fileURLWithPath: "/tmp/first.mov"),
            type: .video, name: "Interview", duration: 10)
        let second = MediaAsset(id: "second-source", url: URL(fileURLWithPath: "/tmp/second.mov"),
            type: .video, name: "Interview", duration: 10)
        editor.mediaAssets = [first, second]
        editor.selectMediaAsset(first)
        let task = try #require(editor.selectedObjectRevisionTask)
        #expect(service.stageTask(task))
        editor.selectMediaAsset(second)
        #expect(task.prompt.contains("media asset ID first-source"))
        #expect(service.pendingFunction == task)
        #expect(service.pendingFunction?.prompt.contains("second-source") == false)
        #expect(editor.selectedObjectRevisionTask?.prompt.contains("media asset ID second-source") == true)
        #expect(task.requiresDirection)
        #expect(service.messages.isEmpty)
    }

    @Test func multiClipRevisionNamesEveryTargetInsteadOfOnlyTheirCount() throws {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.selectedClipIds = ["clip-b", "clip-a"]
        let task = try #require(editor.selectedObjectRevisionTask)
        #expect(task.prompt.contains("timeline clip IDs clip-a, clip-b"))
        editor.selectedClipIds = ["clip-c", "clip-d"]
        #expect(task.prompt.contains("clip-c") == false)
        #expect(task.prompt.contains("clip-d") == false)
        editor.selectedClipIds = []
        editor.inspectedObject = nil
        #expect(editor.selectedObjectRevisionTask == nil)
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


    @Test func stagingDoesNotRunOrConsumeInstructionsAndBusyActionsPreserveTheCurrentTask() {
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.loadSessions(from: nil)
        service.draft = "Keep the ending quiet"
        let task = AgentTask(title: "Revise music", systemImage: "music.note", prompt: "Revise timeline music.")
        #expect(service.stageTask(task))
        #expect(service.pendingFunction == task)
        #expect(service.draft == "Keep the ending quiet")
        #expect(service.messages.isEmpty)
        #expect(!service.isStreaming)

        service.isStreaming = true
        defer { service.isStreaming = false }
        let next = AgentTask(title: "Revise captions", systemImage: "captions.bubble", prompt: "Revise captions.")
        #expect(!service.stageTask(next))
        #expect(!service.sendWorkOrder(next, direction: "Shorten them", mentions: []))
        #expect(!service.send(controlTurn: .init(command: "Apply the revision")))
        #expect(service.pendingFunction == task)
        #expect(service.draft == "Keep the ending quiet")
        #expect(service.messages.isEmpty)
    }

}
