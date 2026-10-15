import Foundation
import NexGenEngine

struct GateArtifactFingerprint: Equatable, Sendable {
    let path: String
    let sha256: String
    let lineageSHA256: String?
    var phase: String? = nil

    func matches(dataRoot: URL) -> Bool {
        if phase == "shotlist" {
            guard let version = latestShotlistVersion(dataRoot: dataRoot),
                  path == PipelineLayout.shotlistVersionFile(version) else { return false }
        }
        guard let url = try? ProjectLocalFile.resolve(path, dataRoot: dataRoot),
              (try? FileDigest.sha256(of: url)) == sha256 else { return false }
        let lineage = try? FileDigest.sha256(of: PipelineLayout.url(PipelineLayout.lineageFile, in: dataRoot))
        return lineage == lineageSHA256
    }
}

/// Host-recorded approval history. `untracked` marks a gate change the host could not fingerprint,
/// so no later comparison may claim to know the last approved version.
struct GateApprovalEvidence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case approved
        case rewound
        case untracked
    }

    let kind: Kind
    /// Affected phases; nil means every phase.
    let phases: [String]?
    var sha256: String? = nil
    var text: String? = nil
    var reason: String? = nil
    let recordedAt: Date

    func affects(_ phase: String) -> Bool { phases?.contains(phase) ?? true }
}

/// The host-recorded approval of the same phase that preceded this request.
struct GatePriorApproval: Equatable, Sendable {
    let sha256: String
    let revisionReason: String?
    var text: String? = nil
}

/// A durable user decision that outlives the requesting gate tool call.
struct GateApproval: Identifiable, Equatable, Sendable {
    enum PriorComparison: Equatable, Sendable {
        case identical
        case changed(revisionReason: String?)
    }

    enum Action: Equatable, Sendable {
        case approve
        case rewind(gatesSHA256: String, phases: [String])
        case setState(GateState)

        static func == (lhs: Action, rhs: Action) -> Bool {
            switch (lhs, rhs) {
            case (.rewind(let a, let ap), .rewind(let b, let bp)):
                return a == b && ap == bp
            case (.approve, .approve):
                return true
            case (.setState(let lhsState), .setState(let rhsState)):
                return lhsState.rawValue == rhsState.rawValue
            default:
                return false
            }
        }
    }

    let id: String
    /// The raw phase key (e.g. `brief`), exactly as written to gates.yaml.
    let phase: String
    /// The human phase name, resolved via `PhaseDisplay.label` — never the raw snake_case id.
    let phaseLabel: String
    /// The notes the agent proposed to attach on approval, if any.
    let notes: String?
    let dataRoot: URL?
    let action: Action
    let declaredPack: String?
    let declaredBinding: ProjectPackBinding?
    let sourceToolName: String
    let sourceToolUseID: String?
    let sourceHostStateID: UUID
    let sourceHostTurnReference: AgentHostTurnReference?
    /// Set only for an in-app turn that can be resumed automatically.
    let sessionId: UUID?
    let artifactFingerprint: GateArtifactFingerprint?
    var priorApproval: GatePriorApproval?
    var priorChanges: ArtifactLineDiff.Result?

    init(
        phase: String,
        notes: String? = nil,
        dataRoot: URL? = nil,
        action: Action = .approve,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil,
        sourceToolName: String = ToolName.approveGate.rawValue,
        sourceToolUseID: String? = nil,
        sourceHostStateID: UUID = UUID(),
        sourceHostTurnReference: AgentHostTurnReference? = nil,
        sessionId: UUID? = nil,
        artifactFingerprint: GateArtifactFingerprint? = nil,
        id: String = UUID().uuidString
    ) {
        self.id = id
        self.artifactFingerprint = artifactFingerprint
        self.phase = phase
        self.phaseLabel = PhaseDisplay.label(phase)
        self.notes = notes
        self.dataRoot = dataRoot
        self.action = action
        self.declaredPack = declaredPack
        self.declaredBinding = declaredBinding
        self.sourceToolName = sourceToolName
        self.sourceToolUseID = sourceToolUseID
        self.sourceHostStateID = sourceHostStateID
        self.sourceHostTurnReference = sourceHostTurnReference
        self.sessionId = sessionId
    }

    var isRewind: Bool {
        if case .rewind = action { return true }
        return false
    }

    var resetPhases: [String]? {
        if case .rewind(_, let phases) = action { return phases }
        return nil
    }

    var decisionTitle: String { isRewind ? "Revise from \(phaseLabel)" : "Approve \(phaseLabel)" }

    var priorComparison: PriorComparison? {
        guard !isRewind, let priorApproval, let current = artifactFingerprint?.sha256 else { return nil }
        return priorApproval.sha256 == current
            ? .identical
            : .changed(revisionReason: priorApproval.revisionReason)
    }

    func scoped(to sessionId: UUID?) -> GateApproval {
        var scoped = GateApproval(
            phase: phase,
            notes: notes,
            dataRoot: dataRoot,
            action: action,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding,
            sourceToolName: sourceToolName,
            sourceToolUseID: sourceToolUseID,
            sourceHostStateID: sourceHostStateID,
            sourceHostTurnReference: sourceHostTurnReference,
            sessionId: sessionId,
            artifactFingerprint: artifactFingerprint,
            id: id
        )
        scoped.priorApproval = priorApproval
        scoped.priorChanges = priorChanges
        return scoped
    }

    /// Latest host-recorded approval of `phase`, plus the reason of a later revision that reset it.
    static func priorApproval(
        phase: String,
        in evidence: [GateApprovalEvidence]
    ) -> GatePriorApproval? {
        var revisionReason: String?
        for entry in evidence.sorted(by: { $0.recordedAt < $1.recordedAt }).reversed() where entry.affects(phase) {
            switch entry.kind {
            case .untracked:
                return nil
            case .rewound:
                if revisionReason == nil { revisionReason = entry.reason }
            case .approved:
                guard let sha256 = entry.sha256 else { return nil }
                return GatePriorApproval(sha256: sha256, revisionReason: revisionReason, text: entry.text)
            }
        }
        return nil
    }

    /// Line changes against the prior approval, when both texts are host-verified.
    static func priorChanges(prior: GatePriorApproval?, fingerprint: GateArtifactFingerprint?, dataRoot: URL?)
        -> ArtifactLineDiff.Result? {
        guard let prior, let old = prior.text, let fingerprint, prior.sha256 != fingerprint.sha256,
              let new = ArtifactLineDiff.verifiedText(path: fingerprint.path, sha256: fingerprint.sha256,
                  dataRoot: dataRoot) else { return nil }
        return ArtifactLineDiff.changes(old: old, new: new)
    }

    func matchesRequest(_ other: GateApproval) -> Bool {
        artifactFingerprint == other.artifactFingerprint
            && phase == other.phase
            && notes == other.notes
            && dataRoot == other.dataRoot
            && action == other.action
            && declaredPack == other.declaredPack
            && declaredBinding == other.declaredBinding
            && sourceToolName == other.sourceToolName
            && sessionId == other.sessionId
    }

    /// The two gate states that MEAN approval — the only ones an agent tool surfaces a user
    /// confirmation for. `.needsRevision` / `.pending` are not approvals and write straight through.
    static func isApproval(_ state: GateState) -> Bool {
        switch state {
        case .approved, .approvedWithNotes: return true
        case .pending, .needsRevision: return false
        }
    }
}

struct GateApprovalRequest: Equatable, Sendable {
    let approval: GateApproval
    let isNew: Bool
    let matchesRequestedApproval: Bool
}

/// The user's decision on a surfaced gate approval. `.approved` writes the gate; `.declined` does not.
enum GateDecision: Equatable, Sendable {
    case approved
    case declined
}
