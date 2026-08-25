import SwiftUI

struct AgentLiveStatus: Equatable {
    enum State: Equatable {
        case working
        case streaming
        case waiting
        case failed
        case ready
        case unavailable
    }

    let state: State
    let title: String
    let detail: String
}

struct AgentLiveStatusView: View {
    let status: AgentLiveStatus

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.hairline)
            HStack(spacing: AppTheme.Spacing.smMd) {
                statusIcon
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(status.title)
                        .font(.system(
                            size: AppTheme.FontSize.xs,
                            weight: AppTheme.FontWeight.semibold
                        ))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    Text(status.detail)
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: AppTheme.Spacing.sm)
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .frame(maxWidth: AppTheme.Layout.chatColumnMax)
        .frame(maxWidth: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.title). \(status.detail)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status.state {
        case .working:
            ProgressView()
                .controlSize(.mini)
        case .streaming:
            Image(systemName: "ellipsis")
                .font(.system(
                    size: AppTheme.FontSize.xs,
                    weight: AppTheme.FontWeight.semibold
                ))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        case .waiting:
            Image(systemName: "clock.fill")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.warningColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.errorColor)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.successColor)
        case .unavailable:
            Image(systemName: "gearshape.fill")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }

    private var titleColor: Color {
        switch status.state {
        case .failed: AppTheme.Status.errorColor
        case .waiting: AppTheme.Status.warningColor
        default: AppTheme.Text.secondaryColor
        }
    }
}
