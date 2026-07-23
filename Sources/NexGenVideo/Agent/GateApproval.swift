import Foundation
import NexGenEngine

/// A durable user decision that outlives the requesting gate tool call.
struct GateApproval: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case approve
        case setState(GateState)

        static func == (lhs: Action, rhs: Action) -> Bool {
            switch (lhs, rhs) {
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
    /// Set only for an in-app turn that can be resumed automatically.
    let sessionId: UUID?

    init(
        phase: String,
        notes: String? = nil,
        dataRoot: URL? = nil,
        action: Action = .approve,
        declaredPack: String? = nil,
        sessionId: UUID? = nil,
        id: String = UUID().uuidString
    ) {
        self.id = id
        self.phase = phase
        self.phaseLabel = PhaseDisplay.label(phase)
        self.notes = notes
        self.dataRoot = dataRoot
        self.action = action
        self.declaredPack = declaredPack
        self.sessionId = sessionId
    }

    func scoped(to sessionId: UUID?) -> GateApproval {
        GateApproval(
            phase: phase,
            notes: notes,
            dataRoot: dataRoot,
            action: action,
            declaredPack: declaredPack,
            sessionId: sessionId,
            id: id
        )
    }

    func matchesRequest(_ other: GateApproval) -> Bool {
        phase == other.phase
            && notes == other.notes
            && dataRoot == other.dataRoot
            && action == other.action
            && declaredPack == other.declaredPack
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
