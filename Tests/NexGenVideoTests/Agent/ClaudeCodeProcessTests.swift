import Foundation
import Testing
@testable import NexGenVideo

// Exercises the subprocess mechanics against standard tools available on the CI macOS runner —
// no `claude` binary required.

@Suite("ClaudeCodeProcess")
struct ClaudeCodeProcessTests {

    @Test func streamsStdoutLines() async throws {
        let proc = ClaudeCodeProcess()
        defer { proc.terminate() }
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
        defer { proc.terminate() }
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

    @Test(.timeLimit(.minutes(1))) func shutdownDoesNotWaitForDescendantStdoutEOF() async throws {
        let proc = ClaudeCodeProcess()
        defer { proc.terminate() }
        let stream = try proc.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 3 & printf 'ready\\n'; wait"],
            workingDirectory: FileManager.default.temporaryDirectory)
        for try await line in stream { if line == "ready" { break } }
        let start = ContinuousClock.now
        await proc.shutdownAndWait()
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(!proc.isRunning && proc.exitStatus != nil)
        try await Task.sleep(for: .seconds(3))
    }

    @Test(.timeLimit(.minutes(1))) func stderrIsDrainedWhileTheChildRuns() async throws {
        let proc = ClaudeCodeProcess()
        defer { proc.terminate() }
        let stream = try proc.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 262144 /dev/zero >&2; printf 'done\\n'"],
            workingDirectory: FileManager.default.temporaryDirectory)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await proc.shutdownAndWait()
        }
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        watchdog.cancel()
        await watchdog.value
        await proc.shutdownAndWait()
        #expect(lines == ["done"])
        #expect(proc.exitStatus == 0)
        #expect(proc.drainStderr().utf8.count == 65_536)
    }

    @Test(.timeLimit(.minutes(1))) func queuedLargeInputPreservesBytesAndEOFOrder() async throws {
        let proc = ClaudeCodeProcess()
        defer { proc.terminate() }
        let stream = try proc.start(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory)
        let text = String(repeating: "é", count: 150_000)
        #expect(proc.send(line: text))
        #expect(proc.send(line: "second"))
        proc.closeStdin()
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        await proc.shutdownAndWait()
        #expect(lines == [text, "second"])
    }

    @Test(.timeLimit(.minutes(1))) func childClosingStdinStillDeliversItsFinalStdoutAndStderr() async throws {
        let proc = ClaudeCodeProcess()
        defer { proc.terminate() }
        let script = "trap 'printf \"final-result\\n\"; printf \"last-stderr\\n\" >&2; exit 0' TERM; exec 0<&-; printf 'ready\\n'; while :; do sleep 0.01; done"
        let stream = try proc.start(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await proc.shutdownAndWait()
        }
        var lines: [String] = []
        for try await line in stream {
            lines.append(line)
            if line == "ready" { #expect(proc.send(line: "closed pipe")) }
        }
        watchdog.cancel()
        await watchdog.value
        #expect(lines == ["ready", "final-result"])
        #expect(proc.drainStderr() == "last-stderr\n")
        await proc.shutdownAndWait()
        #expect(proc.drainStderr() == "last-stderr\n")
        #expect(!proc.isRunning && proc.exitStatus == 0)
    }

    @Test(.timeLimit(.minutes(1))) func exactStderrTailIsAvailableAtStdoutEOF() async throws {
        let proc = ClaudeCodeProcess()
        defer { proc.terminate() }
        let stream = try proc.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 262144 /dev/zero >&2; printf 'exit-diagnostic\\n' >&2; printf 'done\\n'"],
            workingDirectory: FileManager.default.temporaryDirectory)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await proc.shutdownAndWait()
        }
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        watchdog.cancel()
        await watchdog.value
        let expected = String(repeating: "\0", count: 65_536 - "exit-diagnostic\n".utf8.count) + "exit-diagnostic\n"
        #expect(lines == ["done"])
        #expect(proc.drainStderr() == expected)
        await proc.shutdownAndWait()
        #expect(proc.drainStderr() == expected)
        #expect(proc.exitStatus == 0)
    }

    @Test(.timeLimit(.minutes(1))) func concurrentShutdownRetainsAlreadyWrittenStderr() async throws {
        let proc = ClaudeCodeProcess()
        defer { proc.terminate() }
        let stream = try proc.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'before-shutdown\\n' >&2; printf 'ready\\n'; exec sleep 30"],
            workingDirectory: FileManager.default.temporaryDirectory)
        for try await line in stream { if line == "ready" { break } }
        proc.closeStdin()
        async let first: Void = proc.shutdownAndWait()
        async let second: Void = proc.shutdownAndWait()
        _ = await (first, second)
        await proc.shutdownAndWait()
        #expect(proc.drainStderr() == "before-shutdown\n")
        #expect(!proc.isRunning && proc.exitStatus != nil)
    }
}
