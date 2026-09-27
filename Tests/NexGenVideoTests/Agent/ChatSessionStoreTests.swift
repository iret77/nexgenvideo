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
        #expect(session.draft == nil)
        #expect(session.decision == nil)
    }

    @Test("Open decisions reload in their owning session without sending or approving")
    @MainActor
    func openDecisionSurvivesReloadWithoutExecution() throws {
        for embedded in [false, true] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let chat = home.appendingPathComponent(ChatSessionStore.dirName)
            try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let service = AgentService(refreshBackendStatusOnInit: false)
            service.loadSessions(from: nil)
            let id = try #require(service.currentSessionId)
            let origin: ToolCallOrigin = embedded
                ? .embeddedRuntime(chatSessionID: id, mcpSessionID: UUID())
                : .inAppChat(sessionID: id)
            let dialog = try AgentDialog.parse([
                "title": "Revise the chorus", "textField": ["placeholder": "Direction"],
                "sections": [["id": "pace", "label": "Pace", "type": "choices", "options": [
                    ["id": "slow", "label": "Slower"], ["id": "fast", "label": "Faster"],
                ]]],
            ])
            try service.presentDialog(dialog, origin: origin)
            service.dialogDraft = AgentDialogDraft(toggles: ["keep": true], direction: "Preserve the ending",
                customValues: ["style": "Muted"], fileURLs: [URL(fileURLWithPath: "/tmp/reference.png")])
            service.dialogChoiceSelections = ["pace": ["slow"]]
            let saved = try #require(service.sessions.first { $0.id == id })
            #expect(saved.hasPersistedContent)
            #expect(saved.decision?.origin == origin)
            try #require(ChatSessionStore.encodeSession(saved)).write(
                to: chat.appendingPathComponent("\(id.uuidString).json"))

            let restored = AgentService(refreshBackendStatusOnInit: false)
            var writes = 0
            restored.onSessionsChanged = { writes += 1 }
            restored.onDraftChanged = { writes += 1 }
            restored.loadSessions(from: home)
            #expect(restored.currentSessionId == id)
            #expect(restored.pendingDialog == dialog)
            #expect(restored.dialogDraft.direction == "Preserve the ending")
            #expect(restored.dialogDraft.fileURLs == [URL(fileURLWithPath: "/tmp/reference.png")])
            #expect(restored.dialogDraft.customValues == ["style": "Muted"])
            #expect(restored.dialogDraft.toggles == ["keep": true])
            #expect(restored.dialogChoiceSelections == ["pace": ["slow"]])
            #expect(restored.messages.isEmpty)
            #expect(!restored.isStreaming)
            #expect(restored.isComposerBlocked)
            #expect(writes == 0)
            #expect(throws: ToolError.self) { try restored.presentDialog(dialog, origin: origin) }
            restored.abandonDialog()
            #expect(restored.sessions.first { $0.id == id }?.decision == nil)
            #expect(restored.messages.isEmpty)
        }
    }

    @Test("Intake inputs restore only after the host reoffers the matching current step")
    @MainActor
    func intakeReloadRequiresMatchingHostOffer() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chat = home.appendingPathComponent(ChatSessionStore.dirName)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let binding = try #require(ProjectPackBinding(id: "musicvideo", version: "1.0.0", projectSchema: "musicvideo/1"))
        let key = WorkflowIntakeDraftKey(packBinding: binding, phase: "story", stepID: "characters",
            itemNumber: 1, fingerprint: 0, isRepeat: false)
        func dialog(_ title: String = "Character 1") -> AgentDialog {
            AgentDialog(id: UUID().uuidString, title: title, symbol: "person",
                intro: nil, costHint: nil, confirmLabel: "Attach", textField: nil, sections: [],
                fileIntake: AgentDialog.FileIntake(accept: ["image"], prompt: nil,
                    allowsMultiple: true, attachAs: "character", namePrompt: "Name",
                    required: false, completionLabel: "Skip"), purpose: .workflowIntake)
        }
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.loadSessions(from: nil)
        let id = try #require(service.currentSessionId)
        try service.presentDialog(dialog(), intakeKey: key)
        service.dialogDraft.direction = "Lead singer"
        service.dialogDraft.fileURLs = [URL(fileURLWithPath: "/tmp/singer.png")]
        let saved = try #require(service.sessions.first { $0.id == id })
        #expect(saved.decision?.intakeKey == key)
        try #require(ChatSessionStore.encodeSession(saved)).write(
            to: chat.appendingPathComponent("\(id.uuidString).json"))

        let changedPhase = WorkflowIntakeDraftKey(packBinding: binding, phase: "bible", stepID: "characters",
            itemNumber: 1, fingerprint: 0, isRepeat: false)
        let nextItem = WorkflowIntakeDraftKey(packBinding: binding, phase: "story", stepID: "characters",
            itemNumber: 2, fingerprint: 1, isRepeat: true)
        let changedPack = WorkflowIntakeDraftKey(packBinding: nil, phase: "story", stepID: "characters",
            itemNumber: 1, fingerprint: 0, isRepeat: false)
        for (offeredKey, title, shouldRestore) in [
            (key, "Character 1", true), (changedPhase, "Character 1", false),
            (nextItem, "Character 1", false), (changedPack, "Character 1", false),
            (key, "Location 1", false),
        ] {
            let restored = AgentService(refreshBackendStatusOnInit: false)
            restored.loadSessions(from: home)
            #expect(restored.currentSessionId == id)
            #expect(restored.pendingDialog == nil)
            #expect(restored.messages.isEmpty)
            let offered = dialog(title)
            try restored.presentDialog(offered, intakeKey: offeredKey)
            #expect(restored.pendingDialog?.id == offered.id)
            #expect(restored.dialogDraft.direction == (shouldRestore ? "Lead singer" : ""))
            #expect(restored.dialogDraft.fileURLs.count == (shouldRestore ? 1 : 0))
            #expect(restored.messages.isEmpty)
            #expect(!restored.isStreaming)
            if shouldRestore {
                restored.completeDialog(offered)
                #expect(restored.dialogSubmissionError != nil)
                #expect(restored.sessions.first { $0.id == id }?.decision?.intakeKey == key)
                #expect(restored.dialogDraft.direction == "Lead singer")
            }
        }
    }

    @Test("A saved decision cannot claim another session or an external MCP connection")
    func decisionRequiresItsOriginalSession() throws {
        let owner = UUID()
        let dialog = try AgentDialog.parse(["title": "Direction", "textField": [:]])
        for origin in [ToolCallOrigin.inAppChat(sessionID: UUID()),
                       .embeddedRuntime(chatSessionID: UUID(), mcpSessionID: UUID()),
                       .externalMCP(sessionID: owner)] {
            let saved = ChatSessionDecision(dialog: dialog, origin: origin,
                draft: AgentDialogDraft(), selections: [:])
            #expect(!saved.belongs(to: owner))
        }
    }

    @Test("An unsent task survives disk reload without starting the agent")
    @MainActor
    func unsentTaskSurvivesReload() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chat = home.appendingPathComponent(ChatSessionStore.dirName)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.loadSessions(from: nil)
        let id = try #require(service.currentSessionId)
        let task = AgentTask(title: "Revise section", systemImage: "pencil",
            prompt: "Revise the selected section.", requiresDirection: true)
        let reference = AgentMention(displayName: "Character", mediaRef: "character-asset", type: .image)
        service.pendingFunction = task
        service.draft = "Use this character @Character"
        service.mentions = [reference]
        let session = try #require(service.sessions.first { $0.id == id })
        #expect(session.messages.isEmpty)
        #expect(session.hasPersistedContent)
        let data = try #require(ChatSessionStore.encodeSession(session))
        try data.write(to: chat.appendingPathComponent("\(id.uuidString).json"))

        let restored = AgentService(refreshBackendStatusOnInit: false)
        var mutations = 0
        restored.onSessionsChanged = { mutations += 1 }
        restored.loadSessions(from: home)
        #expect(restored.currentSessionId == id)
        #expect(restored.pendingFunction == task)
        #expect(restored.draft == "Use this character @Character")
        #expect(restored.mentions == [reference])
        #expect(restored.messages.isEmpty)
        #expect(!restored.isStreaming)
        #expect(mutations == 0)

        restored.pendingFunction = nil
        restored.draft = ""
        restored.mentions = []
        #expect(restored.sessions.first { $0.id == id }?.hasPersistedContent == false)
    }

    @Test("Closed task drafts remain available without becoming the active task on reload")
    @MainActor
    func closedDraftRemainsClosedOnReload() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chat = home.appendingPathComponent(ChatSessionStore.dirName)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var saved = ChatSession(title: "Deferred revision", isOpen: false)
        saved.draft = .init(text: "Shorten the ending", mentions: [],
            task: .init(title: "Revise ending", systemImage: "pencil", prompt: "Revise the ending.",
                requiresDirection: true))
        try #require(ChatSessionStore.encodeSession(saved))
            .write(to: chat.appendingPathComponent("\(saved.id.uuidString).json"))
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.loadSessions(from: home)
        #expect(service.currentSessionId != saved.id)
        #expect(service.pendingFunction == nil)
        #expect(service.sessions.first { $0.id == saved.id }?.isOpen == false)

        service.selectSession(saved.id)
        #expect(service.draft == "Shorten the ending")
        #expect(service.pendingFunction == saved.draft?.task)
        #expect(!service.isStreaming)
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

    @Test("New is unavailable in an already empty conversation without replacing its identity")
    @MainActor
    func newConversationRequiresAnObservableChange() throws {
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.loadSessions(from: nil)
        let id = try #require(service.currentSessionId)
        #expect(!service.canStartNewConversation)
        #expect(!service.startNewConversation())
        #expect(service.currentSessionId == id)
        #expect(service.sessions.count == 1)
    }

    @Test("New preserves the current draft and focuses the new conversation")
    @MainActor
    func explicitNewConversationPreservesDraftAndFocusesInput() throws {
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.loadSessions(from: nil)
        let first = try #require(service.currentSessionId)
        service.draft = "My next scene"
        #expect(service.canStartNewConversation)
        #expect(service.startNewConversation())
        #expect(service.currentSessionId != first)
        #expect(service.draft.isEmpty)
        #expect(service.composerShouldFocus)
        #expect(!service.canStartNewConversation)
        service.selectSession(first)
        #expect(service.draft == "My next scene")
    }

    @Test("New cannot interrupt a running turn")
    @MainActor
    func explicitNewConversationHonorsRunningState() throws {
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.loadSessions(from: nil)
        let id = try #require(service.currentSessionId)
        service.messages = [AgentMessage(role: .user, blocks: [.text("Continue")])]
        service.isStreaming = true
        defer { service.isStreaming = false }
        #expect(!service.canStartNewConversation)
        #expect(!service.startNewConversation())
        #expect(service.currentSessionId == id)
        #expect(service.messages.count == 1)
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
