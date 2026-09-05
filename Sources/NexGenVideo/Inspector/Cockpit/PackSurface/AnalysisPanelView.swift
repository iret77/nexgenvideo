import Foundation
import SwiftUI

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
              execution.stageID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
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

struct DeclarativePackSurfaceView: View {
    @Environment(EditorViewModel.self) private var editor
    let surface: CockpitSurfaceData
    let onUnavailable: () -> Void

    private struct LoadedSurface: Sendable, Equatable {
        let document: PackSurfaceDocument
        let analysis: AnalysisSurfaceData?
    }

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded(LoadedSurface)
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
            CockpitStateView.error(error, title: "Couldn't load \(surface.title.lowercased())",
                                   subject: "the pack surface",
                                   activePack: InstalledPack.named(editor.activePluginName),
                                   startProduction: { editor.startProduction() },
                                   isStarting: editor.productionStarted) { Task { await load() } }
        case .loaded(let loaded):
            loadedPanel(loaded)
        }
    }

    private func loadedPanel(_ loaded: LoadedSurface) -> some View {
        loadedBody(loaded)
            .overlay {
                if let analysis = loaded.analysis,
                   let progress = AnalysisRemeasurementPresentation.current(
                    execution: editor.pipelinePhaseExecution.snapshot,
                    dataRoot: editor.workingRoot.flatMap {
                        NativeCockpitReader.dataRoot(of: $0)
                    },
                    fallbackTrackName: analysis.trackName
                ) {
                    remeasurementOverlay(progress)
                }
            }
    }

    @ViewBuilder
    private func loadedBody(_ loaded: LoadedSurface) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                ForEach(Array(surface.layout.enumerated()), id: \.offset) { item in
                    primitiveView(item.element, loaded: loaded)
                }
                Text("Measured ground truth — read-only.")
                    .interfaceFont(size: AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func primitiveView(
        _ primitive: CockpitSurfacePrimitiveData,
        loaded: LoadedSurface
    ) -> some View {
        switch primitive {
        case .statRow(let items):
            let tiles = items.compactMap { statTile($0, loaded: loaded) }
            if !tiles.isEmpty { StatRow(tiles: tiles) }
        case .beatTimeline(
            let title,
            let durationField,
            let beatsField,
            let downbeatsField,
            let sectionsField,
            let sectionsVisibility
        ):
            let duration = loaded.document.number(at: durationField) ?? 0
            let beats = loaded.document.numbers(at: beatsField) ?? []
            let downbeats = loaded.document.numbers(at: downbeatsField) ?? []
            let sections = PackSurfaceSectionBinding.sections(
                document: loaded.document,
                field: sectionsField,
                visibility: sectionsVisibility,
                analysis: loaded.analysis
            )
            if beats.isEmpty {
                analysisStatus(loaded.analysis)
                degradedBanner
            } else {
                analysisStatus(loaded.analysis)
                labelledBlock(title, detail: provenance(loaded.analysis, beats: beats, downbeats: downbeats)) {
                    BeatTimeline(
                        duration: duration,
                        beats: beats,
                        downbeats: downbeats,
                        sections: sections
                    )
                }
            }
        case .sectionList(let title, let sectionsField, let visibility):
            let hierarchy = PackSurfaceSectionBinding.hierarchy(
                document: loaded.document,
                field: sectionsField,
                visibility: visibility,
                analysis: loaded.analysis
            )
            if !hierarchy.isEmpty {
                labelledBlock(
                    loaded.analysis?.hasNestedHierarchy == true ? "Structure hierarchy" : title,
                    detail: loaded.analysis.flatMap(structureProvenance)
                ) {
                    StructureHierarchyList(sections: hierarchy)
                }
            }
        case .keyValue(let title, let items):
            let rows = items.compactMap { binding -> KeyValueRow? in
                guard let tile = statTile(binding, loaded: loaded), !tile.muted else { return nil }
                return KeyValueRow(label: tile.label, value: tile.value)
            }
            if !rows.isEmpty { PackSurfaceKeyValueList(title: title, rows: rows) }
        }
    }

    private func statTile(
        _ binding: CockpitValueBindingData,
        loaded: LoadedSurface
    ) -> StatTile? {
        if binding.visibility == .whenCanonicalSections,
           loaded.analysis?.hasCanonicalStructure != true { return nil }

        let value: String?
        switch binding.format {
        case .text:
            value = loaded.document.string(at: binding.field)
        case .fileName:
            value = loaded.document.string(at: binding.field).map { ($0 as NSString).lastPathComponent }
        case .duration:
            value = loaded.document.number(at: binding.field).map(PackSurfaceFormat.mmss)
        case .bpm:
            if loaded.analysis?.hasBeatGrid == false {
                value = nil
            } else {
                value = loaded.document.number(at: binding.field).map { measured in
                    let factor = binding.factorField.flatMap {
                        loaded.document.number(at: $0)
                    } ?? 1
                    return "\(Int((measured * factor).rounded())) BPM"
                }
            }
        case .count:
            value = loaded.document.count(at: binding.field).map(String.init)
        }
        if binding.visibility == .whenPresent,
           value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return nil }
        let rendered = value.flatMap { $0.isEmpty ? nil : $0 }
        return StatTile(label: binding.label, value: rendered ?? "—", muted: rendered == nil)
    }

    @ViewBuilder
    private func analysisStatus(_ data: AnalysisSurfaceData?) -> some View {
        if let data {
            if !data.hasCanonicalStructure { structureBanner(data) }
            if data.requiresStructureReview { structureReviewBanner(data) }
            if !data.nonSuccessStageDiagnostics.isEmpty { stageDiagnosticsBanner(data) }
        }
    }

    private func structureBanner(_ data: AnalysisSurfaceData) -> some View {
        let detail = data.structureResolution?.detail
            ?? "This analysis predates structural confidence tracking. Re-run analysis before approval."
        return HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "xmark.octagon")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.errorColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Section structure unresolved")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(detail)
                    .interfaceFont(size: AppTheme.Typography.ui)
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

    private func structureReviewBanner(_ data: AnalysisSurfaceData) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.warningColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Review section boundaries")
                    .interfaceFont(
                        size: AppTheme.Typography.ui,
                        weight: AppTheme.FontWeight.semibold
                    )
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(data.structureResolution?.detail ?? "Some boundaries have one acoustic detector source.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Status.warningColor.opacity(AppTheme.Opacity.faint))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(
                    AppTheme.Status.warningColor.opacity(AppTheme.Opacity.moderate),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
    }

    private func stageDiagnosticsBanner(_ data: AnalysisSurfaceData) -> some View {
        let failures = data.nonSuccessStageDiagnostics
        return HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.warningColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Analysis completed with reduced evidence")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                ForEach(Array(failures.enumerated()), id: \.offset) { item in
                    Text("\(item.element.stage.replacingOccurrences(of: "_", with: " ")): \(item.element.detail)")
                        .interfaceFont(size: AppTheme.Typography.ui)
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

    private func provenance(
        _ data: AnalysisSurfaceData?,
        beats: [Double],
        downbeats: [Double]
    ) -> String {
        var parts = ["measured"]
        if let source = data?.downbeatSource, !source.isEmpty { parts.append(source) }
        parts.append("\(beats.count) beats / \(downbeats.count) downbeats")
        return parts.joined(separator: " · ")
    }

    private func structureProvenance(_ data: AnalysisSurfaceData) -> String? {
        guard let resolution = data.structureResolution else { return nil }
        let method = resolution.method.replacingOccurrences(of: "_", with: " ")
        let segments = resolution.hierarchy?.segments.count ?? 0
        let phrases = resolution.hierarchy?.phrases.count ?? 0
        var parts = [method]
        if segments > 0 || phrases > 0 {
            parts.append("\(segments) segments")
            parts.append("\(phrases) phrases")
        }
        parts.append("\(resolution.candidateBoundaryCount) measured candidates")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func labelledBlock<Content: View>(_ title: String, detail: String?,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(title)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .interfaceFont(size: AppTheme.Typography.metadata)
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
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.warningColor)
            Text("No stable beat grid detected — this track is rubato / beatless. Beat-synced cutting is unavailable; the key and duration are still usable.")
                .interfaceFont(size: AppTheme.Typography.ui)
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
                    .interfaceFont(size: AppTheme.Typography.title)
                    .foregroundStyle(AppTheme.Accent.timecodeColor)
                Text("Re-measuring \(progress.trackName)")
                    .interfaceFont(
                        size: AppTheme.Typography.ui,
                        weight: AppTheme.FontWeight.semibold
                    )
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("A new analysis is running; the last-known grid stays until it completes.")
                    .interfaceFont(size: AppTheme.Typography.ui)
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
                        .interfaceFont(size: AppTheme.Typography.metadata).monospacedDigit()
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
        let surface = surface
        let loaded = await Task.detached { () -> LoadedSurface? in
            guard let root = NativeCockpitReader.dataRoot(of: dir) else { return nil }
            guard let url = PackSurfaceDataResolver.resolve(
                dataRoot: root,
                pattern: surface.dataFile
            ), let bytes = try? Data(contentsOf: url),
               let document = try? PackSurfaceDocument(data: bytes) else { return nil }
            return LoadedSurface(
                document: document,
                analysis: try? JSONDecoder().decode(AnalysisSurfaceData.self, from: bytes)
            )
        }.value
        guard token == loadToken else { return }
        guard let loaded else {
            state = .idle
            onUnavailable()
            return
        }
        state = .loaded(loaded)
    }
}
