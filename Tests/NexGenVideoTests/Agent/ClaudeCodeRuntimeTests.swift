import Foundation
import Testing
@testable import NexGenVideo

private func texts(_ m: AgentMessage) -> [String] {
    m.blocks.compactMap { block -> String? in
        if case .text(let t) = block { return t }
        return nil
    }
}

@Suite("ClaudeCodeEventMapper user + notes")
struct ClaudeCodeMapperUserTests {

    @Test func appendUserTextAddsUserMessage() {
        var mapper = ClaudeCodeEventMapper()
        mapper.appendUserText("do X")
        #expect(mapper.messages.count == 1)
        #expect(mapper.messages.first?.role == .user)
        #expect(mapper.messages.first.map(texts)?.first == "do X")
    }

    @Test func interleavesUserAndAssistantInOrder() {
        var mapper = ClaudeCodeEventMapper()
        mapper.appendUserText("do X")
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"ok"}]}}"#)
        #expect(mapper.messages.count == 2)
        #expect(mapper.messages.first?.role == .user)
        #expect(mapper.messages.last?.role == .assistant)
    }

    @Test func appendNoteAddsAssistantMessage() {
        var mapper = ClaudeCodeEventMapper()
        mapper.appendNote("CLI not found")
        #expect(mapper.messages.first?.role == .assistant)
        #expect(mapper.messages.first.map(texts)?.first == "CLI not found")
    }

    @Test("seed preloads a resumed transcript; new stream turns append after it")
    func seedPreloadsHistoryThenAppendsNewTurns() {
        var mapper = ClaudeCodeEventMapper()
        mapper.seed([
            AgentMessage(role: .user, blocks: [.text("earlier question")]),
            AgentMessage(role: .assistant, blocks: [.text("earlier answer")]),
        ])
        #expect(mapper.messages.count == 2)
        mapper.appendUserText("follow-up")
        mapper.ingest(line: #"{"type":"assistant","message":{"id":"m9","content":[{"type":"text","text":"resumed reply"}]}}"#)
        #expect(mapper.messages.count == 4)                       // history preserved, not overwritten
        #expect(mapper.messages.first.map(texts)?.first == "earlier question")
        #expect(mapper.messages.last?.role == .assistant)
        #expect(mapper.messages.last.map(texts)?.first == "resumed reply")
    }
}

@Suite("ClaudeCodeDecoder resume signal")
struct ClaudeCodeDecoderResumeTests {

    @Test("a dead --resume result line decodes to an errored turn whose message carries the session id")
    func staleResumeResultLineCarriesErrorId() {
        // Verified vs claude 2.1.207: a bad --resume emits this result line (no system/init), the errors
        // array echoing the exact id — the narrow signal the runtime uses to clear the stale id.
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"dead-id","errors":["No conversation found with session ID: dead-id"]}"#
        let events = ClaudeStreamDecoder.decode(line: line)
        #expect(events.count == 1)
        guard case .turnFinished(let isError, let msg, _) = events.first else {
            Issue.record("expected a turnFinished event"); return
        }
        #expect(isError)
        #expect(msg?.contains("dead-id") == true)
    }

    @Test("a successful result line is not an error and yields no error message")
    func successResultLineHasNoError() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.01}"#
        guard case .turnFinished(let isError, let msg, _) = ClaudeStreamDecoder.decode(line: line).first else {
            Issue.record("expected a turnFinished event"); return
        }
        #expect(!isError)
        #expect(msg == nil)
    }
}

@MainActor
@Suite("ClaudeCodeRuntime")
struct ClaudeCodeRuntimeTests {

    @Test func missingBinaryProducesUserMessageAndNoteAndStops() {
        var captured: [AgentMessage] = []
        var streaming = true
        let runtime = ClaudeCodeRuntime(
            resolveExecutable: { nil },
            resolveWorkingDirectory: { URL(fileURLWithPath: "/tmp") },
            onUpdate: { msgs, isStreaming in captured = msgs; streaming = isStreaming }
        )
        runtime.send(text: "hello")
        #expect(streaming == false)
        #expect(captured.count == 2)                       // user text + runtime note
        #expect(captured.first?.role == .user)
        #expect(captured.first.map(texts)?.first == "hello")
        #expect(captured.last?.role == .assistant)
    }

    @Test func missingWorkingDirectoryProducesNoteAndStops() {
        var captured: [AgentMessage] = []
        var streaming = true
        let runtime = ClaudeCodeRuntime(
            resolveExecutable: { URL(fileURLWithPath: "/usr/bin/true") },
            resolveWorkingDirectory: { nil },
            onUpdate: { msgs, isStreaming in captured = msgs; streaming = isStreaming }
        )
        runtime.send(text: "hello")
        #expect(streaming == false)
        #expect(captured.count == 2)                       // user text + runtime note
        #expect(captured.last?.role == .assistant)
    }
}
