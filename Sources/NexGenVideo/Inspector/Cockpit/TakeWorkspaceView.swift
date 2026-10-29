import AVKit
import NexGenEngine
import SwiftUI

struct TakeWorkspaceView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var takes: [Item] = []
    @State private var selectedID = ""
    @State private var snapshot: TakeReview.Snapshot?
    @State private var player: AVPlayer?
    @State private var failure: String?
    @State private var loading = false
    @State private var canWrite = false
    @State private var showsHistory = false
    @State private var loadedHome: URL?
    @State private var loadGeneration = UUID()

    private var writesAvailable: Bool {
        guard canWrite, !loading, !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let home = editor.workingRoot, loadedHome == home, let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    private struct Item: Identifiable, Sendable {
        let take: PipelineRenderTakeV1
        let selected: Bool
        let review: TakeReview?
        let shotLabel: String
        let shotName: String?
        var id: String { take.id }
        var status: String {
            if selected { return String(localized: "Selected") }
            guard let review else { return String(localized: "Needs review") }
            return review.accepted ? String(localized: "Reviewed") : String(localized: "Rejected")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                Picker("Take history", selection: $showsHistory) {
                    Text("Current production").tag(false)
                    Text("Previous workflows").tag(true)
                }.pickerStyle(.segmented)
                if showsHistory {
                    HistoricalTakeView()
                } else {
                if editor.usesProductionPlanningV2 { ProductionAssemblyView() }
                if editor.usesProductionPlanningV2 { ProductionPerformanceAlignmentView(canWrite: writesAvailable) }
                HStack(alignment: .firstTextBaseline) {
                    Text("Video takes")
                        .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    Spacer(minLength: AppTheme.Spacing.sm)
                    TakeReviewView(initialTakeID: selectedID, onOpen: { player?.pause() }).id(selectedID)
                }
                if loading { ProgressView().controlSize(.small) }
                if let failure {
                    Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                    Button("Reload takes") { Task { await load() } }
                        .buttonStyle(InlineActionButtonStyle())
                }
                if let snapshot {
                    VideoPlayer(player: player)
                        .frame(minHeight: AppTheme.Layout.previewMinHeight)
                        .reviewAcceptanceProbe("take.workspace.player", text: snapshot.take.id)
                    Text("\(takes.first(where: { $0.id == snapshot.take.id })?.shotLabel ?? snapshot.take.shotID) · \(snapshot.take.generationInput.model) · \(snapshot.durationSeconds, specifier: "%.2f") s")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if let name = takes.first(where: { $0.id == snapshot.take.id })?.shotName { Text(name).textSelection(.enabled) }
                    TakeRangeReviewView(snapshot: snapshot, wholeTakePlayer: player, canWrite: writesAvailable)
                        .id(snapshot.take.id)
                    TakeRepairView(snapshot: snapshot, canWrite: writesAvailable).id(snapshot.take.id)
                    DisclosureGroup("Submitted direction and image references") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            Text(snapshot.take.generationInput.prompt).textSelection(.enabled)
                            ForEach(Array(snapshot.referenceImages.enumerated()), id: \.offset) { index, reference in
                                SheetThumbnailView(label: String(localized: "Reference \(index + 1)"), path: reference.path,
                                    projectDir: snapshot.home, tileHeight: AppTheme.ComponentSize.toolImagePreviewMaxHeight)
                            }
                        }
                    }
                } else if !takes.isEmpty {
                    Text("Select a take to preview its video, sources and usable range.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                } else if !loading && failure == nil {
                    CockpitStateView.empty(icon: "film", title: "No video takes yet",
                        message: "Completed renders appear here for review and selection.")
                }
                ForEach(takes) { item in
                    Button { selectedID = item.id } label: {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.shotLabel).fontWeight(AppTheme.FontWeight.semibold)
                                Spacer(minLength: AppTheme.Spacing.sm)
                                Text(item.status)
                            }
                            Text("\(item.take.phase == "preview" ? "Draft" : "Production") · \(item.take.generationInput.model)")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                            if let name = item.shotName { Text(name).lineLimit(2) }
                            Text(item.take.recordedAt).foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppTheme.Spacing.md)
                        .background(selectedID == item.id ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : AppTheme.Background.raisedColor)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .strokeBorder(selectedID == item.id ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                                lineWidth: AppTheme.BorderWidth.thin))
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)
                    .accessibilityLabel("\(item.shotLabel), \(item.status), \(item.take.generationInput.model), \(item.take.recordedAt)")
                    .reviewAcceptanceProbe("take.workspace.select.\(item.id)", text: item.status)
                }
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .reviewAcceptanceProbe("take.workspace")
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
        .task(id: "\(editor.workingRoot?.path ?? ""):\(selectedID)") { await select() }
        .onDisappear { player?.pause() }
        .onChange(of: showsHistory) { _, _ in player?.pause() }
    }

    private func load() async {
        let token = UUID(); loadGeneration = token
        let home = editor.workingRoot
        if loadedHome != home {
            loadedHome = home; takes = []; selectedID = ""; snapshot = nil; player?.pause(); player = nil
        }
        loading = true
        canWrite = false
        defer { if token == loadGeneration { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home) else {
            takes = []; selectedID = ""; snapshot = nil; player?.pause(); player = nil
            return
        }
        canWrite = (try? PipelinePhaseAccess.requireCurrentPhaseAndIntake("render", dataRoot: root,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            declaredProductionContract: editor.declaredProductionContract)) != nil
        do {
            let productionV2 = editor.usesProductionPlanningV2
            let values = try await Task.detached(priority: .userInitiated) {
                let project = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile).project
                let projection = productionV2 ? try ProductionPlanningLineageV2.projection(dataRoot: root) : nil
                return try ["preview", "final"].flatMap { phase in
                    let index = try PipelineRenderTakeStore.load(dataRoot: root, project: project, phase: phase)
                    return try index.takeIDs.map { id in
                        let take = try PipelineRenderTakeStore.take(id: id, dataRoot: root)
                        let number = projection?.shots.firstIndex { $0.id == take.shotID }
                        return Item(take: take, selected: index.selected[take.shotID] == id,
                            review: try TakeReview.load(take: take, dataRoot: root),
                            shotLabel: number.map { "Shot \($0 + 1)" } ?? (productionV2 ? "Previous plan shot" : take.shotID),
                            shotName: number.flatMap { projection?.shots[$0].primaryAction })
                    }
                }.sorted { $0.take.recordedAt > $1.take.recordedAt }
            }.value
            guard !Task.isCancelled, token == loadGeneration, editor.workingRoot == home else { return }
            takes = values
            if !takes.contains(where: { $0.id == selectedID }) { selectedID = "" }
            failure = nil
        } catch {
            guard !Task.isCancelled, token == loadGeneration, editor.workingRoot == home else { return }
            takes = []; selectedID = ""; player?.pause(); player = nil; snapshot = nil
            failure = error.localizedDescription
        }
    }

    private func select() async {
        player?.pause(); player = nil; snapshot = nil
        let id = selectedID
        guard !id.isEmpty, let home = editor.workingRoot else { return }
        do {
            let value = try await TakeReview.capture(takeID: id, home: home)
            guard !Task.isCancelled, selectedID == id, editor.workingRoot == home else { return }
            snapshot = value; player = AVPlayer(url: value.mediaURL); failure = nil
        } catch {
            guard !Task.isCancelled, selectedID == id, editor.workingRoot == home else { return }
            failure = error.localizedDescription
        }
    }
}
