import Foundation
import Testing
@testable import NexGenVideo

// Fixtures mirror real `claude -p --output-format stream-json` lines (binary v2.1.191).

@Suite("ClaudeCodeEventMapper")
struct ClaudeCodeEventMapperTests {

    // MARK: helpers

    private func texts(_ m: AgentMessage) -> [String] {
        m.blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }
    }

    private func toolUses(_ m: AgentMessage) -> [(id: String, name: String, inputJSON: String)] {
        m.blocks.compactMap { block -> (String, String, String)? in
            if case .toolUse(let id, let name, let json) = block { return (id, name, json) }
            return nil
        }
    }

    private func toolResults(_ m: AgentMessage) -> [(toolUseId: String, isError: Bool, content: [ToolResult.Block])] {
        m.blocks.compactMap { block -> (String, Bool, [ToolResult.Block])? in
            if case .toolResult(let id, let content, let isError) = block { return (id, isError, content) }
            return nil
        }
    }

    // MARK: tests

    @Test func initLineCapturesSessionId() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"system","subtype":"init","session_id":"sess-123","cwd":"/tmp"}"#)
        #expect(mapper.sessionId == "sess-123")
        #expect(mapper.messages.isEmpty)
    }

    @Test func assistantTextBecomesAssistantMessage() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"Placing the clip now."}]}}"#)
        #expect(mapper.messages.count == 1)
        #expect(mapper.messages[0].role == .assistant)
        #expect(texts(mapper.messages[0]) == ["Placing the clip now."])
    }

    @Test func sameMessageIdGroupsTextAndToolUse() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"Importing."}]}}"#)
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","id":"toolu_9","name":"importMedia","input":{"source":{"path":"/abs/sample.mp4"}}}]}}"#)
        // One assistant message, two blocks: text then tool_use.
        #expect(mapper.messages.count == 1)
        #expect(texts(mapper.messages[0]) == ["Importing."])
        let uses = toolUses(mapper.messages[0])
        #expect(uses.count == 1)
        #expect(uses.first?.id == "toolu_9")
        #expect(uses.first?.name == "importMedia")
        // Decode inputJSON back so the assertion is robust to key order / slash escaping.
        let inputJSON = uses.first?.inputJSON ?? "{}"
        let parsed = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8), options: [])) as? [String: Any]
        let path = (parsed?["source"] as? [String: Any])?["path"] as? String
        #expect(path == "/abs/sample.mp4")
    }

    @Test func differentMessageIdsStaySeparate() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"a"}]}}"#)
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"text","text":"b"}]}}"#)
        #expect(mapper.messages.count == 2)
    }

    @Test func thinkingBlocksAreSkipped() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"thinking","thinking":"hmm","signature":"x"},{"type":"text","text":"ok"}]}}"#)
        #expect(mapper.messages.count == 1)
        #expect(texts(mapper.messages[0]) == ["ok"])
        #expect(mapper.messages[0].blocks.count == 1)
    }

    @Test func toolResultStringContentBecomesUserMessage() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_9","content":"Imported sample.mp4","is_error":false}]}}"#)
        #expect(mapper.messages.count == 1)
        #expect(mapper.messages[0].role == .user)
        let results = toolResults(mapper.messages[0])
        #expect(results.count == 1)
        #expect(results.first?.toolUseId == "toolu_9")
        #expect(results.first?.isError == false)
        if case .text(let t)? = results.first?.content.first {
            #expect(t == "Imported sample.mp4")
        } else {
            Issue.record("expected text content block")
        }
    }

    @Test func toolResultArrayContentIsMapped() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"text","text":"done"}],"is_error":true}]}}"#)
        let results = toolResults(mapper.messages[0])
        #expect(results.first?.isError == true)
        if case .text(let t)? = results.first?.content.first {
            #expect(t == "done")
        } else {
            Issue.record("expected text content block")
        }
    }

    @Test func successResultCapturesCostAndNoError() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.0123}"#)
        #expect(mapper.lastTurnCostUSD == 0.0123)
        #expect(mapper.turnError == nil)
    }

    @Test func errorResultSurfacesMessage() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"hit the limit"}"#)
        #expect(mapper.turnError == "hit the limit")
    }

    @Test func partialAndStatusLinesAreIgnored() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}}"#)
        mapper.ingest(line: #"{"type":"system","subtype":"status","status":"requesting"}"#)
        mapper.ingest(line: #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#)
        mapper.ingest(line: "")
        mapper.ingest(line: "not json at all")
        #expect(mapper.messages.isEmpty)
        #expect(mapper.sessionId == nil)
    }

    @Test("Claude authentication failures are classified before they reach the transcript")
    func authenticationFailuresRequireSignIn() {
        let resultLine = #"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}"#
        let revokedLine = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["OAuth token revoked · Please run /login"]}"#
        let assistantLine = #"{"type":"assistant","message":{"id":"m-auth","content":[{"type":"text","text":"The service says you are not logged in."}]}}"#
        let unrelatedLine = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Model is temporarily unavailable"]}"#

        #expect(ClaudeStreamDecoder.decode(line: resultLine).contains(where: \.requiresAuthentication))
        #expect(ClaudeStreamDecoder.decode(line: revokedLine).contains(where: \.requiresAuthentication))
        #expect(!ClaudeStreamDecoder.decode(line: assistantLine).contains(where: \.requiresAuthentication))
        #expect(ClaudeStreamDecoder.decode(line: assistantLine).contains(where: \.isAuthenticationMessageCandidate))
        #expect(!ClaudeStreamDecoder.decode(line: unrelatedLine).contains(where: \.requiresAuthentication))
    }

    @Test("auth-like assistant prose is discarded only after a failed result confirms it")
    func authenticationMessageWaitsForResult() {
        let assistant = ClaudeStreamDecoder.decode(
            line: #"{"type":"assistant","message":{"id":"m-auth","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]}}"#
        )
        let failed = ClaudeStreamDecoder.decode(
            line: #"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}"#
        )
        let succeeded = ClaudeStreamDecoder.decode(
            line: #"{"type":"result","subtype":"success","is_error":false,"result":"Done"}"#
        )

        var failedBuffer = ClaudeCodeAuthenticationEventBuffer()
        guard case .waiting = failedBuffer.receive(assistant) else {
            Issue.record("expected auth-like assistant text to wait for the result")
            return
        }
        guard case .authenticationRequired = failedBuffer.receive(failed) else {
            Issue.record("expected the failed result to confirm authentication")
            return
        }
        let trailing = failedBuffer.flush()
        #expect(trailing.isEmpty)

        var successfulBuffer = ClaudeCodeAuthenticationEventBuffer()
        guard case .waiting = successfulBuffer.receive(assistant) else {
            Issue.record("expected auth-like assistant prose to wait for the result")
            return
        }
        guard case .events(let released) = successfulBuffer.receive(succeeded) else {
            Issue.record("expected a successful result to release the assistant prose")
            return
        }
        #expect(released.count == 2)

        var combinedBuffer = ClaudeCodeAuthenticationEventBuffer()
        guard case .events(let combined) = combinedBuffer.receive(assistant + succeeded) else {
            Issue.record("expected a completed non-error batch to pass through immediately")
            return
        }
        #expect(combined.count == 2)
    }

    @Test func endToEndImportTurn() {
        var mapper = ClaudeCodeEventMapper()
        mapper.ingest(line: #"{"type":"system","subtype":"init","session_id":"s1"}"#)
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"On it."}]}}"#)
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"tu1","name":"addClips","input":{"entries":[{"startFrame":0}]}}]}}"#)
        mapper.ingest(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"Added 1 clip","is_error":false}]}}"#)
        mapper.ingest(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","total_cost_usd":0.05}"#)

        #expect(mapper.sessionId == "s1")
        // assistant (text+toolUse) then user (toolResult).
        #expect(mapper.messages.count == 2)
        #expect(mapper.messages[0].role == .assistant)
        #expect(toolUses(mapper.messages[0]).first?.name == "addClips")
        #expect(mapper.messages[1].role == .user)
        #expect(toolResults(mapper.messages[1]).first?.toolUseId == "tu1")
        #expect(mapper.lastTurnCostUSD == 0.05)
        #expect(mapper.turnError == nil)
    }
}
