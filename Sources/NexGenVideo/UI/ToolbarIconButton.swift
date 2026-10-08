import SwiftUI

struct ToolbarIconButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, isSelected: isSelected)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? AppTheme.Text.secondaryColor : AppTheme.Text.disabledControlColor)
                .frame(width: AppTheme.Control.iconTarget, height: AppTheme.Control.iconTarget)
                .hoverHighlight(isActive: isEnabled && isSelected)
                .opacity(isEnabled
                    ? (configuration.isPressed ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
                    : AppTheme.Opacity.disabled)
        }
    }
}
