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
    @State private var showFormatSheet = false

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
        HStack(spacing: 0) {
            HomeSidebar(onNewProject: startNewProject)
                .frame(width: 220)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(AppTheme.Opacity.medium))
        }
        .frame(minWidth: 760, minHeight: 480)
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
        VStack(alignment: .leading, spacing: 0) {
            header
            Text("My Projects")
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.xlXxl)
                .padding(.bottom, AppTheme.Spacing.sm)
            projectGrid
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            WelcomeTitle()

            UpdateBadgeView()

            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.top, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.xxl)
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
                        .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.7), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 60)
            .allowsHitTesting(false)

            Text("Untitled")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .regular))
                .foregroundStyle(.white)
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
                    Color.white.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 12 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .padding(AppTheme.Spacing.xs)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
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
            .font(.system(size: AppTheme.FontSize.title2, weight: .light))
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.primaryColor)
    }
}

private struct HomeSidebar: View {
    let onNewProject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 10)

            Spacer(minLength: 0)

            SidebarRowButton(
                label: "Settings",
                systemImage: "gearshape",
                action: { SettingsWindowController.shared.show() }
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
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
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
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
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
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
