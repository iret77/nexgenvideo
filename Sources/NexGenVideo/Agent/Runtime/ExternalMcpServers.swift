import Foundation

/// User-registered external MCP servers for the embedded Claude Code runtime (Settings → Agent).
/// Stored in UserDefaults as name → serialized `{"command": …, "args": […]}` JSON — the same shape
/// plugin `.mcp.json` entries use — so they merge straight into the launch config and survive
/// `--strict-mcp-config`. This is how e.g. ACE Studio 2's built-in stdio MCP server plugs in: the
/// agent can then drive ACE (compose vocals/music) and pull the exports into the timeline.
enum ExternalMcpServers {
    static let defaultsKey = "externalMcpServers"

    static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    static func set(name: String, entryJSON: String) {
        var current = all()
        current[name] = entryJSON
        UserDefaults.standard.set(current, forKey: defaultsKey)
    }

    static func remove(name: String) {
        var current = all()
        current.removeValue(forKey: name)
        UserDefaults.standard.set(current, forKey: defaultsKey)
    }

    /// Human-readable command preview for the list row.
    static func commandPreview(entryJSON: String) -> String {
        guard let data = entryJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return entryJSON
        }
        if let url = obj["url"] as? String { return url }
        guard let command = obj["command"] as? String else { return entryJSON }
        let args = (obj["args"] as? [String]) ?? []
        return ([command] + args).joined(separator: " ")
    }

    /// Accepts either a JSON entry / full `{"mcpServers": {…}}` snippet (what apps like ACE Studio
    /// put on the clipboard for MCP clients) or a plain command line (shell-split, quotes honored).
    static func entryJSON(fromUserInput input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Hosted HTTP MCP servers (e.g. OpenArt's https://mcp.openart.ai/mcp) — same entry shape
        // the built-in `nexgen` server uses.
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return compact(["type": "http", "url": trimmed])
        }
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            if obj["command"] is String || obj["url"] is String { return compact(obj) }
            if let servers = obj["mcpServers"] as? [String: Any],
               let first = servers.values.first as? [String: Any],
               first["command"] is String || first["url"] is String {
                return compact(first)
            }
            return nil
        }
        let parts = shellSplit(trimmed)
        guard let command = parts.first else { return nil }
        var entry: [String: Any] = ["command": command]
        if parts.count > 1 { entry["args"] = Array(parts.dropFirst()) }
        return compact(entry)
    }

    /// When the pasted snippet is `{"mcpServers": {name: …}}`, surface that name as a suggestion.
    static func nameHint(fromUserInput input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return nil }
        return servers.keys.first
    }

    private static func compact(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Minimal shell-style splitter: whitespace-separated; single/double quotes group tokens.
    static func shellSplit(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
