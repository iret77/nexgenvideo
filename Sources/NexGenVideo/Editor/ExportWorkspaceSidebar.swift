import SwiftUI

struct ExportWorkspaceSidebar: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            Text("Export")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, AppTheme.Spacing.md)
                .panelHeaderBar()

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Image(systemName: "square.and.arrow.up")
                    .interfaceFont(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(editor.projectPalette.accent)
                    .accessibilityHidden(true)
                Text("Prepare the current film for delivery.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Export…") {
                    editor.showExportDialog = true
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .help("Open export settings")
                .accessibilityLabel("Open export settings")
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: AppTheme.Spacing.none)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
