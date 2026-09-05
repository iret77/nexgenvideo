import SwiftUI

struct SidebarRowButton: View {
    let label: String
    let systemImage: String
    var isSelected: Bool = false
    var trailingSystemImage: String? = nil
    var trailingColor: Color = AppTheme.Text.tertiaryColor
    var trailingHelp: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: systemImage)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .frame(width: AppTheme.Spacing.lgXl)
                Text(label)
                    .interfaceFont(size: AppTheme.Typography.ui)
                Spacer(minLength: AppTheme.Spacing.none)
                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(trailingColor)
                        .help(trailingHelp)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            .frame(minHeight: AppTheme.Control.regularHeight)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm, isActive: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
