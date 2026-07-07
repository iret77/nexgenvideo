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
    public private(set) var phasePlacements: [PhasePlacement] = []
    public private(set) var durationPolicy: DurationPolicy?
    public private(set) var libraries: [String: Any] = [:]
    public private(set) var projectDirs: [String] = []
    public private(set) var uiContracts: [String: UIContract.Entry] = [:]

    /// The host's audio decoder, injected so a pack's phase runner can turn an
    /// audio file into a `PCMBuffer` without the pure engine linking
    /// AVFoundation. Nil until the app registers one — the analysis runner then
    /// returns an actionable error instead of crashing.
    public private(set) var audioDecoder: (any AudioPCMDecoding)?

    /// A phase runner is an opaque callable the engine invokes to run a named
    /// pipeline phase (e.g. `"analysis"`). Precise signatures firm up as more
    /// phases land; kept minimal here for the one phase M8 registers. Port of
    /// `pack.py::PhaseRunner`.
    public typealias PhaseRunner = @Sendable (URL) throws -> Void

    public init() {}

    /// Convenience read-through so callers can inspect `checks` the same way
    /// the Python `EngineRegistry.sanity_checks` dict is inspected.
    public var sanityChecks: [String: SanityCheck] { checkRegistry.checks }

    /// Register a pack gate phase and declare where it sits relative to the core
    /// order. `after` names the phase this one follows (a core phase or an
    /// earlier pack phase); nil places it after everything. Unlike the Python
    /// engine, which appended pack phases sorted after all core phases, the Swift
    /// engine honors declared placement so a pack whose gate must precede a core
    /// gate (musicvideo `analysis` before `brief`) reads coherently in the plan,
    /// next_phase, cost, and rewind. See `PhaseOrder.merged`.
    public func registerPhase(_ name: String, after: String? = nil, runner: @escaping PhaseRunner) {
        phases[name] = runner
        registerPhasePlacement(name, after: after)
    }

    /// Declare a gate phase's placement without a code runner (agent-driven pack
    /// phase). The phase still appears in the merged plan/gates at the requested
    /// position; `run_phase` reports the no-runner shape for it.
    public func registerPhasePlacement(_ name: String, after: String? = nil) {
        phasePlacements.removeAll { $0.phase == name }
        phasePlacements.append(PhasePlacement(phase: name, after: after))
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

    /// Inject the host's audio decoder (the app's AVFoundation implementation).
    /// A pack's analysis phase runner resolves it from the registry at run time.
    public func registerAudioDecoder(_ decoder: any AudioPCMDecoding) {
        audioDecoder = decoder
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

/// A pack gate phase and where it sits relative to the pipeline: right after
/// `after` (a core phase or an earlier pack phase), or after everything when
/// `after` is nil.
public struct PhasePlacement: Sendable, Equatable {
    public let phase: String
    public let after: String?

    public init(phase: String, after: String? = nil) {
        self.phase = phase
        self.after = after
    }
}

/// The single source of truth for the merged pipeline order (core phases plus a
/// pack's declared phases). EVERY site that needs the ordered plan — project
/// state, list_phases, cost/next_phase, rewind — goes through here so the order
/// can never diverge between surfaces.
///
/// Placement rules, applied in the order the pack registered them:
/// - a phase already present in `core` is skipped (a pack must not shadow a core
///   gate; matches the old dedup);
/// - `after` naming a phase already in the working order inserts right after it;
/// - `after == nil`, or naming an unknown/not-yet-present phase, appends to the
///   end (safe fallback — never drops the phase).
public enum PhaseOrder {
    public static func merged(core: [String] = coreGatePhases, packPlacements: [PhasePlacement]) -> [String] {
        var order = core
        for placement in packPlacements {
            guard !order.contains(placement.phase) else { continue }
            if let after = placement.after, let idx = order.firstIndex(of: after) {
                order.insert(placement.phase, at: idx + 1)
            } else {
                order.append(placement.phase)
            }
        }
        return order
    }
}

/// A pack's presentation identity for the app's gallery/chip — the native
/// replacement for the disk `ngv-plugin.json` (displayName/tagline/badge).
/// `badgeURL` points into the pack's OWN resource bundle, so a pack ships
/// self-contained with its badge art; nil → the gallery paints a fallback.
public struct PackManifest: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let tagline: String
    public let badgeURL: URL?

    public init(id: String, displayName: String, tagline: String, badgeURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.tagline = tagline
        self.badgeURL = badgeURL
    }
}

/// One agent-panel starter for a pack — a plain-language instruction the pack
/// wants to offer as a one-tap chip. Not a slash-command: `prompt` is sent to
/// the agent as ordinary text so it works under either backend.
public struct PackStarter: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let prompt: String

    public init(id: String, title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }
}

/// A format pack (e.g. musicvideo). Thin by contract: it registers only
/// domain-specific behavior into the engine. Port of `pack.py::Pack`.
public protocol Pack: Sendable {
    var name: String { get }
    var version: String { get }
    /// Gallery/chip identity — the native successor to `ngv-plugin.json`.
    var manifest: PackManifest { get }
    /// Agent-panel starter chips for the active pack (may be empty).
    var starters: [PackStarter] { get }

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
