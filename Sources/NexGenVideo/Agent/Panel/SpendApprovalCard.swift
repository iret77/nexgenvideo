import SwiftUI

private enum SpendApprovalFocusTarget: Hashable {
    case provider
    case model
    case approve
    case prepare
}

struct SpendApprovalCard: View {
    let approval: SpendApproval
    let error: String?
    let isWorking: Bool
    let onApprove: (SpendOption) -> Void
    let onDecline: () -> Void
    let onRefresh: () -> Void
    let onPrepare: (SpendOption) -> Void
    let projectHome: URL?

    @State private var selectedOptionId: String
    @FocusState private var focusedControl: SpendApprovalFocusTarget?

    init(
        approval: SpendApproval,
        error: String? = nil,
        isWorking: Bool = false,
        onApprove: @escaping (SpendOption) -> Void,
        onDecline: @escaping () -> Void,
        onRefresh: @escaping () -> Void = {},
        onPrepare: @escaping (SpendOption) -> Void = { _ in },
        projectHome: URL? = nil
    ) {
        self.approval = approval
        self.error = error
        self.isWorking = isWorking
        self.onApprove = onApprove
        self.onDecline = onDecline
        self.onRefresh = onRefresh
        self.onPrepare = onPrepare
        self.projectHome = projectHome
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
        selectedOption?.target.provider ?? availableProviders.first
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
            footerRow.fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
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
            if availableOptions.count > 1 { selectionControls }
            if approval.requiresGenerationPackage == true {
                if let package = selectedOption?.generationPackage {
                    GenerationPackageReviewView(package: package, projectHome: projectHome)
                } else if selectedOption != nil {
                    Text(error == nil ? "Preparing request…" : "Request preparation required")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            if !availableOptions.isEmpty {
                Text("Only connected models compatible with this request are shown.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            if error != nil || !providerIssues.isEmpty {
                Text("Request needs attention. Review the selected provider and model.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                DisclosureGroup("Diagnostic details") {
                    if let error { Text(error).textSelection(.enabled) }
                    ForEach(providerIssues, id: \.self) { Text($0).textSelection(.enabled) }
                }
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            } else if availableOptions.isEmpty {
                Text("No valid provider and model combination is currently available.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "creditcard")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Accent.primary)
            Text("Approve spend")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: onDecline) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
            }
            .buttonStyle(InlineActionButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Decline (Esc)")
            .disabled(isWorking)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("\(approval.actionLabel) with \(selectedOption.map { displayName($0) } ?? "Unavailable model")")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .help(selectedOption?.modelName ?? "")
            if let selectedOption {
                Text(approval.requiresGenerationPackage == true || selectedOption.generationPackage != nil
                    ? String(localized: "via \(selectedOption.providerLabel)")
                    : "\(selectedOption.providerLabel) · \(CostEstimator.format(selectedOption.credits))")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
    }

    private var selectionControls: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("PROVIDER")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
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
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                NativeChoicePicker(
                    label: "Model",
                    options: modelOptions.map {
                        .init(id: $0.id, title: $0.modelName)
                    },
                    selection: $selectedOptionId
                )
                .disabled(isWorking || modelOptions.count < 2)
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
                selectedOptionId = matching.first { $0.modelId == currentModelId }?.id
                    ?? matching.first?.id
                    ?? ""
            }
        )
    }

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if showsPreparationRecovery {
                Text("Verified estimate required").font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.warningColor)
                Button("Prepare request again", action: prepareSelectionAgain)
                    .buttonStyle(InlineActionButtonStyle()).disabled(isWorking)
                    .focused($focusedControl, equals: .prepare)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.sm) { declineButton; Spacer(minLength: AppTheme.Spacing.sm); approveButton }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) { approveButton; declineButton }
            }
        }
    }

    private var declineButton: some View {
        Button("Decline", action: onDecline)
            .buttonStyle(.capsule(.secondary, size: .regular)).controlSize(.small).disabled(isWorking)
    }

    private var approveButton: some View {
        Button(approveLabel, action: approveSelection)
            .buttonStyle(.capsule(.prominent, size: .regular)).controlSize(.small)
            .disabled(!canApproveSelection).focused($focusedControl, equals: .approve)
            .accessibilityHint(canApproveSelection ? "" : "Prepare a verified estimate before approving")
    }

    private var approveLabel: String {
        if isWorking { return String(localized: "Generating…") }
        if let package = selectedOption?.generationPackage {
            guard let estimate = package.payload.estimate else { return approval.actionLabel }
            let amount = estimate.eurAmount.formatted(.number.precision(.fractionLength(2)))
            return "\(approval.actionLabel) · €\(amount)"
        }
        if approval.requiresGenerationPackage == true { return approval.actionLabel }
        return "\(approval.actionLabel) · \(CostEstimator.format(selectedOption?.credits))"
    }

    var canApproveSelection: Bool {
        guard let selectedOption, !isWorking else { return false }
        if let package = selectedOption.generationPackage { return package.payload.estimate != nil }
        return approval.requiresGenerationPackage != true
    }

    var showsPreparationRecovery: Bool {
        guard let selectedOption else { return false }
        if let package = selectedOption.generationPackage { return package.payload.estimate == nil }
        return approval.requiresGenerationPackage == true && error != nil
    }

    func approveSelection() {
        guard canApproveSelection, let selectedOption else { return }
        onApprove(selectedOption)
    }

    func prepareSelectionAgain() {
        guard showsPreparationRecovery, !isWorking, let selectedOption else { return }
        onPrepare(selectedOption)
    }

    private func requestInitialFocus() {
        let target: SpendApprovalFocusTarget = if availableProviders.count > 1 {
            .provider
        } else if modelOptions.count > 1 {
            .model
        } else if showsPreparationRecovery {
            .prepare
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
        selectedOptionId = availableOptions.first?.id ?? ""
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
