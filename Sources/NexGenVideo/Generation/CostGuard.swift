import Foundation

/// The user's final word on paid AGENT renders (locked provider architecture, M7). NGV/the agent
/// recommends a model and NGV derives a default provider — but before the agent spends money on the
/// user's behalf, the user can change either and confirms. This is user-clicks-to-confirm, never
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

struct SpendModelCandidate: Sendable {
    let modelId: String
    let modelName: String
    let credits: Int?
}

enum SpendOptionBuilder {
    @MainActor
    static func options(
        candidates: [SpendModelCandidate],
        isModelAvailable: (String) -> Bool,
        runnableBindings: (String) -> [ProviderBinding]
    ) -> [SpendOption] {
        candidates
            .filter { isModelAvailable($0.modelId) }
            .flatMap { candidate in
                runnableBindings(candidate.modelId).map { binding in
                    SpendOption(
                        modelId: candidate.modelId,
                        modelName: candidate.modelName,
                        target: ResolvedGenerationTarget(
                            modelId: candidate.modelId,
                            provider: binding.provider,
                            endpoint: binding.providerRef,
                            binding: binding
                        ),
                        credits: candidate.credits,
                        requiresCatalogAvailability: true
                    )
                }
            }
    }

    static func recommended(
        from options: [SpendOption],
        currentModelId: String,
        defaultTarget: ResolvedGenerationTarget
    ) -> SpendOption? {
        options.first {
            $0.modelId == currentModelId && $0.target == defaultTarget
        } ?? options.first
    }
}

/// One exact model/provider combination the user can approve and dispatch unchanged.
struct SpendOption: Identifiable, Equatable, Sendable {
    let modelId: String
    let modelName: String
    let target: ResolvedGenerationTarget
    let credits: Int?
    /// Provider workflow tools use the same card but are not catalog models.
    let requiresCatalogAvailability: Bool

    var id: String {
        [
            modelId,
            target.provider.rawValue,
            target.transport.rawValue,
            target.endpoint,
            target.binding?.modelParam ?? "",
        ].joined(separator: "|")
    }

    var providerLabel: String { target.provider.displayName }

    @MainActor
    var isCurrentlyAvailable: Bool {
        guard requiresCatalogAvailability else { return true }
        guard ModelRegistry.exists(id: modelId),
              ModelPreferences.shared.isEnabled(modelId),
              let binding = target.binding else { return false }
        return ProviderManifest.runnableBindingsByProvider(forModelId: modelId)
            .contains(binding)
    }
}

/// The pending spend confirmation surfaced in the composer dock (never a modal — LOCKED placement).
struct SpendApproval: Identifiable, Equatable, Sendable {
    let id: String
    let recommendedOptionId: String
    /// Valid model/provider combinations for this exact operation. The recommended option is first.
    let options: [SpendOption]
    /// Verb for the action, e.g. "Generate video", used on the approve button.
    let actionLabel: String

}

/// The user's decision. `.approved` carries the exact model/provider target selected in the card.
enum SpendDecision: Equatable, Sendable {
    case approved(option: SpendOption)
    case declined
    case blocked(reason: String)
}
