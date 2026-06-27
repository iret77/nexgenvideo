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

    func send(text: String) {
        mapper.appendUserText(text)
        if process == nil {
            guard startSession(firstMessage: text) else { return }  // failure path already published
        } else {
            process?.send(line: ClaudeCodeLaunch.userMessageLine(text))
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
            mcpPort: mcpPort,
            permissionMode: permissionMode
        )
        let newProcess = ClaudeCodeProcess()
        do {
            let stream = try newProcess.start(
                executableURL: executable,
                arguments: ClaudeCodeLaunch.arguments(config),
                workingDirectory: workingDirectory
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
        do {
            for try await line in stream {
                let events = ClaudeStreamDecoder.decode(line: line)
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
        onUpdate(mapper.messages, false)
    }

    private func fail(_ note: String) {
        mapper.appendNote(note)
        onUpdate(mapper.messages, false)
    }
}
