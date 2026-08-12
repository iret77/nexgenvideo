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

        var body: some View {
            configuration.label
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
            guard isEnabled else { return AppTheme.Text.mutedColor }
            switch variant {
            case .neutral: return AppTheme.Text.secondaryColor
            case .pack: return AppTheme.Accent.pack
            case .approval: return AppTheme.Accent.timecodeColor
            }
        }

        private var background: Color {
            guard isEnabled else { return AppTheme.Background.raisedColor }
            switch variant {
            case .neutral: return AppTheme.Background.clearColor
            case .pack: return AppTheme.Accent.pack.opacity(AppTheme.Opacity.faint)
            case .approval: return AppTheme.Accent.timecodeColor.opacity(AppTheme.Opacity.faint)
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
