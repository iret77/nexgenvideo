import SwiftUI

private enum SpendApprovalFocusTarget: Hashable {
    case provider
    case model
    case approve
}

struct SpendApprovalCard: View {
    @Environment(EditorViewModel.self) private var editor

    let approval: SpendApproval
    let error: String?
    let isWorking: Bool
    let onApprove: (SpendOption) -> Void
    let onDecline: () -> Void
    let onRefresh: () -> Void
    let onPrepare: (SpendOption) -> Void

    @State private var selectedOptionId: String
    @State private var chosenProvider: GenerationProvider?
    @State private var approvalError: String?
    @State private var budgetStopIsSet = false
    @FocusState private var focusedControl: SpendApprovalFocusTarget?

    init(
        approval: SpendApproval,
        error: String? = nil,
        isWorking: Bool = false,
        onApprove: @escaping (SpendOption) -> Void,
        onDecline: @escaping () -> Void,
        onRefresh: @escaping () -> Void = {},
        onPrepare: @escaping (SpendOption) -> Void = { _ in }
    ) {
        self.approval = approval
        self.error = error
        self.isWorking = isWorking
        self.onApprove = onApprove
        self.onDecline = onDecline
        self.onRefresh = onRefresh
        self.onPrepare = onPrepare
        _selectedOptionId = State(initialValue: approval.recommendedOptionId)
    }

    private var availableOptions: [SpendOption] {
        approval.options
    }

    private var selectedOption: SpendOption? {
        availableOptions.first { $0.id == selectedOptionId }
    }

    private var selectedCostIsUnknown: Bool {
        guard let selectedOption else { return false }
        guard approval.requiresGenerationPackage == true else { return selectedOption.credits == nil }
        guard let package = selectedOption.generationPackage else { return false }
        return package.payload.estimate == nil
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            ScrollView {
                decisionBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            footerRow
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(
                    AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium),
                    lineWidth: AppTheme.BorderWidth.thin
                )
        )
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .onAppear {
            normalizeSelection()
            requestInitialFocus()
        }
        .onChange(of: availableOptions.map(\.id)) { _, _ in normalizeSelection() }
        .task(id: selectedOptionId + "|" + (approval.preparationRevision ?? "")) {
            if approval.requiresGenerationPackage == true, let selectedOption { onPrepare(selectedOption) }
        }
        .task(id: editor.workingRoot) {
            budgetStopIsSet = GenerationBudgetGuard.hasBudgetStop(in: editor.workingRoot)
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerKeysChanged)) { _ in
            onRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelCatalogChanged)) { _ in
            onRefresh()
        }
        .id(approval.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approve spend")
    }

    private var decisionBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            summary
            if let requirement = approval.modelRequirement { requirementNotice(requirement) }
            if availableOptions.count > 1 || (selectedOption == nil && !availableOptions.isEmpty) {
                selectionControls
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
            if !availableOptions.isEmpty {
                Text("Only connected models compatible with this request are shown.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
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

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "creditcard")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Accent.primary)
            Text("Approve spend")
                .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: onDecline) {
                Image(systemName: "xmark")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .accessibilityLabel("Decline")
            .keyboardShortcut(.cancelAction)
            .help("Decline (Esc)")
            .disabled(isWorking)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(summaryTitle)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .help(selectedOption?.modelName ?? "")
            if let selectedOption {
                Text("via \(selectedOption.providerLabel) · \(CostEstimator.format(selectedOption.credits))")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if budgetStopIsSet, selectedCostIsUnknown {
                Text("Cost unknown. Not covered by the budget limit.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
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
                    selectedOptionId = sameModel ?? matching.first?.id ?? ""
                }
                approvalError = nil
            }
        )
    }

    private var footerRow: some View {
        WrapLayout(spacing: AppTheme.Spacing.sm, trailingLastItem: true) {
            Button("Decline") { onDecline() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(isWorking)
            Button(isWorking ? "Generating…" : "\(approval.actionLabel) · \(CostEstimator.format(selectedOption?.credits))") {
                guard let selectedOption else { return }
                approvalError = nil
                onApprove(selectedOption)
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .disabled(selectedOption == nil || isWorking
                || (approval.requiresGenerationPackage == true && selectedOption?.generationPackage == nil))
            .focused($focusedControl, equals: .approve)
            .accessibilityHint(
                selectedOption == nil ? "Choose an available provider and model" : ""
            )
        }
    }

    private func requestInitialFocus() {
        let target: SpendApprovalFocusTarget = if availableProviders.count > 1 {
            .provider
        } else if modelOptions.count > 1 || selectedOption == nil {
            .model
        } else {
            .approve
        }
        Task { @MainActor in
            await Task.yield()
            focusedControl = target
        }
    }

    private func normalizeSelection() {
        guard !availableOptions.contains(where: { $0.id == selectedOptionId }) else { return }
        if let requirement = approval.modelRequirement {
            selectedOptionId = availableOptions.first { $0.modelId == requirement.modelId }?.id ?? ""
        } else {
            selectedOptionId = availableOptions.first?.id ?? ""
        }
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
