import Darwin
import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Bounded Claude CLI probes")
struct ClaudeCodeProbeTests {
    private struct Fixture: Sendable {
        let root: URL
        init(_ body: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let executable = root.appendingPathComponent("claude")
            try Data(("#!/bin/sh\n" + body).utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        var environment: [String: String] { ["HOME": root.path, "PATH": root.path] }
        func close() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func hungStatusSharesOneDeadlineAndReapsATermIgnoringChild() async throws {
        let fixture = try Fixture(#"""
        trap '' TERM
        printf '%s\n' "$$" > "${0%/*}/pid"
        exec /bin/sleep 60
        """#)
        defer { fixture.close() }
        let began = ProcessInfo.processInfo.systemUptime
        let status = await Task.detached { ClaudeCodeLocator.status(environment: fixture.environment) }.value
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        #expect(status.found && status.version == nil && !status.isAuthenticated)
        #expect(elapsed < 6)
        let raw = try String(contentsOf: fixture.root.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try #require(Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        let result = kill(pid, 0)
        let code = errno
        #expect(result == -1 && code == ESRCH)
    }

    @Test func statusDrainsVersionAndDiscardsLargeStderr() async throws {
        let fixture = try Fixture(#"""
        i=0
        while [ "$i" -lt 4096 ]; do
            printf '01234567890123456789012345678901\n' >&2
            i=$((i + 1))
        done
        printf '2.1.191 (Claude Code)\n'
        exit 0
        """#)
        defer { fixture.close() }
        let status = await Task.detached { ClaudeCodeLocator.status(environment: fixture.environment) }.value
        #expect(status.found && status.version == "2.1.191" && status.isAuthenticated)
    }

    @Test func startingASessionDoesNotRunAVersionProbe() async throws {
        let fixture = try Fixture(#"""
        printf '%s\n' "$*" >> "${0%/*}/arguments"
        printf '%s\n' '{"type":"result","subtype":"success","is_error":false}'
        """#)
        defer { fixture.close() }
        let runtime = ClaudeCodeRuntime(environment: fixture.environment,
            resolveWorkingDirectory: { fixture.root }, systemInstructions: "test instructions", onUpdate: { _, _ in })
        defer { runtime.stop() }
        runtime.send(text: "hello")
        let arguments = fixture.root.appendingPathComponent("arguments")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var invocations = ""
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileReadNoSuchFile) }
            invocations = (try? String(contentsOf: arguments, encoding: .utf8)) ?? ""
            if invocations.contains("--input-format") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!invocations.contains("--version"))
    }
}
