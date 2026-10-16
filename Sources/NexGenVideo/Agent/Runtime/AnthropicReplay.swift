import CryptoKit
import Foundation

/// Fingerprint of everything a thinking block's signature is bound to: system, tools as loaded, and
/// the non-thinking content before it. Insensitive to message merging and to thinking removal.
struct AnthropicPrefixDigest {
    private var hasher = SHA256()
    private let replaysServerTools: Bool

    init(system: String, tools: [AgentRuntimeToolSchema], toolSearch: Bool = false) {
        let loaded = AnthropicToolSearch.loadedToolNames(tools.map(\.name), enabled: toolSearch)
        replaysServerTools = loaded != nil
        write("system")
        write(system)
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            write("tool")
            write(tool.name)
            write(tool.description)
            let schema = (try? JSONSerialization.data(withJSONObject: tool.inputSchema, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            write(schema)
        }
        if let loaded {
            write("tool_search")
            write(AnthropicToolSearch.toolType)
            for name in loaded.sorted() {
                write("loaded")
                write(name)
            }
        }
    }

    mutating func append(_ message: AgentRuntimeMessage) {
        let role = message.role == .user ? "user" : "assistant"
        for content in message.content {
            switch content {
            case .thinking:
                continue
            case .serverTool(let block):
                guard replaysServerTools else { continue }
                write(role); write("server_tool"); write(block.canonicalJSON)
            case .text(let value):
                write(role); write("text"); write(value)
            case .image(let image):
                write(role); write("image"); write(image.mediaType); write(image.base64)
            case .toolUse(let id, let name, let inputJSON):
                write(role); write("tool_use"); write(id); write(name); write(inputJSON)
            case .toolResult(let id, let blocks, let isError):
                write(role); write("tool_result"); write(id); write(isError ? "error" : "ok")
                for block in blocks {
                    switch block {
                    case .text(let value):
                        write("text"); write(value)
                    case .image(let base64, let mediaType):
                        write("image"); write(mediaType); write(base64)
                    }
                }
                write("end")
            }
        }
    }

    var value: String {
        var snapshot = hasher
        return snapshot.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func of(
        system: String,
        tools: [AgentRuntimeToolSchema],
        toolSearch: Bool = false,
        messages: [AgentRuntimeMessage]
    ) -> String {
        var digest = AnthropicPrefixDigest(system: system, tools: tools, toolSearch: toolSearch)
        for message in messages { digest.append(message) }
        return digest.value
    }

    private mutating func write(_ string: String) {
        let bytes = Data(string.utf8)
        var length = UInt64(bytes.count).littleEndian
        hasher.update(data: Data(bytes: &length, count: MemoryLayout<UInt64>.size))
        hasher.update(data: bytes)
    }
}

/// Append-only replay for the Anthropic Messages API (preserved thinking).
enum AnthropicReplay {
    struct Entry: Equatable {
        let role: AgentMessage.Role
        var content: [AgentRuntimeContent]
        let recordedPrefixDigest: String?
    }

    /// Removes thinking from every assistant turn up to the last one whose recorded prefix no
    /// longer matches, so the replayed blocks stay a contiguous, still-valid tail.
    static func strippingInvalidatedThinking(
        _ entries: [Entry],
        system: String,
        tools: [AgentRuntimeToolSchema],
        toolSearch: Bool = false
    ) -> [AgentRuntimeMessage] {
        var entries = entries
        let carriesThinking = entries.contains { entry in
            entry.role == .assistant && entry.content.contains(where: isThinking)
        }
        if carriesThinking {
            var digest = AnthropicPrefixDigest(system: system, tools: tools, toolSearch: toolSearch)
            var lastInvalid: Int?
            for (index, entry) in entries.enumerated() {
                if entry.role == .assistant, entry.recordedPrefixDigest != digest.value {
                    lastInvalid = index
                }
                digest.append(AgentRuntimeMessage(role: entry.role, content: entry.content))
            }
            if let lastInvalid {
                for index in entries.indices where index <= lastInvalid && entries[index].role == .assistant {
                    entries[index].content.removeAll(where: isThinking)
                }
            }
        }
        return entries
            .filter { !$0.content.isEmpty }
            .map { AgentRuntimeMessage(role: $0.role, content: $0.content) }
    }

    /// The Messages API joins consecutive same-role turns; sending them joined keeps every
    /// later request byte-identical to the one that produced a block. Without tool search in the
    /// request, its earlier server steps cannot be replayed.
    static func wireMessages(
        _ messages: [AgentRuntimeMessage],
        keepingServerTools: Bool = true
    ) -> [AgentRuntimeMessage] {
        var result: [AgentRuntimeMessage] = []
        let sendable = keepingServerTools ? messages : messages.map { message in
            AgentRuntimeMessage(role: message.role, content: message.content.filter { !isServerTool($0) })
        }
        for message in sendable where !message.content.isEmpty {
            if let last = result.last, last.role == message.role {
                result[result.count - 1] = AgentRuntimeMessage(
                    role: last.role,
                    content: last.content + message.content
                )
            } else {
                result.append(message)
            }
        }
        return result
    }

    static func isThinking(_ content: AgentRuntimeContent) -> Bool {
        if case .thinking = content { return true }
        return false
    }

    static func isServerTool(_ content: AgentRuntimeContent) -> Bool {
        if case .serverTool = content { return true }
        return false
    }
}
