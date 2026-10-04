import Foundation
import Testing
@testable import NexGenVideo

@Suite("Anthropic thinking continuity")
@MainActor
struct AnthropicThinkingTests {
    @Test("signed, omitted, and redacted thinking survive streaming, session storage, and the next tool request")
    func roundTrip() throws {
        var decoder = AnthropicSSE.Decoder()
        let records = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":"","display":"summarized"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Check the "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"timeline.\n"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed-"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"bytes=="}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Inspecting the project."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"thinking","thinking":"","signature":"opaque=="}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"redacted_thinking","data":"encrypted+/==","future_field":{"version":2}}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"content_block_start","index":4,"content_block":{"type":"tool_use","id":"tool-1","name":"get_project_state","input":{}}}"#,
            #"{"type":"content_block_delta","index":4,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
            #"{"type":"content_block_stop","index":4}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"{"type":"message_stop"}"#,
        ]
        var blocks: [AgentContentBlock] = []
        var stopReason: AnthropicStopReason?
        for record in records {
            for event in try decoder.consume(Data(record.utf8)) {
                switch event {
                case .thinkingComplete(let block): blocks.append(.thinking(block))
                case .textDelta(let text): blocks.append(.text(text))
                case .toolUseComplete(let id, let name, let input):
                    blocks.append(.toolUse(id: id, name: name, inputJSON: input))
                case .messageStop(let reason): stopReason = reason
                case .usage: break
                }
            }
        }
        try decoder.finish()
        #expect(stopReason == .toolUse)
        let saved = try JSONEncoder().encode(AgentMessage(role: .assistant, blocks: blocks))
        let restored = try JSONDecoder().decode(AgentMessage.self, from: saved)
        #expect(restored.blocks == blocks)
        let body = AnthropicRequestBody.build(
            model: .sonnet46, system: "Edit a film.", tools: [], messages: [
                .init(role: .assistant, content: restored.blocks
                    .compactMap(AgentService.runtimeContent)
                    .map(AnthropicRuntimeAdapter.anthropicContent)),
                .init(role: .user, content: [["type": "tool_result", "tool_use_id": "tool-1", "content": "ok"]]),
            ]
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["thinking", "text", "thinking", "redacted_thinking", "tool_use"])
        #expect(NSDictionary(dictionary: content[0]).isEqual(to: [
            "type": "thinking", "thinking": "Check the timeline.\n", "signature": "signed-bytes==", "display": "summarized",
        ]))
        #expect(NSDictionary(dictionary: content[2]).isEqual(to: [
            "type": "thinking", "thinking": "", "signature": "opaque==",
        ]))
        #expect(NSDictionary(dictionary: content[3]).isEqual(to: [
            "type": "redacted_thinking", "data": "encrypted+/==", "future_field": ["version": 2],
        ]))
    }

    @Test("a cache boundary never edits a signed block")
    func thinkingCacheBoundary() throws {
        let blocks: [[String: Any]] = [
            ["type": "thinking", "thinking": "", "signature": "signed=="],
            ["type": "redacted_thinking", "data": "opaque=="],
        ]
        for block in blocks {
            let body = AnthropicRequestBody.build(
                model: .opus48, system: "Edit.", tools: [],
                messages: [.init(role: .assistant, content: [block])]
            )
            let messages = try #require(body["messages"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? [[String: Any]])
            #expect(NSDictionary(dictionary: content[0]).isEqual(to: block))
        }
    }

    @Test("usage records are returned as stream events without losing the stop reason")
    func usageEvents() throws {
        var decoder = AnthropicSSE.Decoder()
        let start = try decoder.consume(Data(
            #"{"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":3}}}"#.utf8
        ))
        guard start.count == 1, case .usage(let startUsage) = start[0] else {
            Issue.record("message_start usage was not returned")
            return
        }
        #expect(startUsage.inputTokens == 12)
        #expect(startUsage.cacheReadInputTokens == 3)
        let delta = try decoder.consume(Data(
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#.utf8
        ))
        guard delta.count == 1, case .usage(let deltaUsage) = delta[0] else {
            Issue.record("message_delta usage was not returned")
            return
        }
        #expect(deltaUsage.outputTokens == 7)
        let stop = try decoder.consume(Data(#"{"type":"message_stop"}"#.utf8))
        guard stop.count == 1, case .messageStop(let reason) = stop[0] else {
            Issue.record("message_stop lost the stop reason")
            return
        }
        #expect(reason == .endTurn)
        try decoder.finish()
    }

    @Test("incomplete signatures and truncated responses fail instead of authorizing a tool loop")
    func interruptedStream() throws {
        var decoder = AnthropicSSE.Decoder()
        _ = try decoder.consume(Data(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"Partial"}}"#.utf8))
        #expect(throws: (any Error).self) {
            _ = try decoder.consume(Data(#"{"type":"content_block_stop","index":0}"#.utf8))
        }
        #expect(throws: (any Error).self) { try decoder.finish() }
        var endedWithoutStop = AnthropicSSE.Decoder()
        let events = try endedWithoutStop.consume(Data(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#.utf8))
        #expect(events.isEmpty)
        #expect(throws: (any Error).self) { try endedWithoutStop.finish() }
        #expect(throws: (any Error).self) {
            _ = try endedWithoutStop.consume(Data(#"{"type":"error","error":{"message":"Overloaded"}}"#.utf8))
        }
    }

    @Test("saved legacy text still decodes and corrupted signed content is rejected")
    func savedContentValidation() throws {
        let legacy = try JSONDecoder().decode(AgentContentBlock.self, from: Data(#"{"kind":"text","text":"Existing conversation"}"#.utf8))
        #expect(legacy == .text("Existing conversation"))
        let corrupt = Data(#"{"type":"thinking","thinking":"Text without signature"}"#.utf8)
        let container = try JSONEncoder().encode(corrupt)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(AnthropicThinkingBlock.self, from: container)
        }
    }

    @Test("interrupted output remains visible after reload but cannot replay or execute tools")
    func interruptedHistory() async throws {
        let thought = try AnthropicThinkingBlock(json: [
            "type": "thinking", "thinking": "Check the edit.", "signature": "signed==",
        ])
        var partial = AgentMessage(role: .assistant, blocks: [
            .thinking(thought), .text("A partial answer"),
            .toolUse(id: "not-run", name: "get_project_state", inputJSON: "{}"),
        ])
        partial.isIncompleteAPIResponse = true
        let restored = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(partial))
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.messages = [
            AgentMessage(role: .user, blocks: [.text("Review.")]), restored,
            AgentMessage(role: .user, blocks: [.text("Try again.")]),
        ]
        _ = await service.runPendingToolUses(assistantID: restored.id, origin: .direct)
        #expect(service.messages.count == 3)
        #expect(service.messages[1].blocks == partial.blocks)
        let replay = await service.runtimeMessages(transientImages: [])
        #expect(replay.count == 2)
        #expect(replay.allSatisfy { $0.role == .user })
        #expect(restored.isIncompleteAPIResponse)
        let turns = AgentTranscriptProjection.turns(messages: [restored], isStreaming: false)
        let items = try #require(turns.first?.items)
        guard case .assistantResult(let partialResult)? = items.first,
              case .notice(let notice)? = items.last else {
            Issue.record("Partial text must remain visible with a durable interruption notice")
            return
        }
        #expect(partialResult.blocks == [.text("A partial answer")])
        #expect(!notice.text.isEmpty)
        let live = AgentTranscriptProjection.turns(messages: [restored], isStreaming: true)
        for item in live.flatMap(\.items) {
            if case .notice = item { Issue.record("The live response must not be marked interrupted") }
            if case .activity(let activity) = item { #expect(activity.steps.isEmpty) }
        }
        var completed = restored
        completed.isIncompleteAPIResponse = false
        let finished = AgentTranscriptProjection.turns(messages: [completed], isStreaming: false)
        let activities = finished.flatMap(\.items).compactMap { item -> AgentActivity? in
            guard case .activity(let activity) = item else { return nil }
            return activity
        }
        #expect(activities.first?.steps.map(\.id) == ["not-run"])
        #expect(activities.first?.statuses == ["A partial answer"])
        for item in items {
            if case .activity(let activity) = item {
                #expect(activity.steps.isEmpty)
                #expect(activity.statuses.isEmpty)
                #expect(!activity.isRunning)
            }
        }
    }

    @Test("thinking without a tool has a neutral completed detail label")
    func thinkingOnlyPresentation() throws {
        let thought = try AnthropicThinkingBlock(json: [
            "type": "thinking", "thinking": "Review the request.", "signature": "signed==",
        ])
        let turns = AgentTranscriptProjection.turns(messages: [
            AgentMessage(role: .assistant, blocks: [.thinking(thought), .text("Ready.")]),
        ], isStreaming: false)
        let items = try #require(turns.first?.items)
        guard case .activity(let activity)? = items.last else {
            Issue.record("Thinking summaries must remain available as activity detail")
            return
        }
        #expect(activity.steps.isEmpty)
        #expect(activity.operationLabel == "Thinking")
        #expect(activity.trailingThinkingSummaries == ["Review the request."])
        #expect(!activity.isRunning)
    }

    @Test("request policy budgets adaptive thinking and preserves the legacy Haiku dialect")
    func requestPolicy() throws {
        for model in [AnthropicModel.sonnet46, .opus48] {
            let body = AnthropicRequestBody.build(model: model, system: "Edit.", tools: [], messages: [])
            #expect(body["max_tokens"] as? Int == 64000)
            #expect(body["thinking"] as? [String: String] == ["type": "adaptive", "display": "summarized"])
            #expect(body["output_config"] as? [String: String] == ["effort": "high"])
        }
        let haiku = AnthropicRequestBody.build(model: .haiku45, system: "Edit.", tools: [], messages: [])
        #expect(haiku["thinking"] == nil)
        #expect(haiku["output_config"] == nil)
        #expect(haiku["max_tokens"] as? Int == 8192)
    }

    @Test("thinking stays in ordered activity details, never in the result or host status")
    func thinkingPresentation() throws {
        let first = try AnthropicThinkingBlock(json: ["type": "thinking", "thinking": "Inspect sources.", "signature": "one=="])
        let second = try AnthropicThinkingBlock(json: ["type": "thinking", "thinking": "Check cuts.", "signature": "two=="])
        let omitted = try AnthropicThinkingBlock(json: ["type": "thinking", "thinking": "", "signature": "three=="])
        let redacted = try AnthropicThinkingBlock(json: ["type": "redacted_thinking", "data": "opaque=="])
        let turns = AgentTranscriptProjection.turns(messages: [
            AgentMessage(role: .user, blocks: [.text("Review.")]),
            AgentMessage(role: .assistant, blocks: [
                .thinking(first), .toolUse(id: "one", name: "get_project_state", inputJSON: "{}"),
                .thinking(second), .thinking(omitted), .thinking(redacted),
                .toolUse(id: "two", name: "get_timeline", inputJSON: "{}"),
            ]),
            AgentMessage(role: .assistant, blocks: [.text("Reviewed.")]),
        ], isStreaming: false)
        let items = try #require(turns.first?.items)
        guard case .assistantResult(let result) = items[1], case .activity(let activity) = items[2] else {
            Issue.record("Expected result followed by activity details")
            return
        }
        #expect(result.blocks == [.text("Reviewed.")])
        #expect(activity.steps.map(\.thinkingSummaries) == [["Inspect sources."], ["Check cuts."]])
        #expect(activity.statuses.isEmpty)
        #expect(activity.trailingThinkingSummaries.isEmpty)
    }
}
