import Foundation

/// The user's final word on paid AGENT renders (locked provider architecture, M7). NGV/the agent
/// recommend a model and NGV resolves the cheapest activated provider — but before the agent spends
/// money on the user's behalf, the user confirms. This is user-clicks-to-confirm, never
/// agent-self-asserted: the gate suspends the tool call on a continuation the UI resolves.
///
/// Only `.agentTool` renders pass through here. Panel / dialog / rerun renders are the user's own
/// click — already confirmed. The threshold is the user's budget dial: renders at or under it run
/// without a prompt (the user pre-approved that ceiling); anything above it, or of unknown cost,
/// waits for an explicit tap.
enum CostGuard {
    /// Auto-approve ceiling in credits. Default 0 → confirm every paid agent render (the strict
    /// Pflicht). Raising it is the user pre-approving spend up to that amount — still their final word.
    static let autoApproveKey = "agentAutoApproveCredits"

    static var autoApproveCredits: Int { UserDefaults.standard.integer(forKey: autoApproveKey) }

    /// A free render (0 credits) never needs approval. Unknown cost (nil) is treated as over-budget —
    /// we don't spend the user's money on an unpriced call without asking.
    static func needsApproval(credits: Int?) -> Bool {
        (credits ?? Int.max) > autoApproveCredits
    }
}

/// A cheaper model the user can swap to before approving — same modality, actually runnable now.
struct SpendAlternative: Identifiable, Equatable, Sendable {
    let modelId: String
    let name: String
    let providerLabel: String
    let credits: Int?
    var id: String { modelId }
}

/// The pending spend confirmation surfaced in the composer dock (never a modal — LOCKED placement).
struct SpendApproval: Identifiable, Equatable, Sendable {
    let id: String
    let modelId: String
    let modelName: String
    let providerLabel: String
    let credits: Int?
    /// Cheaper runnable models of the same modality, cost-ascending. Empty when none are cheaper.
    let alternatives: [SpendAlternative]
    /// Verb for the action, e.g. "Generate video", used on the approve button.
    let actionLabel: String
}

/// The user's decision. `.approved` carries the chosen model id — the same one when kept, a cheaper
/// one when swapped. `.declined` means the render must not run.
enum SpendDecision: Equatable, Sendable {
    case approved(modelId: String)
    case declined
}
