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
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .frame(width: AppTheme.Spacing.lgXl)
                Text(label)
                    .font(.system(size: AppTheme.FontSize.md))
                Spacer(minLength: AppTheme.Spacing.none)
                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(trailingColor)
                        .help(trailingHelp)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm, isActive: isSelected)
        }
        .buttonStyle(.plain)
    }
}
