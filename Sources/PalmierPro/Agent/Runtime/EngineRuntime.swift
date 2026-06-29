import Foundation

// Bootstraps the bundled Generic Engine into a local venv (via `uv`) so the embedded
// claude can reach its MCP server. bundle.sh ships the engine + packs at
// Contents/Resources/{engine,packs}; the venv lives in Application Support (survives app
// updates); the resolved python is published to UserDefaults `claudeRuntimeEnginePython`,
// which ClaudeCodeRuntime registers as the `engine` MCP server.
//
// The uv run is macOS-only at runtime, but the paths + status are inspectable and
// bootstrap() is idempotent (skips the venv create if it already exists).
enum EngineRuntime {
    static let pythonDefaultsKey = "claudeRuntimeEnginePython"

    static var bundledEngineDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("engine") }
    static var bundledPacksDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("packs") }

    // uv shipped inside the .app (bundle.sh → Contents/Resources/bin/uv). Self-contained: it
    // downloads + manages its own CPython, so a release Mac needs no brew/uv/system Python.
    static var bundledUV: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/uv"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static var venvDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("NexGenVideo/engine-venv", isDirectory: true)
    }
    static var venvPython: URL { venvDir.appendingPathComponent("bin/python") }

    static var isVenvReady: Bool { FileManager.default.fileExists(atPath: venvPython.path) }

    enum Status: Equatable {
        case unavailable        // no engine bundled (e.g. dev build run from .build)
        case notBootstrapped
        case ready(python: String)
        case failed(String)
    }

    static func status() -> Status {
        guard let engine = bundledEngineDir, FileManager.default.fileExists(atPath: engine.path) else {
            return .unavailable
        }
        if let python = UserDefaults.standard.string(forKey: pythonDefaultsKey),
           !python.isEmpty, FileManager.default.fileExists(atPath: python) {
            return .ready(python: python)
        }
        return .notBootstrapped
    }

    enum EngineError: LocalizedError {
        case toolNotFound(String)
        case command(String)
        var errorDescription: String? {
            switch self {
            case .toolNotFound(let t): return "Engine runtime tool \"\(t)\" is missing from this build."
            case .command(let m): return m
            }
        }
    }

    /// Create the venv (uv) and install the bundled engine + packs, then publish the python
    /// path so the engine MCP registers. Idempotent; safe to call when already ready.
    @discardableResult
    static func bootstrap() async -> Status {
        guard let engine = bundledEngineDir, FileManager.default.fileExists(atPath: engine.path) else {
            return .unavailable
        }
        do {
            if !isVenvReady {
                try FileManager.default.createDirectory(
                    at: venvDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                // --python 3.12 lets uv fetch + manage its own CPython; no system Python required.
                try await run("uv", ["venv", "--python", "3.12", venvDir.path])
            }
            var installArgs = ["pip", "install", "--python", venvPython.path, "-e", engine.path]
            if let packs = bundledPacksDir,
               let entries = try? FileManager.default.contentsOfDirectory(at: packs, includingPropertiesForKeys: nil) {
                for dir in entries where FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("pyproject.toml").path) {
                    installArgs += ["-e", dir.path]
                }
            }
            try await run("uv", installArgs)
            UserDefaults.standard.set(venvPython.path, forKey: pythonDefaultsKey)
            return .ready(python: venvPython.path)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Process

    private static func run(_ tool: String, _ args: [String]) async throws {
        let executable = try resolve(tool)
        let env = augmentedEnvironment()
        // Process/Pipe live entirely inside the detached task; only Sendable values are captured.
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.environment = env
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            try process.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw EngineError.command("\(tool) \(args.first ?? "") failed (\(process.terminationStatus)): \(msg)")
            }
        }.value
    }

    private static func resolve(_ tool: String) throws -> URL {
        // Release path: prefer the uv shipped inside the .app. Fall back to PATH/homebrew/~/.local
        // only for dev builds run from .build (no bundled uv) where a developer has uv installed.
        if tool == "uv", let bundled = bundledUV { return bundled }
        let candidates = [
            "/opt/homebrew/bin", "/usr/local/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
        ] + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        for dir in candidates {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw EngineError.toolNotFound(tool)
    }

    private static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin",
                     (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")]
        var seen = Set<String>()
        var ordered: [String] = []
        for path in (env["PATH"] ?? "").split(separator: ":").map(String.init) + extra
        where !path.isEmpty && seen.insert(path).inserted {
            ordered.append(path)
        }
        env["PATH"] = ordered.joined(separator: ":")
        return env
    }
}
