import Foundation
import NexGenEngine

// Read-only bridge from the native cockpit UI to the engine. Every read kind is served IN-PROCESS via
// NativeCockpitReader — no venv, no subprocess. All emitted JSON matches the shapes the panel decoders
// expect (the frozen shapes ported from the former Python read CLI). Read-only; never mutates state.

enum CockpitError: Error, Sendable, Equatable {
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
        // Two phrasings of the same normal state: the read CLI's canonicalizer says "no project
        // at …", the state loader says "… set mode/budget via project init". Neither is a failure.
        message.contains("set mode/budget via project init") || message.contains("no project at")
            ? .notInitialized : .engine(message)
    }

    var message: String {
        switch self {
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

    /// Frame candidates per shot, straight from disk (`frames` read kind). Never null from the
    /// engine; empty `shots` when nothing has been generated yet.
    static func frames(projectDir: URL) async -> Result<FramesData?, CockpitError> {
        await decoded(kind: "frames", projectDir: projectDir, decodeError: "Couldn't read the frames.")
    }

    /// The Intent Ledger (`ledger` read kind). Never null; empty `objects` when nothing is recorded.
    static func ledger(projectDir: URL) async -> Result<LedgerData?, CockpitError> {
        await decoded(kind: "ledger", projectDir: projectDir, decodeError: "Couldn't read the ledger.")
    }

    /// The Brief (`brief` read kind); null until the brief phase ran.
    static func brief(projectDir: URL) async -> Result<BriefData?, CockpitError> {
        await decoded(kind: "brief", projectDir: projectDir, decodeError: "Couldn't read the brief.")
    }

    /// The latest treatment (`treatment` read kind); null until the treatment phase ran.
    static func treatment(projectDir: URL) async -> Result<TreatmentData?, CockpitError> {
        await decoded(kind: "treatment", projectDir: projectDir, decodeError: "Couldn't read the treatment.")
    }

    /// The per-phase UI contract (`contract` read kind, projectless but tolerant of a project arg).
    static func contract(projectDir: URL) async -> Result<ContractData?, CockpitError> {
        await decoded(kind: "contract", projectDir: projectDir, decodeError: "Couldn't read the contract.")
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

    // MARK: - Native read

    /// Serve a cockpit read entirely in-process via NativeCockpitReader — no venv, no subprocess.
    /// Every cockpit kind is native (M7+); an unknown kind reports a process error.
    private static func run(kind: String, projectDir: URL) async -> Result<Data, CockpitError> {
        nativeRun(kind: kind, projectDir: projectDir)
    }

    /// In-process native read for a kind NativeCockpitReader serves. Projectless kinds (contract,
    /// router, phases) answer without a data root; state/brief/treatment resolve `<projectDir>/pipeline`
    /// first and report `.notInitialized` (the calm "no pipeline yet" state) when it isn't a project.
    private static func nativeRun(kind: String, projectDir: URL) -> Result<Data, CockpitError> {
        let activePack = ProjectPluginSettings.activePlugin(projectURL: projectDir)
        do {
            switch kind {
            case "phases":
                return .success(try NativeCockpitReader.phasesJSON(activePack: activePack))
            case "contract":
                return .success(try NativeCockpitReader.contractJSON(activePack: activePack))
            case "router":
                return .success(try NativeCockpitReader.routerJSON(dataRoot: NativeCockpitReader.dataRoot(of: projectDir)))
            default:
                guard let root = NativeCockpitReader.dataRoot(of: projectDir) else {
                    return .failure(.notInitialized)
                }
                switch kind {
                case "state": return .success(try NativeCockpitReader.stateJSON(dataRoot: root, activePack: activePack))
                case "brief": return .success(try NativeCockpitReader.briefJSON(dataRoot: root))
                case "treatment": return .success(try NativeCockpitReader.treatmentJSON(dataRoot: root))
                case "bible": return .success(try NativeCockpitReader.bibleJSON(dataRoot: root))
                case "shotlist": return .success(try NativeCockpitReader.shotlistJSON(dataRoot: root))
                case "sanity": return .success(try NativeCockpitReader.sanityJSON(dataRoot: root, activePack: activePack))
                case "frames": return .success(try NativeCockpitReader.framesJSON(dataRoot: root))
                case "ledger": return .success(try NativeCockpitReader.ledgerJSON(dataRoot: root))
                case "cost": return .success(try NativeCockpitReader.costJSON(dataRoot: root, activePack: activePack))
                default: return .failure(.process("Unsupported native kind \(kind)."))
                }
            }
        } catch NativeCockpitReader.NativeError.notInitialized {
            return .failure(.notInitialized)
        } catch {
            return .failure(.decode("Couldn't read \(kind)."))
        }
    }
}
