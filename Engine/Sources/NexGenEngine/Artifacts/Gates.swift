import Foundation

/// Per-project approval gates — the generic mechanism. Every phase must be
/// explicitly approved before the next step runs. Port of `core/gates.py`.
public enum GateState: String, Codable, Sendable, CaseIterable {
    case pending
    case approved
    case approvedWithNotes = "approved_with_notes"
    case needsRevision = "needs_revision"
}

/// The generic core production pipeline, in order. A pack's own gate phases are
/// merged in at the position the pack declares (see `PhaseOrder.merged` /
/// `EngineRegistry.registerPhase(_:after:)`) — a deliberate deviation from the
/// retired Python `mcp_server.phases()`, which appended pack phases sorted after
/// all core phases. musicvideo's `analysis` gates BEFORE `brief`, so append-order
/// would describe an impossible workflow. Port of `gates.py::CORE_PHASES`.
public let coreGatePhases: [String] = [
    "project_init",
    "brief",
    "production_design",
    "treatment",
    "storyboard",
    "bible",
    "shotlist",
    "sanity",
    "frames",
    "render",
]

/// One phase's approval state. `approved` is the compatibility bool the
/// pipeline blocks on; `state` carries the richer verdict — older gates.yaml
/// files have no `state`, so decode reconciles it the same way pydantic's
/// `_derive_state` model validator does.
public struct Gate: Codable, Sendable, Equatable {
    public var approved: Bool
    public var approvedAt: String?
    public var approvedBy: String?
    public var notes: String?
    public var state: GateState

    private enum CodingKeys: String, CodingKey {
        case approved
        case approvedAt = "approved_at"
        case approvedBy = "approved_by"
        case notes
        case state
    }

    public init(
        approved: Bool = false, approvedAt: String? = nil, approvedBy: String? = nil,
        notes: String? = nil, state: GateState = .pending
    ) {
        self.approved = approved
        self.approvedAt = approvedAt
        self.approvedBy = approvedBy
        self.notes = notes
        self.state = state
        deriveState()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approved = try container.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        approvedAt = try container.decodeIfPresent(String.self, forKey: .approvedAt)
        approvedBy = try container.decodeIfPresent(String.self, forKey: .approvedBy)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        state = try container.decodeIfPresent(GateState.self, forKey: .state) ?? .pending
        deriveState()
    }

    /// Port of `Gate._derive_state`: reconciles `approved` (bool) against
    /// `state` (richer verdict) for hand-edited or legacy files.
    private mutating func deriveState() {
        if approved && (state == .pending || state == .needsRevision) {
            state = (notes != nil && !(notes ?? "").isEmpty) ? .approvedWithNotes : .approved
        } else if !approved && (state == .approved || state == .approvedWithNotes) {
            // Contradictory hand-edited file: the pipeline blocks on `approved`,
            // so the richer state must not claim otherwise.
            state = .pending
        }
    }
}

/// Port of `gates.py::Gates`. `schema` defaults to `gates/v2` on encode/new.
public struct Gates: Codable, Sendable, Equatable {
    public var project: String
    public var schema: String
    public var gates: [String: Gate]

    private enum CodingKeys: String, CodingKey {
        case project
        case schema
        case gates
    }

    public init(project: String, schema: String = "gates/v2", gates: [String: Gate] = [:]) {
        self.project = project
        self.schema = schema
        self.gates = gates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(String.self, forKey: .project)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? "gates/v2"
        gates = try container.decodeIfPresent([String: Gate].self, forKey: .gates) ?? [:]
    }

    public func get(_ phase: String) -> Gate {
        gates[phase] ?? Gate()
    }

    public mutating func set(_ phase: String, _ gate: Gate) {
        gates[phase] = gate
    }
}

/// Raised when a required gate is not approved. Port of `gates.py::GateBlocked`.
public struct GateBlocked: Swift.Error, Sendable, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Deterministic hard-gate enforcement. This is the code that physically prevents the agent from
/// advancing a phase whose prerequisites aren't genuinely satisfied — the port of the predecessor's
/// `require()`-chain + sanity self-approval guard. Two layers:
///  - `checkApprovable`: a pack's per-phase artifact precondition (e.g. `analysis` must have produced
///    real beats/downbeats) is verified BEFORE the gate can be stamped, in both approve paths.
///  - `requireChain`: before an expensive downstream compute step (assembly/render), every phase up
///    to and including a target must already be approved.
public enum GateGuard {
    /// Verify the deterministic precondition for approving `phase`. Prose phases that carry no
    /// registered requirement are approvable on the user's judgement alone; phases with a requirement
    /// (a real artifact must exist) throw `GateBlocked` when it isn't met.
    public static func checkApprovable(phase: String, dataRoot: URL, requirement: EngineRegistry.GateRequirement?) throws {
        try requirement?(dataRoot)
    }

    /// FAIL-CLOSED liveness precondition, checked before ANY approval. A project that DECLARES an active
    /// pack owns that pack's gate machinery only if the pack is genuinely wired into the running
    /// registry. If it isn't — the class of bug where a pack loads as a bundle but resolves to nil at
    /// runtime, silently disabling every gate — NO step may be approved, or the pipeline would advance
    /// ungated while masquerading as a generic project. A generic project (no declared pack) is
    /// unaffected. `declared` is the ground truth from the package; `resolved`/`registry` are what the
    /// runtime resolved and built. The deterministic verdict lives in `PackWiring`.
    public static func requireWiredPack(declared: String?, resolved: String?, registry: EngineRegistry) throws {
        guard PackWiring.verify(expected: declared, resolved: resolved, registry: registry).isWired else {
            throw GateBlocked(
                "Can't approve this step: the \"\(declared ?? "")\" workflow isn't wired into this session "
                    + "— its engine↔plugin link is broken, so its gates and analysis are inactive. No step "
                    + "can be approved until the pack is active. Reopen the project; if it persists, report it.")
        }
    }

    /// Terminal backstop: every phase up to and including `phase` in `order` must be approved, else
    /// `GateBlocked`. Mirrors the predecessor render dispatcher's require-loop over the whole chain.
    public static func requireChain(_ gates: Gates, order: [String], through phase: String) throws {
        guard let idx = order.firstIndex(of: phase) else { return }
        for p in order[...idx] {
            _ = try GatesOperations.require(gates, phase: p)
        }
    }

    /// Approving in order: every phase BEFORE `phase` in `order` must already be approved. Phases not
    /// in `order` (unknown) impose no constraint. Throws `GateBlocked` naming the first gap.
    public static func requirePriorApproved(_ gates: Gates, order: [String], phase: String) throws {
        guard let idx = order.firstIndex(of: phase), idx > 0 else { return }
        for p in order[..<idx] where !gates.get(p).approved {
            throw GateBlocked("Can't approve \"\(phase)\" yet — approve \"\(p)\" first (phases go in order).")
        }
    }
}

/// Free-function operations on `Gates`, mirroring the Python module-level
/// functions (which take a `project_dir` and load/save around the mutation).
/// The Swift port keeps these pure — callers own load/save via `ArtifactStore`.
public enum GatesOperations {
    /// Port of `gates.py::set_state`. The multi-state verdict: approved /
    /// approved_with_notes / needs_revision / pending. `approved` (what the
    /// pipeline blocks on) follows: only the two approve states pass.
    public static func setState(
        _ gates: inout Gates, phase: String, state: GateState, notes: String? = nil,
        by: String = "user", now: () -> String = currentTimestamp
    ) {
        var state = state
        if state == .approved, let notes, !notes.trimmingCharacters(in: .whitespaces).isEmpty {
            // notes on an approval ARE the with-notes verdict
            state = .approvedWithNotes
        }
        let approved = state == .approved || state == .approvedWithNotes
        gates.set(
            phase,
            Gate(
                approved: approved,
                approvedAt: approved ? now() : nil,
                approvedBy: approved ? by : nil,
                notes: notes,
                state: state
            )
        )
    }

    /// Port of `gates.py::approve`.
    public static func approve(
        _ gates: inout Gates, phase: String, notes: String? = nil, by: String = "user",
        now: () -> String = currentTimestamp
    ) {
        gates.set(phase, Gate(approved: true, approvedAt: now(), approvedBy: by, notes: notes))
    }

    /// Port of `gates.py::reset`.
    public static func reset(_ gates: inout Gates, phase: String) {
        gates.set(phase, Gate())
    }

    /// Port of `gates.py::require`. Throws `GateBlocked` if the phase isn't approved.
    public static func require(_ gates: Gates, phase: String) throws -> Gate {
        let gate = gates.get(phase)
        guard gate.approved else {
            throw GateBlocked(
                "Gate \"\(phase)\" not approved for project \"\(gates.project)\". Claude must get "
                    + "explicit user approval (AskUserQuestion) before continuing, then set the gate."
            )
        }
        return gate
    }

    /// Port of `gates.py::rewind_to`. Resets the target gate and every
    /// following gate (in `order`) to `approved=false`. Artifacts are kept
    /// (versioned history); a re-run writes a new version. Returns the reset
    /// phase names. Throws if `target` is not in `order`.
    public enum RewindError: Swift.Error, Sendable, Equatable {
        case unknownGate(String)
    }

    public static func rewindTo(
        _ gates: inout Gates, target: String, order: [String] = coreGatePhases,
        now: () -> String = currentTimestamp
    ) throws -> [String] {
        guard let startIndex = order.firstIndex(of: target) else {
            throw RewindError.unknownGate(target)
        }
        let stamp = now()
        var affected: [String] = []
        for phase in order[startIndex...] {
            gates.set(phase, Gate(approved: false, notes: "rewound @ \(stamp)"))
            affected.append(phase)
        }
        return affected
    }
}

/// UTC ISO-8601 timestamp with second precision, matching Python's
/// `datetime.now(timezone.utc).isoformat(timespec="seconds")`.
public func currentTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}
