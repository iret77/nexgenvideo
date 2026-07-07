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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AgentBlock) -> some View {
        switch block {
        case .headline(let text, let symbol):
            HStack(spacing: AppTheme.Spacing.sm) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
                Text(text)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
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
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                        Text(row.0)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .frame(width: AppTheme.ComponentSize.agentBlockLabelWidth, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(AppTheme.Spacing.mdLg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.md).fill(AppTheme.Background.raisedColor))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )

        case .callout(let tone, let text):
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Image(systemName: toneSymbol(tone))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(toneColor(tone))
                Text(text)
                    .font(.system(size: AppTheme.FontSize.xs))
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
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            Text(badge.label)
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(badge.value)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
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
        case .warn: return .orange
        case .success: return .green
        }
    }
}

/// Minimal wrapping row: subviews flow left-to-right and break onto new lines at the
/// proposed width (badge rows in narrow panels).
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in layout(proposal: proposal, subviews: subviews).origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            width = max(width, x + size.width)
            x += size.width + spacing
        }
        return (origins, CGSize(width: width, height: y + rowHeight))
    }
}
