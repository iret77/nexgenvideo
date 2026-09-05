import SwiftUI

enum HelpTab: String, CaseIterable, Identifiable {
    case shortcuts = "Shortcuts"
    case mcp = "MCP"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .shortcuts: "keyboard"
        case .mcp: "network"
        }
    }

    var subtitle: String {
        switch self {
        case .shortcuts:
            return "Review the keyboard controls available while editing."
        case .mcp:
            return "Connect external AI clients to the open NexGenVideo project."
        }
    }
}

struct HelpView: View {
    @State private var selectedTab: HelpTab

    init(initialTab: HelpTab = .shortcuts) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        SettingsWindowShell {
            sidebar
        } detail: {
            SettingsPage(title: selectedTab.rawValue, subtitle: selectedTab.subtitle) {
                switch selectedTab {
                case .shortcuts: ShortcutsPane()
                case .mcp: MCPInstructionsPane()
                }
            }
            .id(selectedTab)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ForEach(HelpTab.allCases) { tab in
                SidebarRowButton(
                    label: tab.rawValue,
                    systemImage: tab.icon,
                    isSelected: selectedTab == tab,
                    action: { selectedTab = tab }
                )
            }
            Spacer(minLength: AppTheme.Spacing.none)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.md)
    }
}

@MainActor
final class HelpWindowController: NSWindowController {
    static let shared = HelpWindowController()

    private var hosting: NSHostingController<AnyView>?

    private init() {
        let initialView = HelpView().interfaceStyle()
        let hosting = NSHostingController(rootView: AnyView(initialView))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(AppTheme.Window.settingsDefault)
        window.minSize = AppTheme.Window.settingsMin
        window.title = "Help"
        window.setFrameAutosaveName("NexGenVideoHelp-v2")
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

    func show(tab: HelpTab = .shortcuts) {
        hosting?.rootView = AnyView(
            HelpView(initialTab: tab)
                .id(UUID())
                .interfaceStyle()
        )
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    HelpView()
}
