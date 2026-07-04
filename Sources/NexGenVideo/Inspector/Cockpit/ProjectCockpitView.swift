import SwiftUI

/// Tabs of the Project cockpit: Story (brief + treatment, the pipeline's front), Bible, Pipeline
/// (incl. budget), Shotlist, Review (frames + sanity findings). `project` is the settings view,
/// reached via the trailing gear, never a peer tab.
enum CockpitTab: String, Hashable, CaseIterable {
    case story = "Story"
    case bible = "Bible"
    case pipeline = "Pipeline"
    case shotlist = "Shotlist"
    case review = "Review"
    case project = "Project"

    // Tab budget stays ≤5 (Fable's width math): sanity findings live inside Review — both are
    // quality-control surfaces over the same shots.
    static let visibleTabs: [CockpitTab] = [.story, .bible, .pipeline, .shotlist, .review]
}

/// The Project cockpit — the canonical home for project-level artifacts (the engine-read Bible /
/// Pipeline / Shotlist / Sanity panels + settings behind the gear). It lives under the left sidebar's
/// Project tab, reachable in both focuses, and is never crammed into the selection Inspector
/// (docs/UI_UX_CONCEPT.md §3). The Bible keeps its board layout and needs surface area here.
struct ProjectCockpitView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SegmentedTabBar(
                    titles: CockpitTab.visibleTabs.map(\.rawValue),
                    selected: editor.cockpitTab.rawValue
                ) { title in
                    if let tab = CockpitTab(rawValue: title) { editor.cockpitTab = tab }
                }
                settingsButton
            }
            Group {
                switch editor.cockpitTab {
                case .story: StoryPanelView()
                case .bible: BiblePanelView()
                case .pipeline: PipelinePanelView()
                case .shotlist: ShotlistPanelView()
                case .review: ReviewPanelView()
                case .project: ProjectSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
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
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Rows

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
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
                        .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
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
