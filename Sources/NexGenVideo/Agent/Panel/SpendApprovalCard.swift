import SwiftUI

/// The user's final word on a paid agent render (Cost-Guard, M7). Docked in the composer exactly
/// where the generative dialog lives — never a modal — so the user approves the spend in context.
/// The agent's render tool-call is suspended until Approve or Decline; a cheaper model can be picked
/// first. Approve carries the chosen model id (the same one, or a swap).
struct SpendApprovalCard: View {
    let approval: SpendApproval
    let onApprove: (String) -> Void
    let onDecline: () -> Void

    @State private var selectedModelId: String = ""

    private var chosenCredits: Int? {
        if selectedModelId == approval.modelId { return approval.credits }
        return approval.alternatives.first { $0.modelId == selectedModelId }?.credits
    }

    private var chosenName: String {
        if selectedModelId == approval.modelId { return approval.modelName }
        return approval.alternatives.first { $0.modelId == selectedModelId }?.name ?? approval.modelName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            summary
            if !approval.alternatives.isEmpty { alternatives }
            footerRow
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium),
                              lineWidth: AppTheme.BorderWidth.thin)
        )
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .onAppear { if selectedModelId.isEmpty { selectedModelId = approval.modelId } }
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
            Text("\(approval.actionLabel) with \(chosenName)")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(providerLine)
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    private var providerLine: String {
        let provider = (selectedModelId == approval.modelId)
            ? approval.providerLabel
            : (approval.alternatives.first { $0.modelId == selectedModelId }?.providerLabel ?? approval.providerLabel)
        return "via \(provider) · \(CostEstimator.format(chosenCredits))"
    }

    private var alternatives: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("CHEAPER OPTIONS")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: AppTheme.Spacing.xs)],
                      alignment: .leading, spacing: AppTheme.Spacing.xs) {
                modelChip(id: approval.modelId, name: approval.modelName, credits: approval.credits)
                ForEach(approval.alternatives) { alt in
                    modelChip(id: alt.modelId, name: alt.name, credits: alt.credits)
                }
            }
        }
    }

    private func modelChip(id: String, name: String, credits: Int?) -> some View {
        let isOn = selectedModelId == id
        return Button { selectedModelId = id } label: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.micro) {
                Text(name)
                    .font(.system(size: AppTheme.FontSize.xs, weight: isOn ? .semibold : .regular))
                    .lineLimit(1)
                Text(CostEstimator.format(credits))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isOn ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(isOn
                    ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint)
                    : AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(
                    isOn ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                    lineWidth: AppTheme.BorderWidth.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    private var footerRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Decline") { onDecline() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
            Spacer()
            Button("\(approval.actionLabel) · \(CostEstimator.format(chosenCredits))") {
                onApprove(selectedModelId)
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .controlSize(.small)
        }
    }
}
