import SwiftUI

/// Native rendering of a `show_blocks` call (#135) — the transcript's "Word template":
/// headlines, badge rows, key-value boxes, callouts, and prose, in AppTheme language.
struct AgentBlocksView: View {
    let blocks: [AgentBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(
                    AppTheme.Border.subtleColor,
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Structured result")
    }

    @ViewBuilder
    private func blockView(_ block: AgentBlock) -> some View {
        switch block {
        case .headline(let text, let symbol):
            HStack(spacing: AppTheme.Spacing.sm) {
                if let symbol {
                    Image(systemName: symbol)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Accent.primary)
                }
                Text(text)
                    .interfaceFont(size: AppTheme.Typography.reading, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
            .padding(.top, AppTheme.Spacing.xs)

        case .text(let body):
            MarkdownText(text: body)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .status(let badges):
            WrapLayout(spacing: AppTheme.Spacing.sm) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    badgeView(badge)
                }
            }

        case .keyValue(let title, let rows):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if let title {
                    Text(title.uppercased())
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                        Text(row.0)
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .frame(width: AppTheme.ComponentSize.agentBlockLabelWidth, alignment: .leading)
                        Text(row.1)
                            .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: AppTheme.Spacing.none)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .callout(let tone, let text):
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Image(systemName: toneSymbol(tone))
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(toneColor(tone))
                Text(text)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(toneColor(tone).opacity(AppTheme.Opacity.subtle))
            )
        }
    }

    private func badgeView(_ badge: AgentBlock.Badge) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let symbol = badge.symbol {
                Image(systemName: symbol)
                    .interfaceFont(size: AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            Text(badge.label)
                .interfaceFont(size: AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(badge.value)
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(Capsule().fill(AppTheme.Background.raisedColor))
        .overlay(Capsule().strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
    }

    private func toneSymbol(_ tone: AgentBlock.CalloutTone) -> String {
        switch tone {
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private func toneColor(_ tone: AgentBlock.CalloutTone) -> Color {
        switch tone {
        case .info: return AppTheme.Accent.primary
        case .warn: return AppTheme.Status.warningColor
        case .success: return AppTheme.Status.successColor
        }
    }
}
