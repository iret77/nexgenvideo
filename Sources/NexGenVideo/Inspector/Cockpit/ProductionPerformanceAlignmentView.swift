import AVKit
import NexGenEngine
import SwiftUI

struct ProductionPerformanceAlignmentView: View {
    let canWrite: Bool
    @Environment(EditorViewModel.self) private var editor
    @State private var items: [Item] = []
    @State private var selected: Item?
    @State private var loading = false
    @State private var failure: String?
    @State private var generation = UUID()

    private struct Item: Identifiable, Sendable {
        let home: URL
        let id: String
        let number: Int
        let action: String
        let ready: Bool
        let confirmed: Bool
        let detail: String?
    }

    private var canOpen: Bool {
        guard !loading, !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            if !items.isEmpty || failure != nil {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("Performance alignment")
                        .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    Text("Review each performance shot with its original song phrase. Changing the selected take or range requires a new confirmation.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("Shot \(item.number) · \(item.action)").lineLimit(2)
                            Text(item.confirmed ? "Alignment confirmed" : "Alignment needs review")
                                .foregroundStyle(item.confirmed ? AppTheme.Text.secondaryColor : AppTheme.Status.warningColor)
                                .reviewAcceptanceProbe("performance.alignment.status.\(item.id)", state: item.confirmed)
                            if let detail = item.detail { Text(detail).foregroundStyle(AppTheme.Text.secondaryColor) }
                            Button(canWrite ? "Review alignment" : "Inspect alignment") { selected = item }
                                .buttonStyle(InlineActionButtonStyle())
                                .disabled(!canOpen || !item.ready)
                                .reviewAcceptanceProbe("performance.alignment.open.\(item.id)", state: canOpen && item.ready)
                        }
                    }
                    if let failure {
                        Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                        Button("Reload alignment") { Task { await load() } }
                            .buttonStyle(InlineActionButtonStyle()).disabled(loading)
                    }
                }
                .sheet(item: $selected, onDismiss: { Task { await load() } }) { item in
                    ProductionPerformanceAlignmentSheet(home: item.home, shotID: item.id, number: item.number, canWrite: canWrite)
                        .environment(editor)
                }
            }
        }
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
    }

    private func load() async {
        let token = UUID(); generation = token
        let home = editor.workingRoot
        loading = true
        defer { if token == generation { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home), editor.usesProductionPlanningV2 else { items = []; failure = nil; return }
        do {
            let values = try await Task.detached(priority: .userInitiated) {
                let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
                guard projection.executionPlan.extensionReferences.contains(where: { $0.id == MusicvideoProductionExtensionV2.artifactID }) else { return [Item]() }
                let music = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: root)
                let ids = Set(music.performanceSegments.flatMap { $0.draft.shotIDs })
                return projection.shots.enumerated().filter { ids.contains($0.element.id) }.map { number, shot in
                    do {
                        guard try PipelineProductionPerformanceAlignment.candidate(shotID: shot.id, projection: projection, dataRoot: root) != nil else {
                            throw GateBlocked("The performance phrase changed. Reload the current shot before reviewing its alignment.")
                        }
                        let current = (try? PipelineProductionPerformanceAlignment.requireCurrent(shotID: shot.id,
                            projection: projection, dataRoot: root)) != nil
                        return Item(home: home, id: shot.id, number: number + 1, action: shot.primaryAction,
                            ready: true, confirmed: current, detail: nil)
                    } catch {
                        return Item(home: home, id: shot.id, number: number + 1, action: shot.primaryAction,
                            ready: false, confirmed: false, detail: error.localizedDescription)
                    }
                }
            }.value
            guard !Task.isCancelled, token == generation, editor.workingRoot == home else { return }
            items = values; failure = nil
        } catch {
            guard !Task.isCancelled, token == generation, editor.workingRoot == home else { return }
            items = []; failure = error.localizedDescription
        }
    }
}

private struct ProductionPerformanceAlignmentSheet: View {
    let home: URL
    let shotID: String
    let number: Int
    let canWrite: Bool
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: PipelineProductionPerformanceAlignment.Snapshot?
    @State private var player: AVPlayer?
    @State private var operation: Task<Void, Never>?
    @State private var watchedAndListened = false
    @State private var observation = ""
    @State private var failure: String?
    @State private var recorded: CanonicalArtifactReferenceV1?
    @State private var presented = false

    private var active: Bool {
        guard presented, operation == nil, editor.workingRoot == home,
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    private var canConfirm: Bool {
        active && canWrite && snapshot != nil && recorded == nil && failure == nil && watchedAndListened
            && !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Phrase alignment · Shot \(number)")
                .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("Watch the selected image range and listen to the original song together. Confirm the visible timing against this phrase.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if let snapshot {
                        VideoPlayer(player: player).frame(height: AppTheme.Layout.productionAssetPreviewHeight)
                            .reviewAcceptanceProbe("performance.alignment.player", text: snapshot.previewSHA256)
                        Text("Song: \(snapshot.binding.songStart.cmTime.seconds, specifier: "%.3f")–\(CMTimeAdd(snapshot.binding.songStart.cmTime, snapshot.binding.duration.cmTime).seconds, specifier: "%.3f") s · \(snapshot.phrase.sampleRate) Hz")
                            .monospacedDigit().reviewAcceptanceProbe("performance.alignment.range",
                                text: "\(snapshot.binding.songStart.value)/\(snapshot.binding.songStart.timescale):\(snapshot.binding.duration.value)/\(snapshot.binding.duration.timescale)")
                        Button("Play phrase") {
                            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                            player?.play()
                        }.buttonStyle(InlineActionButtonStyle()).disabled(operation != nil)
                            .reviewAcceptanceProbe("performance.alignment.play", state: operation == nil)
                        Toggle("I watched the image and listened to the phrase together", isOn: $watchedAndListened)
                            .disabled(!active || !canWrite || recorded != nil)
                            .reviewAcceptanceProbe("performance.alignment.observe", state: watchedAndListened)
                        TextField("Describe the timing you checked", text: $observation, axis: .vertical)
                            .lineLimit(2...4).disabled(!active || !canWrite || recorded != nil)
                            .reviewAcceptanceProbe("performance.alignment.observation", text: observation)
                    }
                    if operation != nil { ProgressView("Preparing alignment…") }
                    if let recorded {
                        Text("Alignment confirmed").foregroundStyle(AppTheme.Text.secondaryColor)
                            .reviewAcceptanceProbe("performance.alignment.recorded", text: recorded.sha256)
                    }
                    if let failure {
                        Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                            .reviewAcceptanceProbe("performance.alignment.error", text: failure)
                    }
                }
            }
            HStack(spacing: AppTheme.Spacing.md) {
                Button("Done") { dismiss() }.buttonStyle(InlineActionButtonStyle()).keyboardShortcut(.cancelAction)
                    .reviewAcceptanceProbe("performance.alignment.close")
                Button("Reload") { load() }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                    .reviewAcceptanceProbe("performance.alignment.reload", state: active)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Confirm alignment") { confirm() }.buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(!canConfirm).reviewAcceptanceProbe("performance.alignment.confirm", state: canConfirm)
            }
        }
        .padding(AppTheme.Spacing.lg).interfaceFont(size: AppTheme.Typography.ui)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .reviewAcceptanceProbe("performance.alignment.sheet", text: shotID)
        .onAppear { presented = true; load() }
        .onDisappear { presented = false; operation?.cancel(); releasePreview() }
        .onChange(of: editor.workingRoot) { _, value in if value != home { dismiss() } }
    }

    private func releasePreview() {
        player?.pause(); player = nil
        if let snapshot { PipelineProductionPerformanceAlignment.discard(snapshot) }
        snapshot = nil
    }

    private func load() {
        guard presented, operation == nil else { return }
        releasePreview(); watchedAndListened = false; observation = ""; recorded = nil; failure = nil
        operation = Task {
            defer { operation = nil }
            do {
                guard let value = try await PipelineProductionPerformanceAlignment.capture(shotID: shotID, editor: editor) else {
                    throw GateBlocked("The performance phrase changed. Reload the current shot before reviewing its alignment.")
                }
                guard !Task.isCancelled, presented, editor.workingRoot == home else {
                    PipelineProductionPerformanceAlignment.discard(value); return
                }
                let item = AVPlayerItem(url: value.previewURL)
                item.forwardPlaybackEndTime = value.binding.duration.cmTime
                snapshot = value; player = AVPlayer(playerItem: item)
            } catch { if presented && !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    private func confirm() {
        guard canConfirm, let snapshot else { return }
        let note = observation
        player?.pause()
        operation = Task {
            defer { operation = nil }
            do {
                let value = try await PipelineProductionPerformanceAlignment.record(snapshot: snapshot,
                    watchedAndListened: true, observation: note, editor: editor)
                guard presented, !Task.isCancelled, editor.workingRoot == home else { return }
                recorded = value
            } catch { if presented && !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
