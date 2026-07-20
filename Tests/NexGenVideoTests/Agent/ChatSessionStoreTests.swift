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
}
