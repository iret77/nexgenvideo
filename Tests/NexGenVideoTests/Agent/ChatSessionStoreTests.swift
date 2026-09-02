import Foundation
import Testing
@testable import NexGenVideo

@Suite("ChatSession persistence")
struct ChatSessionStoreTests {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @Test("claudeSessionId round-trips through the on-disk encoding, so reload can --resume the chat")
    func claudeSessionIdRoundTrips() throws {
        var session = ChatSession(title: "t", messages: [AgentMessage(role: .user, blocks: [.text("hi")])])
        session.claudeSessionId = "abc-123"
        let data = try #require(ChatSessionStore.encodeSession(session))
        let back = try decoder.decode(ChatSession.self, from: data)
        #expect(back.claudeSessionId == "abc-123")
        #expect(back.id == session.id)
    }

    @Test("a legacy chat file written before session-resume decodes with a nil claudeSessionId")
    func decodesLegacyPayloadWithoutClaudeSessionId() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"old","updatedAt":"2026-01-01T00:00:00Z","messages":[],"isOpen":true}
        """
        let session = try decoder.decode(ChatSession.self, from: Data(json.utf8))
        #expect(session.claudeSessionId == nil)
    }

    @Test("dialog choice presentation round-trips with the semantic user turn")
    func dialogPresentationRoundTrips() throws {
        let record = AgentChoiceRecord(
            selections: [.init(label: "Shots", values: ["Generated"])],
            attachmentNames: [],
            confirmed: false
        )
        let presentation = AgentUserPresentation(
            choiceRecord: record,
            typedText: "Keep it stark.",
            notice: "One file was not attached."
        )
        let message = AgentMessage(
            role: .user,
            blocks: [.text("The user submitted the setup dialog.")],
            userPresentation: presentation
        )
        let session = ChatSession(title: "t", messages: [message])

        let data = try #require(ChatSessionStore.encodeSession(session))
        let back = try decoder.decode(ChatSession.self, from: data)

        #expect(back.messages.first?.userPresentation == presentation)
    }

    @Test("workflow intake records round-trip without synthetic chat prose")
    func workflowRecordRoundTrips() throws {
        let record = AgentWorkflowRecord(
            title: "Prepared character 1",
            symbol: "person.crop.rectangle.stack",
            phase: "brief",
            detail: "Claude Mouse",
            attachmentNames: ["claude-front.png", "claude-side.png"],
            outcome: .attached
        )
        let presentation = AgentUserPresentation(
            choiceRecord: nil,
            typedText: nil,
            workflowRecord: record
        )
        let session = ChatSession(
            title: "t",
            messages: [AgentMessage(
                role: .user,
                blocks: [],
                userPresentation: presentation
            )]
        )

        let data = try #require(ChatSessionStore.encodeSession(session))
        let back = try decoder.decode(ChatSession.self, from: data)

        #expect(back.messages.first?.blocks.isEmpty == true)
        #expect(back.messages.first?.userPresentation?.workflowRecord == record)
    }

    @Test("conversation titles preserve distinguishing text at both ends")
    func conversationTitleUsesMiddleCompaction() {
        let source = String(repeating: "opening detail ", count: 8)
            + String(repeating: "shared middle ", count: 8)
            + "distinct ending"
        let title = AgentService.conversationTitle(from: source)

        #expect(title.count == 120)
        #expect(title.contains("…"))
        #expect(title.hasPrefix("opening detail"))
        #expect(title.hasSuffix("distinct ending"))
    }

    @Test("conversation switching restores only that conversation's composer state")
    @MainActor
    func composerStateIsScopedToConversation() throws {
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.newChat()
        let originalHeight = service.composerHeight
        defer { service.composerHeight = originalHeight }

        let firstSessionID = try #require(service.currentSessionId)
        let firstMention = AgentMention(
            displayName: "First-reference",
            mediaRef: "first-asset",
            type: .image
        )
        let firstFunction = AgentService.PendingFunction(
            title: "First function",
            systemImage: "sparkles",
            prompt: "Run the first function"
        )
        let firstHeight = Double(AppTheme.ComponentSize.agentComposerMinHeight)
            + Double(AppTheme.Spacing.md)
        service.draft = "First draft @First-reference"
        service.mentions = [firstMention]
        service.pendingFunction = firstFunction
        service.composerHeight = firstHeight
        service.recordComposerFocus(true)

        service.newChat()
        let secondSessionID = try #require(service.currentSessionId)
        #expect(secondSessionID != firstSessionID)
        #expect(service.draft.isEmpty)
        #expect(service.mentions.isEmpty)
        #expect(service.pendingFunction == nil)
        #expect(!service.composerShouldFocus)

        let secondMention = AgentMention(
            displayName: "Second-reference",
            mediaRef: "second-asset",
            type: .image
        )
        let secondHeight = Double(AppTheme.ComponentSize.agentComposerMinHeight)
            + Double(AppTheme.Spacing.xl)
        service.draft = "Second draft @Second-reference"
        service.mentions = [secondMention]
        service.composerHeight = secondHeight

        service.selectAdjacentOpenSession(offset: 1)
        #expect(service.currentSessionId == firstSessionID)
        #expect(service.draft == "First draft @First-reference")
        #expect(service.mentions == [firstMention])
        #expect(service.pendingFunction == firstFunction)
        #expect(service.composerHeight == firstHeight)
        #expect(service.composerShouldFocus)

        service.selectAdjacentOpenSession(offset: -1)
        #expect(service.currentSessionId == secondSessionID)
        #expect(service.draft == "Second draft @Second-reference")
        #expect(service.mentions == [secondMention])
        #expect(service.pendingFunction == nil)
        #expect(service.composerHeight == secondHeight)
        #expect(!service.composerShouldFocus)
    }

    @Test("a dock decision leaves the owning conversation composer state unchanged")
    @MainActor
    func composerStateSurvivesDecisionRoundTrip() throws {
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.newChat()
        let originalHeight = service.composerHeight
        defer { service.composerHeight = originalHeight }
        let mention = AgentMention(
            displayName: "Look-reference",
            mediaRef: "look-reference",
            type: .image
        )
        let height = Double(AppTheme.ComponentSize.agentComposerMinHeight)
            + Double(AppTheme.Spacing.xl)
        service.draft = "Keep this draft @Look-reference"
        service.mentions = [mention]
        service.composerHeight = height
        service.recordComposerFocus(true)

        let dialog = AgentDialog(
            id: "decision-round-trip",
            title: "Choose the treatment",
            symbol: "questionmark",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: nil,
            sections: []
        )
        try service.presentDialog(dialog)
        #expect(service.isComposerBlocked)
        service.abandonDialog()

        #expect(!service.isComposerBlocked)
        #expect(service.draft == "Keep this draft @Look-reference")
        #expect(service.mentions == [mention])
        #expect(service.composerHeight == height)
        #expect(service.composerShouldFocus)
    }

    @Test("conversation attention is keyed to the owning session")
    @MainActor
    func sessionAttentionIsScoped() async throws {
        let service = AgentService()
        service.newChat()
        let current = try #require(service.currentSessionId)
        service.isStreaming = true
        #expect(service.sessionAttention(for: current) == .running)
        service.isStreaming = false

        _ = try service.requestGateApproval(GateApproval(phase: "brief"))
        #expect(service.sessionAttention(for: current) == .actionRequired)
        _ = await service.resolveGate(.declined)
    }

    @Test("strict project load rejects a malformed chat instead of dropping it")
    func malformedChatIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ngv-chat-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = root.appendingPathComponent(ChatSessionStore.dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: chat.appendingPathComponent("session.json"))

        #expect(throws: (any Error).self) {
            _ = try ChatSessionStore.loadThrowing(from: root)
        }
        #expect(FileManager.default.fileExists(
            atPath: chat.appendingPathComponent("session.json").path
        ))
    }
}
