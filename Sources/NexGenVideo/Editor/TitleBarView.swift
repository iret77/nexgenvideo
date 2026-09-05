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
    @Bindable private var packUpdates = PluginUpdateCenter.shared
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
        .padding(.leading, AppTheme.Layout.trafficLightInset)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(minHeight: AppTheme.Layout.titleBarChromeHeight)
        .background(
            // Double-click the bare titlebar to zoom the window (macOS convention). It's a
            // background layer, so the buttons on top take their clicks first — only empty
            // titlebar area double-clicks zoom. Ambient pack presence: a faint accent wash tints
            // the chrome when a format pack is active (generic project → neutral).
            ZStack {
                Rectangle().fill(AppTheme.Background.raisedColor)
                if let accent = editor.activePackAccentColor {
                    Rectangle().fill(accent.opacity(AppTheme.Opacity.subtle))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
        )
        .overlay(alignment: .bottom) {
            // The window's bottom chrome edge becomes an accent line when a pack is active — the
            // clearest, full-width "you're in this format" signal without recoloring everything.
            let packAccent = editor.activePackAccentColor
            Rectangle()
                .fill(packAccent.map { $0.opacity(AppTheme.Opacity.strong) } ?? AppTheme.Border.primaryColor)
                .frame(height: packAccent != nil ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline)
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
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.regular)
                .foregroundStyle(AppTheme.Text.mutedColor)
                .fixedSize()
            Text(editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
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
                        .interfaceFont(size: AppTheme.Typography.ui, weight: selected ? .semibold : .regular)
                        .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                .fill(selected ? AppTheme.Background.surfaceColor : AppTheme.Background.clearColor)
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
    private var activeProjectBinding: ProjectPackBinding? {
        guard case .bound(let binding) = ProjectPluginSettings.bindingResolution(
            projectURL: editor.workingRoot
        ) else { return nil }
        return binding
    }
    private var activePackAttention: PluginUpdateCenter.Attention? {
        packUpdates.attention(for: activeProjectBinding)
    }

    /// The Format control. Before production starts it's a tappable picker (choose/change the format —
    /// generic ⇄ pack — safe, no artifacts yet). Once production starts it becomes a plain STATUS pill
    /// (no chevron, not tappable): the workspace shows the running format, but you can't switch it.
    @ViewBuilder
    private var pluginChip: some View {
        if formatLocked,
           activePackAttention != nil,
           editor.activePluginName != nil {
            Button {
                if activePackAttention == .restartRequired {
                    AppState.shared.upgradeActiveProjectPack()
                } else {
                    SettingsWindowController.shared.show(tab: .plugins)
                }
            } label: {
                chipBody(interactive: false)
            }
            .buttonStyle(.plain)
            .help(
                activePackAttention == .restartRequired
                    ? "Upgrade this project to the installed format-pack update."
                    : "Open Format Packs to install the available update."
            )
        } else if formatLocked {
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
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(active ? editor.projectPalette.accent : AppTheme.Text.tertiaryColor)
            Text("Format")
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.mutedColor)
                .fixedSize()
            Text(activePluginLabel)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(active ? editor.projectPalette.accent : AppTheme.Text.secondaryColor)
                .lineLimit(1)
            // Chevron only when it's actually a picker; the locked status pill carries no affordance.
            if interactive {
                Image(systemName: "chevron.down")
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            if let attention = activePackAttention {
                Image(systemName: attention == .restartRequired
                      ? "exclamationmark.circle.fill"
                      : "arrow.clockwise.circle")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(attention == .restartRequired
                                     ? AppTheme.Status.warningColor
                                     : editor.projectPalette.accent)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(
            Capsule().fill(active
                           ? editor.projectPalette.accent.opacity(AppTheme.Opacity.faint)
                           : AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            Capsule().strokeBorder(active
                                   ? editor.projectPalette.accent.opacity(AppTheme.Opacity.moderate)
                                   : AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint),
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
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(state.isComplete ? editor.projectPalette.accent : AppTheme.Text.tertiaryColor)
                    Text(healthText(state))
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                    if state.budgetEur > 0 {
                        Text(String(format: "€%.0f/%.0f", state.budgetSpentEur, state.budgetEur))
                            .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium).monospacedDigit()
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
