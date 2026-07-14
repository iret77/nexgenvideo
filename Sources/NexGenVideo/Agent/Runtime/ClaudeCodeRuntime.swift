import Foundation

// Drives one embedded `claude -p` session: starts the subprocess on the first message, streams its
// stdout through the decoder + mapper, writes follow-up user messages to stdin (one live process per
// session, so the conversation continues without --resume), and publishes the running conversation
// back to the agent panel via `onUpdate`.
//
// MainActor-isolated: all state + publishing happen on the main thread; the only suspension points are
// awaiting the line stream. Dependencies are injected so the error paths are unit-testable without a
// real `claude` binary.

@MainActor
final class ClaudeCodeRuntime {

    private let pluginDirectories: [URL]
    private let mcpPort: Int
    private let permissionMode: String
    private let resolveExecutable: () -> URL?
    private let resolveWorkingDirectory: @MainActor () -> URL?
    private let onUpdate: @MainActor ([AgentMessage], _ isStreaming: Bool) -> Void

    private var mapper = ClaudeCodeEventMapper()
    private var process: ClaudeCodeProcess?
    private var readTask: Task<Void, Never>?

    init(
        pluginDirectories: [URL] = [],
        mcpPort: Int = 19789,
        permissionMode: String = "bypassPermissions",
        resolveExecutable: @escaping () -> URL? = { ClaudeCodeLocator.resolve().executableURL },
        resolveWorkingDirectory: @MainActor @escaping () -> URL?,
        onUpdate: @MainActor @escaping ([AgentMessage], Bool) -> Void
    ) {
        self.pluginDirectories = pluginDirectories
        self.mcpPort = mcpPort
        self.permissionMode = permissionMode
        self.resolveExecutable = resolveExecutable
        self.resolveWorkingDirectory = resolveWorkingDirectory
        self.onUpdate = onUpdate
    }

    var messages: [AgentMessage] { mapper.messages }

    /// `context` (e.g. the user's current selection) is prepended to the payload sent to the model but
    /// never shown in the transcript — the user sees exactly what they typed.
    func send(text: String, context: String? = nil, hidden: Bool = false) {
        mapper.appendUserText(text, hidden: hidden)
        let payload = context.map { "\($0)\n\n\(text)" } ?? text
        if process == nil {
            guard startSession(firstMessage: payload) else { return }  // failure path already published
        } else {
            process?.send(line: ClaudeCodeLaunch.userMessageLine(payload))
        }
        onUpdate(mapper.messages, true)
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        process?.terminate()
        process = nil
        onUpdate(mapper.messages, false)
    }

    /// Returns true if the process started (and the first message was sent); false on failure
    /// (a note is appended and published before returning).
    private func startSession(firstMessage: String) -> Bool {
        guard let executable = resolveExecutable() else {
            fail("Claude Code CLI not found. Install it, or set its path in Settings → Agent.")
            return false
        }
        guard let workingDirectory = resolveWorkingDirectory() else {
            fail("No project folder is selected for the Claude Code runtime.")
            return false
        }

        let config = ClaudeCodeLaunchConfig(
            workingDirectory: workingDirectory,
            pluginDirectories: pluginDirectories,
            pluginMcpServers: Self.loadPluginMcpServers(pluginDirectories)
                .merging(ExternalMcpServers.all()) { existing, _ in existing },
            mcpPort: mcpPort,
            permissionMode: permissionMode,
            // #201: hand `claude -p` the FULL operating manual as a hard --append-system-prompt (it
            // already ends with the presentation contract), at parity with the API-key agent which gets
            // serverInstructions as its `system:` prompt. The MCP-advertised `instructions` field is a
            // soft protocol hint, not guaranteed injection — this closes that backend gap.
            appendSystemPrompt: AgentInstructions.serverInstructions
        )
        let newProcess = ClaudeCodeProcess()
        do {
            let stream = try newProcess.start(
                executableURL: executable,
                arguments: ClaudeCodeLaunch.arguments(config),
                workingDirectory: workingDirectory,
                environment: Self.childEnvironment()
            )
            process = newProcess
            newProcess.send(line: ClaudeCodeLaunch.userMessageLine(firstMessage))
            readTask = Task { [weak self] in
                await self?.consume(stream)
            }
            return true
        } catch {
            fail("Failed to start Claude Code: \(error.localizedDescription)")
            return false
        }
    }

    private func consume(_ stream: AsyncThrowingStream<String, Error>) async {
        var sawOutput = false
        do {
            for try await line in stream {
                let events = ClaudeStreamDecoder.decode(line: line)
                if !events.isEmpty { sawOutput = true }
                for event in events { mapper.ingest(event) }
                let finished = events.contains { event in
                    if case .turnFinished = event { return true }
                    return false
                }
                onUpdate(mapper.messages, !finished)
            }
        } catch {
            mapper.appendNote("Claude Code stream error: \(error.localizedDescription)")
        }
        // A session that ends with no parseable output almost always means claude exited early
        // (not logged in, a rejected flag/MCP config, a missing plugin venv, …). Surface its stderr
        // so the failure isn't silent.
        if !sawOutput, !Task.isCancelled {
            let stderr = (process?.drainStderr() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            mapper.appendNote(
                stderr.isEmpty
                    ? "Claude Code produced no output. Verify the CLI runs and is logged in — try `claude -p \"hi\"` in Terminal."
                    : "Claude Code produced no output.\nstderr:\n\(stderr)"
            )
        }
        onUpdate(mapper.messages, false)
    }

    private func fail(_ note: String) {
        mapper.appendNote(note)
        onUpdate(mapper.messages, false)
    }

    // MARK: - Launch resolution (I/O)

    /// Read each external plugin dir's `.mcp.json` and return its servers (name → serialized JSON
    /// entry), expanding `${CLAUDE_PLUGIN_ROOT}` to the plugin dir. Lets an external Claude-Code
    /// plugin's MCP server coexist with `nexgen` under `--strict-mcp-config`. First-party format packs
    /// are native and contribute no plugin dir, so `dirs` is only the dev "extra plugin folder".
    private static func loadPluginMcpServers(_ dirs: [URL]) -> [String: String] {
        var result: [String: String] = [:]
        for dir in dirs {
            let url = dir.appendingPathComponent(".mcp.json")
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let servers = json["mcpServers"] as? [String: Any]
            else { continue }
            for (name, entry) in servers {
                guard let entryData = try? JSONSerialization.data(withJSONObject: entry),
                      let entryString = String(data: entryData, encoding: .utf8)
                else { continue }
                result[name] = entryString.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: dir.path)
            }
        }
        return result
    }

    private static let providerEnvNames: [(GenerationProvider, String)] = [
        (.fal, "FAL_KEY"),
        (.runway, "RUNWAYML_API_SECRET"),
        (.elevenlabs, "ELEVENLABS_API_KEY"),
        (.marble, "WORLD_LABS_API_KEY"),
    ]

    /// Environment for the spawned `claude`: inherit the app's, augment PATH with the common
    /// tool locations a Finder-launched app misses (so the plugin's python/uv/claude resolve), and
    /// inject the BYO provider keys the pipeline's render step reads (e.g. FAL_KEY).
    private static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
        ]
        var seen = Set<String>()
        var ordered: [String] = []
        for path in (env["PATH"] ?? "").split(separator: ":").map(String.init) + extra
        where !path.isEmpty && seen.insert(path).inserted {
            ordered.append(path)
        }
        env["PATH"] = ordered.joined(separator: ":")
        for (provider, name) in providerEnvNames {
            if let key = ProviderKeychain.load(provider) { env[name] = key }
        }
        return env
    }
}
