import Foundation

// Bootstraps the bundled Generic Engine into a local venv (via `uv`) so the embedded
// claude can reach its MCP server. bundle.sh ships the engine + plugins at
// Contents/Resources/{engine,plugins}; the venv lives in Application Support (survives app
// updates); the resolved python is published to UserDefaults `claudeRuntimeEnginePython`,
// which ClaudeCodeRuntime registers as the `engine` MCP server.
//
// The uv run is macOS-only at runtime, but the paths + status are inspectable and
// bootstrap() is idempotent (skips the venv create if it already exists).
enum EngineRuntime {
    static let pythonDefaultsKey = "claudeRuntimeEnginePython"

    static var bundledEngineDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("engine") }
    static var bundledPluginsDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("plugins") }

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

    /// Tear the engine down: delete the venv and clear the published python path so `status()` returns
    /// `.notBootstrapped` again. Best-effort and non-throwing — a missing venv or remove failure is
    /// swallowed; clearing the defaults key is what actually flips the status back.
    static func reset() {
        try? FileManager.default.removeItem(at: venvDir)
        UserDefaults.standard.removeObject(forKey: pythonDefaultsKey)
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

    /// Create the venv (uv) and install the bundled engine + plugins, then publish the python
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
            // The engine itself must install — its failure fails the bootstrap.
            try await run("uv", ["pip", "install", "--python", venvPython.path, "-e", engine.path])
            UserDefaults.standard.set(venvPython.path, forKey: pythonDefaultsKey)
            await installDiscoveredPacks()
            return .ready(python: venvPython.path)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Install every discovered plugin's Python pack into the venv (`uv pip install -e <name>/`), then
    /// the engine picks them up via entry-points. Per-plugin non-fatal: a pack that fails to install is
    /// skipped so it can't break the others or the engine. Idempotent — `uv pip install -e` of an
    /// already-installed editable pack is a fast no-op, so this is safe to re-run on every bootstrap.
    /// No-op when no python is published yet (engine install failed) or no installable plugin is found.
    static func installDiscoveredPacks() async {
        guard isVenvReady else { return }
        for plugin in PluginManager.installablePlugins() {
            do {
                try await run("uv", ["pip", "install", "--python", venvPython.path, "-e", plugin.installRoot.path])
            } catch {
                NSLog("EngineRuntime: skipped plugin pack \"%@\": %@", plugin.name, error.localizedDescription)
            }
        }
    }

    // MARK: - Optional audio extra

    /// Outcome of an opt-in extra install. Sendable so it can cross the async boundary back to the UI.
    enum InstallResult: Equatable, Sendable {
        case installed
        case failed(String)
    }

    /// Install a plugin's optional extra into the engine venv: `uv pip install -e <root>[<extra>]`.
    /// Long-running (minutes) and may fail — these DSP deps are heavy/fragile on macOS arm64 — so it
    /// never throws: it returns `.installed` on success or `.failed(message)` with the captured error.
    /// Requires the venv (engine bootstrap) to be ready; if not, returns a `.failed` explaining that.
    static func installExtra(pluginInstallRoot: URL, extra: String) async -> InstallResult {
        guard isVenvReady else {
            return .failed("Engine is not set up yet — set up the engine first.")
        }
        let target = "\(pluginInstallRoot.path)[\(extra)]"
        do {
            try await run("uv", ["pip", "install", "--python", venvPython.path, "-e", target])
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Whether the audio extra is usable in the venv, probed by importing librosa — the module-level
    /// anchor of the DSP stack. Runs the venv python with `import librosa`; exit 0 ⇒ present. Cheap-ish
    /// (one subprocess) but still a process spawn, so callers should invoke it sparingly (on appear /
    /// after engine-ready / after an install), not on every view refresh. Any failure (no venv, import
    /// error, missing python) reads as not-installed.
    static func audioExtraInstalled() async -> Bool {
        guard isVenvReady else { return false }
        return await succeeds(venvPython, ["-c", "import librosa"])
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

    /// Run an executable to completion and report whether it exited 0. Non-throwing: a failed launch (or
    /// any error) reads as `false`. Used for cheap presence probes (e.g. `python -c "import …"`).
    private static func succeeds(_ executable: URL, _ args: [String]) async -> Bool {
        let env = augmentedEnvironment()
        return await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.environment = env
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
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
