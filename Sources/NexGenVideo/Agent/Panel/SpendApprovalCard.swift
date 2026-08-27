import SwiftUI

struct SpendApprovalCard: View {
    let approval: SpendApproval
    let onApprove: (SpendOption) -> String?
    let onDecline: () -> Void
    let onRefresh: () -> Void

    @State private var selectedOptionId: String
    @State private var approvalError: String?
    @State private var providerKeyRevision = 0

    init(
        approval: SpendApproval,
        onApprove: @escaping (SpendOption) -> String?,
        onDecline: @escaping () -> Void,
        onRefresh: @escaping () -> Void = {}
    ) {
        self.approval = approval
        self.onApprove = onApprove
        self.onDecline = onDecline
        self.onRefresh = onRefresh
        _selectedOptionId = State(initialValue: approval.recommendedOptionId)
    }

    private var availableOptions: [SpendOption] {
        _ = providerKeyRevision
        return approval.options.filter { $0.isCurrentlyAvailable }
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

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            summary
            if availableOptions.count > 1 { selectionControls }
            if !availableOptions.isEmpty {
                Text("Only connected models compatible with this request are shown.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            if let approvalError {
                Text(approvalError)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            } else if availableOptions.isEmpty {
                Text("No valid provider and model combination is currently available.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
            footerRow
        }
        .padding(AppTheme.Spacing.md)
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
        .onAppear { normalizeSelection() }
        .onChange(of: availableOptions.map(\.id)) { _, _ in normalizeSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .providerKeysChanged)) { _ in
            onRefresh()
            providerKeyRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelCatalogChanged)) { _ in
            onRefresh()
            providerKeyRevision += 1
        }
        .id(approval.id)
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
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Decline (Esc)")
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
                Text("via \(selectedOption.providerLabel) · \(CostEstimator.format(selectedOption.credits))")
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
                Picker("Provider", selection: providerSelection) {
                    ForEach(availableProviders) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(availableProviders.count < 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("MODEL")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Picker("Model", selection: $selectedOptionId) {
                    ForEach(modelOptions) { option in
                        Text(displayName(option))
                            .tag(option.id)
                            .help(option.modelName)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(modelOptions.count < 2)
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
                approvalError = nil
            }
        )
    }

    private var footerRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Decline") { onDecline() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
            Spacer()
            Button("\(approval.actionLabel) · \(CostEstimator.format(selectedOption?.credits))") {
                guard let selectedOption else { return }
                approvalError = onApprove(selectedOption)
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .controlSize(.small)
            .disabled(selectedOption == nil)
        }
    }

    private func normalizeSelection() {
        guard !availableOptions.contains(where: { $0.id == selectedOptionId }) else { return }
        selectedOptionId = availableOptions.first?.id ?? ""
        approvalError = nil
    }

    private func displayName(_ option: SpendOption) -> String {
        AgentDialog.limitedChoiceDisplayLabel(option.modelName)
    }
}
