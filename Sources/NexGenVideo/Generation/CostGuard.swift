import Foundation

/// The user's final word on paid AGENT renders (locked provider architecture, M7). NGV/the agent
/// recommends a model and NGV derives a default provider — but before the agent spends money on the
/// user's behalf, the user can change either and confirms. This is user-clicks-to-confirm, never
/// agent-self-asserted: the host stores the exact operation and executes it only from the card.
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
        return ProviderActivation.current().isActive(binding.provider, binding.transport)
            && ProviderManifest.bindings(forModelId: modelId).contains(binding)
    }
}

struct SpendPipelineScope: Equatable, Sendable {
    let dataRoot: URL
    let phase: String?
    let tool: ToolName
    let declaredPack: String?
    let declaredBinding: ProjectPackBinding?
    let bindingResolution: ProjectPluginSettings.BindingResolution

    init(
        dataRoot: URL,
        phase: String?,
        tool: ToolName,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding? = nil,
        bindingResolution: ProjectPluginSettings.BindingResolution
    ) {
        self.dataRoot = dataRoot
        self.phase = phase
        self.tool = tool
        self.declaredPack = declaredPack
        self.declaredBinding = declaredBinding
        self.bindingResolution = bindingResolution
    }
}

enum SpendSelectionScope: String, Equatable, Sendable {
    case image
    case video
    case audio
    case upscale
}

enum SpendSelectionPreferences {
    private static let defaultsKeyPrefix = "agentSpendApprovalSelection"

    static func defaultsKey(for scope: SpendSelectionScope) -> String {
        "\(defaultsKeyPrefix).\(scope.rawValue)"
    }

    static func applyingStoredSelection(
        to approval: SpendApproval,
        defaults: UserDefaults = .standard
    ) -> SpendApproval {
        guard let scope = approval.selectionScope,
              let stored = defaults.dictionary(forKey: defaultsKey(for: scope)),
              let providerRaw = stored["provider"] as? String,
              let provider = GenerationProvider(rawValue: providerRaw) else {
            return approval
        }
        let optionID = stored["option_id"] as? String
        let modelID = stored["model_id"] as? String
        let recommended = approval.options.first {
            $0.id == approval.recommendedOptionId
        }
        let preferred = approval.options.first { $0.id == optionID }
            ?? approval.options.first {
                $0.target.provider == provider && $0.modelId == modelID
            }
            ?? recommended.flatMap { recommended in
                approval.options.first {
                    $0.target.provider == provider
                        && $0.modelId == recommended.modelId
                }
            }
            ?? approval.options.first { $0.target.provider == provider }
        guard let preferred else { return approval }
        let ordered = [preferred] + approval.options.filter { $0.id != preferred.id }
        return SpendApproval(
            id: approval.id,
            recommendedOptionId: preferred.id,
            options: ordered,
            actionLabel: approval.actionLabel,
            providerScope: approval.providerScope,
            selectionScope: scope
        )
    }

    static func record(
        _ option: SpendOption,
        for approval: SpendApproval,
        defaults: UserDefaults = .standard
    ) {
        guard let scope = approval.selectionScope else { return }
        defaults.set([
            "option_id": option.id,
            "model_id": option.modelId,
            "provider": option.target.provider.rawValue,
        ], forKey: defaultsKey(for: scope))
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
    let providerScope: [GenerationProvider]
    let selectionScope: SpendSelectionScope?

    init(
        id: String,
        recommendedOptionId: String,
        options: [SpendOption],
        actionLabel: String,
        providerScope: [GenerationProvider]? = nil,
        selectionScope: SpendSelectionScope? = nil
    ) {
        self.id = id
        self.recommendedOptionId = recommendedOptionId
        self.options = options
        self.actionLabel = actionLabel
        self.selectionScope = selectionScope
        var seen = Set<GenerationProvider>()
        self.providerScope = (providerScope ?? options.map(\.target.provider)).filter {
            seen.insert($0).inserted
        }
    }
}
