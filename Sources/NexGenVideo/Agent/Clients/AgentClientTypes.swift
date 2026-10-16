import Foundation

// MARK: - Shared value types

enum AnthropicStopReason: String, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case pauseTurn = "pause_turn"
    case refusal = "refusal"
    case other
}

struct AnthropicMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: [[String: Any]]
}

struct AnthropicToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum AnthropicStreamEvent: Sendable {
    case textDelta(String)
    case thinkingComplete(AnthropicThinkingBlock)
    case serverToolComplete(AnthropicServerToolBlock)
    case toolUseComplete(id: String, name: String, inputJSON: String)
    case usage(AgentRuntimeUsage)
    case messageStop(stopReason: AnthropicStopReason)
}

enum AnthropicClientError: LocalizedError, Sendable {
    case missingAPIKey
    case httpError(status: Int, body: String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No Anthropic API key is set."
        case .httpError(let status, let body): "Anthropic API error (\(status)): \(body.prefix(500))"
        case .streamError(let msg): "Stream error: \(msg)"
        }
    }
}

// MARK: - Client protocol

protocol AgentClient: Sendable {
    /// Whether requests defer non-core tools behind server-side tool search.
    var supportsToolSearch: Bool { get }

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error>
}

extension AgentClient {
    var supportsToolSearch: Bool { false }
}

// MARK: - Shared SSE parser

enum AnthropicSSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var decoder = Decoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            for event in try decoder.consume(Data(payload.utf8)) {
                continuation.yield(event)
            }
        }
        try decoder.finish()
    }

    struct Decoder {
        private var pendingTools: [Int: (id: String, name: String, json: String)] = [:]
        private var pendingThinking: [Int: [String: Any]] = [:]
        private var pendingServerTools: [Int: (block: [String: Any], json: String)] = [:]
        private var stopReason: AnthropicStopReason?
        private var stopped = false

        mutating func consume(_ data: Data) throws -> [AnthropicStreamEvent] {
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else {
                throw AnthropicClientError.streamError("Invalid stream event.")
            }
            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    return [.usage(AnthropicSSE.runtimeUsage(usage))]
                }
            case "content_block_start":
                guard let index = event["index"] as? Int,
                      let block = event["content_block"] as? [String: Any] else { break }
                switch block["type"] as? String {
                case "tool_use":
                    if let id = block["id"] as? String, let name = block["name"] as? String {
                        pendingTools[index] = (id, name, "")
                    }
                case "thinking", "redacted_thinking":
                    pendingThinking[index] = block
                case "server_tool_use", "tool_search_tool_result":
                    pendingServerTools[index] = (block, "")
                default: break
                }
            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { break }
                if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                    HangDiagnosticRecorder.shared.record(.apiReceive, values: [Double(text.utf8.count)])
                    return [.textDelta(text)]
                } else if deltaType == "input_json_delta",
                          let partial = delta["partial_json"] as? String,
                          var acc = pendingTools[index] {
                    acc.json += partial
                    pendingTools[index] = acc
                } else if deltaType == "input_json_delta",
                          let partial = delta["partial_json"] as? String,
                          var acc = pendingServerTools[index] {
                    acc.json += partial
                    pendingServerTools[index] = acc
                } else if deltaType == "thinking_delta" || deltaType == "signature_delta" {
                    let key = deltaType == "thinking_delta" ? "thinking" : "signature"
                    guard var block = pendingThinking[index],
                          let value = delta[key] as? String else {
                        throw AnthropicClientError.streamError("Thinking delta has no matching block.")
                    }
                    block[key] = (block[key] as? String ?? "") + value
                    pendingThinking[index] = block
                }
            case "content_block_stop":
                guard let index = event["index"] as? Int else { break }
                if let block = pendingThinking.removeValue(forKey: index) {
                    return [.thinkingComplete(try AnthropicThinkingBlock(json: block))]
                }
                if let acc = pendingServerTools.removeValue(forKey: index) {
                    var block = acc.block
                    if !acc.json.isEmpty, block["type"] as? String == "server_tool_use" {
                        guard let input = try? JSONSerialization.jsonObject(with: Data(acc.json.utf8)) as? [String: Any] else {
                            throw AnthropicClientError.streamError("Server tool input is not a JSON object.")
                        }
                        block["input"] = input
                    }
                    return [.serverToolComplete(try AnthropicServerToolBlock(json: block))]
                }
                if let acc = pendingTools.removeValue(forKey: index) {
                    let json = acc.json.isEmpty ? "{}" : acc.json
                    HangDiagnosticRecorder.shared.record(.apiReceive, values: [Double(json.utf8.count)])
                    return [.toolUseComplete(id: acc.id, name: acc.name, inputJSON: json)]
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let raw = delta["stop_reason"] as? String {
                    stopReason = AnthropicStopReason(rawValue: raw) ?? .other
                }
                if let usage = event["usage"] as? [String: Any] {
                    return [.usage(AnthropicSSE.runtimeUsage(usage))]
                }
            case "message_stop":
                guard let stopReason, pendingThinking.isEmpty, pendingTools.isEmpty,
                      pendingServerTools.isEmpty else {
                    throw AnthropicClientError.streamError("The response ended with incomplete content.")
                }
                stopped = true
                return [.messageStop(stopReason: stopReason)]
            case "error":
                let error = event["error"] as? [String: Any]
                throw AnthropicClientError.streamError(error?["message"] as? String ?? "The stream failed.")
            default: break
            }
            return []
        }

        func finish() throws {
            guard stopped else {
                throw AnthropicClientError.streamError("The response was interrupted. Try again.")
            }
        }
    }

    private static func runtimeUsage(_ usage: [String: Any]) -> AgentRuntimeUsage {
        AgentRuntimeUsage(
            inputTokens: usage["input_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int,
            cacheCreationInputTokens: usage["cache_creation_input_tokens"] as? Int,
            cacheReadInputTokens: usage["cache_read_input_tokens"] as? Int,
            costUSD: nil
        )
    }
}

// MARK: - Request body builder

enum AnthropicRequestBody {
    static let maxOutputTokensCeiling = 64000
    static let unknownModelMaxTokens = 8192
    private static let uncacheableBlockTypes: Set<String> = [
        "thinking", "redacted_thinking", "server_tool_use", "tool_search_tool_result",
    ]

    static func build(
        model: AnthropicModelInfo,
        maxTokens: Int? = nil,
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> [String: Any] {
        let loaded = AnthropicToolSearch.loadedToolNames(tools.map(\.name), enabled: model.supportsToolSearch)
        var toolBlocks: [[String: Any]] = tools.map {
            var block: [String: Any] = ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema]
            if let loaded, !loaded.contains($0.name) { block["defer_loading"] = true }
            return block
        }
        if loaded != nil { toolBlocks.insert(AnthropicToolSearch.searchToolBlock, at: 0) }
        // Prompt-cache boundary covers system + loaded tools; a deferred tool cannot carry one.
        if let index = toolBlocks.lastIndex(where: { $0["defer_loading"] == nil }) {
            toolBlocks[index]["cache_control"] = ["type": "ephemeral"]
        }
        // Prompt-cache the conversation prefix
        var messageBlocks: [[String: Any]] = messages.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        if var lastMsg = messageBlocks.popLast(),
           var content = lastMsg["content"] as? [[String: Any]],
           var lastBlock = content.popLast() {
            if !Self.uncacheableBlockTypes.contains(lastBlock["type"] as? String ?? "") {
                lastBlock["cache_control"] = ["type": "ephemeral"]
            }
            content.append(lastBlock)
            lastMsg["content"] = content
            messageBlocks.append(lastMsg)
        }
        let modelLimit = model.maxOutputTokens.map { min(maxOutputTokensCeiling, $0) }
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": maxTokens ?? modelLimit ?? unknownModelMaxTokens,
            "stream": true,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messageBlocks,
        ]
        // Budget-only thinking models keep the request without a thinking parameter.
        if model.supportsAdaptiveThinking {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        if model.supportsHighEffort {
            body["output_config"] = ["effort": "high"]
        }
        if !toolBlocks.isEmpty { body["tools"] = toolBlocks }
        return body
    }
}
