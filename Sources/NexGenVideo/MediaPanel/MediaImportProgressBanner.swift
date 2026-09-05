import SwiftUI

struct MediaImportProgressBanner: View {
    @Environment(EditorViewModel.self) private var editor
    let progress: MediaImportProgress

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if progress.total > 0 {
                ProgressView(
                    value: Double(progress.completed),
                    total: Double(progress.total)
                )
                .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Importing media")
                    .interfaceFont(
                        size: AppTheme.Typography.ui,
                        weight: AppTheme.FontWeight.semibold
                    )
                if let name = progress.currentName {
                    Text(name)
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            Button("Cancel") { editor.cancelMediaImport() }
                .buttonStyle(.capsule(.secondary, size: .small))
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Background.raisedColor)
    }
}
