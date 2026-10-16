import Foundation
import Testing
@testable import NexGenVideo

@Suite("Chat token usage")
struct AgentTokenUsageTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @Test("partial usage events fold into one final count per request")
    func meterFoldsPerRequest() {
        var meter = AgentRequestUsageMeter()
        var finished: [AgentRuntimeUsage] = []
        let events: [AgentRuntimeEvent] = [
            .providerRequest(prefixDigest: "first"),
            .usage(AgentRuntimeUsage(inputTokens: 12, outputTokens: 1, cacheCreationInputTokens: 300, cacheReadInputTokens: 0)),
            .usage(AgentRuntimeUsage(outputTokens: 48)),
            .text(messageID: nil, value: "Done", isDelta: true),
            .providerRequest(prefixDigest: "second"),
            .usage(AgentRuntimeUsage(inputTokens: 4, outputTokens: 9, cacheReadInputTokens: 300)),
            .terminal(.completed(.endTurn)),
        ]
        for event in events {
            if let usage = meter.observe(event) { finished.append(usage) }
        }
        let rest = meter.flush()

        #expect(finished == [
            AgentRuntimeUsage(inputTokens: 12, outputTokens: 48, cacheCreationInputTokens: 300, cacheReadInputTokens: 0),
            AgentRuntimeUsage(inputTokens: 4, outputTokens: 9, cacheReadInputTokens: 300),
        ])
        #expect(rest == nil)
    }

    @Test("request totals accumulate and the cache-read share covers every prompt token")
    func accumulationAndCacheShare() {
        var usage = AgentTokenUsage()
        #expect(usage.isEmpty)
        #expect(usage.cacheReadShare == nil)
        usage.add(.init(inputTokens: 12, outputTokens: 48, cacheCreationInputTokens: 300, cacheReadInputTokens: 0))
        usage.add(.init(inputTokens: 4, outputTokens: 9, cacheReadInputTokens: 300))
        usage.add(.init(costUSD: 0.01))
        #expect(usage.inputTokens == 16)
        #expect(usage.outputTokens == 57)
        #expect(usage.cacheCreationInputTokens == 300)
        #expect(usage.cacheReadInputTokens == 300)
        #expect(usage.promptTokens == 616)
        #expect(usage.cacheReadShare == 300.0 / 616.0)
        #expect(!usage.isEmpty)
    }

    @Test("chat usage round-trips through the session file; older files have none")
    func persistenceRoundTrip() throws {
        var usage = AgentTokenUsage()
        usage.add(.init(inputTokens: 16, outputTokens: 57, cacheCreationInputTokens: 300, cacheReadInputTokens: 300))
        var session = ChatSession(title: "t", messages: [AgentMessage(role: .user, blocks: [.text("hi")])])
        session.tokenUsage = usage
        let data = try #require(ChatSessionStore.encodeSession(session))
        let restored = try decoder.decode(ChatSession.self, from: data)
        #expect(restored.tokenUsage == usage)

        let legacy = """
        {"id":"\(UUID().uuidString)","title":"old","updatedAt":"2026-01-01T00:00:00Z","messages":[],"isOpen":true}
        """
        #expect(try decoder.decode(ChatSession.self, from: Data(legacy.utf8)).tokenUsage == nil)

        let partial = try JSONDecoder().decode(AgentTokenUsage.self, from: Data(#"{"inputTokens":5}"#.utf8))
        #expect(partial.inputTokens == 5)
        #expect(partial.outputTokens == 0)
        #expect(partial.cacheReadShare == 0)
    }
}
