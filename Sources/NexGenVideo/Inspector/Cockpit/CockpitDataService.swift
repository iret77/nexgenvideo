import Foundation

// Read-only bridge from the native cockpit UI to the engine's `nexgen_engine.read` CLI:
//   <enginePython> -m nexgen_engine.read <kind> <projectDir>  → one JSON document on stdout.
// The CLI contract (engine/nexgen_engine/read.py) guarantees stdout is always parseable JSON —
// success payloads or `{"error": "<message>"}`, never a traceback — so decoding is unconditional.
// Everything here is read-only; the cockpit never mutates project state.

enum CockpitError: Error, Sendable, Equatable {
    /// Engine venv isn't set up yet (EngineRuntime not `.ready`). The UI offers to set it up in Settings.
    case engineNotReady
    /// The engine ran, but this project has no production pipeline yet (no `project.yaml`). A normal
    /// state for a plain editing project — not a failure. The UI shows a calm, retry-less state.
    case notInitialized
    /// No project directory could be resolved (no open project / working dir).
    case noProject
    /// The engine reported a structured `{"error": ...}` document.
    case engine(String)
    /// The subprocess failed to launch or exited non-zero without a parseable error document.
    case process(String)
    /// stdout wasn't the shape we expected.
    case decode(String)

    /// Classify a raw engine `{"error": ...}` string: the "no project.yaml" case is a normal
    /// not-initialized state; everything else is a genuine engine error. Marker matches
    /// `engine/nexgen_engine/core/project.py` ("missing — set mode/budget via project init").
    static func fromEngine(_ message: String) -> CockpitError {
        message.contains("set mode/budget via project init") ? .notInitialized : .engine(message)
    }

    var message: String {
        switch self {
        case .engineNotReady: return "The engine isn't set up yet."
        case .notInitialized: return "This project has no production pipeline yet."
        case .noProject: return "No project is open."
        case .engine(let m): return m
        case .process(let m): return m
        case .decode(let m): return m
        }
    }
}

/// Envelope for a `{"error": ...}` document the CLI emits on failure.
private struct CockpitErrorEnvelope: Decodable {
    let error: String
}

enum CockpitDataService {

    /// Fetch and decode the Bible for a project. Returns `.success(nil)` when the project simply has
    /// no Bible yet (the CLI prints literal `null`); `.success(data)` when present; `.failure` for
    /// engine-not-ready, a structured engine error, a process failure, or a decode mismatch.
    static func bible(projectDir: URL) async -> Result<BibleData?, CockpitError> {
        let raw: Data
        switch await run(kind: "bible", projectDir: projectDir) {
        case .failure(let e): return .failure(e)
        case .success(let d): raw = d
        }

        // Literal `null` → project has no Bible. Distinguish it from an object before decoding.
        let trimmed = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "null" || trimmed.isEmpty { return .success(nil) }

        // A well-formed `{"error": ...}` document from the CLI is surfaced as an engine error.
        if let envelope = try? JSONDecoder().decode(CockpitErrorEnvelope.self, from: raw) {
            return .failure(CockpitError.fromEngine(envelope.error))
        }

        do {
            return .success(try JSONDecoder().decode(BibleData.self, from: raw))
        } catch {
            return .failure(.decode("Couldn't read the Bible data."))
        }
    }

    /// Fetch and decode the project state (phase gates + budget). Never `null` from the engine, but a
    /// `{"error": ...}` document (e.g. a project without a state file) surfaces as an engine error.
    static func projectState(projectDir: URL) async -> Result<ProjectStateData?, CockpitError> {
        await decoded(kind: "state", projectDir: projectDir, decodeError: "Couldn't read the project state.")
    }

    /// Fetch and decode the sanity audit. The CLI emits `{"error": "no shotlist", ...}` when the
    /// project has no shotlist yet — that isn't a failure, it's "nothing to check", so it maps to
    /// `.success(nil)`. Every other `{"error": ...}` document is a real engine error.
    static func sanity(projectDir: URL) async -> Result<SanityData?, CockpitError> {
        let raw: Data
        switch await run(kind: "sanity", projectDir: projectDir) {
        case .failure(let e): return .failure(e)
        case .success(let d): raw = d
        }

        if let envelope = try? JSONDecoder().decode(CockpitErrorEnvelope.self, from: raw) {
            if envelope.error == "no shotlist" { return .success(nil) }
            return .failure(CockpitError.fromEngine(envelope.error))
        }

        do {
            return .success(try JSONDecoder().decode(SanityData.self, from: raw))
        } catch {
            return .failure(.decode("Couldn't read the sanity report."))
        }
    }

    /// Fetch and decode the latest shotlist. Returns `.success(nil)` when the project has no shotlist
    /// yet (the CLI prints literal `null`); `.success(data)` when present.
    static func shotlist(projectDir: URL) async -> Result<ShotlistData?, CockpitError> {
        await decoded(kind: "shotlist", projectDir: projectDir, decodeError: "Couldn't read the shotlist.")
    }

    /// Shared run + decode for kinds that follow the Bible idiom: literal `null` → `.success(nil)`,
    /// a `{"error": ...}` envelope → `.failure(.engine)`, otherwise decode `T`.
    private static func decoded<T: Decodable & Sendable>(
        kind: String, projectDir: URL, decodeError: String
    ) async -> Result<T?, CockpitError> {
        let raw: Data
        switch await run(kind: kind, projectDir: projectDir) {
        case .failure(let e): return .failure(e)
        case .success(let d): raw = d
        }

        let trimmed = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "null" || trimmed.isEmpty { return .success(nil) }

        if let envelope = try? JSONDecoder().decode(CockpitErrorEnvelope.self, from: raw) {
            return .failure(CockpitError.fromEngine(envelope.error))
        }

        do {
            return .success(try JSONDecoder().decode(T.self, from: raw))
        } catch {
            return .failure(.decode(decodeError))
        }
    }

    // MARK: - Subprocess

    /// Run `<enginePython> -m nexgen_engine.read <kind> <projectDir>` and return raw stdout bytes.
    /// Fails early when the engine isn't ready or the python path is missing/unusable. A non-zero exit
    /// whose stdout is still a parseable `{"error": ...}` document is treated as success at this layer
    /// (the caller decodes the envelope); only an unparseable non-zero exit becomes `.process`.
    private static func run(kind: String, projectDir: URL) async -> Result<Data, CockpitError> {
        guard case .ready(let pythonPath) = EngineRuntime.status() else {
            return .failure(.engineNotReady)
        }
        let python = URL(fileURLWithPath: pythonPath)
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            return .failure(.engineNotReady)
        }
        let args = ["-m", "nexgen_engine.read", kind, projectDir.path]
        let env = augmentedEnvironment()

        // Process/Pipe live entirely inside the detached task; only Sendable values cross the boundary.
        return await Task.detached { () -> Result<Data, CockpitError> in
            let process = Process()
            process.executableURL = python
            process.arguments = args
            process.environment = env
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                return .failure(.process("Couldn't run the engine: \(error.localizedDescription)"))
            }
            // Drain both pipes before waitUntilExit so a large stdout can't deadlock on a full buffer.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                // read.py prints `{"error": ...}` to stdout even on non-zero exit; keep stdout so the
                // caller can decode it. Fall back to stderr only when stdout is empty.
                if !outData.isEmpty { return .success(outData) }
                let msg = String(decoding: errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.process(msg.isEmpty ? "The engine exited with an error." : msg))
            }
            return .success(outData)
        }.value
    }

    /// PATH-augmented environment mirroring EngineRuntime, so a python that shells out to sibling tools
    /// still finds them. The venv python is invoked by absolute path, so PATH is only a safety net.
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
