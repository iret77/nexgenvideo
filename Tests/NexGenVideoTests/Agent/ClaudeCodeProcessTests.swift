import Foundation
import Testing
@testable import NexGenVideo

// Exercises the subprocess mechanics against standard tools available on the CI macOS runner —
// no `claude` binary required.

@Suite("ClaudeCodeProcess")
struct ClaudeCodeProcessTests {

    @Test func streamsStdoutLines() async throws {
        let proc = ClaudeCodeProcess()
        let stream = try proc.start(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'a\\nb\\nc\\n'"],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        #expect(lines == ["a", "b", "c"])
    }

    @Test func echoesStdinThenFinishesAtEOF() async throws {
        let proc = ClaudeCodeProcess()
        let stream = try proc.start(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        proc.send(line: "hello")
        proc.closeStdin()   // cat exits at EOF, which finishes the stream

        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        #expect(lines == ["hello"])
    }
}
