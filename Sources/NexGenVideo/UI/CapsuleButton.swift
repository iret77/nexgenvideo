import SwiftUI

struct CapsuleButtonStyle: ButtonStyle {
    enum Variant { case secondary, prominent }
    enum Size { case small, regular }

    var variant: Variant = .secondary
    var size: Size = .small
    var fill: AnyShapeStyle?

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, variant: variant, size: size, fill: fill)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let variant: Variant
        let size: Size
        let fill: AnyShapeStyle?
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        private var fontSize: CGFloat { size == .small ? AppTheme.FontSize.xs : AppTheme.FontSize.smMd }
        private var hPadding: CGFloat { size == .small ? AppTheme.Spacing.smMd : AppTheme.Spacing.lgXl }
        private var vPadding: CGFloat { size == .small ? AppTheme.Spacing.xs : AppTheme.Spacing.smMd }

        private var foreground: AnyShapeStyle {
            guard isEnabled else { return AnyShapeStyle(AppTheme.Text.mutedColor) }
            return variant == .prominent
                ? AnyShapeStyle(AppTheme.Background.baseColor)
                : AnyShapeStyle(AppTheme.Text.secondaryColor)
        }
        private var background: AnyShapeStyle {
            guard isEnabled else { return AnyShapeStyle(AppTheme.Background.prominentColor) }
            return variant == .prominent
                ? (fill ?? AnyShapeStyle(AppTheme.Accent.primary))
                : AnyShapeStyle(AppTheme.Background.prominentColor)
        }

        var body: some View {
            configuration.label
                .font(.system(size: fontSize, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, hPadding)
                .padding(.vertical, vPadding)
                .background(Capsule(style: .continuous).fill(background))
                .overlay(
                    Capsule(style: .continuous).fill(
                        AppTheme.Text.primaryColor.opacity(
                            hovered && isEnabled ? AppTheme.Opacity.faint : AppTheme.Opacity.transparent
                        )
                    )
                )
                .opacity(opacity)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovered = isEnabled && $0 }
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: hovered)
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: isEnabled)
        }

        private var opacity: Double {
            guard isEnabled else { return AppTheme.Opacity.disabled }
            return configuration.isPressed ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsule: CapsuleButtonStyle { .init() }
    static func capsule(_ variant: CapsuleButtonStyle.Variant = .secondary,
                        size: CapsuleButtonStyle.Size = .small,
                        fill: AnyShapeStyle? = nil) -> CapsuleButtonStyle {
        .init(variant: variant, size: size, fill: fill)
    }
}
