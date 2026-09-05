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

    /// Deterministic hard-gate preconditions, keyed by phase. A pack registers a check that throws
    /// `GateBlocked` when the phase's artifact isn't genuinely present (e.g. musicvideo's `analysis`
    /// requires a written artifact with real beats/downbeats). The approve paths consult this before
    /// stamping a gate, so the agent cannot rubber-stamp a phase whose deterministic output is missing.
    public private(set) var gateRequirements: [String: GateRequirement] = [:]

    /// Engine-pinned deterministic steps, in registration order (#174). A load-bearing step — file
    /// intake into the right project dir, the one-song contract, the assembly hand-off — is the same
    /// every run with a hard contract, so it must NOT depend on the agent choosing to perform it. A
    /// pack declares such steps against a phase; the host runs them itself at phase entry, and reports
    /// them to the agent as engine-owned so the agent orchestrates AROUND them (it never gets to skip a
    /// load-bearing step). A step that throws blocks the phase with its actionable message. This is the
    /// deterministic sibling of `PhaseRunner` (whole-phase code) and `GateRequirement` (approve-time
    /// precondition): a named, guaranteed operation the agent can neither improvise nor omit.
    public private(set) var deterministicSteps: [DeterministicStep] = []

    /// Liveness probe for the active pack: a closure the pack registers that returns
    /// `PackWiring.token(pack:nonce:)` for a nonce. It exists ONLY if the pack's code actually loaded
    /// into THIS registry — so the host can prove, deterministically, that the pack a project declares is
    /// genuinely wired into the session, not silently resolved to nil (the class of bug where the bundle
    /// loads but the runtime never routes to it: no phases, no gates). See `PackWiring`.
    public private(set) var wiringToken: (@Sendable (String) -> String)?

    /// The host's audio decoder, injected so a pack's phase runner can turn an
    /// audio file into a `PCMBuffer` without the pure engine linking
    /// AVFoundation. Nil until the app registers one — the analysis runner then
    /// returns an actionable error instead of crashing.
    public private(set) var audioDecoder: (any AudioPCMDecoding)?

    /// Host-injected on-device audio-ML inference (see `AudioML.swift`). Each is
    /// nil until the app registers it; a pack's analysis runner degrades or blocks
    /// with an actionable message rather than crashing when one is absent.
    public private(set) var transcriber: (any AudioTranscribing)?
    public private(set) var stemSeparator: (any AudioStemSeparating)?
    public private(set) var beatDetector: (any AudioBeatDetecting)?
    public private(set) var chordRecognizer: (any AudioChordRecognizing)?

    /// Pack-provided director-pattern query surface (see `PatternProviding`). Nil until a pack registers
    /// one; the host's `suggest_patterns`/`get_pattern` tools return an actionable "no patterns" instead.
    public private(set) var patternProvider: (any PatternProviding)?

    /// Pack-provided reference-plan surface (see `ReferencePlanProviding`). Nil until a pack registers
    /// one; the host's `next_render_shot` then surfaces no planned refs (the agent picks its own).
    public private(set) var referencePlanProvider: (any ReferencePlanProviding)?

    // ⚠️ ABI: a `.ngvpack` is compiled SEPARATELY against this class and ships on its own channel, so
    // ivar offsets are baked into the pack binary. Inserting a stored property ABOVE an existing one
    // shifts every later offset and the already-shipped pack writes to the wrong field → SIGSEGV on
    // `register`. ADD NEW STORED PROPERTIES ONLY BELOW THIS LINE, never in the middle.

    /// Legacy pack cockpit declarations retained at their shipped ivar offset.
    public private(set) var cockpitSurfaces: [CockpitSurface] = []

    /// Pack-supplied deterministic input/output fingerprints for durable phase lineage.
    public private(set) var phaseLineageProviders: [String: PhaseLineageProvider] = [:]

    /// Transactional project-schema upgrades supplied by the pack that owns the data.
    public private(set) var projectSchemaMigrations: [ProjectSchemaMigration] = []

    /// Staged phase runners preserving the original `PhaseRunner` ABI for installed packs.
    public private(set) var progressPhaseRunners: [String: ProgressPhaseRunner] = [:]

    /// Reusable core production doctrine activated by a thin format pack.
    public private(set) var productionProfiles: [ProductionProfile] = []

    /// Pack-owned artifact invariants checked before a host writer may interpret a phase result.
    public private(set) var artifactWriteRequirements: [String: GateRequirement] = [:]

    /// Host implementation of the system music-understanding contract.
    public private(set) var musicUnderstandingAnalyzer: (any MusicUnderstandingAnalyzing)?

    /// The active pack's single declarative cockpit surface.
    public private(set) var declarativeCockpitSurface: DeclarativeCockpitSurface?

    /// Exact project-local files owned by each phase, for cumulative execution lineage.
    public private(set) var phaseArtifactProviders: [String: PhaseArtifactProvider] = [:]

    /// Pack-neutral declarations that bind an active format to host-owned production knowledge.
    public private(set) var productionKnowledgeConsumers: [ProductionKnowledgeConsumerRegistrationV1] = []

    /// A phase runner is an opaque callable the engine invokes to run a named
    /// pipeline phase (e.g. `"analysis"`). Precise signatures firm up as more
    /// phases land; kept minimal here for the one phase M8 registers. Port of
    /// `pack.py::PhaseRunner`.
    public typealias PhaseRunner = @Sendable (URL) throws -> Void
    public typealias ProgressPhaseRunner =
        @Sendable (URL, @escaping @Sendable (PhaseProgress) -> Void) throws -> Void

    /// A deterministic precondition for approving a gate: throws `GateBlocked` (with an actionable
    /// message) when the phase's artifact isn't genuinely present in the data root.
    public typealias GateRequirement = @Sendable (URL) throws -> Void

    public typealias PhaseLineageProvider =
        @Sendable (URL) throws -> PhaseLineageSnapshot

    public typealias PhaseArtifactProvider =
        @Sendable (URL) throws -> [String]

    /// A named, engine-run step pinned to a phase (#174). `run` executes the deterministic operation
    /// against the data root; throwing blocks the phase with the error's message.
    public struct DeterministicStep: Sendable {
        public let id: String
        public let phase: String
        /// Human-facing one-liner for the agent's orchestration map ("engine owns this step").
        public let summary: String
        public let run: @Sendable (URL) throws -> Void
        public init(id: String, phase: String, summary: String, run: @escaping @Sendable (URL) throws -> Void) {
            self.id = id
            self.phase = phase
            self.summary = summary
            self.run = run
        }
    }

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

    public func registerProgressPhaseRunner(
        _ name: String,
        runner: @escaping ProgressPhaseRunner
    ) {
        progressPhaseRunners[name] = runner
    }

    /// Declare a gate phase's placement without a code runner (agent-driven pack
    /// phase). The phase still appears in the merged plan/gates at the requested
    /// position; `run_phase` reports the no-runner shape for it.
    public func registerPhasePlacement(_ name: String, after: String? = nil) {
        phasePlacements.removeAll { $0.phase == name }
        phasePlacements.append(PhasePlacement(phase: name, after: after))
    }

    /// Declare an engine-pinned deterministic step for a phase (#174). Registration order within a
    /// phase is preserved (steps run top-to-bottom). The host runs these at phase entry, before the
    /// agent touches the phase.
    public func registerDeterministicStep(
        _ id: String, phase: String, summary: String, run: @escaping @Sendable (URL) throws -> Void
    ) {
        deterministicSteps.append(DeterministicStep(id: id, phase: phase, summary: summary, run: run))
    }

    /// The deterministic steps declared for a phase, in registration order.
    public func deterministicSteps(forPhase phase: String) -> [DeterministicStep] {
        deterministicSteps.filter { $0.phase == phase }
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

    public func registerProductionProfile(_ profile: ProductionProfile) {
        productionProfiles.removeAll { $0.id == profile.id }
        productionProfiles.append(profile)
    }

    public func registerProductionProfiles(_ profiles: [ProductionProfile]) {
        for profile in profiles {
            registerProductionProfile(profile)
        }
    }

    public func activeProductionProfileIDs(metadata: [String: String]) -> Set<ProductionProfileID> {
        Set(productionProfiles.filter { $0.activation.matches(metadata) }.map(\.id))
    }

    /// Register a deterministic hard-gate precondition for `phase`. Consulted by the approve paths
    /// (agent tool + Pipeline panel) before a gate is stamped.
    public func registerGateRequirement(_ phase: String, _ check: @escaping GateRequirement) {
        gateRequirements[phase] = check
    }

    public func registerArtifactWriteRequirement(
        _ phase: String,
        _ check: @escaping GateRequirement
    ) {
        artifactWriteRequirements[phase] = check
    }

    public func registerPhaseLineageProvider(
        _ phase: String,
        _ provider: @escaping PhaseLineageProvider
    ) {
        phaseLineageProviders[phase] = provider
    }

    public func registerPhaseArtifactProvider(
        _ phase: String,
        _ provider: @escaping PhaseArtifactProvider
    ) {
        phaseArtifactProviders[phase] = provider
    }

    public func registerProjectSchemaMigration(
        from: String,
        to: String,
        migrate: @escaping @Sendable (URL) throws -> Void
    ) {
        projectSchemaMigrations.removeAll {
            $0.from == from && $0.to == to
        }
        projectSchemaMigrations.append(
            ProjectSchemaMigration(from: from, to: to, migrate: migrate)
        )
    }

    /// Register the pack's wiring-liveness probe (see `wiringToken`). A pack calls this in `register`;
    /// the host later asks the built registry for a token and compares it to the shared formula.
    public func registerWiringProbe(_ probe: @escaping @Sendable (String) -> String) {
        wiringToken = probe
    }

    /// Inject the host's audio decoder (the app's AVFoundation implementation).
    /// A pack's analysis phase runner resolves it from the registry at run time.
    public func registerAudioDecoder(_ decoder: any AudioPCMDecoding) {
        audioDecoder = decoder
    }

    /// Inject the host's on-device audio-ML implementations. A pack's analysis
    /// runner resolves whichever are present at run time (see `AudioML.swift`).
    public func registerTranscriber(_ transcriber: any AudioTranscribing) {
        self.transcriber = transcriber
    }

    public func registerStemSeparator(_ separator: any AudioStemSeparating) {
        self.stemSeparator = separator
    }

    public func registerBeatDetector(_ detector: any AudioBeatDetecting) {
        self.beatDetector = detector
    }

    public func registerChordRecognizer(_ recognizer: any AudioChordRecognizing) {
        self.chordRecognizer = recognizer
    }

    public func registerMusicUnderstandingAnalyzer(
        _ analyzer: any MusicUnderstandingAnalyzing
    ) {
        musicUnderstandingAnalyzer = analyzer
    }

    /// Register the pack's director-pattern query surface (see `PatternProviding`).
    public func registerPatternProvider(_ provider: any PatternProviding) {
        self.patternProvider = provider
    }

    /// Register the pack's reference-plan surface (see `ReferencePlanProviding`).
    public func registerReferencePlanProvider(_ provider: any ReferencePlanProviding) {
        self.referencePlanProvider = provider
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

    /// Contribute a cockpit surface (see `cockpitSurfaces`). Re-registering the same `id` replaces it.
    @discardableResult
    public func registerCockpitSurface(_ surface: CockpitSurface) -> CockpitSurface {
        cockpitSurfaces.removeAll { $0.id == surface.id }
        cockpitSurfaces.append(surface)
        return surface
    }

    @discardableResult
    public func registerDeclarativeCockpitSurface(
        _ surface: DeclarativeCockpitSurface
    ) -> DeclarativeCockpitSurface {
        declarativeCockpitSurface = surface
        return surface
    }

    public func registerProductionKnowledgeConsumer(
        _ descriptor: ProductionKnowledgeConsumerDescriptorV1,
        metadataProvider: @escaping ProductionKnowledgeActivationMetadataProviderV1
    ) {
        productionKnowledgeConsumers.append(
            ProductionKnowledgeConsumerRegistrationV1(
                descriptor: descriptor,
                metadataProvider: metadataProvider
            )
        )
    }
}

public struct ProjectSchemaMigration: Sendable {
    public let from: String
    public let to: String
    public let migrate: @Sendable (URL) throws -> Void

    public init(
        from: String,
        to: String,
        migrate: @escaping @Sendable (URL) throws -> Void
    ) {
        self.from = from
        self.to = to
        self.migrate = migrate
    }
}

/// Legacy ABI surface retained for installed packs and adapted by the host.
public struct CockpitSurface: Sendable, Equatable {
    public let id: String
    public let title: String
    public let symbol: String
    public let phase: String
    public let kind: String

    public init(id: String, title: String, symbol: String, phase: String, kind: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.phase = phase
        self.kind = kind
    }
}

public struct DeclarativeCockpitSurface: Sendable, Equatable {
    public let id: String
    public let title: String
    public let symbol: String
    public let phase: String
    public let dataFile: String
    public let layout: [CockpitSurfacePrimitive]

    public init(
        id: String,
        title: String,
        symbol: String,
        phase: String,
        dataFile: String,
        layout: [CockpitSurfacePrimitive]
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.phase = phase
        self.dataFile = dataFile
        self.layout = layout
    }
}

public enum CockpitValueFormat: String, Sendable, Equatable {
    case text
    case fileName
    case duration
    case bpm
    case count
}

public enum CockpitBindingVisibility: String, Sendable, Equatable {
    case always
    case whenPresent
    case whenCanonicalSections
}

public struct CockpitValueBinding: Sendable, Equatable {
    public let label: String
    public let field: String
    public let format: CockpitValueFormat
    public let factorField: String?
    public let visibility: CockpitBindingVisibility

    public init(
        label: String,
        field: String,
        format: CockpitValueFormat,
        factorField: String? = nil,
        visibility: CockpitBindingVisibility = .always
    ) {
        self.label = label
        self.field = field
        self.format = format
        self.factorField = factorField
        self.visibility = visibility
    }
}

public enum CockpitSurfacePrimitive: Sendable, Equatable {
    case statRow(items: [CockpitValueBinding])
    case beatTimeline(
        title: String,
        durationField: String,
        beatsField: String,
        downbeatsField: String,
        sectionsField: String,
        sectionsVisibility: CockpitBindingVisibility
    )
    case sectionList(
        title: String,
        sectionsField: String,
        visibility: CockpitBindingVisibility
    )
    case keyValue(title: String?, items: [CockpitValueBinding])
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
/// This is the historical placement adapter. Declarative pack contracts provide
/// their complete order directly. The adapter is strict so malformed legacy
/// registrations cannot silently become a different graph.
public enum PhaseOrder {
    public enum ResolutionError: Swift.Error, Sendable, Equatable {
        case duplicateCorePhase(String)
        case duplicatePlacement(String)
        case shadowsCorePhase(String)
        case unknownPredecessor(phase: String, predecessor: String)
        case ambiguousPredecessor(String)
        case invalidPhase(String)
    }

    public static func validatedMerged(
        core: [String] = coreGatePhases,
        packPlacements: [PhasePlacement]
    ) throws -> [String] {
        var seenCore = Set<String>()
        for phase in core {
            guard isValidPhaseID(phase) else {
                throw ResolutionError.invalidPhase(phase)
            }
            guard seenCore.insert(phase).inserted else {
                throw ResolutionError.duplicateCorePhase(phase)
            }
        }

        var seenPlacements = Set<String>()
        var usedPredecessors = Set<String>()
        var order = core
        for placement in packPlacements {
            guard isValidPhaseID(placement.phase) else {
                throw ResolutionError.invalidPhase(placement.phase)
            }
            guard seenPlacements.insert(placement.phase).inserted else {
                throw ResolutionError.duplicatePlacement(placement.phase)
            }
            guard !seenCore.contains(placement.phase) else {
                throw ResolutionError.shadowsCorePhase(placement.phase)
            }
            if let after = placement.after {
                guard isValidPhaseID(after), let index = order.firstIndex(of: after) else {
                    throw ResolutionError.unknownPredecessor(
                        phase: placement.phase,
                        predecessor: after
                    )
                }
                guard usedPredecessors.insert(after).inserted else {
                    throw ResolutionError.ambiguousPredecessor(after)
                }
                order.insert(placement.phase, at: index + 1)
            } else {
                guard usedPredecessors.insert("<end>").inserted else {
                    throw ResolutionError.ambiguousPredecessor("<end>")
                }
                order.append(placement.phase)
            }
        }
        return order
    }

    public static func merged(core: [String] = coreGatePhases, packPlacements: [PhasePlacement]) -> [String] {
        (try? validatedMerged(core: core, packPlacements: packPlacements)) ?? []
    }

    private static func isValidPhaseID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.first?.isLetter == true || value.first == "_" else {
            return false
        }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
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
    /// A bold one-line pitch the card shows in place of the technical `tagline`.
    /// Empty → the card falls back to `tagline`.
    public let headline: String
    /// A short benefit line under the headline (what the pack does for the user).
    public let benefit: String
    /// Minimum NexGenVideo marketing version (`CFBundleShortVersionString`) this
    /// pack needs. The loadable-pack gate compares the `.ngvpack`'s
    /// `NGVMinAppVersion` against the running app BEFORE loading any code; this
    /// mirror on the in-code manifest lets the picker show the requirement.
    public let minAppVersion: String
    public let badgeURL: URL?
    /// The pack's brand accent as a `#RRGGBB` hex, used to make its critical in-chat controls (e.g. the
    /// track/lyrics upload well) recognizably the pack's own. Nil → the host uses its default accent.
    public let accentHex: String?

    public init(
        id: String,
        displayName: String,
        tagline: String,
        headline: String = "",
        benefit: String = "",
        minAppVersion: String = "0.0.0",
        badgeURL: URL? = nil,
        accentHex: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.tagline = tagline
        self.headline = headline
        self.benefit = benefit
        self.minAppVersion = minAppVersion
        self.badgeURL = badgeURL
        self.accentHex = accentHex
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

/// How far a project has actually come, handed to a pack so its starter can speak to the real
/// situation. Without it a pack can only ever offer "start from the beginning" — which is wrong, and
/// actively harmful, for a project that is half-finished: the user reopens mid-pipeline and the one
/// chip on offer tells the agent to begin again.
public struct PackProgress: Sendable, Equatable {
    /// First phase not yet approved, if any. Nil once every phase is approved.
    public let nextPhase: String?
    public let approvedPhases: Int
    public let totalPhases: Int

    public init(nextPhase: String?, approvedPhases: Int, totalPhases: Int) {
        self.nextPhase = nextPhase
        self.approvedPhases = approvedPhases
        self.totalPhases = totalPhases
    }

    /// No project open, or nothing approved yet — the project is still at the starting line.
    public static let untouched = PackProgress(nextPhase: nil, approvedPhases: 0, totalPhases: 0)

    /// Whether anything has been approved. Drives "start" vs "continue".
    public var hasStarted: Bool { approvedPhases > 0 }
    public var isComplete: Bool { totalPhases > 0 && approvedPhases == totalPhases }
}

/// A format pack (e.g. musicvideo). Thin by contract: it registers only
/// domain-specific behavior into the engine. Port of `pack.py::Pack`.
public protocol Pack: Sendable {
    var name: String { get }
    var version: String { get }
    /// Gallery/chip identity — the native successor to `ngv-plugin.json`.
    var manifest: PackManifest { get }
    /// Agent-panel starter chips for a project that hasn't started — also the gallery's entry chip.
    var starters: [PackStarter] { get }

    /// Starters for a project at `progress`. A pack that doesn't care keeps the default and behaves
    /// exactly as before.
    func starters(for progress: PackProgress) -> [PackStarter]

    func register(_ registry: EngineRegistry) -> Void
}

extension Pack {
    public func starters(for progress: PackProgress) -> [PackStarter] { starters }
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
