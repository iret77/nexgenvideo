import SwiftUI

/// Surfaces the scope a prose invocation resolves against ("this" = what, exactly) — any prose
/// invocation must show its scope (docs/UI_UX_CONCEPT.md §2.2/§4). Quiet by design: tertiary text,
/// no animation — it's grounding context, not a control.
struct ScopeChip: View {
    let text: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "viewfinder")
                .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
            Text(text)
                .font(.system(size: AppTheme.FontSize.xs))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(Capsule(style: .continuous).fill(AppTheme.Background.raisedColor))
        .overlay(Capsule(style: .continuous).strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
    }
}
