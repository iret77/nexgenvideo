import Foundation

/// Frame-audit v1: a vision-audit report per rendered keyframe. Between the image-provider
/// call and the user's approve there is otherwise no automated inspection of the frame — a
/// bad keyframe (wrong pose, missing figure, frontal gaze where the spec says away) still gets
/// fed into the expensive image-to-video step before anyone notices. A vision model inspects the
/// rendered frame against the shot spec and emits a structured, machine-validated verdict per
/// audit point; routing then follows deterministically from `verdict`. Port of
/// `frames/audit_schema.py::FrameAudit`. One YAML per audited frame at
/// `<data-root>/frames/<shot_id>-<role>.audit.yaml`.
public let frameAuditSchemaVersion = "frame_audit/v1"

/// Auto-re-render budget before the user takes over. Port of `MAX_AUTO_RERENDER_ATTEMPTS`.
public let maxAutoRerenderAttempts = 2

/// The standard audit points every frame audit must cover (extra free keys are allowed).
/// Order and membership follow `audit_schema.py::STANDARD_CHECK_KEYS`.
public let standardAuditCheckKeys = [
    "character_count",
    "framing",
    "camera_angle",
    "camera_height",
    "character_position",
    "gaze",
    "forbidden_elements",
    "visible_zones",
    "anchor_at_t0",
    "proportion_anchor_match",
]

/// Severity of a single audit point. Port of `audit_schema.py::AuditStatus`.
/// - `clean`: passes, no note needed.
/// - `minor`: deviation visible but usable; the user decides.
/// - `blocking`: grossly wrong; auto-re-render with a correction patch.
/// - `n/a`: not applicable for this shot (e.g. character_count on a figure-free shot).
/// - `pending`: skeleton state, forbidden as an end state (rejected by `validate()`).
public enum AuditStatus: String, Codable, Sendable, CaseIterable {
    case clean
    case minor
    case blocking
    case notApplicable = "n/a"
    case pending
}

/// The routing verdict the executor hands the agent so it never recomputes policy.
/// Port of the reference's `APPROVE | RERENDER | USER_DECIDES`.
public enum AuditVerdict: String, Sendable {
    case approve = "APPROVE"
    case rerender = "RERENDER"
    case userDecides = "USER_DECIDES"
}

/// A single audit point with soll/ist and a finding note. Port of `audit_schema.py::AuditCheck`.
public struct AuditCheck: Codable, Sendable, Equatable {
    public var status: AuditStatus
    /// What the shot spec demands. Empty for `n/a`.
    public var expected: String
    /// What the image shows. Empty when not assessable.
    public var observed: String
    /// Short explanation for the user / re-render patch.
    public var note: String

    public init(status: AuditStatus, expected: String = "", observed: String = "", note: String = "") {
        self.status = status
        self.expected = expected
        self.observed = observed
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(AuditStatus.self, forKey: .status)
        expected = try c.decodeIfPresent(String.self, forKey: .expected) ?? ""
        observed = try c.decodeIfPresent(String.self, forKey: .observed) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// Audit report for one rendered frame. The agent judges (`status`/`observed`/`note`); the
/// machine measures (`render_sha256`, `generated`, `expected`, `auto_rerender_attempt`).
/// Validators mirror `_overall_consistent_with_checks` and run on BOTH inits, exactly like
/// `Bible.validate()`. Port of `audit_schema.py::FrameAudit`.
public struct FrameAudit: Codable, Sendable, Equatable {
    public var schema: String
    public var shotId: String
    /// "start" | "end".
    public var role: String
    /// Path to the audited image, relative to the project home.
    public var renderPath: String
    /// Binds the audit to the exact file audited.
    public var renderSha256: String
    public var generated: String
    /// Free identity string, e.g. "orchestrator-claude-opus-4.8", "google-gemini-3-pro".
    public var auditor: String
    public var checks: [String: AuditCheck]
    public var overall: AuditStatus
    /// Machine-owned: how many auto-re-renders already ran for this shot+role.
    public var autoRerenderAttempt: Int
    /// STRICT/MUST/NOT instructions for the next re-render; set when `overall == blocking`.
    public var autoRerenderPatch: String

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case schemaUnknown(String)
        case roleUnknown(String)
        case attemptNegative
        case overallPending
        case checkPending
        case blockingCheckOverallNotBlocking(overall: String)
        case minorCheckOverallNotMinor(overall: String)
    }

    public init(
        schema: String = frameAuditSchemaVersion, shotId: String, role: String = "start",
        renderPath: String, renderSha256: String, generated: String, auditor: String,
        checks: [String: AuditCheck] = [:], overall: AuditStatus,
        autoRerenderAttempt: Int = 0, autoRerenderPatch: String = ""
    ) throws {
        self.schema = schema
        self.shotId = shotId
        self.role = role
        self.renderPath = renderPath
        self.renderSha256 = renderSha256
        self.generated = generated
        self.auditor = auditor
        self.checks = checks
        self.overall = overall
        self.autoRerenderAttempt = autoRerenderAttempt
        self.autoRerenderPatch = autoRerenderPatch
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case shotId = "shot_id"
        case role
        case renderPath = "render_path"
        case renderSha256 = "render_sha256"
        case generated
        case auditor
        case checks
        case overall
        case autoRerenderAttempt = "auto_rerender_attempt"
        case autoRerenderPatch = "auto_rerender_patch"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? frameAuditSchemaVersion
        shotId = try c.decode(String.self, forKey: .shotId)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "start"
        renderPath = try c.decode(String.self, forKey: .renderPath)
        renderSha256 = try c.decode(String.self, forKey: .renderSha256)
        generated = try c.decode(String.self, forKey: .generated)
        auditor = try c.decode(String.self, forKey: .auditor)
        checks = try c.decodeIfPresent([String: AuditCheck].self, forKey: .checks) ?? [:]
        overall = try c.decode(AuditStatus.self, forKey: .overall)
        autoRerenderAttempt = try c.decodeIfPresent(Int.self, forKey: .autoRerenderAttempt) ?? 0
        autoRerenderPatch = try c.decodeIfPresent(String.self, forKey: .autoRerenderPatch) ?? ""
        try validate()
    }

    /// `overall` must match the worst check status, and `pending` is forbidden as an end state.
    /// Without this `overall=clean` alongside a `blocking` check would be schema-valid and the
    /// routing verdict would lie. Port of `_schema_const` + `_attempts_nonneg` +
    /// `_overall_consistent_with_checks`.
    public func validate() throws {
        guard schema == frameAuditSchemaVersion else { throw ValidationError.schemaUnknown(schema) }
        guard role == "start" || role == "end" else { throw ValidationError.roleUnknown(role) }
        guard autoRerenderAttempt >= 0 else { throw ValidationError.attemptNegative }
        guard overall != .pending else { throw ValidationError.overallPending }
        let statuses = Set(checks.values.map(\.status))
        if statuses.contains(.pending) { throw ValidationError.checkPending }
        if statuses.contains(.blocking), overall != .blocking {
            throw ValidationError.blockingCheckOverallNotBlocking(overall: overall.rawValue)
        }
        if statuses.contains(.minor), !statuses.contains(.blocking),
           overall != .minor, overall != .blocking {
            throw ValidationError.minorCheckOverallNotMinor(overall: overall.rawValue)
        }
    }

    // MARK: Derived routing (port of the reference computed properties)

    public var hasBlocking: Bool {
        overall == .blocking || checks.values.contains { $0.status == .blocking }
    }

    public var hasMinor: Bool {
        checks.values.contains { $0.status == .minor }
    }

    /// Auto-re-render trigger: blocking AND attempt budget left.
    public var needsRerender: Bool {
        hasBlocking && autoRerenderAttempt < maxAutoRerenderAttempts
    }

    /// User-approve trigger: not (clean without minor) and not needsRerender.
    public var needsUserDecision: Bool {
        if overall == .clean, !hasMinor { return false }
        if hasBlocking, autoRerenderAttempt < maxAutoRerenderAttempts { return false }
        return true
    }

    /// The single routing verdict for the agent.
    public var verdict: AuditVerdict {
        if needsRerender { return .rerender }
        if needsUserDecision { return .userDecides }
        return .approve
    }

    /// Auto-re-render attempts still available.
    public var attemptsLeft: Int {
        max(0, maxAutoRerenderAttempts - autoRerenderAttempt)
    }
}

/// The audit YAML path for a shot+role under a data root. Port of `audit_schema.py::audit_path`.
public func frameAuditPath(dataRoot: URL, shotId: String, role: String = "start") -> URL {
    dataRoot
        .appendingPathComponent(PipelineLayout.framesDir)
        .appendingPathComponent("\(shotId)-\(role).audit.yaml")
}

/// Load a frame audit, or nil when the file is absent. Throws on a corrupt / schema-invalid file
/// (the bridge surfaces that as a warning). Port of `audit_schema.py::load`.
public func loadFrameAudit(dataRoot: URL, shotId: String, role: String = "start") throws -> FrameAudit? {
    let url = frameAuditPath(dataRoot: dataRoot, shotId: shotId, role: role)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let text = try String(contentsOf: url, encoding: .utf8)
    return try YAMLCoding.decode(FrameAudit.self, from: text)
}

/// Persist a frame audit to `<data-root>/frames/<shot>-<role>.audit.yaml` (atomic, parent-dir
/// created). Port of `audit_schema.py::save`.
@discardableResult
public func saveFrameAudit(_ audit: FrameAudit, dataRoot: URL) throws -> URL {
    let url = frameAuditPath(dataRoot: dataRoot, shotId: audit.shotId, role: audit.role)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let yaml = try YAMLCoding.encode(audit)
    try yaml.write(to: url, atomically: true, encoding: .utf8)
    return url
}
