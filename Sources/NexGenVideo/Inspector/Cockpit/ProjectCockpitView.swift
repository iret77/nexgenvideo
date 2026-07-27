import AppKit
import SwiftUI

/// Tabs of the Project cockpit. Pipeline (status + gates + budget) is the control room and leads as the
/// default landing tab; the rest follow the production timeline left→right — Story (brief + treatment),
/// Bible, Shotlist, Review (frames + sanity findings). `project` is the settings view, reached via the
/// trailing gear, never a peer tab.
enum CockpitTab: String, Hashable, CaseIterable {
    case pipeline = "Pipeline"
    case story = "Story"
    case bible = "Bible"
    case shotlist = "Shotlist"
    case review = "Review"
    case project = "Project"

    // Tab budget stays ≤5 (Fable's width math): sanity findings live inside Review — both are
    // quality-control surfaces over the same shots. Order: the control room first, then the artifacts
    // in phase order (brief/treatment → bible → shotlist → frames/sanity).
    static let visibleTabs: [CockpitTab] = [.pipeline, .story, .bible, .shotlist, .review]
}

/// The Project cockpit — the canonical home for project-level artifacts (the engine-read Bible /
/// Pipeline / Shotlist / Sanity panels + settings behind the gear). It lives under the left sidebar's
/// Project tab, reachable in both focuses, and is never crammed into the selection Inspector
/// (docs/UI_UX_CONCEPT.md §3). The Bible keeps its board layout and needs surface area here.
struct ProjectCockpitView: View {
    @Environment(EditorViewModel.self) private var editor

    /// The active pack's cockpit surface, resolved only when it has data — the contextual tab shows just
    /// then (never an empty tab). Nil for a generic project or before the surface's data exists.
    @State private var packSurface: CockpitSurfaceData?

    var body: some View {
        @Bindable var editor = editor
        var titles = CockpitTab.visibleTabs.map(\.rawValue)
        if let surface = packSurface { titles.insert(surface.title, at: min(1, titles.count)) }
        let packSelected = editor.cockpitPackSurfaceID != nil && packSurface != nil
        let selectedTitle = packSelected ? (packSurface?.title ?? "") : editor.cockpitTab.rawValue

        return VStack(spacing: AppTheme.Spacing.none) {
            HStack(spacing: AppTheme.Spacing.none) {
                SegmentedTabBar(
                    titles: titles,
                    selected: selectedTitle,
                    accentedTitles: packSurface.map { Set([$0.title]) } ?? [],
                    accentColor: AppTheme.Accent.pack
                ) { title in
                    if let surface = packSurface, title == surface.title {
                        editor.cockpitPackSurfaceID = surface.id
                    } else if let tab = CockpitTab(rawValue: title) {
                        editor.cockpitTab = tab
                        editor.cockpitPackSurfaceID = nil
                    }
                }
                settingsButton
            }
            Group {
                if packSelected, let surface = packSurface {
                    packSurfaceView(surface)
                } else {
                    switch editor.cockpitTab {
                    case .story: StoryPanelView()
                    case .bible: BiblePanelView()
                    case .pipeline: PipelinePanelView()
                    case .shotlist: ShotlistPanelView()
                    case .review: ReviewPanelView()
                    case .project: ProjectSettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()  // a panel may never paint over the cockpit tab bar
        }
        .task(id: editor.projectURL) { await resolvePackSurface() }
        .onChange(of: editor.engineStateRevision) { _, _ in Task { await resolvePackSurface() } }
    }

    /// Render a pack surface by its declared `kind`. Unknown kinds (a newer pack on an older app) show a
    /// clear placeholder rather than a blank panel.
    @ViewBuilder
    private func packSurfaceView(_ surface: CockpitSurfaceData) -> some View {
        switch surface.kind {
        case "beatAnalysis":
            AnalysisPanelView()
        default:
            CockpitStateView.empty(icon: "square.dashed", title: surface.title,
                                   message: "This surface isn't supported by this version of the app.")
        }
    }

    /// Show the pack tab only when a supported surface is declared AND its data exists — checked off the
    /// main actor. If the selected surface goes away, fall back to the generic tabs.
    private func resolvePackSurface() async {
        let declared = editor.uiContract?.cockpitSurfaces.first { $0.kind == "beatAnalysis" }
        guard let declared, let dir = editor.workingRoot else {
            applyPackSurface(nil)
            return
        }
        let hasData = await Task.detached { () -> Bool in
            guard let root = NativeCockpitReader.dataRoot(of: dir) else { return false }
            return AnalysisSurfaceData.artifactURL(dataRoot: root) != nil
        }.value
        applyPackSurface(hasData ? declared : nil)
    }

    private func applyPackSurface(_ surface: CockpitSurfaceData?) {
        packSurface = surface
        if surface == nil, editor.cockpitPackSurfaceID != nil { editor.cockpitPackSurfaceID = nil }
    }

    private var settingsButton: some View {
        let selected = editor.cockpitTab == .project
        return Button {
            editor.cockpitTab = .project
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: AppTheme.FontSize.sm, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm, isActive: selected)
        }
        .buttonStyle(.plain)
        .padding(.trailing, AppTheme.Spacing.sm)
        .accessibilityLabel("Project settings")
        .help("Project settings")
    }
}

/// Project-level settings: name/path/duration plus resolution, frame rate, and aspect ratio. Self
/// contained so it does not depend on the Inspector's private row helpers.
struct ProjectSettingsView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var showsPluginPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                section("Project") {
                    if let url = editor.projectURL {
                        plainRow("Name", url.deletingPathExtension().lastPathComponent)
                        plainRow("Path", url.path, truncate: .middle)
                    }
                    plainRow("Duration", formatDuration(Double(editor.timeline.totalFrames) / Double(editor.timeline.fps)))
                }
                section("Settings") {
                    menuRow("Resolution", "\(editor.timeline.width) × \(editor.timeline.height)") { qualityMenuItems }
                    menuRow("Frame Rate", "\(editor.timeline.fps) fps") { fpsMenuItems }
                    menuRow("Aspect Ratio", formatAspectRatio(width: editor.timeline.width, height: editor.timeline.height)) { aspectMenuItems }
                }

                pluginSection
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Format plugin (the activation surface — Epic #98 / #95 C3)

    /// Exactly one plugin is active per project ("installed ≠ active"); none = the generic
    /// workflow. The pane shows ONLY the project's state — the active pack with its global
    /// actions, or the choose entry. Browsing/activating lives in `PluginPickerView`.
    private var pluginSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("FORMAT PLUGIN")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            if let active = InstalledPack.named(editor.activePluginName) {
                activePluginCard(active)
            } else if let missing = editor.activePluginName {
                missingPluginRow(name: missing)
            } else {
                noPluginRow
            }
        }
        .sheet(isPresented: $showsPluginPicker) {
            PluginPickerView(editor: editor)
        }
    }

    /// The project names a format plugin that isn't installed (or failed the load
    /// gate) — don't pretend it's active; point at the library to install it.
    private func missingPluginRow(name: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Label("The \"\(name)\" plugin isn't installed", systemImage: "exclamationmark.triangle")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Status.warningColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("This project was built with it. Open the plugin library to add it, or remove it to continue generically.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            WrapLayout(spacing: AppTheme.Spacing.sm) {
                Button("Open Plugins…") { showsPluginPicker = true }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.small)
                // Once production has started the format is locked — the recovery path is to install
                // the missing plugin, not to strand the pipeline by dropping to generic.
                if editor.canChangeFormat {
                    Button("Remove") { withAnimation { editor.setActivePlugin(nil) } }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.small)
                        .help("Back to the generic workflow. Pipeline data stays in the project.")
                }
            }
        }
    }

    private var noPluginRow: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(editor.canChangeFormat
                 ? "Generic production workflow. Choose a format plugin to specialize this project."
                 : "Generic production workflow. Format is locked now that production has started.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if editor.canChangeFormat {
                Button("Choose Plugin…") { showsPluginPicker = true }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.small)
            }
        }
    }

    /// The active pack: its badge, the state + entry point, and the pack-global actions
    /// (switch / remove). Activating installs nothing — it binds the project's workflow.
    /// Vertical, with a wrapping action row: this section also lives in the ~280pt Edit
    /// sidebar, where a badge-beside-buttons row would crush.
    private func activePluginCard(_ plugin: InstalledPack) -> some View {
        let initialized = editor.projectState != nil
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            PluginBadgeView(plugin: plugin)
                .frame(maxWidth: AppTheme.ComponentSize.pluginBadgeWidth, alignment: .leading)
            Text(initialized
                 ? "Active. Production runs the \(plugin.displayName) workflow. Continue in Pipeline."
                 : "Active and ready. Start production and the agent guides each phase.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            WrapLayout(spacing: AppTheme.Spacing.sm) {
                if initialized {
                    // Working the pipeline is Produce's job — land there, not in a sidebar tab.
                    Button("Open Pipeline") {
                        editor.cockpitTab = .pipeline
                        editor.setWorkspaceFocus(.produce)
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.small)
                } else if editor.productionStarting {
                    // Genuine in-flight scaffold — a spinner, not a re-tappable button.
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Starting…")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                } else if editor.hasProductionPipeline {
                    // The pipeline exists (e.g. the agent scaffolded it) but this view's state hasn't
                    // loaded — never offer Start again (double-start), never spin forever; the real
                    // state lives in Pipeline.
                    Button("Open Pipeline") {
                        editor.cockpitTab = .pipeline
                        editor.setWorkspaceFocus(.produce)
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.small)
                } else {
                    Button("Start production") { editor.startProduction() }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .controlSize(.small)
                }
                // Format is locked once production starts — its artifacts are format-specific.
                if editor.canChangeFormat {
                    Button("Switch…") { showsPluginPicker = true }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.small)
                    Button("Remove") { withAnimation { editor.setActivePlugin(nil) } }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.small)
                        .help("Back to the generic workflow. Pipeline data stays in the project.")
                }
            }
        }
    }

    // MARK: - Rows

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            VStack(spacing: AppTheme.Spacing.sm) { content() }
        }
    }

    private func plainRow(_ label: String, _ value: String, truncate: Text.TruncationMode = .tail) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize()
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(truncate)
        }
    }

    private func menuRow<MenuContent: View>(
        _ label: String, _ value: String,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize()
            Spacer()
            Menu {
                menu()
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(value)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .padding(.horizontal, AppTheme.Spacing.xs)
                .frame(height: AppTheme.IconSize.md)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Menu items

    @ViewBuilder private var aspectMenuItems: some View {
        ForEach(AspectPreset.allCases, id: \.self) { preset in
            Button {
                editor.applyTimelineSettings(fps: editor.timeline.fps, width: preset.width, height: preset.height)
            } label: {
                HStack {
                    Text(preset.label)
                    Spacer()
                    if editor.timeline.width == preset.width && editor.timeline.height == preset.height {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    @ViewBuilder private var fpsMenuItems: some View {
        ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
            Button {
                editor.applyTimelineSettings(fps: fps, width: editor.timeline.width, height: editor.timeline.height)
            } label: {
                HStack {
                    Text("\(fps) fps")
                    Spacer()
                    if editor.timeline.fps == fps { Image(systemName: "checkmark") }
                }
            }
        }
    }

    @ViewBuilder private var qualityMenuItems: some View {
        ForEach(QualityPreset.allCases, id: \.self) { preset in
            Button {
                let (w, h) = preset.resolution(currentWidth: editor.timeline.width, currentHeight: editor.timeline.height)
                editor.applyTimelineSettings(fps: editor.timeline.fps, width: w, height: h)
            } label: {
                HStack {
                    Text(preset.label)
                    Spacer()
                    if preset.matches(width: editor.timeline.width, height: editor.timeline.height) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    // MARK: - Formatting

    private func formatAspectRatio(width: Int, height: Int) -> String {
        let d = greatestCommonDivisor(width, height)
        guard d > 0 else { return "\(width):\(height)" }
        return "\(width / d):\(height / d)"
    }

    private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
