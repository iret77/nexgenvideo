import Foundation

// Builds the launch argv (and inline MCP config) for one embedded `claude -p` session. Pure /
// deterministic so it is fully unit-tested. The user prompt is delivered over stdin as stream-json,
// so it is NOT part of the argv. Flags verified against `claude` v2.1.191.

struct ClaudeCodeLaunchConfig: Sendable, Equatable {
    var workingDirectory: URL
    /// External Claude-Code plugin dirs (the dev "extra plugin folder"). First-party format packs are
    /// native — they contribute no `--plugin-dir`.
    var pluginDirectories: [URL]
    /// Plugin-contributed MCP servers (name → serialized JSON entry, already
    /// `${CLAUDE_PLUGIN_ROOT}`-expanded). Merged alongside `nexgen` so they survive
    /// `--strict-mcp-config`. Read from each external plugin dir's `.mcp.json` at launch.
    var pluginMcpServers: [String: String]
    /// NexGenVideo's local MCP server port.
    var mcpPort: Int
    /// e.g. "bypassPermissions", "acceptEdits", "dontAsk", "default".
    var permissionMode: String
    /// Comma-separated setting sources (user/project/local). "project,local" keeps the session
    /// hermetic — drops the user's global CLAUDE.md / hooks / settings — while keeping subscription
    /// auth (verified against claude v2.1.191). Empty → omit the flag (load all sources).
    var settingSources: String
    /// Optional allowlist (e.g. ["mcp__nexgen"]). Empty → rely on permissionMode alone.
    var allowedTools: [String]
    /// Model alias or full id; nil = user default.
    var model: String?
    /// Appended to the runtime's system prompt (--append-system-prompt) — the presentation
    /// contract reaches the embedded session even though it loads no in-app manual.
    var appendSystemPrompt: String?
    /// Pre-assigned UUID for a new session (lets us --resume it later).
    var sessionId: String?
    /// Resume an existing session id (takes precedence over sessionId).
    var resumeSessionId: String?

    init(
        workingDirectory: URL,
        pluginDirectories: [URL] = [],
        pluginMcpServers: [String: String] = [:],
        mcpPort: Int = 19789,
        permissionMode: String = "bypassPermissions",
        settingSources: String = "project,local",
        allowedTools: [String] = [],
        model: String? = nil,
        appendSystemPrompt: String? = nil,
        sessionId: String? = nil,
        resumeSessionId: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.pluginDirectories = pluginDirectories
        self.pluginMcpServers = pluginMcpServers
        self.mcpPort = mcpPort
        self.permissionMode = permissionMode
        self.settingSources = settingSources
        self.allowedTools = allowedTools
        self.model = model
        self.appendSystemPrompt = appendSystemPrompt
        self.sessionId = sessionId
        self.resumeSessionId = resumeSessionId
    }
}

enum ClaudeCodeLaunch {

    /// Inline MCP config (passed via --mcp-config). Always registers the local `nexgen` HTTP server;
    /// merges in any external plugin-contributed servers so both survive `--strict-mcp-config`.
    /// `pluginServers` values are already-serialized JSON objects.
    static func mcpConfigJSON(port: Int, pluginServers: [String: String] = [:]) -> String {
        var entries = ["\"nexgen\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:\(port)/mcp\"}"]
        for name in pluginServers.keys.sorted() where name != "nexgen" {
            entries.append("\"\(name)\":\(pluginServers[name]!)")
        }
        return "{\"mcpServers\":{\(entries.joined(separator: ","))}}"
    }

    /// Argv for `claude` (excluding the executable path). Hermetic: --strict-mcp-config so only
    /// NexGenVideo's MCP is visible, not the user's global servers.
    static func arguments(_ cfg: ClaudeCodeLaunchConfig) -> [String] {
        var args: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            // claude refuses `--print --output-format=stream-json` without --verbose (exits to stderr,
            // no stdout) — its absence is a silent total failure.
            "--verbose",
            "--mcp-config", mcpConfigJSON(port: cfg.mcpPort, pluginServers: cfg.pluginMcpServers),
            "--strict-mcp-config",
            "--permission-mode", cfg.permissionMode,
            "--add-dir", cfg.workingDirectory.path,
        ]
        for dir in cfg.pluginDirectories {
            args.append("--plugin-dir")
            args.append(dir.path)
        }
        if !cfg.settingSources.isEmpty {
            args.append("--setting-sources")
            args.append(cfg.settingSources)
        }
        if !cfg.allowedTools.isEmpty {
            args.append("--allowedTools")
            args.append(cfg.allowedTools.joined(separator: " "))
        }
        if let model = cfg.model {
            args.append("--model")
            args.append(model)
        }
        if let append = cfg.appendSystemPrompt, !append.isEmpty {
            args.append("--append-system-prompt")
            args.append(append)
        }
        if let resume = cfg.resumeSessionId {
            args.append("--resume")
            args.append(resume)
        } else if let sessionId = cfg.sessionId {
            args.append("--session-id")
            args.append(sessionId)
        }
        return args
    }

    /// One stream-json input line carrying a user message (written to the process stdin). `imageBlocks`
    /// are `{"type":"image","source":{...}}` dicts (the same base64 shape the API path builds) so an
    /// uploaded image reaches the subprocess instead of being dropped — the CLI's stream-json `user`
    /// message accepts the API image-source shape.
    static func userMessageLine(_ text: String, imageBlocks: [[String: Any]] = []) -> String {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        content.append(contentsOf: imageBlocks)
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }
}
