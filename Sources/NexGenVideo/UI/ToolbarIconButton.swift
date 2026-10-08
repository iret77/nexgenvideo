import SwiftUI

struct ToolbarIconButtonStyle: ButtonStyle {
    var isSelected = false
    var hasLabel = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, isSelected: isSelected, hasLabel: hasLabel)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let hasLabel: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? AppTheme.Text.secondaryColor : AppTheme.Text.disabledControlColor)
                .padding(.horizontal, hasLabel ? AppTheme.Spacing.sm : AppTheme.Spacing.none)
                .frame(width: hasLabel ? nil : AppTheme.Control.iconTarget, height: AppTheme.Control.iconTarget)
                .hoverHighlight(isActive: isEnabled && isSelected)
                .opacity(isEnabled
                    ? (configuration.isPressed ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
                    : AppTheme.Opacity.disabledControl)
        }
    }
}
