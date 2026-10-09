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
            .interfaceControlHeight(AppTheme.Control.regularHeight)

        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppTheme.Text.primaryColor)
            .hoverHighlight(isActive: isEnabled && isSelected)
            .opacity(isEnabled
                ? (configuration.isPressed ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
                : AppTheme.Opacity.disabledControl)
    }
}
