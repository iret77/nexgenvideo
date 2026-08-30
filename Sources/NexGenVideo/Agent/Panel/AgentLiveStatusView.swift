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
    let canCancel: Bool
    let cancellationRequested: Bool

    init(
        state: State,
        title: String,
        detail: String,
        canCancel: Bool = false,
        cancellationRequested: Bool = false
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.canCancel = canCancel
        self.cancellationRequested = cancellationRequested
    }
}

struct AgentLiveStatusView: View {
    let status: AgentLiveStatus
    let onCancel: () -> Void

    init(status: AgentLiveStatus, onCancel: @escaping () -> Void = {}) {
        self.status = status
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.hairline)
            HStack(spacing: AppTheme.Spacing.smMd) {
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
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(status.title). \(status.detail)")
                Spacer(minLength: AppTheme.Spacing.sm)
                if status.canCancel {
                    Button(status.cancellationRequested ? "Cancelling…" : "Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.capsule(.secondary, size: .small))
                    .disabled(status.cancellationRequested)
                    .accessibilityLabel(
                        status.cancellationRequested
                            ? "Cancelling generation"
                            : "Cancel generation"
                    )
                }
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .frame(maxWidth: AppTheme.Layout.chatColumnMax)
        .frame(maxWidth: .infinity)
        .background(AppTheme.Background.surfaceColor)
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
