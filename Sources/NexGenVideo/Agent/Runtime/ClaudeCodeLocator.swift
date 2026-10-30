import BpyRuntimeProtocol
import Darwin
import Foundation

// Keep chat startup independent of metadata probes.

struct ClaudeCodeLocator {

    struct Status: Sendable, Equatable {
        var executableURL: URL?
        var version: String?
        var isAuthenticated: Bool
        var found: Bool { executableURL != nil }
    }

    /// Install directories a Finder-launched app's PATH misses: the native installer, then Homebrew.
    static func installDirectories(home: String) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// Candidate locations in priority order: legacy local install, PATH entries, install directories.
    static func candidatePaths(home: String, path: String?) -> [String] {
        var out: [String] = ["\(home)/.claude/local/claude"]
        if let path {
            for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
                out.append("\(dir)/claude")
            }
        }
        out += installDirectories(home: home).map { "\($0)/claude" }
        return out
    }

    /// PATH for the spawned runtime: the app's own entries, then the same install directories.
    static func runtimePath(existing: String?, home: String) -> String {
        var seen = Set<String>()
        return ((existing ?? "").split(separator: ":").map(String.init) + installDirectories(home: home))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// Parse `claude --version` output, e.g. "2.1.191 (Claude Code)" → "2.1.191".
    static func parseVersion(_ output: String) -> String? {
        let token = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .first
            .map(String.init)
        guard let token,
              token.split(separator: ".").count >= 2,
              token.allSatisfy({ $0.isNumber || $0 == "." })
        else { return nil }
        return token
    }

    /// First candidate that exists and is executable.
    static func locateExecutable(candidates: [String], fileManager: FileManager = .default) -> URL? {
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Just find the binary (no --version subprocess) — cheap enough to call from a view body.
    static func locateOnly(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return locateExecutable(candidates: candidatePaths(home: home, path: environment["PATH"]))
    }

    static func status(environment: [String: String] = ProcessInfo.processInfo.environment) -> Status {
        let deadline = DispatchTime.now() + 5
        guard let executableURL = locateOnly(environment: environment) else {
            return Status(executableURL: nil, version: nil, isAuthenticated: false)
        }
        return Status(
            executableURL: executableURL,
            version: readVersion(executableURL: executableURL, environment: environment, deadline: deadline),
            isAuthenticated: probe(executableURL: executableURL, arguments: ["auth", "status", "--json"],
                environment: environment, deadline: deadline, captureOutput: false)?.status == 0
        )
    }

    private static func readVersion(executableURL: URL, environment: [String: String], deadline: DispatchTime) -> String? {
        guard let result = probe(executableURL: executableURL, arguments: ["--version"], environment: environment,
                                 deadline: deadline, captureOutput: true), result.status == 0 else { return nil }
        return parseVersion(String(decoding: result.output, as: UTF8.self))
    }

    private static func probe(executableURL: URL, arguments: [String], environment: [String: String],
                              deadline: DispatchTime, captureOutput: Bool) -> (status: Int32, output: Data)? {
        guard DispatchTime.now() < deadline else { return nil }
        let pipe = captureOutput ? Pipe() : nil
        defer { try? pipe?.fileHandleForReading.close(); try? pipe?.fileHandleForWriting.close() }
        let descriptor = pipe?.fileHandleForReading.fileDescriptor ?? -1
        if descriptor >= 0 {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        }
        guard let process = try? BpyOwnedProcess(executable: executableURL, arguments: arguments, environment: environment,
            directory: FileManager.default.temporaryDirectory, input: .nullDevice,
            output: pipe?.fileHandleForWriting ?? .nullDevice, errors: .nullDevice) else { return nil }
        defer { _ = try? process.terminateAndReap(grace: 0.1) }
        try? pipe?.fileHandleForWriting.close()
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        func drain() -> Bool {
            guard descriptor >= 0 else { return true }
            while DispatchTime.now() < deadline {
                let received = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                if received > 0 {
                    guard output.count + received <= 65_536 else { return false }
                    output.append(contentsOf: buffer.prefix(received))
                } else if received == 0 { return true }
                else if errno != EINTR { return errno == EAGAIN || errno == EWOULDBLOCK }
            }
            return false
        }
        while DispatchTime.now() < deadline {
            guard drain() else { return nil }
            if let status = try? process.waitUntilExit(timeout: 0) {
                guard drain() else { return nil }
                return (status, output)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }
}
