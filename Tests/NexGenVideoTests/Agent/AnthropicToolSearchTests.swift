import Foundation
import Testing
@testable import NexGenVideo

private func isDeferred(_ block: [String: Any]) -> Bool {
    block.keys.contains("defer_loading")
}

@Suite("Anthropic tool search")
@MainActor
struct AnthropicToolSearchTests {
    private var hostTools: [AnthropicToolSchema] {
        ToolDefinitions.all.map {
            AnthropicToolSchema(name: $0.name.rawValue, description: $0.description, inputSchema: $0.inputSchema)
        }
    }

    private let userTurn = AnthropicMessage(role: .user, content: [["type": "text", "text": "Cut the intro."]])

    private func toolBlocks(_ body: [String: Any]) throws -> [[String: Any]] {
        try #require(body["tools"] as? [[String: Any]])
    }

    @Test("a documented model loads the core set and defers every other tool behind tool search")
    func deferredRequestShape() throws {
        let tools = hostTools
        let model = AnthropicModelFixtures.info(AnthropicModelFixtures.opus55)
        #expect(model.supportsToolSearch)
        let blocks = try toolBlocks(AnthropicRequestBody.build(
            model: model, system: "Edit.", tools: tools, messages: [userTurn]
        ))

        #expect(blocks.count == tools.count + 1)
        let search = try #require(blocks.first)
        #expect(search["type"] as? String == "tool_search_tool_regex_20251119")
        #expect(search["name"] as? String == "tool_search_tool_regex")
        #expect(!isDeferred(search))
        #expect(blocks.dropFirst().compactMap { $0["name"] as? String } == tools.map(\.name))

        let core = Set(ToolDefinitions.core.map(\.rawValue))
        #expect(core.isSubset(of: Set(tools.map(\.name))))
        for block in blocks.dropFirst() {
            let name = try #require(block["name"] as? String)
            if core.contains(name) {
                #expect(!isDeferred(block), "\(name) must load up front")
            } else {
                #expect(block["defer_loading"] as? Bool == true, "\(name) must be deferred")
            }
        }
        #expect(blocks.filter { !isDeferred($0) }.count == core.count + 1)

        let cached = blocks.indices.filter { blocks[$0].keys.contains("cache_control") }
        let lastLoaded = blocks.lastIndex { !isDeferred($0) }
        #expect(cached.count == 1)
        #expect(cached.first == lastLoaded)
    }

    @Test("tools a chat called before any search surfaced them stay loaded")
    func pinnedToolsStayLoaded() throws {
        let surfaced = try AnthropicServerToolBlock(json: [
            "type": "tool_search_tool_result", "tool_use_id": "srvtoolu_1",
            "content": [
                "type": "tool_search_tool_search_result",
                "tool_references": [["type": "tool_reference", "tool_name": "write_treatment"]],
            ],
        ])
        var interrupted = AgentMessage(role: .assistant, blocks: [.toolUse(id: "t5", name: "write_shotlist", inputJSON: "{}")])
        interrupted.isIncompleteAPIResponse = true
        let history = [
            AgentMessage(role: .assistant, blocks: [.toolUse(id: "t1", name: "write_brief", inputJSON: "{}")]),
            AgentMessage(role: .assistant, blocks: [
                .serverTool(surfaced),
                .toolUse(id: "t2", name: "write_treatment", inputJSON: "{}"),
                .toolUse(id: "t3", name: "get_project_state", inputJSON: "{}"),
            ]),
            AgentMessage(role: .assistant, blocks: [.toolUse(id: "t4", name: "write_bible", inputJSON: "{}")]),
            interrupted,
        ]
        let used = AnthropicToolSearch.toolsUsedBeforeSurfacing(history)
        #expect(used == Set(["write_brief", "write_bible"]))

        let names = ["get_project_state", "write_brief", "write_treatment"]
        let partlyPinned = AnthropicToolSearch.loadedToolNames(names, enabled: true, pinned: ["write_brief", "gone"])
        #expect(partlyPinned == Set(["get_project_state", "write_brief"]))
        let fullyPinned = AnthropicToolSearch.loadedToolNames(names, enabled: true, pinned: ["write_brief", "write_treatment"])
        #expect(fullyPinned == nil)

        let schema: [String: Any] = ["type": "object"]
        let tools = names.map {
            AnthropicToolSchema(name: $0, description: $0, inputSchema: schema, loadsUpFront: $0 == "write_brief")
        }
        let blocks = try toolBlocks(AnthropicRequestBody.build(
            model: AnthropicModelFixtures.info(AnthropicModelFixtures.opus55), system: "Edit.", tools: tools,
            messages: [userTurn]
        ))
        #expect(blocks.filter(isDeferred).compactMap { $0["name"] as? String } == ["write_treatment"])
    }

    @Test("an undocumented or unlisted model sends every tool loaded, as before")
    func unsupportedModelFallsBack() throws {
        let tools = hostTools
        let undocumented = AnthropicModelFixtures.info(AnthropicModelFixtures.entry(
            id: "claude-opus-9", name: "Claude Opus 9", created: "2027-01-01T00:00:00Z", line: "opus"
        ))
        for model in [undocumented, AnthropicModelInfo.unlisted("claude-sonnet-9")] {
            #expect(!model.supportsToolSearch)
            let blocks = try toolBlocks(AnthropicRequestBody.build(
                model: model, system: "Edit.", tools: tools, messages: [userTurn]
            ))
            #expect(blocks.compactMap { $0["name"] as? String } == tools.map(\.name))
            #expect(!blocks.contains { $0.keys.contains("type") })
            #expect(!blocks.contains(where: isDeferred))
            let cached = blocks.indices.filter { blocks[$0].keys.contains("cache_control") }
            #expect(cached == [blocks.count - 1])
        }
    }

    @Test("without a core tool or anything to defer, no search tool is added")
    func noSearchWithoutCoreOrDeferredTools() throws {
        let model = AnthropicModelFixtures.info(AnthropicModelFixtures.opus55)
        let schema: [String: Any] = ["type": "object"]
        let onlyOther = [AnthropicToolSchema(name: "host_tool", description: "Host", inputSchema: schema)]
        let onlyCore = [AnthropicToolSchema(name: "get_project_state", description: "State", inputSchema: schema)]
        for tools in [onlyOther, onlyCore, []] {
            let body = AnthropicRequestBody.build(model: model, system: "Edit.", tools: tools, messages: [userTurn])
            let blocks = body["tools"] as? [[String: Any]] ?? []
            #expect(blocks.count == tools.count)
            #expect(!blocks.contains(where: isDeferred))
        }
    }

    @Test("the tool list is byte-identical for every request of one conversation")
    func toolListIsByteStable() throws {
        let model = AnthropicModelFixtures.info(AnthropicModelFixtures.sonnet55)
        let later: [AnthropicMessage] = [
            userTurn,
            .init(role: .assistant, content: [["type": "tool_use", "id": "t1", "name": "get_project_state", "input": [:] as [String: Any]]]),
            .init(role: .user, content: [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]),
            .init(role: .assistant, content: [["type": "text", "text": "Done."]]),
            .init(role: .user, content: [["type": "text", "text": "Tighten the outro."]]),
        ]
        let encoded = try [[userTurn], later, later].map { messages -> Data in
            let body = AnthropicRequestBody.build(model: model, system: "Edit.", tools: hostTools, messages: messages)
            return try JSONSerialization.data(withJSONObject: try toolBlocks(body), options: [.sortedKeys])
        }
        #expect(Set(encoded).count == 1)
    }

    @Test("tool search steps survive streaming, session storage, and the next request")
    func serverStepsRoundTrip() throws {
        var decoder = AnthropicSSE.Decoder()
        let records = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"tool_search_tool_regex","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"pattern\":\"write_"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"brief\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_search_tool_result","tool_use_id":"srvtoolu_1","content":{"type":"tool_search_tool_search_result","tool_references":[{"type":"tool_reference","tool_name":"write_brief"}]}}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"write_brief","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"{"type":"message_stop"}"#,
        ]
        var blocks: [AgentContentBlock] = []
        for record in records {
            for event in try decoder.consume(Data(record.utf8)) {
                switch event {
                case .serverToolComplete(let block): blocks.append(.serverTool(block))
                case .toolUseComplete(let id, let name, let input):
                    blocks.append(.toolUse(id: id, name: name, inputJSON: input))
                default: break
                }
            }
        }
        try decoder.finish()
        #expect(blocks.count == 3)

        let restored = try JSONDecoder().decode(
            AgentMessage.self,
            from: JSONEncoder().encode(AgentMessage(role: .assistant, blocks: blocks))
        )
        #expect(restored.blocks == blocks)

        let body = AnthropicRequestBody.build(
            model: AnthropicModelFixtures.info(AnthropicModelFixtures.opus55), system: "Edit.", tools: hostTools,
            messages: [
                userTurn,
                .init(role: .assistant, content: restored.blocks
                    .compactMap(AgentService.runtimeContent)
                    .map(AnthropicRuntimeAdapter.anthropicContent)),
                .init(role: .user, content: [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]]),
            ]
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["server_tool_use", "tool_search_tool_result", "tool_use"])
        #expect(NSDictionary(dictionary: content[0]).isEqual(to: [
            "type": "server_tool_use", "id": "srvtoolu_1", "name": "tool_search_tool_regex",
            "input": ["pattern": "write_brief"],
        ]))
        #expect(NSDictionary(dictionary: content[1]).isEqual(to: [
            "type": "tool_search_tool_result", "tool_use_id": "srvtoolu_1",
            "content": [
                "type": "tool_search_tool_search_result",
                "tool_references": [["type": "tool_reference", "tool_name": "write_brief"]],
            ],
        ]))
    }

    @Test("an unfinished tool search step fails instead of reaching the next request")
    func unfinishedServerStepFails() throws {
        var decoder = AnthropicSSE.Decoder()
        _ = try decoder.consume(Data(
            #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"tool_search_tool_regex","input":{}}}"#.utf8
        ))
        _ = try decoder.consume(Data(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#.utf8))
        #expect(throws: (any Error).self) {
            _ = try decoder.consume(Data(#"{"type":"message_stop"}"#.utf8))
        }
    }

    @Test("without tool search in the request, earlier search steps are left out of the wire")
    func wireDropsServerStepsWithoutSearch() throws {
        let use = try AnthropicServerToolBlock(json: [
            "type": "server_tool_use", "id": "srvtoolu_1", "name": "tool_search_tool_regex",
            "input": ["pattern": "write"],
        ])
        let messages = [
            AgentRuntimeMessage(role: .user, content: [.text("Write it")]),
            AgentRuntimeMessage(role: .assistant, content: [.serverTool(use)]),
            AgentRuntimeMessage(role: .assistant, content: [.toolUse(id: "t1", name: "write_brief", inputJSON: "{}")]),
            AgentRuntimeMessage(role: .user, content: [.toolResult(id: "t1", content: [.text("ok")], isError: false)]),
        ]
        let kept = AnthropicReplay.wireMessages(messages)
        #expect(kept[1].content == [.serverTool(use), .toolUse(id: "t1", name: "write_brief", inputJSON: "{}")])
        let dropped = AnthropicReplay.wireMessages(messages, keepingServerTools: false)
        #expect(dropped.count == 3)
        #expect(dropped[1].content == [.toolUse(id: "t1", name: "write_brief", inputJSON: "{}")])
    }

    @Test("switching tool loading invalidates earlier thinking once, then replays stay stable")
    func toolLoadingChangeStripsStaleThinkingOnce() throws {
        let tools = ["get_project_state", "host_tool"].map {
            AgentRuntimeToolSchema(name: $0, description: $0, inputSchema: ["type": "object"])
        }
        let system = "Edit."
        let before = try AnthropicThinkingBlock(json: ["type": "thinking", "thinking": "", "signature": "before=="])
        let after = try AnthropicThinkingBlock(json: ["type": "thinking", "thinking": "", "signature": "after=="])
        let first = AgentRuntimeMessage(role: .user, content: [.text("Plan")])
        let firstReply = AgentRuntimeMessage(role: .assistant, content: [.thinking(before), .text("Planned.")])
        let second = AgentRuntimeMessage(role: .user, content: [.text("Continue")])
        let secondReply = AgentRuntimeMessage(role: .assistant, content: [.thinking(after), .text("Continued.")])
        let third = AgentRuntimeMessage(role: .user, content: [.text("Finish")])

        #expect(
            AnthropicPrefixDigest.of(system: system, tools: tools, toolSearch: true, messages: [first])
                != AnthropicPrefixDigest.of(system: system, tools: tools, messages: [first])
        )
        let entries = [
            AnthropicReplay.Entry(role: .user, content: first.content, recordedPrefixDigest: nil),
            AnthropicReplay.Entry(
                role: .assistant, content: firstReply.content,
                recordedPrefixDigest: AnthropicPrefixDigest.of(system: system, tools: tools, messages: [first])
            ),
            AnthropicReplay.Entry(role: .user, content: second.content, recordedPrefixDigest: nil),
            AnthropicReplay.Entry(
                role: .assistant, content: secondReply.content,
                recordedPrefixDigest: AnthropicPrefixDigest.of(
                    system: system, tools: tools, toolSearch: true, messages: [first, firstReply, second]
                )
            ),
            AnthropicReplay.Entry(role: .user, content: third.content, recordedPrefixDigest: nil),
        ]
        func signatures(_ replay: [AgentRuntimeMessage]) -> [String] {
            replay.flatMap(\.content).compactMap {
                guard case .thinking(let block) = $0 else { return nil }
                return block.json["signature"] as? String
            }
        }
        let searching = AnthropicReplay.strippingInvalidatedThinking(
            entries, system: system, tools: tools, toolSearch: true
        )
        #expect(signatures(searching) == ["after=="])
        let fallback = AnthropicReplay.strippingInvalidatedThinking(entries, system: system, tools: tools)
        #expect(signatures(fallback).isEmpty)
    }
}
