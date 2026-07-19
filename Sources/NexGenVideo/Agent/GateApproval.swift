import Foundation
import NexGenEngine

/// The user's confirmation of an agent-initiated phase-gate approval (HAX G11). A phase gate is the
/// USER's decision, not the agent's: when the agent calls approve_gate (or an approving set_gate_state)
/// the tool call suspends and this request is surfaced in the composer dock. The gate is written ONLY
/// after the user taps Approve. Mirrors the spend-approval seam (SpendApproval / CostGuard).
struct GateApproval: Identifiable, Equatable, Sendable {
    let id: String
    /// The raw phase key (e.g. `brief`), exactly as written to gates.yaml.
    let phase: String
    /// The human phase name, resolved via `PhaseDisplay.label` — never the raw snake_case id.
    let phaseLabel: String
    /// The notes the agent proposed to attach on approval, if any.
    let notes: String?

    init(phase: String, notes: String? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.phase = phase
        self.phaseLabel = PhaseDisplay.label(phase)
        self.notes = notes
    }

    /// The two gate states that MEAN approval — the only ones an agent tool surfaces a user
    /// confirmation for. `.needsRevision` / `.pending` are not approvals and write straight through.
    static func isApproval(_ state: GateState) -> Bool {
        state == .approved || state == .approvedWithNotes
    }
}

/// The user's decision on a surfaced gate approval. `.approved` writes the gate; `.declined` does not.
enum GateDecision: Equatable, Sendable {
    case approved
    case declined
}
