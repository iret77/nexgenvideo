import SwiftUI

/// Adds a subtle rounded-rect background that appears on hover and expands the
/// hit area to the framed rect (via `contentShape`). Use on small icon buttons
/// so users can see what's clickable and land on it without aiming at a tiny
/// glyph.
///
/// Apply after the frame has been set on the label:
///
///     Image(systemName: "xmark")
///         .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
///         .hoverHighlight()
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = AppTheme.Radius.sm
    var isActive: Bool = false

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.projectPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { isHovered = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: isActive)
    }

    private var fill: Color {
        guard isEnabled else { return AppTheme.Background.clearColor }
        return switch (isActive, isHovered) {
        case (true, true): palette.accent.opacity(AppTheme.Opacity.muted)
        case (true, false): palette.accent.opacity(AppTheme.Opacity.soft)
        case (false, true): AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint)
        case (false, false): AppTheme.Background.clearColor
        }
    }
}

extension View {
    func hoverHighlight(
        cornerRadius: CGFloat = AppTheme.Radius.sm,
        isActive: Bool = false
    ) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isActive: isActive))
    }
}
