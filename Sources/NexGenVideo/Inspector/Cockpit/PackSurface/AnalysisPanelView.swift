import SwiftUI

// The `beatAnalysis` cockpit surface (musicvideo song analysis): read-only measured ground truth —
// tempo, key, beat grid, sections — rendered from `analysis/<song>.json` via the host primitives.
// No mutations: lyrics label the sections, they never move the measured boundaries.

struct AnalysisPanelView: View {
    @Environment(EditorViewModel.self) private var editor

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded(AnalysisSurfaceData?)
        case failed(CockpitError)
    }

    @State private var state: LoadState = .idle
    @State private var loadToken = 0

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: editor.projectURL) { await load() }
            .onChange(of: editor.engineStateRevision) { _, _ in Task { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            centeredProgress()
        case .failed(let error):
            CockpitStateView.error(error, title: "Couldn't load the analysis",
                                   subject: "the song analysis",
                                   activePack: InstalledPack.named(editor.activePluginName),
                                   startProduction: { editor.startProduction() },
                                   isStarting: editor.productionStarted) { Task { await load() } }
        case .loaded(nil):
            CockpitStateView.empty(icon: "waveform", title: "No analysis yet",
                                   message: "Run the analysis phase to measure this song.")
        case .loaded(.some(let data)):
            loadedBody(data)
        }
    }

    @ViewBuilder
    private func loadedBody(_ data: AnalysisSurfaceData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                StatRow(tiles: stats(data))
                if data.hasBeatGrid {
                    labelledBlock("Beat grid", detail: provenance(data)) {
                        BeatTimeline(duration: data.durationS, beats: data.beats,
                                     downbeats: data.downbeats, sections: data.sections)
                    }
                } else {
                    degradedBanner
                }
                if !data.sections.isEmpty {
                    labelledBlock("Sections", detail: nil) { SectionList(sections: data.sections) }
                }
                Text("Measured ground truth — read-only. Lyrics label the sections; they never move the measured boundaries.")
                    .font(.system(size: AppTheme.FontSize.micro))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stats(_ d: AnalysisSurfaceData) -> [StatTile] {
        var tiles: [StatTile] = [
            StatTile(label: "Track", value: d.trackName.isEmpty ? "—" : d.trackName),
            StatTile(label: "Duration", value: PackSurfaceFormat.mmss(d.durationS)),
            StatTile(label: "Tempo",
                     value: d.hasBeatGrid ? "\(Int(d.perceivedBpm.rounded())) BPM" : "—",
                     muted: !d.hasBeatGrid),
        ]
        if let key = d.key, !key.isEmpty { tiles.append(StatTile(label: "Key", value: key)) }
        if !d.sections.isEmpty { tiles.append(StatTile(label: "Sections", value: "\(d.sections.count)")) }
        return tiles
    }

    private func provenance(_ d: AnalysisSurfaceData) -> String {
        var parts = ["measured"]
        if let source = d.downbeatSource, !source.isEmpty { parts.append(source) }
        parts.append("\(d.beats.count) beats / \(d.downbeats.count) downbeats")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func labelledBlock<Content: View>(_ title: String, detail: String?,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(.system(size: AppTheme.FontSize.micro))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                }
            }
            content()
        }
    }

    private var degradedBanner: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.warningColor)
            Text("No stable beat grid detected — this track is rubato / beatless. Beat-synced cutting is unavailable; the key and duration are still usable.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Status.warningColor.opacity(AppTheme.Opacity.faint))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Status.warningColor.opacity(AppTheme.Opacity.moderate),
                              lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private func centeredProgress() -> some View {
        VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let dir = editor.workingRoot else {
            state = .failed(.noProject)
            return
        }
        loadToken += 1
        let token = loadToken
        state = .loading
        let data = await Task.detached { () -> AnalysisSurfaceData? in
            guard let root = NativeCockpitReader.dataRoot(of: dir) else { return nil }
            return AnalysisSurfaceData.load(dataRoot: root)
        }.value
        guard token == loadToken else { return }
        state = .loaded(data)
    }
}
