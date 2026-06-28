import Foundation

// Builds the launch argv (and inline MCP config) for one embedded `claude -p` session. Pure /
// deterministic so it is fully unit-tested. The user prompt is delivered over stdin as stream-json,
// so it is NOT part of the argv. Flags verified against `claude` v2.1.191.

struct ClaudeCodeLaunchConfig: Sendable, Equatable {
    var workingDirectory: URL
    /// Generic core first, then any active format pack(s) (e.g. musicvideo).
    var pluginDirectories: [URL]
    /// Palmier's local MCP server port.
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
    /// Pre-assigned UUID for a new session (lets us --resume it later).
    var sessionId: String?
    /// Resume an existing session id (takes precedence over sessionId).
    var resumeSessionId: String?

    init(
        workingDirectory: URL,
        pluginDirectories: [URL] = [],
        mcpPort: Int = 19789,
        permissionMode: String = "bypassPermissions",
        settingSources: String = "project,local",
        allowedTools: [String] = [],
        model: String? = nil,
        sessionId: String? = nil,
        resumeSessionId: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.pluginDirectories = pluginDirectories
        self.mcpPort = mcpPort
        self.permissionMode = permissionMode
        self.settingSources = settingSources
        self.allowedTools = allowedTools
        self.model = model
        self.sessionId = sessionId
        self.resumeSessionId = resumeSessionId
    }
}

enum ClaudeCodeLaunch {

    /// Inline MCP config (passed via --mcp-config) registering Palmier's local HTTP MCP server.
    static func mcpConfigJSON(port: Int) -> String {
        "{\"mcpServers\":{\"nexgen\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:\(port)/mcp\"}}}"
    }

    /// Argv for `claude` (excluding the executable path). Hermetic: --strict-mcp-config so only
    /// Palmier's MCP is visible, not the user's global servers.
    static func arguments(_ cfg: ClaudeCodeLaunchConfig) -> [String] {
        var args: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--mcp-config", mcpConfigJSON(port: cfg.mcpPort),
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
        if let resume = cfg.resumeSessionId {
            args.append("--resume")
            args.append(resume)
        } else if let sessionId = cfg.sessionId {
            args.append("--session-id")
            args.append(sessionId)
        }
        return args
    }

    /// One stream-json input line carrying a user text message (written to the process stdin).
    static func userMessageLine(_ text: String) -> String {
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }
}
