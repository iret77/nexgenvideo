import SwiftUI

/// The one canonical horizontal sub-tab bar (text label + active underline, optional raised
/// background). Used by the Inspector's clip/asset tabs, the Media panel, and the Project cockpit —
/// one component, one behavior, rendered wherever sub-tabs are needed (docs/UI_UX_CONCEPT.md §2.1).
/// Second-level navigation: type sits one step below the sidebar's Level-1 tabs, and by default the
/// bar lies flat on the surface — a panel gets exactly one raised band, at its very top.
struct SegmentedTabBar: View {
    let titles: [String]
    let selected: String?
    var raisedBackground: Bool = false
    /// Titles rendered with the AI accent gradient — declared by the caller, never inferred here.
    var accentedTitles: Set<String> = []
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ForEach(titles, id: \.self) { title in
                let isActive = selected == title
                let isAccented = accentedTitles.contains(title)
                let foreground: AnyShapeStyle = isAccented
                    ? AnyShapeStyle(AppTheme.aiGradient.opacity(isActive ? 1 : 0.6))
                    : AnyShapeStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                Button {
                    onSelect(title)
                } label: {
                    VStack(spacing: AppTheme.Spacing.xs) {
                        Text(title)
                            .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? .medium : .regular))
                            .foregroundStyle(foreground)
                        Rectangle()
                            .fill(isActive ? foreground : AnyShapeStyle(Color.clear))
                            .frame(height: AppTheme.BorderWidth.medium)
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.top, AppTheme.Spacing.xs)
        .background(raisedBackground ? AppTheme.Background.raisedColor : Color.clear)
        .overlay(alignment: .bottom) {
            if raisedBackground {
                Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.thin)
            }
        }
    }
}
