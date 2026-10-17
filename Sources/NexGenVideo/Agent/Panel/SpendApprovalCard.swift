import SwiftUI

private enum SpendApprovalFocusTarget: Hashable {
    case provider
    case model
}

struct SpendApprovalCard: View {
    let approval: SpendApproval
    let error: String?
    let isWorking: Bool
    let onApprove: (SpendOption) -> Void
    let onDecline: () -> Void
    let onRefresh: () -> Void
    let onPrepare: (SpendOption) -> Void
    let approvalPhase: String?
    let onApproveAll: ((SpendOption) -> Void)?

    @State private var selectedOptionId: String
    @State private var chosenProvider: GenerationProvider?
    @State private var approvalError: String?
    @State private var showsModelSelection = false
    @FocusState private var focusedControl: SpendApprovalFocusTarget?

    init(
        approval: SpendApproval,
        error: String? = nil,
        isWorking: Bool = false,
        onApprove: @escaping (SpendOption) -> Void,
        onDecline: @escaping () -> Void,
        onRefresh: @escaping () -> Void = {},
        onPrepare: @escaping (SpendOption) -> Void = { _ in },
        approvalPhase: String? = nil,
        onApproveAll: ((SpendOption) -> Void)? = nil
    ) {
        self.approval = approval
        self.error = error
        self.isWorking = isWorking
        self.onApprove = onApprove
        self.onDecline = onDecline
        self.onRefresh = onRefresh
        self.onPrepare = onPrepare
        self.approvalPhase = approvalPhase
        self.onApproveAll = onApproveAll
        _selectedOptionId = State(initialValue: approval.recommendedOptionId)
    }

    private var availableOptions: [SpendOption] {
        approval.options
    }

    private var selectedOption: SpendOption? {
        availableOptions.first { $0.id == selectedOptionId }
    }

    private var availableProviders: [GenerationProvider] {
        var seen: Set<GenerationProvider> = []
        return availableOptions.compactMap { option in
            seen.insert(option.target.provider).inserted ? option.target.provider : nil
        }
    }

    private var selectedProvider: GenerationProvider? {
        selectedOption?.target.provider
            ?? chosenProvider.flatMap { availableProviders.contains($0) ? $0 : nil }
            ?? availableProviders.first
    }

    private var modelPickerOptions: [NativeChoicePicker.Option] {
        let options = modelOptions.map { NativeChoicePicker.Option(id: $0.id, title: $0.modelName) }
        guard selectedOption == nil, !options.isEmpty else { return options }
        return [.init(id: "", title: "Choose a model", isEnabled: false)] + options
    }

    private var modelOptions: [SpendOption] {
        guard let selectedProvider else { return [] }
        return availableOptions.filter { $0.target.provider == selectedProvider }
    }

    private var providerIssues: [String] {
        let scope = selectedProvider.map { [$0] } ?? approval.providerScope
        return SpendApprovalProviderDiagnostics.messages(
            providerScope: scope,
            availableOptions: availableOptions,
            discovery: ModelCatalog.shared.providerDiscovery
        )
    }

    var body: some View {
        GenerationApprovalCard(title: [actionLabel, approvalPhase.map(PhaseDisplay.label)]
            .compactMap { $0 }.joined(separator: " · ")) {
            ScrollView {
                decisionBody.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        } footer: {
            footerRow
        }
        .onAppear {
            normalizeSelection()
            requestInitialFocus()
        }
        .onChange(of: availableOptions.map(\.id)) { _, _ in normalizeSelection() }
        .task(id: selectedOptionId + "|" + (approval.preparationRevision ?? "")) {
            if approval.requiresGenerationPackage == true, let selectedOption { onPrepare(selectedOption) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerKeysChanged)) { _ in
            onRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelCatalogChanged)) { _ in
            onRefresh()
        }
        .id(approval.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(actionLabel)
    }

    private var decisionBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            if selectedOption?.generationPackage == nil { summary }
            if let requirement = approval.modelRequirement { requirementNotice(requirement) }
            if availableOptions.count > 1 || (selectedOption == nil && !availableOptions.isEmpty) {
                DisclosureGroup("Change model", isExpanded: $showsModelSelection) {
                    selectionControls
                    Text("Only connected models compatible with this request are shown.")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            if approval.requiresGenerationPackage == true {
                if let package = selectedOption?.generationPackage {
                    GenerationPackageReviewView(package: package)
                } else if let selectedOption {
                    Text(error == nil ? "Preparing request…" : "Request preparation required")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if error != nil {
                        Button("Prepare request again") { onPrepare(selectedOption) }
                            .buttonStyle(InlineActionButtonStyle()).disabled(isWorking)
                    }
                }
            }
            ForEach(providerIssues, id: \.self) { message in
                Text(message)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.warningColor)
            }
            if let message = approvalError ?? error {
                Text(message)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.errorColor)
            } else if availableOptions.isEmpty {
                Text("No valid provider and model combination is currently available.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    private var actionLabel: String {
        selectedOption?.generationPackage.map { GenerationApprovalPresentation.actionLabel(packages: [$0]) }
            ?? approval.actionLabel
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(summaryTitle)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .help(selectedOption?.modelName ?? "")
            if let selectedOption {
                Text("via \(selectedOption.providerLabel) · Price unknown")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
    }

    private var summaryTitle: String {
        if let selectedOption { return "\(approval.actionLabel) with \(displayName(selectedOption))" }
        return availableOptions.isEmpty
            ? "\(approval.actionLabel) with Unavailable model"
            : "\(approval.actionLabel): choose a model"
    }

    @ViewBuilder
    private func requirementNotice(_ requirement: SpendModelRequirement) -> some View {
        if let reason = requirement.unavailableReason {
            Text("\(requirement.modelName), set for \(requirement.source), can't run this request. \(reason)")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.warningColor)
                .fixedSize(horizontal: false, vertical: true)
            if !availableOptions.isEmpty {
                Text("Choose another model for this image only. The brief stays unchanged.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let selectedOption, requirement.isModelChange(selectedOption) {
            Text("Model change: \(selectedOption.modelName) replaces \(requirement.modelName), set for \(requirement.source). Applies to this image only; the brief stays unchanged.")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.warningColor)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Model set for \(requirement.source).")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("PROVIDER")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                NativeChoicePicker(
                    label: "Provider",
                    options: availableProviders.map {
                        .init(id: $0.rawValue, title: $0.displayName)
                    },
                    selection: providerSelection
                )
                .disabled(isWorking || availableProviders.count < 2)
                .focused($focusedControl, equals: .provider)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("MODEL")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                NativeChoicePicker(
                    label: "Model",
                    options: modelPickerOptions,
                    selection: $selectedOptionId
                )
                .disabled(isWorking || modelOptions.isEmpty || (modelOptions.count < 2 && selectedOption != nil))
                .focused($focusedControl, equals: .model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { selectedProvider?.rawValue ?? "" },
            set: { rawValue in
                guard let provider = GenerationProvider(rawValue: rawValue) else { return }
                let currentModelId = selectedOption?.modelId
                let matching = availableOptions.filter { $0.target.provider == provider }
                let sameModel = matching.first { $0.modelId == currentModelId }?.id
                chosenProvider = provider
                if let requirement = approval.modelRequirement {
                    selectedOptionId = sameModel
                        ?? matching.first { $0.modelId == requirement.modelId }?.id
                        ?? ""
                } else {
                    selectedOptionId = sameModel ?? ""
                }
                approvalError = nil
            }
        )
    }

    private var footerRow: some View {
        GenerationApprovalActions(
            actionLabel: isWorking ? String(localized: "Preparing generation…") : actionLabel,
            phase: approvalPhase,
            canApprove: !approveDisabled,
            canEdit: !isWorking,
            onApprove: {
                guard let selectedOption else { return }
                approvalError = nil
                onApprove(selectedOption)
            },
            onDecline: onDecline,
            onApprovePhase: onApproveAll.map { approvePhase in
                {
                    guard let selectedOption else { return }
                    approvalError = nil
                    approvePhase(selectedOption)
                }
            },
            runtimeEvidenceEnabled: GenerationBatchReviewSelfTest.isRequested || WorkspaceUIAcceptance.isRequested
        )
    }

    private var approveDisabled: Bool {
        selectedOption == nil || isWorking
            || (approval.requiresGenerationPackage == true && selectedOption?.generationPackage == nil)
    }

    private func requestInitialFocus() {
        guard selectedOption == nil else { return }
        showsModelSelection = true
        let target: SpendApprovalFocusTarget = if availableProviders.count > 1 {
            .provider
        } else {
            .model
        }
        Task { @MainActor in
            await Task.yield()
            focusedControl = target
        }
    }

    private func normalizeSelection() {
        guard !availableOptions.contains(where: { $0.id == selectedOptionId }) else { return }
        selectedOptionId = SpendApprovalSelection.optionID(approval: approval, current: selectedOptionId)
        if selectedOptionId.isEmpty { showsModelSelection = true }
        approvalError = nil
    }

    private func displayName(_ option: SpendOption) -> String {
        AgentDialog.limitedChoiceDisplayLabel(option.modelName)
    }
}

enum SpendApprovalProviderDiagnostics {
    static func messages(
        providerScope: [GenerationProvider],
        availableOptions: [SpendOption],
        discovery: [GenerationProvider: ProviderDiscoveryState]
    ) -> [String] {
        providerScope.compactMap { provider in
            let hasOption = availableOptions.contains {
                $0.target.provider == provider
            }
            switch discovery[provider] {
            case .actionRequired(let message), .unavailable(let message):
                return "\(provider.displayName): \(message)"
            case .stale(_, let message):
                return "\(provider.displayName): \(message)"
            case .checking where !hasOption:
                return "\(provider.displayName): Refreshing available models."
            case .ready where !hasOption:
                return "\(provider.displayName): No model supports this request."
            case .inactive where !hasOption:
                return "\(provider.displayName): No runnable model was discovered."
            case .none where !hasOption:
                return "\(provider.displayName): No runnable model was discovered."
            case .inactive, .checking, .ready, .none:
                return nil
            }
        }
    }
}

enum SpendApprovalSelection {
    static func optionID(approval: SpendApproval, current: String) -> String {
        if approval.options.contains(where: { $0.id == current }) { return current }
        if approval.options.contains(where: { $0.id == approval.recommendedOptionId }) {
            return approval.recommendedOptionId
        }
        if let requirement = approval.modelRequirement {
            return approval.options.first { $0.modelId == requirement.modelId }?.id ?? ""
        }
        return ""
    }
}
