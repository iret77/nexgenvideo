import SwiftUI

/// The window chrome row. The project window hides the system title and extends content beneath a
/// transparent titlebar (the FCP dark-room pattern — no standard toolbar chrome), and this view owns
/// that row: project identity leading, the `Edit ↔ Produce` focus centered, pipeline health as a
/// compact capsule trailing (click → Project → Pipeline). Window-level facts live here; panel
/// navigation stays in the sidebar; object context stays in the Inspector breadcrumb — three roles,
/// three kinds of chrome (docs/UI_UX_CONCEPT.md §3).
struct TitleBarView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        ZStack {
            HStack(spacing: AppTheme.Spacing.md) {
                projectName
                Spacer(minLength: AppTheme.Spacing.md)
                healthCapsule
            }
            focusToggle
        }
        .padding(.leading, Layout.trafficLightInset)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(height: Layout.titleBarChromeHeight)
        .background(AppTheme.Background.raisedColor)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.hairline)
        }
        .task(id: editor.projectURL) { await editor.refreshEngineState() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Re-read on window activation so gate approvals / engine runs done elsewhere show up.
            Task { await editor.refreshEngineState() }
        }
    }

    private var projectName: some View {
        Text(editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: - Focus toggle (centered — the window-level mode switch)

    private var focusToggle: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            ForEach(EditorViewModel.WorkspaceFocus.allCases, id: \.self) { focus in
                let selected = editor.workspaceFocus == focus
                Button {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                        editor.setWorkspaceFocus(focus)
                    }
                } label: {
                    Text(focus.label)
                        .font(.system(size: AppTheme.FontSize.xs, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                .fill(selected ? AppTheme.Background.surfaceColor : Color.clear)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppTheme.Spacing.xxs)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.baseColor)
        }
    }

    // MARK: - Pipeline health capsule (absent when the project has no pipeline)

    @ViewBuilder
    private var healthCapsule: some View {
        if let state = editor.projectState {
            Button {
                editor.revealCockpit(.pipeline)
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: state.isComplete ? "checkmark.seal.fill" : "circle.dotted")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(state.isComplete ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
                    Text(healthText(state))
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                    if state.budgetEur > 0 {
                        Text(String(format: "€%.0f/%.0f", state.budgetSpentEur, state.budgetEur))
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium).monospacedDigit())
                            .foregroundStyle(state.budgetWarning ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background {
                    Capsule().fill(AppTheme.Background.baseColor)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Pipeline status — click to open")
        }
    }

    private func healthText(_ state: ProjectStateData) -> String {
        let approved = state.phases.filter(\.approved).count
        let total = state.phases.count
        if state.isComplete { return "Complete" }
        if let next = state.nextPhaseName { return "\(next.capitalized) · \(approved)/\(total)" }
        return "\(approved)/\(total)"
    }
}
