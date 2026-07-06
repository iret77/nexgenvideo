import Foundation

/// A min/max shot-duration window for a given mode. Port of
/// `engine/nexgen_engine/pack.py::DurationBand`.
public struct DurationBand: Sendable, Equatable {
    public let label: String
    public let minS: Double
    public let maxS: Double

    public init(label: String, minS: Double, maxS: Double) {
        self.label = label
        self.minS = minS
        self.maxS = maxS
    }
}

/// Seam 1 (music-assumption decoupling): the engine's Shot/sanity logic is
/// generic; a pack supplies how a mode maps to a duration band (e.g. music
/// makes it BPM-aware via `context`). Port of `pack.py::DurationPolicy`.
public protocol DurationPolicy: Sendable {
    func band(for mode: Mode, context: [String: String]) -> DurationBand
}

/// Handed to each pack's `register()`; collects the pack's contributions so
/// the engine can expose them (phases/checks) through its core surface. Port
/// of `pack.py::EngineRegistry`.
///
/// Registration is by name and last-write-wins for sanity checks (see
/// `CheckRegistry`'s doc comment on `register(_:_:)`): a pack registering a
/// check under a core check's name overrides it outright.
public final class EngineRegistry: @unchecked Sendable {
    public let checkRegistry = CheckRegistry()
    public private(set) var phases: [String: PhaseRunner] = [:]
    public private(set) var durationPolicy: DurationPolicy?
    public private(set) var libraries: [String: Any] = [:]
    public private(set) var projectDirs: [String] = []
    public private(set) var uiContracts: [String: UIContract.Entry] = [:]

    /// A phase runner is an opaque callable the engine invokes to run a named
    /// pipeline phase (e.g. `"analysis"`). Precise signatures firm up as more
    /// phases land; kept minimal here for the one phase M8 registers. Port of
    /// `pack.py::PhaseRunner`.
    public typealias PhaseRunner = @Sendable (URL) throws -> Void

    public init() {}

    /// Convenience read-through so callers can inspect `checks` the same way
    /// the Python `EngineRegistry.sanity_checks` dict is inspected.
    public var sanityChecks: [String: SanityCheck] { checkRegistry.checks }

    public func registerPhase(_ name: String, runner: @escaping PhaseRunner) {
        phases[name] = runner
    }

    /// Extra project-layout subdirs the pack needs (e.g. music:
    /// audio/lyrics/analysis). The engine creates its own core dirs (bible,
    /// treatment, frames, ...) regardless.
    public func registerProjectDirs(_ dirs: [String]) {
        projectDirs.append(contentsOf: dirs)
    }

    public func registerSanityCheck(_ name: String, _ check: @escaping SanityCheck) {
        checkRegistry.register(name, check)
    }

    public func registerDurationPolicy(_ policy: DurationPolicy) {
        durationPolicy = policy
    }

    /// Domain reference data (e.g. music genre/mood pattern library).
    public func registerLibrary(_ name: String, _ library: Any) {
        libraries[name] = library
    }

    /// The phase's default interaction surface (choice/prose/review) and its
    /// router task class. Overrides the engine's core default for that phase.
    @discardableResult
    public func registerUIContract(phase: String, surface: String, taskClass: String) throws -> UIContract.Entry {
        let entry = try UIContract.validateEntry(phase: phase, surface: surface, taskClass: taskClass)
        uiContracts[phase] = entry
        return entry
    }
}

/// A format pack (e.g. musicvideo). Thin by contract: it registers only
/// domain-specific behavior into the engine. Port of `pack.py::Pack`.
public protocol Pack: Sendable {
    var name: String { get }
    var version: String { get }

    func register(_ registry: EngineRegistry) -> Void
}

/// Loads packs and aggregates their contributions for the engine core. Port
/// of `pack.py::PackRegistry`. Unlike Python's `discover_packs()` (which
/// walks `importlib.metadata` entry points), the Swift engine has no dynamic
/// plugin discovery yet — a host explicitly constructs and `load()`s the
/// packs it bundles.
public final class PackRegistry: @unchecked Sendable {
    public let engine = EngineRegistry()
    public private(set) var packs: [Pack] = []

    public init() {}

    public func load(_ pack: Pack) {
        pack.register(engine)
        packs.append(pack)
    }
}
