import AVKit
import SwiftUI
import NexGenEngine

struct TakeReviewView: View {
    private let onOpen: (() -> Void)?
    @Environment(EditorViewModel.self) private var editor
    @State private var presented = false
    @State private var takes: [TakeChoice] = []
    @State private var selectedID = ""
    @State private var snapshot: TakeReview.Snapshot?
    @State private var player: AVPlayer?
    @State private var findings: [TakeReview.Finding] = []
    @State private var verdict = TakeReview.Verdict.conforms
    @State private var observation = ""
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var message: String?
    @State private var busy = false
    @State private var canSelect = false
    @State private var canWrite = false
    @State private var queue: TakeReviewQueue?
    @State private var queueHome: URL?
    @State private var queueGeneration: UUID?
    @State private var queueRevision = 0
    @State private var loadToken = UUID()

    private struct TakeChoice: Identifiable, Sendable {
        let take: PipelineRenderTakeV1
        let shotLabel: String
        var id: String { take.id }
    }

    init(initialTakeID: String = "", onOpen: (() -> Void)? = nil) {
        _selectedID = State(initialValue: initialTakeID)
        self.onOpen = onOpen
    }

    var body: some View {
        Button("Review video takes") { onOpen?(); presented = true }
            .buttonStyle(InlineActionButtonStyle())
            .reviewAcceptanceProbe("take.open")
            .sheet(isPresented: $presented) { reviewSheet }
    }

    private var reviewSheet: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Video takes").fontWeight(AppTheme.FontWeight.semibold)
                Spacer()
                Button("Close") { presented = false }.buttonStyle(InlineActionButtonStyle())
                    .reviewAcceptanceProbe("take.close")
            }
            if takes.isEmpty { Text("No recorded video takes. Record a completed render to begin review.") }
            else {
                Picker("Take", selection: $selectedID) {
                    Text("Choose a take").tag("")
                    ForEach(Array(takes.enumerated()), id: \.element.id) { index, choice in
                        let phase = choice.take.phase == "preview" ? String(localized: "Draft") : String(localized: "Production")
                        Text("\(choice.shotLabel) · \(phase) · Take \(index + 1) · \(choice.take.recordedAt)").tag(choice.id)
                    }
                }
                    .reviewAcceptanceProbe("take.picker", text: selectedID)
                    .disabled(busy)
                if let snapshot {
                    VideoPlayer(player: player).frame(minHeight: AppTheme.Layout.previewMinHeight)
                        .reviewAcceptanceProbe("take.preview.player")
                    TakeRangeReviewView(snapshot: snapshot, wholeTakePlayer: player, canWrite: canWrite).id(snapshot.take.id)
                    TakeRepairView(snapshot: snapshot, canWrite: canWrite).id(snapshot.take.id)
                    DisclosureGroup("Submitted direction and image references") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                Text(snapshot.take.generationInput.prompt).textSelection(.enabled)
                                ForEach(Array(snapshot.referenceImages.enumerated()), id: \.offset) { index, reference in
                                    SheetThumbnailView(label: String(localized: "Reference \(index + 1)"), path: reference.path,
                                        projectDir: snapshot.home, tileHeight: AppTheme.ComponentSize.toolImagePreviewMaxHeight)
                                }
                            }
                        }.frame(maxHeight: AppTheme.ComponentSize.productionStyleReviewMaxHeight)
                    }
                    Button("Use reviewed take") {
                        busy = true
                        Task {
                            do {
                                try await TakeReview.select(take: snapshot.take, home: snapshot.home, editor: editor)
                                message = "Take selected. Its source and conditioning were revalidated."
                            } catch { message = error.localizedDescription }
                            busy = false
                        }
                    }.buttonStyle(InlineActionButtonStyle(variant: .approval))
                        .reviewAcceptanceProbe("take.use", state: !busy && canSelect && canWrite)
                        .disabled(busy || !canSelect || !canWrite)
                    nextShotView(snapshot)
                    if findings.count < TakeReview.Pass.allCases.count && findings.last?.verdict != .rejected {
                        let pass = TakeReview.Pass.allCases[findings.count]
                        Text("\(findings.count + 1) of 6 · \(pass.label)").fontWeight(AppTheme.FontWeight.semibold)
                            .reviewAcceptanceProbe("take.pass", text: pass.rawValue)
                        if pass == .identity {
                            Text("Check subject and scene identity, including objects when no person is present.")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        Picker("Finding", selection: $verdict) {
                            Text(verdictLabel(.conforms)).tag(TakeReview.Verdict.conforms)
                            Text("Reject").tag(TakeReview.Verdict.rejected)
                            if pass != .identity { Text("Accept deviation — explain").tag(TakeReview.Verdict.acceptedDeviation) }
                            if pass != .identity { Text("Not applicable — explain").tag(TakeReview.Verdict.notApplicable) }
                        }
                        .reviewAcceptanceProbe("take.verdict", text: verdict.rawValue)
                        TextField("Describe what you observed in this take", text: $observation)
                            .reviewAcceptanceProbe("take.observation", text: observation)
                        HStack {
                            TextField("Start seconds", value: $start, format: .number)
                                .reviewAcceptanceProbe("take.start", text: String(start))
                            TextField("End seconds", value: $end, format: .number)
                                .reviewAcceptanceProbe("take.end", text: String(end))
                        }
                        let canRecord = !busy && !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && start.isFinite && end.isFinite && start >= 0 && end > start && end <= snapshot.durationSeconds
                        Button("Record pass") {
                            findings.append(.init(pass: pass, verdict: verdict, observation: observation, startSeconds: start, endSeconds: end))
                            observation = ""; verdict = .conforms; start = 0; end = snapshot.durationSeconds
                        }
                        .buttonStyle(InlineActionButtonStyle(variant: .approval))
                        .reviewAcceptanceProbe("take.record-pass", state: canRecord, text: String(findings.count))
                        .disabled(!canRecord)
                    } else {
                        ForEach(findings, id: \.pass) { finding in
                            Text("\(finding.pass.label): \(verdictLabel(finding.verdict)) — \(finding.observation)")
                        }
                        Button("Save take review") {
                            busy = true
                            Task {
                                do {
                                    try await TakeReview.save(snapshot: snapshot, findings: findings, editor: editor)
                                    await editor.refreshEngineState()
                                    message = "Review saved for this exact take. Rejected takes cannot pass Render approval."
                                    canSelect = findings.count == TakeReview.Pass.allCases.count && findings.allSatisfy { $0.verdict != .rejected }
                                } catch { message = error.localizedDescription }
                                busy = false
                            }
                        }.buttonStyle(InlineActionButtonStyle(variant: .approval))
                            .reviewAcceptanceProbe("take.save", state: !busy && canWrite, text: String(findings.count))
                            .disabled(busy || !canWrite)
                        Button("Review again") { findings = []; observation = ""; verdict = .conforms; start = 0; end = snapshot.durationSeconds; canSelect = false }
                            .reviewAcceptanceProbe("take.review-again", state: !busy)
                            .buttonStyle(InlineActionButtonStyle()).disabled(busy)
                    }
                }
            }
            if let message { Text(message).foregroundStyle(AppTheme.Text.secondaryColor).reviewAcceptanceProbe("take.message", text: message) }
            if !canWrite { Text("Save reviews and select takes during Render. Rewind Render before changing an approved selection.").foregroundStyle(AppTheme.Text.secondaryColor) }
        }
        .padding(AppTheme.Spacing.lg)
        }
        .frame(minWidth: AppTheme.Layout.takeReviewWidth)
        .frame(maxHeight: AppTheme.Layout.takeReviewMaxHeight)
        .interfaceFont(size: AppTheme.Typography.ui)
        .task(id: editor.engineStateRevision) { await load() }
        .task(id: selectedID) { await select() }
        .onDisappear { player?.pause() }
        .onChange(of: editor.workingRoot) { _, _ in presented = false; snapshot = nil; player?.pause(); player = nil }
    }

    private func load() async {
        let token = UUID(); loadToken = token
        let generation = editor.openWorkingCopyGeneration
        let revision = editor.engineStateRevision
        canWrite = false
        queue = nil
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else { return }
        canWrite = (try? PipelinePhaseAccess.requireCurrentPhaseAndIntake("render", dataRoot: root,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            declaredProductionContract: editor.declaredProductionContract)) != nil
        do {
            let productionV2 = editor.usesProductionPlanningV2
            let values = try await Task.detached(priority: .userInitiated) {
                let project = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile).project
                let projection = productionV2 ? try ProductionPlanningLineageV2.projection(dataRoot: root) : nil
                let choices = try ["preview", "final"].flatMap { phase in
                    try PipelineRenderTakeStore.load(dataRoot: root, project: project, phase: phase).takeIDs.map {
                        let take = try PipelineRenderTakeStore.take(id: $0, dataRoot: root)
                        let number = projection?.shots.firstIndex { $0.id == take.shotID }
                        return TakeChoice(take: take, shotLabel: number.map { String(localized: "Shot \($0 + 1)") }
                            ?? (productionV2 ? String(localized: "Previous plan shot") : take.shotID))
                    }
                }
                return choices
            }.value
            guard !Task.isCancelled, loadToken == token, editor.workingRoot == home,
                  editor.openWorkingCopyGeneration == generation, editor.engineStateRevision == revision else { return }
            takes = values.sorted { $0.take.recordedAt > $1.take.recordedAt }
            guard productionV2 else { return }
            let loadedQueue = try await TakeReviewQueue.load(takes: values.map(\.take), dataRoot: root)
            guard !Task.isCancelled, loadToken == token, editor.workingRoot == home,
                  editor.openWorkingCopyGeneration == generation, editor.engineStateRevision == revision else { return }
            queue = loadedQueue; queueHome = home; queueGeneration = generation; queueRevision = revision
        } catch {
            if !Task.isCancelled, loadToken == token, editor.workingRoot == home,
               editor.openWorkingCopyGeneration == generation { message = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func nextShotView(_ snapshot: TakeReview.Snapshot) -> some View {
        if snapshot.take.phase == "final", queueHome == editor.workingRoot,
           queueGeneration == editor.openWorkingCopyGeneration, queueRevision == editor.engineStateRevision,
           let queue {
            TakeReviewNextShotView(queue: queue, shotID: snapshot.take.shotID, enabled: !busy) { takeID in
                player?.pause(); selectedID = takeID
            }
        }
    }

    private func select() async {
        player?.pause(); player = nil; snapshot = nil; findings = []; observation = ""; message = nil; canSelect = false
        guard !selectedID.isEmpty, let home = editor.workingRoot else { return }
        let id = selectedID
        busy = true
        defer { busy = false }
        do {
            let value = try await TakeReview.capture(takeID: id, home: home)
            guard selectedID == id, editor.workingRoot == home else { return }
            snapshot = value; start = 0; end = value.durationSeconds; verdict = .conforms
            player = AVPlayer(url: value.mediaURL)
            if let root = DataRootResolver.dataRoot(of: home), let review = try TakeReview.load(take: value.take, dataRoot: root) {
                findings = review.findings; canSelect = review.accepted
            }
        } catch { if selectedID == id, editor.workingRoot == home { message = error.localizedDescription } }
    }

    private func verdictLabel(_ value: TakeReview.Verdict) -> String {
        switch value {
        case .conforms: String(localized: "Meets the approved plan")
        case .rejected: String(localized: "Rejected")
        case .acceptedDeviation: String(localized: "Accepted deviation")
        case .notApplicable: String(localized: "Not applicable")
        }
    }
}
