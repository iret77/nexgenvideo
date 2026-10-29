import SwiftUI

struct ExportWorkspaceSidebar: View {
    var body: some View {
        ExportView(presentation: .workspaceSettings)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.Background.surfaceColor)
    }
}
