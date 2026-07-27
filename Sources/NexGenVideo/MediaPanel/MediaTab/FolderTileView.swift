import SwiftUI

struct FolderTileView: View {
    let folder: MediaFolder
    let isSelected: Bool
    let isDropHover: Bool
    let childCount: Int
    @Binding var isRenaming: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void
    let shouldAutoFocus: Bool
    let onAutoFocusConsumed: () -> Void

    @State private var renameDraft: String = ""
    @FocusState private var isRenameFieldFocused: Bool
    @State private var lastClickTime: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.subtle))
                Image(systemName: "folder.fill")
                    .font(.system(size: AppTheme.FontSize.display, weight: AppTheme.FontWeight.light))
                    .foregroundStyle(AppTheme.Accent.primary.opacity(AppTheme.Opacity.emphasis))
                if childCount > 0 {
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(childCount)")
                                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                                .monospacedDigit()
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xxs)
                                .background(.ultraThinMaterial, in: .capsule)
                                .padding(AppTheme.Spacing.xs)
                        }
                        Spacer()
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        borderColor,
                        lineWidth: borderWidth
                    )
            )
            .contentShape(Rectangle())

            ZStack(alignment: .leading) {
                if isRenaming {
                    TextField("Folder", text: $renameDraft)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .focused($isRenameFieldFocused)
                        .onSubmit { commit() }
                        .onChange(of: isRenameFieldFocused) { _, focused in
                            if !focused { commit() }
                        }
                        .onExitCommand { onCancelRename() }
                } else {
                    Text(folder.name)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isRenaming ? AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint) : AppTheme.Background.clearColor)
            )
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { handleClick() }
        .contextMenu { contextMenuItems }
        .onAppear {
            if shouldAutoFocus {
                renameDraft = folder.name
                isRenameFieldFocused = true
                onAutoFocusConsumed()
            }
        }
        .onChange(of: isRenaming) { _, newValue in
            if newValue {
                renameDraft = folder.name
                DispatchQueue.main.async { isRenameFieldFocused = true }
            }
        }
    }

    private var borderColor: Color {
        if isDropHover { return AppTheme.Accent.primary.opacity(AppTheme.Opacity.prominent) }
        if isSelected { return AppTheme.Accent.primary }
        return AppTheme.Background.clearColor
    }

    private var borderWidth: CGFloat {
        if isDropHover { return AppTheme.BorderWidth.thick }
        if isSelected { return AppTheme.BorderWidth.thick }
        return 0
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Open") { onOpen() }
        Button("Rename") { beginRename() }
        Divider() // app-theme: native-menu-divider
        Button("Delete", role: .destructive) { onDelete() }
    }

    private func beginRename() {
        renameDraft = folder.name
        isRenaming = true
    }

    private func handleClick() {
        let now = Date()
        if let last = lastClickTime, now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
            onOpen()
            lastClickTime = nil
        } else {
            onTap()
            lastClickTime = now
        }
    }

    private func commit() {
        guard isRenaming else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == folder.name {
            onCancelRename()
        } else {
            onCommitRename(trimmed)
        }
    }
}
