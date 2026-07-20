import Foundation

// Decoding for the NDJSON lines emitted by `claude -p --output-format stream-json`.
//
// We consume only the *complete* line types (`system/init`, `assistant`, `user`, `result`).
// The `stream_event` partial deltas (emitted with --include-partial-messages) are deliberately
// ignored here: the complete lines carry whole content blocks, which keeps the mapping to the
// editor's AgentMessage model unambiguous. Live token streaming can layer on later.

/// A completed content block inside an assistant message.
enum ClaudeBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
}

/// A semantically-relevant event distilled from one stream-json line. A single line may yield
/// several events (an assistant message can hold multiple blocks; a user line multiple results).
enum ClaudeStreamEvent: Sendable {
    /// `system/init` — carries the session id needed for `--resume`.
    case sessionStarted(sessionId: String)
    /// One completed block of the assistant message identified by `messageId`.
    case assistantBlock(messageId: String, block: ClaudeBlock)
    /// A tool result returned to the model (arrives on a `user` line).
    case toolResult(toolUseId: String, blocks: [ToolResult.Block], isError: Bool)
    /// `result` — the turn finished, with optional cost and error.
    case turnFinished(isError: Bool, errorMessage: String?, costUSD: Double?)
}

enum ClaudeStreamDecoder {

    /// Decode one NDJSON line. Returns `[]` for blank, unparseable, or non-surfaced lines so the
    /// caller stays resilient to interleaved stderr noise and partial-message events.
    static func decode(line: String) -> [ClaudeStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        return decode(object: obj)
    }

    static func decode(object obj: [String: Any]) -> [ClaudeStreamEvent] {
        switch obj["type"] as? String {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String {
                return [.sessionStarted(sessionId: sid)]
            }
            return []
        case "assistant":
            return assistantBlocks(obj)
        case "user":
            return toolResults(obj)
        case "result":
            let isError = (obj["is_error"] as? Bool ?? false) || (obj["subtype"] as? String != "success")
            let cost = obj["total_cost_usd"] as? Double
            // On an error the payload carries `errors: [String]` rather than a `result` string (e.g. a
            // dead `--resume` → "No conversation found with session ID: <id>"). Verified vs claude 2.1.207.
            let text = (obj["result"] as? String) ?? (obj["errors"] as? [String])?.joined(separator: "\n")
            return [.turnFinished(isError: isError, errorMessage: isError ? text : nil, costUSD: cost)]
        default:
            return []
        }
    }

    private static func assistantBlocks(_ obj: [String: Any]) -> [ClaudeStreamEvent] {
        guard let message = obj["message"] as? [String: Any],
              let messageId = message["id"] as? String,
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        return content.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.isEmpty else { return nil }
                return .assistantBlock(messageId: messageId, block: .text(text))
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                return .assistantBlock(messageId: messageId, block: .toolUse(id: id, name: name, inputJSON: jsonString(block["input"])))
            default:
                // thinking, redacted_thinking, etc. — not surfaced in the panel.
                return nil
            }
        }
    }

    private static func toolResults(_ obj: [String: Any]) -> [ClaudeStreamEvent] {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        return content.compactMap { block in
            guard block["type"] as? String == "tool_result",
                  let toolUseId = block["tool_use_id"] as? String
            else { return nil }
            let isError = block["is_error"] as? Bool ?? false
            return .toolResult(toolUseId: toolUseId, blocks: resultBlocks(block["content"]), isError: isError)
        }
    }

    /// A tool_result `content` is either a plain string or an array of text/image blocks.
    private static func resultBlocks(_ content: Any?) -> [ToolResult.Block] {
        if let s = content as? String { return [.text(s)] }
        guard let items = content as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            switch item["type"] as? String {
            case "text":
                guard let text = item["text"] as? String else { return nil }
                return .text(text)
            case "image":
                guard let source = item["source"] as? [String: Any],
                      let data = source["data"] as? String,
                      let mime = source["media_type"] as? String
                else { return nil }
                return .image(base64: data, mediaType: mime)
            default:
                return nil
            }
        }
    }

    /// Serialize a parsed JSON value (e.g. a tool_use `input` object) back to a compact string.
    /// Operates on the raw `Any` from JSONSerialization to avoid lossy intermediate bridging casts.
    private static func jsonString(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
