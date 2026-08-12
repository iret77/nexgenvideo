import Foundation
import SwiftUI

// The `beatAnalysis` cockpit surface (musicvideo song analysis): read-only measured ground truth —
// tempo, key, beat grid, sections — rendered from `analysis/<song>.json` via the host primitives.
// No mutations: lyrics label the sections, they never move the measured boundaries.

struct AnalysisRemeasurementPresentation: Equatable {
    let trackName: String
    let completedUnitCount: Int
    let totalUnitCount: Int

    static func current(
        execution: PipelinePhaseExecutionSnapshot?,
        dataRoot: URL?,
        fallbackTrackName: String
    ) -> Self? {
        guard let execution,
              execution.isRunning,
              execution.phase == "analysis",
              let dataRoot,
              execution.projectRootPath == canonicalPath(dataRoot) else { return nil }
        let total = max(0, execution.totalUnitCount)
        let completed = min(max(0, execution.completedUnitCount), total)
        let source = execution.sourceFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fallbackTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trackName: String
        if let source, !source.isEmpty {
            trackName = source
        } else {
            trackName = fallback.isEmpty ? "Assigned track" : fallback
        }
        return Self(
            trackName: trackName,
            completedUnitCount: completed,
            totalUnitCount: total
        )
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

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
            .onChange(of: editor.engineStateRevision) { _, _ in
                Task { await load(showProgress: false) }
            }
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
            loadedPanel(data)
        }
    }

    private func loadedPanel(_ data: AnalysisSurfaceData) -> some View {
        loadedBody(data)
            .overlay {
                if let progress = AnalysisRemeasurementPresentation.current(
                    execution: editor.pipelinePhaseExecution.snapshot,
                    dataRoot: editor.workingRoot.flatMap {
                        DataRootResolver.dataRoot(of: $0)
                    },
                    fallbackTrackName: data.trackName
                ) {
                    remeasurementOverlay(progress)
                }
            }
    }

    @ViewBuilder
    private func loadedBody(_ data: AnalysisSurfaceData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                StatRow(tiles: stats(data))
                if !data.hasCanonicalStructure {
                    structureBanner(data)
                }
                if !data.nonSuccessStageDiagnostics.isEmpty {
                    stageDiagnosticsBanner(data)
                }
                if data.hasBeatGrid {
                    labelledBlock("Beat grid", detail: provenance(data)) {
                        BeatTimeline(duration: data.durationS, beats: data.beats,
                                     downbeats: data.downbeats,
                                     sections: data.hasCanonicalStructure ? data.sections : [])
                    }
                } else {
                    degradedBanner
                }
                if let hierarchy = data.canonicalHierarchy, !hierarchy.isEmpty {
                    labelledBlock("Structure hierarchy", detail: structureProvenance(data)) {
                        StructureHierarchyList(sections: hierarchy)
                    }
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
        if d.hasCanonicalStructure, !d.sections.isEmpty {
            tiles.append(StatTile(label: "Sections", value: "\(d.sections.count)"))
        }
        return tiles
    }

    private func structureBanner(_ data: AnalysisSurfaceData) -> some View {
        let detail = data.structureResolution?.detail
            ?? "This analysis predates structural confidence tracking. Re-run analysis before approval."
        return HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.errorColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Section structure unresolved")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(detail)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Status.errorColor.opacity(AppTheme.Opacity.faint))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Status.errorColor.opacity(AppTheme.Opacity.moderate),
                              lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private func stageDiagnosticsBanner(_ data: AnalysisSurfaceData) -> some View {
        let failures = data.nonSuccessStageDiagnostics
        return HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.warningColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Analysis completed with reduced evidence")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                ForEach(Array(failures.enumerated()), id: \.offset) { item in
                    Text("\(item.element.stage.replacingOccurrences(of: "_", with: " ")): \(item.element.detail)")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
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

    private func provenance(_ d: AnalysisSurfaceData) -> String {
        var parts = ["measured"]
        if let source = d.downbeatSource, !source.isEmpty { parts.append(source) }
        parts.append("\(d.beats.count) beats / \(d.downbeats.count) downbeats")
        return parts.joined(separator: " · ")
    }

    private func structureProvenance(_ data: AnalysisSurfaceData) -> String? {
        guard let resolution = data.structureResolution else { return nil }
        let method = resolution.method.replacingOccurrences(of: "_", with: " ")
        let segments = resolution.hierarchy?.segments.count ?? 0
        let phrases = resolution.hierarchy?.phrases.count ?? 0
        return "\(method) · \(segments) segments · \(phrases) phrases · \(resolution.candidateBoundaryCount) diagnostic change points"
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

    private func remeasurementOverlay(
        _ progress: AnalysisRemeasurementPresentation
    ) -> some View {
        VStack {
            Spacer()
            VStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: "music.note")
                    .font(.system(size: AppTheme.FontSize.title1))
                    .foregroundStyle(AppTheme.Accent.timecodeColor)
                Text("Re-measuring \(progress.trackName)")
                    .font(.system(
                        size: AppTheme.FontSize.md,
                        weight: AppTheme.FontWeight.semibold
                    ))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("A new analysis is running; the last-known grid stays until it completes.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .multilineTextAlignment(.center)
                if progress.totalUnitCount > 0 {
                    ProgressView(
                        value: Double(progress.completedUnitCount),
                        total: Double(progress.totalUnitCount)
                    )
                    .progressViewStyle(.linear)
                    .tint(AppTheme.Accent.timecodeColor)
                    Text("\(progress.completedUnitCount) of \(progress.totalUnitCount)")
                        .font(.system(size: AppTheme.FontSize.xxs).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: AppTheme.ComponentSize.packSurfaceProgressMaxWidth)
            .background(AppTheme.Background.raisedColor)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(
                        AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
            )
            Spacer()
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.medium))
        .allowsHitTesting(false)
    }

    private func centeredProgress() -> some View {
        VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(showProgress: Bool = true) async {
        guard let dir = editor.workingRoot else {
            state = .failed(.noProject)
            return
        }
        loadToken += 1
        let token = loadToken
        if showProgress { state = .loading }
        let data = await Task.detached { () -> AnalysisSurfaceData? in
            guard let root = NativeCockpitReader.dataRoot(of: dir) else { return nil }
            return AnalysisSurfaceData.load(dataRoot: root)
        }.value
        guard token == loadToken else { return }
        state = .loaded(data)
    }
}
