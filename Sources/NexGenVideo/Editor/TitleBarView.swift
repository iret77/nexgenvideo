import AppKit
import SwiftUI

/// The document window's fixed chrome: panel visibility, project identity, workspaces, and format.
struct TitleBarView: View {
    @Environment(EditorViewModel.self) private var editor
    @Bindable private var packUpdates = PluginUpdateCenter.shared

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                panelButton(
                    systemName: "sidebar.left",
                    label: "Sidebar",
                    isVisible: editor.isSidebarPresented
                ) {
                    editor.toggleSidebarPresentation()
                }
                projectName
            }
            .padding(.leading, AppTheme.Layout.trafficLightInset)
            .frame(minWidth: AppTheme.Spacing.none, maxWidth: .infinity, alignment: .leading)
            .clipped()

            focusToggle
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            HStack(spacing: AppTheme.Spacing.sm) {
                formatStatus
                panelButton(
                    systemName: "sidebar.right",
                    label: "Inspector",
                    isVisible: editor.isInspectorPresented
                ) {
                    editor.toggleInspectorPresentation()
                }
            }
            .frame(minWidth: AppTheme.Spacing.none, maxWidth: .infinity, alignment: .trailing)
            .clipped()
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(minHeight: AppTheme.Layout.titleBarChromeHeight)
        .background(
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
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
        .task(id: editor.projectURL) { await editor.refreshEngineState() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Re-read on window activation so gate approvals / engine runs done elsewhere show up.
            Task { await editor.refreshEngineState() }
        }
    }

    private var projectName: some View {
        Text(editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
            .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: AppTheme.Layout.titleBarProjectNameMaxWidth, alignment: .leading)
            .accessibilityLabel("Project \(editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")")
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
                        .foregroundStyle(selected ? editor.projectPalette.onAccent : AppTheme.Text.tertiaryColor)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                .fill(selected ? editor.projectPalette.accent : AppTheme.Background.clearColor)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(focus.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .background {
                    if WorkspaceUIAcceptance.isRequested {
                        AppRelaunchClickProbe(
                            identifier: "editor.workspace.\(focus.rawValue)",
                            acceptanceState: selected
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.xxs)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.baseColor)
        }
    }

    private var activeProjectBinding: ProjectPackBinding? {
        guard case .bound(let binding) = ProjectPluginSettings.bindingResolution(
            projectURL: editor.workingRoot
        ) else { return nil }
        return binding
    }
    private var activePackAttention: PluginUpdateCenter.Attention? {
        packUpdates.attention(for: activeProjectBinding)
    }

    private var formatStatus: some View {
        let active = editor.activePluginName != nil
        return HStack(spacing: AppTheme.Spacing.xs) {
            Text("Format")
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.mutedColor)
                .fixedSize()
            Text(activePluginLabel)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(active ? editor.projectPalette.accent : AppTheme.Text.secondaryColor)
                .lineLimit(1)
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
        .frame(maxWidth: AppTheme.Layout.titleBarFormatStatusMaxWidth, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Format \(activePluginLabel)")
        .help("Project format. Change it in Production project settings.")
    }

    private var activePluginLabel: String {
        guard let active = editor.activePluginName else { return "Generic" }
        return InstalledPack.named(active)?.displayName ?? active
    }

    private func panelButton(
        systemName: String,
        label: String,
        isVisible: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(isVisible ? editor.projectPalette.accent : AppTheme.Text.mutedColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm, isActive: isVisible)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isVisible ? "Shown" : "Hidden")
        .accessibilityAddTraits(isVisible ? .isSelected : [])
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(
                    identifier: "editor.panel.\(label.lowercased())",
                    acceptanceState: isVisible
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .help("\(isVisible ? "Hide" : "Show") \(label.lowercased())")
    }
}
