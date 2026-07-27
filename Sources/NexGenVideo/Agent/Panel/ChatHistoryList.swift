import SwiftUI

struct ChatHistoryList: View {
    let sessions: [ChatSession]
    let currentId: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            if sessions.isEmpty {
                Text("No conversations yet")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(AppTheme.Spacing.md)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                        ForEach(sessions) { session in
                            row(session: session)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: AppTheme.ComponentSize.chatHistoryMaxHeight)
            }
        }
        .frame(width: AppTheme.ComponentSize.chatHistoryWidth)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
    }

    private func row(session: ChatSession) -> some View {
        let isCurrent = session.id == currentId
        return HStack(spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(session.title)
                        .font(.system(size: AppTheme.FontSize.xs, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                }
                Text(Self.formatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            if !isCurrent {
                Button { onDelete(session.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Delete from history")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(isCurrent ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted) : AppTheme.Background.clearColor)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(session.id) }
    }
}
