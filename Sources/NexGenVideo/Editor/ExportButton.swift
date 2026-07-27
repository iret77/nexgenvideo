import SwiftUI

struct ExportButton: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        Button(action: { editor.showExportDialog = true }) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "square.and.arrow.up")
                    .offset(y: -1)
                Text("Export")
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: AppTheme.IconSize.lg)
            .hoverHighlight()
            .help("Export (⌘E)")
        }
        .buttonStyle(.plain)
    }
}
