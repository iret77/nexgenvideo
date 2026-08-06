import SwiftUI

struct HomeView: View {
    private let columns = [
        GridItem(
            .adaptive(
                minimum: AppTheme.ComponentSize.projectCardWidth,
                maximum: AppTheme.ComponentSize.projectCardWidth
            ),
            spacing: AppTheme.Spacing.md,
            alignment: .leading
        )
    ]

    @Bindable private var changelog = ChangelogStore.shared
    @Bindable private var packUpdates = PluginUpdateCenter.shared
    @Bindable private var updater = Updater.shared
    @State private var showFormatSheet = false

    private var hasUpdateNotices: Bool {
        packUpdates.attention != nil || updater.updateAvailable
    }

    /// New project → choose a format first, unless no packs are installed (then generic, no needless
    /// one-option sheet).
    private func startNewProject() {
        if InstalledPack.all.isEmpty {
            AppState.shared.createNewProject()
        } else {
            showFormatSheet = true
        }
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.none) {
            HomeSidebar(onNewProject: startNewProject)
                .frame(width: AppTheme.ComponentSize.homeSidebarWidth)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.medium))
        }
        .frame(minWidth: AppTheme.Window.homeMin.width, minHeight: AppTheme.Window.homeMin.height)
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
        .sheet(isPresented: $showFormatSheet) {
            NewProjectFormatSheet { format in AppState.shared.createNewProject(format: format) }
        }
        .task { await VisualModelLoader.shared.prepare() }
        .onAppear { changelog.checkForWhatsNew() }
        .overlay(alignment: .bottomTrailing) {
            VersionTag()
                .padding(.trailing, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.smMd)
        }
        .overlay {
            if let entry = changelog.pending {
                UpdateOverlay(entry: entry, changelogURL: changelog.changelogURL) {
                    withAnimation { changelog.dismiss() }
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            header
            if hasUpdateNotices {
                HomeUpdateNotices(
                    packAttention: packUpdates.attention,
                    appUpdateAvailable: updater.updateAvailable,
                    appUpdateVersion: updater.updateVersion
                )
            }
            Text("My Projects")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.xlXxl)
                .padding(.bottom, AppTheme.Spacing.sm)
            projectGrid
        }
    }

    private var header: some View {
        WelcomeTitle()
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.top, AppTheme.Spacing.lg)
            .padding(
                .bottom,
                hasUpdateNotices
                    ? AppTheme.Spacing.lgXl
                    : AppTheme.Spacing.xxl
            )
    }

    private var projectGrid: some View {
        let entries = ProjectRegistry.shared.sortedEntries
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.xl) {
                if entries.isEmpty {
                    NewProjectCard(action: startNewProject)
                } else {
                    ForEach(entries) { entry in
                        ProjectCard(
                            entry: entry,
                            onOpen: { AppState.shared.openProject(at: $0) },
                            onRemove: { ProjectRegistry.shared.remove($0) }
                        )
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.xlXxl)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NewProjectCard: View {
    let action: () -> Void

    @State private var isHovered = false

    private let cardRadius: CGFloat = AppTheme.Radius.mdLg

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AppTheme.Background.placeholderColor
                .aspectRatio(5.0/4.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: AppTheme.Background.clearColor, location: 0),
                    .init(color: AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.scrim), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: AppTheme.ComponentSize.homeCardOverlayHeight)
            .allowsHitTesting(false)

            Text("Untitled")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.smMd)
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(
                    AppTheme.Text.primaryColor.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .shadow(isHovered ? AppTheme.Shadow.cardHover : AppTheme.Shadow.cardRest)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .padding(AppTheme.Spacing.xs)
        .animation(.spring(response: AppTheme.Anim.cardSpringResponse, dampingFraction: AppTheme.Anim.cardSpringDamping), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

/// Discreet corner version on the Home window. Hidden in bare `swift run` builds
/// (no Info.plist version); the packaged app always carries one.
private struct VersionTag: View {
    var body: some View {
        if let version = AppVersion.marketing {
            Text("Version \(version)")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .help(AppVersion.build.map { "Version \(version) (\($0))" } ?? "Version \(version)")
        }
    }
}

private struct WelcomeTitle: View {
    var body: some View {
        Text("Welcome to NexGenVideo")
            .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.light))
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.primaryColor)
    }
}

private struct HomeUpdateNotices: View {
    let packAttention: PluginUpdateCenter.Attention?
    let appUpdateAvailable: Bool
    let appUpdateVersion: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            noticeStack(layout: .horizontal)
            noticeStack(layout: .compact)
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.bottom, AppTheme.Spacing.xxl)
    }

    private func noticeStack(
        layout: HomeStatusNoticeLayout
    ) -> some View {
        VStack(spacing: AppTheme.Spacing.smMd) {
            if let packAttention {
                packNotice(packAttention, layout: layout)
            }
            if appUpdateAvailable {
                appNotice(layout: layout)
            }
        }
    }

    @ViewBuilder
    private func packNotice(
        _ attention: PluginUpdateCenter.Attention,
        layout: HomeStatusNoticeLayout
    ) -> some View {
        switch attention {
        case .restartRequired:
            HomeStatusNotice(
                title: "Restart to finish updating format packs",
                message: "The update is installed. Restart before creating a project with the updated format.",
                systemImage: "exclamationmark.circle.fill",
                tone: .warning,
                layout: layout
            ) {
                Button("Restart NexGenVideo") {
                    PluginUpdateCenter.shared.restartToApplyUpdates()
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.small)
                .accessibilityIdentifier("home.restart-format-packs")
                .help("Restart NexGenVideo to activate this update.")
            }
        case .updateAvailable:
            HomeStatusNotice(
                title: "Format pack update available",
                message: "Review and install the update before starting a project with that format.",
                systemImage: "arrow.clockwise.circle",
                tone: .pack,
                layout: layout
            ) {
                Button("Open Format Packs…") {
                    SettingsWindowController.shared.show(tab: .plugins)
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.small)
                .help("Open Format Packs to install the available update.")
            }
        }
    }

    private func appNotice(
        layout: HomeStatusNoticeLayout
    ) -> some View {
        HomeStatusNotice(
            title: appUpdateVersion.map {
                "NexGenVideo \($0) is available"
            } ?? "A NexGenVideo update is available",
            message: "Install the update to get the latest fixes and improvements.",
            systemImage: "arrow.up.circle",
            tone: .pack,
            layout: layout
        ) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Button("Not Now") {
                    Updater.shared.dismissUpdate()
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
                .help("Dismiss this update notice.")
                Button("Install Update…") {
                    Updater.shared.checkForUpdates(nil)
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.small)
                .help("Install the available NexGenVideo update.")
            }
        }
    }
}

private enum HomeStatusNoticeLayout {
    case horizontal
    case compact
}

private struct HomeStatusNotice<Actions: View>: View {
    enum Tone {
        case warning
        case pack

        var color: Color {
            switch self {
            case .warning: return AppTheme.Status.warningColor
            case .pack: return AppTheme.Accent.pack
            }
        }
    }

    let title: String
    let message: String
    let systemImage: String
    let tone: Tone
    let layout: HomeStatusNoticeLayout
    let actions: Actions

    init(
        title: String,
        message: String,
        systemImage: String,
        tone: Tone,
        layout: HomeStatusNoticeLayout,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tone = tone
        self.layout = layout
        self.actions = actions()
    }

    var body: some View {
        Group {
            if layout == .horizontal {
                HStack(spacing: AppTheme.Spacing.mdLg) {
                    icon
                    copy
                        .frame(
                            width: AppTheme.ComponentSize.homeNoticeCopyWidth,
                            alignment: .leading
                        )
                    Spacer(minLength: AppTheme.Spacing.md)
                    actions
                        .frame(
                            width: AppTheme.ComponentSize.homeNoticeActionsWidth,
                            alignment: .trailing
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
                        icon
                        copy
                    }
                    HStack(spacing: AppTheme.Spacing.none) {
                        Spacer(minLength: AppTheme.Spacing.none)
                        actions
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.mdLg)
        .frame(
            maxWidth: .infinity,
            minHeight: AppTheme.ComponentSize.homeNoticeMinHeight,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .fill(tone.color.opacity(AppTheme.Opacity.hint))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(
                    tone.color.opacity(AppTheme.Opacity.moderate),
                    lineWidth: AppTheme.BorderWidth.thin
                )
        )
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.system(
                size: AppTheme.FontSize.lgXl,
                weight: AppTheme.FontWeight.bold
            ))
            .foregroundStyle(tone.color)
            .frame(
                width: AppTheme.IconSize.lgXl,
                height: AppTheme.IconSize.lgXl
            )
            .background(
                Circle().fill(tone.color.opacity(AppTheme.Opacity.faint))
            )
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(
                    size: AppTheme.FontSize.md,
                    weight: AppTheme.FontWeight.semibold
                ))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(message)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HomeSidebar: View {
    let onNewProject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                SidebarRowButton(
                    label: "New Project",
                    systemImage: "plus",
                    action: onNewProject
                )
                SidebarRowButton(
                    label: "Open Project",
                    systemImage: "folder",
                    action: { AppState.shared.openProjectFromPanel() }
                )
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.md)

            Spacer(minLength: 0)

            SidebarRowButton(
                label: "Settings",
                systemImage: "gearshape",
                action: { SettingsWindowController.shared.show() }
            )
            .accessibilityIdentifier("home.settings")
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.bottom, AppTheme.Spacing.md)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Home window controller

@MainActor
final class HomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HomeWindowController()

    private init() {
        let hostingController = NSHostingController(rootView: HomeView().tint(AppTheme.Accent.primary))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "NexGenVideo"
        // v4: bump the key so the taller screen-fraction default replaces frames saved by earlier,
        // too-short builds. A user-resized frame is still honored on later launches.
        let restored = window.setFrameUsingName("NexGenVideoHome-v4")
        window.setFrameAutosaveName("NexGenVideoHome-v4")
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(origin: .zero, size: AppTheme.Window.fallbackVisibleFrame)
        window.minSize = NSSize(width: min(AppTheme.Window.homeMin.width, visible.width),
                                height: min(AppTheme.Window.homeMin.height, visible.height))
        if restored {
            window.setFrame(
                WindowGeometry.restoredFrame(window.frame, minimum: window.minSize, visible: visible),
                display: false
            )
        } else {
            window.setContentSize(Self.defaultContentSize(visible: visible))
            window.center()
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(AppTheme.Opacity.settingsWindow)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior = [.fullScreenNone]

        super.init(window: window)
        window.delegate = self
    }

    /// A fraction of the visible screen (60% × 82%), capped at `homeDefault` and floored at `homeMin`,
    /// so the launcher opens tall enough on any display for the format sheet to fit its pack cards.
    private static func defaultContentSize(visible: NSRect) -> NSSize {
        let cap = AppTheme.Window.homeDefault
        let floor = AppTheme.Window.homeMin
        let w = min(max(visible.width * 0.60, floor.width), cap.width, visible.width)
        let h = min(max(visible.height * 0.82, floor.height), cap.height, visible.height)
        return NSSize(width: w, height: h)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Closing the launch window ends the session — the app doesn't linger headless in the Dock.
    /// Opening a project HIDES this window with `orderOut` (not a close), so that path is unaffected.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}
