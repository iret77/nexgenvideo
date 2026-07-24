import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case agent
    case plugins
    case providers
    case models
    case storage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .agent: return "Agent"
        case .plugins: return "Format Packs"
        case .providers: return "Providers"
        case .storage: return "Storage"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "square.stack.3d.up"
        case .agent: return "paperplane"
        case .plugins: return "puzzlepiece.extension"
        case .providers: return "key.horizontal"
        case .storage: return "internaldrive"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "Choose how NexGenVideo communicates and shares diagnostics."
        case .agent:
            return "Configure the in-app agent, paid render approvals, and local automation."
        case .plugins:
            return "Manage installed workflow packs and apply available updates."
        case .providers:
            return "Connect the services that supply generation models."
        case .models:
            return "Choose which runnable models appear in generation tools."
        case .storage:
            return "Manage project locations, temporary files, and on-device search data."
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab
    @State private var pluginManager = PluginManager()

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.none) {
            SettingsSidebar(
                selectedTab: $selectedTab,
                visibleTabs: visibleTabs,
                pluginManager: pluginManager
            )
                .frame(width: AppTheme.ComponentSize.settingsSidebarWidth)

            SettingsDetail(tab: selectedTab, pluginManager: pluginManager)
                .id(selectedTab)  // fresh view tree per tab — stale layers ghosted through the material
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(AppTheme.Opacity.medium))
        }
        .frame(
            minWidth: AppTheme.Window.settingsMin.width,
            idealWidth: AppTheme.Window.settingsDefault.width,
            minHeight: AppTheme.Window.settingsMin.height,
            idealHeight: AppTheme.Window.settingsDefault.height
        )
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
        .onAppear {
            if !visibleTabs.contains(selectedTab) {
                selectedTab = visibleTabs.first ?? .general
            }
        }
        .task {
            await pluginManager.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginInstallationChanged)) { _ in
            pluginManager.reloadInstalled()
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab
    let visibleTabs: [SettingsTab]
    let pluginManager: PluginManager

    private var packAttention: PluginSettingsAttention? {
        PluginSettingsAttention.resolve(pluginManager.rows(activePluginName: nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            tabList
            Spacer(minLength: AppTheme.Spacing.none)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.surfaceColor)  // opaque: previous panes ghosted through the material
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ForEach(visibleTabs) { tab in
                let attention = tab == .plugins ? packAttention : nil
                SidebarRowButton(
                    label: tab.label,
                    systemImage: tab.systemImage,
                    isSelected: selectedTab == tab,
                    trailingSystemImage: attention?.systemImage,
                    trailingColor: attention?.color ?? AppTheme.Text.tertiaryColor,
                    trailingHelp: attention?.help ?? "",
                    action: { selectedTab = tab }
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.md)
    }
}

private struct SettingsDetail: View {
    let tab: SettingsTab
    let pluginManager: PluginManager

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(tab.label)
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(tab.subtitle)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.top, AppTheme.Spacing.xxl)
            .padding(.bottom, AppTheme.Spacing.lgXl)

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    switch tab {
                    case .general:
                        NotificationsPane()
                        PrivacyPane()
                    case .models:
                        ModelsPane()
                    case .agent:
                        AgentPane()
                    case .plugins:
                        PluginsPane(manager: pluginManager)
                    case .providers:
                        ProvidersPane()
                    case .storage:
                        StoragePane()
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xlXxl)
                .padding(.bottom, AppTheme.Spacing.xlXxl)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}

private extension PluginSettingsAttention {
    var systemImage: String {
        switch self {
        case .updateAvailable: return "arrow.clockwise.circle"
        case .restartRequired: return "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .updateAvailable: return AppTheme.Accent.primary
        case .restartRequired: return AppTheme.Status.warningColor
        }
    }

    var help: String {
        switch self {
        case .updateAvailable: return "A format pack update is available."
        case .restartRequired: return "Restart NexGenVideo to activate a format pack update."
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.raisedColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let accessory: Accessory

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: AppTheme.Spacing.lg)
            accessory
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(AppTheme.Border.subtleColor)
    }
}

enum SettingsTone {
    case neutral
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .neutral: return AppTheme.Text.tertiaryColor
        case .success: return AppTheme.Status.successColor
        case .warning: return AppTheme.Status.warningColor
        case .error: return AppTheme.Status.errorColor
        }
    }
}

struct SettingsStatusBadge: View {
    let text: String
    let tone: SettingsTone

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Circle()
                .fill(tone.color)
                .frame(
                    width: AppTheme.ComponentSize.statusDotDiameter,
                    height: AppTheme.ComponentSize.statusDotDiameter
                )
            Text(text)
        }
        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(Capsule().fill(tone.color.opacity(AppTheme.Opacity.faint)))
        .fixedSize()
    }
}

struct SettingsNotice: View {
    let text: String
    let systemImage: String
    let tone: SettingsTone

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: AppTheme.FontSize.sm))
        .foregroundStyle(tone.color)
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(AppTheme.Opacity.subtle))
    }
}

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, AppTheme.Spacing.xxs)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var hosting: NSHostingController<AnyView>?

    private init() {
        let initialView = SettingsView().tint(AppTheme.Accent.primary)
        let hosting = NSHostingController(rootView: AnyView(initialView))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(AppTheme.Window.settingsDefault)
        window.minSize = AppTheme.Window.settingsMin
        window.title = "Settings"
        window.setFrameAutosaveName("NexGenVideoSettings-v2")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(AppTheme.Opacity.settingsWindow)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        self.hosting = hosting
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: SettingsTab? = nil) {
        if let tab {
            hosting?.rootView = AnyView(
                SettingsView(initialTab: tab)
                    .id(UUID())
                    .tint(AppTheme.Accent.primary)
            )
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    SettingsView()
}
