import SwiftUI

struct ChatHistoryCue {
    let symbol: String
    let color: Color
    let label: String
}

struct ChatHistoryList: View {
    let sessions: [ChatSession]
    let currentId: UUID?
    let cuesBySessionID: [UUID: ChatHistoryCue]
    let canSwitch: Bool
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void

    @State private var query = ""
    @State private var pendingDeletion: ChatSession?

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            if sessions.isEmpty {
                Text("No conversations yet")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(AppTheme.Spacing.md)
            } else {
                searchField
                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: AppTheme.BorderWidth.hairline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                        ForEach(filteredSessions) { session in
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
        .confirmationDialog(
            "Delete conversation?",
            isPresented: deletionIsPresented,
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button("Delete “\(pendingDeletion.title)”", role: .destructive) {
                    onDelete(pendingDeletion.id)
                    self.pendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This permanently removes the selected conversation from history.")
        }
    }

    private var filteredSessions: [ChatSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    private var deletionIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search conversations", text: $query)
                .textFieldStyle(.plain)
                .interfaceFont(size: AppTheme.Typography.ui)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private func row(session: ChatSession) -> some View {
        let isCurrent = session.id == currentId
        let cue = cuesBySessionID[session.id]
        let updated = Self.formatter.localizedString(for: session.updatedAt, relativeTo: Date())
        return HStack(spacing: AppTheme.Spacing.smMd) {
            Button { onSelect(session.id) } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(session.title)
                            .interfaceFont(size: AppTheme.Typography.ui, weight: isCurrent ? .semibold : .regular)
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text(updated)
                            if let cue {
                                Label(cue.label, systemImage: cue.symbol)
                                    .foregroundStyle(cue.color)
                            }
                        }
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    Spacer(minLength: AppTheme.Spacing.sm)
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .accessibilityLabel("Current")
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityLabel(
                [session.title, updated, isCurrent ? "Current" : nil, cue?.label]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
            .disabled(!canSwitch && !isCurrent)
            Button { pendingDeletion = session } label: {
                Image(systemName: "trash")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .buttonStyle(.plain)
            .disabled(!canSwitch)
            .accessibilityLabel("Delete \(session.title)")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(isCurrent ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted) : AppTheme.Background.clearColor)
    }
}
