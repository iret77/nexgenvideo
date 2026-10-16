import Foundation

/// A server-run tool step (tool search) kept byte-exact so later requests replay it unchanged.
struct AnthropicServerToolBlock: Codable, Sendable, Equatable {
    private let encodedJSON: Data

    init(json: [String: Any]) throws {
        switch json["type"] as? String {
        case "server_tool_use":
            guard let id = json["id"] as? String, !id.isEmpty,
                  let name = json["name"] as? String, !name.isEmpty,
                  json["input"] is [String: Any] else {
                throw AnthropicClientError.streamError("Server tool call is incomplete.")
            }
        case "tool_search_tool_result":
            guard let id = json["tool_use_id"] as? String, !id.isEmpty,
                  json["content"] is [String: Any] else {
                throw AnthropicClientError.streamError("Tool search result is incomplete.")
            }
        default:
            throw AnthropicClientError.streamError("Unexpected server tool block type.")
        }
        encodedJSON = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: encodedJSON) as? [String: Any]) ?? [:]
    }

    var canonicalJSON: String { String(decoding: encodedJSON, as: UTF8.self) }

    /// Tools a search result surfaced; empty for any other block.
    var referencedToolNames: [String] {
        let object = json
        guard object["type"] as? String == "tool_search_tool_result",
              let content = object["content"] as? [String: Any],
              let references = content["tool_references"] as? [[String: Any]] else { return [] }
        return references.compactMap { $0["tool_name"] as? String }
    }

    init(from decoder: any Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicClientError.streamError("Invalid saved server tool block.")
        }
        try self.init(json: json)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedJSON)
    }
}

/// Server-side tool search with deferred loading for the API-key backend.
enum AnthropicToolSearch {
    static let toolType = "tool_search_tool_regex_20251119"
    static let toolName = "tool_search_tool_regex"

    // No Models API flag exists; documented support only (Haiku 4.5 omitted: the docs disagree on it).
    private static let documentedModels: Set<String> = [
        "claude-fable-5-1", "claude-mythos-5-1", "claude-fable-5", "claude-mythos-5",
        "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-sonnet-5", "claude-haiku-5-5",
        "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6",
        "claude-opus-4-5", "claude-opus-4-5-20251101", "claude-sonnet-4-5", "claude-sonnet-4-5-20250929",
    ]

    static func isDocumented(modelID: String) -> Bool {
        documentedModels.contains(modelID)
    }

    /// Tools that stay loaded up front, or nil when every tool loads directly without search.
    static func loadedToolNames(_ names: [String], enabled: Bool, pinned: Set<String> = []) -> Set<String>? {
        guard enabled else { return nil }
        let all = Set(names)
        let core = all.intersection(ToolDefinitions.core.map(\.rawValue))
        let loaded = core.union(all.intersection(pinned))
        guard !core.isEmpty, loaded.count < all.count, !all.contains(toolName) else { return nil }
        return loaded
    }

    /// Non-core tools a chat called before any search result in it surfaced them.
    static func toolsUsedBeforeSurfacing(_ messages: [AgentMessage]) -> Set<String> {
        let core = Set(ToolDefinitions.core.map(\.rawValue))
        var surfaced: Set<String> = []
        var used: Set<String> = []
        for message in messages where message.role == .assistant && !message.isIncompleteAPIResponse {
            for block in message.blocks {
                switch block {
                case .serverTool(let server):
                    surfaced.formUnion(server.referencedToolNames)
                case .toolUse(_, let name, _) where !core.contains(name) && !surfaced.contains(name):
                    used.insert(name)
                default:
                    break
                }
            }
        }
        return used
    }

    static var searchToolBlock: [String: Any] {
        ["type": toolType, "name": toolName]
    }
}
