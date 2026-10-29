import SwiftUI

struct PluginRemovalSheet: View {
    let installedVersion: InstalledPluginVersion
    let presentation: PluginRemovalPresentation
    let isRemoving: Bool
    let error: String?
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            Text("Remove \(installedVersion.displayName) \(installedVersion.version)?")
                .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
            Text(presentation.removalMessage)
                .reviewAcceptanceProbe("settings.pack.removal.message", text: presentation.removalMessage)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", action: onCancel)
                    .reviewAcceptanceProbe("settings.pack.removal.cancel")
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRemoving)
                Spacer()
                Button(installedVersion.isResident ? "Remove and Restart" : "Remove",
                       role: .destructive, action: onRemove)
                    .reviewAcceptanceProbe("settings.pack.removal.confirm")
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(isRemoving || !presentation.canRemove)
                if isRemoving { ProgressView().controlSize(.small) }
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.xlXxl)
        .frame(width: AppTheme.ComponentSize.formatSheetWidth)
        .interactiveDismissDisabled(isRemoving)
    }
}
