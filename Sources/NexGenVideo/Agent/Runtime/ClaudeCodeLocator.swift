import Foundation

// Locates the user's installed `claude` CLI and reads its version. The embedded runtime uses the
// user's own logged-in Claude subscription, so we shell out to their existing binary rather than
// bundling one. Pure helpers (candidatePaths/parseVersion) are unit-tested; resolve() does the IO.

struct ClaudeCodeLocator {

    struct Result: Sendable, Equatable {
        var executableURL: URL?
        var version: String?
        var found: Bool { executableURL != nil }
    }

    /// Candidate locations in priority order: explicit local install, PATH entries, Homebrew prefixes.
    static func candidatePaths(home: String, path: String?) -> [String] {
        var out: [String] = ["\(home)/.claude/local/claude"]
        if let path {
            for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
                out.append("\(dir)/claude")
            }
        }
        out.append("/opt/homebrew/bin/claude")
        out.append("/usr/local/bin/claude")
        return out
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

    /// Resolve binary + version from the given environment. Synchronous — used by settings/status.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Result {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let candidates = candidatePaths(home: home, path: environment["PATH"])
        guard let url = locateExecutable(candidates: candidates) else {
            return Result(executableURL: nil, version: nil)
        }
        return Result(executableURL: url, version: readVersion(executableURL: url))
    }

    private static func readVersion(executableURL: URL) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parseVersion(String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }
}
