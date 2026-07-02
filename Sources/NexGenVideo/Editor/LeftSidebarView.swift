import SwiftUI

/// The single left sidebar. Consolidates the former separate Media column and Agent column into one
/// tabbed surface — `Media / Project / Agent` — so the layout has one left edge, not three columns
/// (docs/UI_UX_CONCEPT.md §3). Each tab hosts the *canonical* panel, never a variant.
struct LeftSidebarView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Group {
                switch editor.leftSidebarTab {
                case .media: MediaPanelView()
                case .project: ProjectCockpitView()
                case .agent: AgentPanelView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(EditorViewModel.LeftSidebarTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .frame(maxWidth: .infinity)
        .background(AppTheme.Background.raisedColor)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private func tabButton(_ tab: EditorViewModel.LeftSidebarTab) -> some View {
        let selected = editor.leftSidebarTab == tab
        return Button {
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) { editor.leftSidebarTab = tab }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: tab.sfSymbol)
                    .font(.system(size: AppTheme.FontSize.sm, weight: selected ? .semibold : .medium))
                Text(tab.label)
                    .font(.system(size: AppTheme.FontSize.xs, weight: selected ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(selected ? AppTheme.Background.surfaceColor : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .buttonStyle(.plain)
    }
}
