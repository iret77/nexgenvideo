import AVKit
import SwiftUI
import NexGenEngine

struct TakeReviewView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var presented = false
    @State private var takes: [PipelineRenderTakeV1] = []
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

    var body: some View {
        Button("Review video takes") { presented = true }
            .buttonStyle(InlineActionButtonStyle())
            .sheet(isPresented: $presented) { reviewSheet }
    }

    private var reviewSheet: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Video takes").fontWeight(AppTheme.FontWeight.semibold)
                Spacer()
                Button("Close") { presented = false }.buttonStyle(InlineActionButtonStyle())
            }
            if takes.isEmpty { Text("No recorded video takes. Record a completed render to begin review.") }
            else {
                Picker("Take", selection: $selectedID) {
                    Text("Choose a take").tag("")
                    ForEach(takes, id: \.id) { take in
                        Text("\(take.shotID) · \(take.phase) · \(take.recordedAt) · \(take.id.prefix(8))").tag(take.id)
                    }
                }.disabled(busy)
                if let snapshot {
                    VideoPlayer(player: player).frame(minHeight: AppTheme.Layout.previewMinHeight)
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
                    }.buttonStyle(InlineActionButtonStyle(variant: .approval)).disabled(busy || !canSelect || !canWrite)
                    if findings.count < TakeReview.Pass.allCases.count && findings.last?.verdict != .rejected {
                        let pass = TakeReview.Pass.allCases[findings.count]
                        Text("\(findings.count + 1) of 6 · \(pass.label)").fontWeight(AppTheme.FontWeight.semibold)
                        if pass == .identity {
                            Text("Check subject and scene identity, including objects when no person is present.")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        Picker("Finding", selection: $verdict) {
                            Text("Meets the approved plan").tag(TakeReview.Verdict.conforms)
                            Text("Reject").tag(TakeReview.Verdict.rejected)
                            if pass != .identity { Text("Accept deviation — explain").tag(TakeReview.Verdict.acceptedDeviation) }
                            if pass != .identity { Text("Not applicable — explain").tag(TakeReview.Verdict.notApplicable) }
                        }
                        TextField("Describe what you observed in this take", text: $observation)
                        HStack {
                            TextField("Start seconds", value: $start, format: .number)
                            TextField("End seconds", value: $end, format: .number)
                        }
                        Button("Record pass") {
                            findings.append(.init(pass: pass, verdict: verdict, observation: observation, startSeconds: start, endSeconds: end))
                            observation = ""; verdict = .conforms; start = 0; end = snapshot.durationSeconds
                        }
                        .buttonStyle(InlineActionButtonStyle(variant: .approval))
                        .disabled(busy || observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !start.isFinite || !end.isFinite || start < 0 || end <= start || end > snapshot.durationSeconds)
                    } else {
                        ForEach(findings, id: \.pass) { finding in
                            Text("\(finding.pass.label): \(finding.verdict.rawValue) — \(finding.observation)")
                        }
                        Button("Save take review") {
                            busy = true
                            Task {
                                do {
                                    try await TakeReview.save(snapshot: snapshot, findings: findings, editor: editor)
                                    message = "Review saved for this exact take. Rejected takes cannot pass Render approval."
                                    canSelect = findings.count == TakeReview.Pass.allCases.count && findings.allSatisfy { $0.verdict != .rejected }
                                } catch { message = error.localizedDescription }
                                busy = false
                            }
                        }.buttonStyle(InlineActionButtonStyle(variant: .approval)).disabled(busy || !canWrite)
                        Button("Review again") { findings = []; observation = ""; verdict = .conforms; start = 0; end = snapshot.durationSeconds; canSelect = false }
                            .buttonStyle(InlineActionButtonStyle()).disabled(busy)
                    }
                }
            }
            if let message { Text(message).foregroundStyle(AppTheme.Text.secondaryColor) }
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
        canWrite = false
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else { return }
        canWrite = (try? PipelinePhaseAccess.requireCurrentPhaseAndIntake("render", dataRoot: root,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)) != nil
        do {
            let values = try await Task.detached(priority: .userInitiated) {
                let project = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile).project
                return try ["preview", "final"].flatMap { phase in
                    try PipelineRenderTakeStore.load(dataRoot: root, project: project, phase: phase).takeIDs.map {
                        try PipelineRenderTakeStore.take(id: $0, dataRoot: root)
                    }
                }
            }.value
            guard editor.workingRoot == home else { return }
            takes = values.sorted { $0.recordedAt > $1.recordedAt }
        } catch { if editor.workingRoot == home { message = error.localizedDescription } }
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
}
