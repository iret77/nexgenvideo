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
        SettingsWindowShell {
            SettingsSidebar(
                selectedTab: $selectedTab,
                visibleTabs: visibleTabs,
                pluginManager: pluginManager
            )
        } detail: {
            SettingsDetail(tab: selectedTab, pluginManager: pluginManager)
                .id(selectedTab)
        }
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

struct SettingsWindowShell<Sidebar: View, Detail: View>: View {
    let sidebar: Sidebar
    let detail: Detail

    init(
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.none) {
            sidebar
                .frame(width: AppTheme.ComponentSize.settingsSidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(AppTheme.Background.surfaceColor)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.medium))
        }
        .frame(
            minWidth: AppTheme.Window.settingsMin.width,
            idealWidth: AppTheme.Window.settingsDefault.width,
            minHeight: AppTheme.Window.settingsMin.height,
            idealHeight: AppTheme.Window.settingsDefault.height
        )
        .background(AppTheme.Background.surfaceColor)

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
        SettingsPage(title: tab.label, subtitle: tab.subtitle) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                switch tab {
                case .general:
                    AppearancePane()
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
        }
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(subtitle)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.top, AppTheme.Spacing.xxl)
            .padding(.bottom, AppTheme.Spacing.lgXl)

            ScrollView {
                content
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let subtitle {
                    Text(subtitle)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}

struct SettingsCard<Content: View>: View {
    let minHeight: CGFloat?
    let content: Content

    init(minHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            content
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
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
    @Environment(\.interfaceScale) private var textScale
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
        ViewThatFits(in: .horizontal) {
            row(horizontal: true).fixedSize(horizontal: true, vertical: false)
            row(horizontal: false)
        }
        .padding(AppTheme.Spacing.lgXl)
    }

    private func row(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(alignment: .top, spacing: AppTheme.Spacing.lgXl))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Spacing.mdLg))
        return layout {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let subtitle {
                    Text(subtitle)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if horizontal { Spacer(minLength: AppTheme.Spacing.lg) }
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsDivider: View {
    var body: some View {
        AppDivider()
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
        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
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
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
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
                .accessibilityLabel(title)
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
        let initialView = SettingsView().interfaceStyle()
        let hosting = NSHostingController(rootView: AnyView(initialView.interfaceStyle()))
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
                    .interfaceStyle()
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
