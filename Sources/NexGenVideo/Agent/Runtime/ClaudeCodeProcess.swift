import Foundation

// Thin wrapper around the embedded `claude -p` subprocess: launch with argv + cwd, stream stdout
// NDJSON lines as an AsyncThrowingStream, write stream-json lines to stdin, and tear down cleanly.
//
// Mirrors the streaming shape of AnthropicClient.stream(): the Task captures only Sendable values
// (self, continuation) and obtains the byte sequence *inside* the async work, never across the
// concurrency boundary. `@unchecked Sendable` because access is serialized by the owning runtime.

final class ClaudeCodeProcess: @unchecked Sendable {

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle

    init() {
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
    }

    /// Launch the process and return a stream of stdout lines. Throws if it can't be started.
    func start(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let environment { process.environment = environment }

        try process.run()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in self.stdoutHandle.bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Write one stream-json line (a newline is appended) to the process stdin.
    func send(line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? stdinHandle.write(contentsOf: data)
    }

    /// Close stdin (signals end-of-input to the child).
    func closeStdin() {
        try? stdinHandle.close()
    }

    /// Read whatever the child wrote to stderr so far (diagnostics on failure).
    func drainStderr() -> String {
        let data = stderrPipe.fileHandleForReading.availableData
        return String(decoding: data, as: UTF8.self)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    var isRunning: Bool { process.isRunning }
}
