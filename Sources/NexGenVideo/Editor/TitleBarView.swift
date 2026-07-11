import AppKit
import SwiftUI

/// The window chrome row. The project window hides the system title and extends content beneath a
/// transparent titlebar (the FCP dark-room pattern — no standard toolbar chrome), and this view owns
/// that row: brand + project identity leading, the `Produce · Edit · Finish` stage toggle centered,
/// the active-plugin chip (click → plugin picker) and pipeline health trailing. Window-level facts
/// live here; panel navigation stays in the sidebar; object context stays in the Inspector
/// breadcrumb — three roles, three kinds of chrome (docs/UI_UX_CONCEPT.md §3).
struct TitleBarView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var showsPluginPicker = false

    var body: some View {
        ZStack {
            HStack(spacing: AppTheme.Spacing.md) {
                projectName
                Spacer(minLength: AppTheme.Spacing.md)
                pluginChip
                healthCapsule
            }
            focusToggle
        }
        .sheet(isPresented: $showsPluginPicker) {
            PluginPickerView(editor: editor)
        }
        .padding(.leading, Layout.trafficLightInset)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(height: Layout.titleBarChromeHeight)
        .background(
            // Double-click the bare titlebar to zoom the window (macOS convention). It's a
            // background layer, so the buttons on top take their clicks first — only empty
            // titlebar area double-clicks zoom. Ambient pack presence: a faint accent wash tints
            // the chrome when a format pack is active (generic project → neutral).
            ZStack {
                Rectangle().fill(AppTheme.Background.raisedColor)
                if editor.activePluginName != nil {
                    Rectangle().fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.subtle))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
        )
        .overlay(alignment: .bottom) {
            // The window's bottom chrome edge becomes an accent line when a pack is active — the
            // clearest, full-width "you're in this format" signal without recoloring everything.
            let packActive = editor.activePluginName != nil
            Rectangle()
                .fill(packActive ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : AppTheme.Border.primaryColor)
                .frame(height: packActive ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline)
        }
        .task(id: editor.projectURL) { await editor.refreshEngineState() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Re-read on window activation so gate approvals / engine runs done elsewhere show up.
            Task { await editor.refreshEngineState() }
        }
    }

    /// Quiet brand lockup: the wordmark muted and regular, the project name emphasized. Mac-tasteful
    /// (name is the loud element), never the Windows "App - Doc" style. Wordmark is one word.
    private var projectName: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("NexGenVideo")
                .font(.system(size: AppTheme.FontSize.xs, weight: .regular))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .fixedSize()
            Text(editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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

    /// Once production has started, the format is fixed — switching would strand the pipeline's
    /// artifacts (phases/bible/shotlist are format-specific). Generic counts as a started workflow too
    /// once its pipeline exists. Single source of truth: the same gate `setActivePlugin` enforces.
    private var formatLocked: Bool { !editor.canChangeFormat }

    /// The Format control. Before production starts it's a tappable picker (choose/change the format —
    /// generic ⇄ pack — safe, no artifacts yet). Once production starts it becomes a plain STATUS pill
    /// (no chevron, not tappable): the workspace shows the running format, but you can't switch it.
    @ViewBuilder
    private var pluginChip: some View {
        if formatLocked {
            chipBody(interactive: false)
                .help("Format is set for this project. It's chosen at the start — changing it mid-workflow would strand the pipeline.")
        } else {
            Button { showsPluginPicker = true } label: { chipBody(interactive: true) }
                .buttonStyle(.plain)
                .help(editor.activePluginName != nil
                      ? "Active format. Click to change — available until production starts."
                      : "Generic workflow. Click to pick a format (until production starts).")
        }
    }

    private func chipBody(interactive: Bool) -> some View {
        let active = editor.activePluginName != nil
        return HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(active ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
            Text("Format")
                .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .fixedSize()
            Text(activePluginLabel)
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(active ? AppTheme.Accent.primary : AppTheme.Text.secondaryColor)
                .lineLimit(1)
            // Chevron only when it's actually a picker; the locked status pill carries no affordance.
            if interactive {
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(
            Capsule().fill(active
                           ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint)
                           : Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            Capsule().strokeBorder(active
                                   ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.moderate)
                                   : Color.white.opacity(AppTheme.Opacity.faint),
                                   lineWidth: AppTheme.BorderWidth.hairline)
        )
        .contentShape(Capsule())
    }

    private var activePluginLabel: String {
        guard let active = editor.activePluginName else { return "Generic" }
        return InstalledPack.named(active)?.displayName ?? active
    }

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
        if let next = state.nextPhaseName { return "\(Self.phaseLabel(next)) · \(approved)/\(total)" }
        return "\(approved)/\(total)"
    }

    /// User-facing label for a phase id. Delegates to `PhaseDisplay`, the single source of truth for
    /// phase wording across surfaces (title bar, pipeline panel).
    static func phaseLabel(_ id: String) -> String {
        PhaseDisplay.label(id)
    }
}
