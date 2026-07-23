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
