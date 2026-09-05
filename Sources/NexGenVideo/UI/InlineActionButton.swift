import SwiftUI

struct InlineActionButtonStyle: ButtonStyle {
    enum Variant { case neutral, pack, approval }

    var variant: Variant = .neutral

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, variant: variant)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let variant: Variant
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.projectPalette) private var palette
        @Environment(\.interfaceScale) private var textScale

        var body: some View {
            configuration.label
                .interfaceFont(size: AppTheme.Typography.action, weight: AppTheme.FontWeight.medium)
                .frame(minHeight: AppTheme.Control.compactHeight * textScale)
                .foregroundStyle(foreground)
                .padding(.horizontal, hasBackground ? AppTheme.Spacing.xs : AppTheme.Spacing.none)
                .padding(.vertical, hasBackground ? AppTheme.Spacing.xxs : AppTheme.Spacing.none)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(background)
                )
                .opacity(opacity)
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
        }

        private var hasBackground: Bool { variant != .neutral }

        private var foreground: Color {
            guard isEnabled else { return AppTheme.Text.disabledControlColor }
            switch variant {
            case .neutral: return AppTheme.Text.secondaryColor
            case .pack: return palette.accent
            case .approval: return palette.accent
            }
        }

        private var background: Color {
            guard isEnabled else { return AppTheme.Background.raisedColor }
            switch variant {
            case .neutral: return AppTheme.Background.clearColor
            case .pack: return palette.accent.opacity(AppTheme.Opacity.faint)
            case .approval: return palette.accent.opacity(AppTheme.Opacity.faint)
            }
        }

        private var opacity: Double {
            guard isEnabled else { return AppTheme.Opacity.disabled }
            return configuration.isPressed ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque
        }
    }
}

extension ButtonStyle where Self == InlineActionButtonStyle {
    static func inlineAction(_ variant: InlineActionButtonStyle.Variant = .neutral)
        -> InlineActionButtonStyle {
        .init(variant: variant)
    }
}
