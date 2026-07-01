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
