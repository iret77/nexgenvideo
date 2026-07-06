import Foundation

/// Per-project approval gates — the generic mechanism. Every phase must be
/// explicitly approved before the next step runs. Port of `core/gates.py`.
public enum GateState: String, Codable, Sendable, CaseIterable {
    case pending
    case approved
    case approvedWithNotes = "approved_with_notes"
    case needsRevision = "needs_revision"
}

/// The generic core production pipeline, in order. A pack inserts/extends it
/// (music adds "analysis" after project_init). Port of `gates.py::CORE_PHASES`.
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
public struct GateBlocked: Swift.Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
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
