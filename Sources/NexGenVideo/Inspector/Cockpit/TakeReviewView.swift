import AVKit
import SwiftUI
import NexGenEngine

private struct TakeLoadKey: Hashable {
    let home: URL?
    let revision: Int
}

struct TakeReviewView: View {
    @Environment(EditorViewModel.self) private var editor
    var allowsMutation = true
    var readOnlyReason: String?
    @State private var presented = false
    @State private var takes: [PipelineRenderTakeV1] = []
    @State private var loadToken = 0
    @State private var loadError: String?
    @State private var selectedID = ""
    @State private var snapshot: TakeReview.Snapshot?
    @State private var player: AVPlayer?
    @State private var playbackSeconds = 0.0
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
            .accessibilityIdentifier("production.render.review-takes")
            .sheet(isPresented: $presented) { reviewSheet }
            .task(id: TakeLoadKey(home: editor.workingRoot, revision: editor.engineStateRevision)) {
                await load()
            }
            .onChange(of: editor.workingRoot) { _, _ in
                loadToken += 1
                presented = false
                takes = []
                loadError = nil
                canWrite = false
                selectedID = ""
                snapshot = nil
                player?.pause()
                player = nil
            }
            .overlay(alignment: .topLeading) {
                if let take = takes.first {
                    AppRelaunchClickProbe(
                        identifier: "production.artifact.render",
                        acceptanceValue: "render:\(take.shotID):\(take.id)"
                    )
                    .frame(width: AppTheme.BorderWidth.hairline, height: AppTheme.BorderWidth.hairline)
                    .allowsHitTesting(false)
                }
            }
    }

    private var reviewSheet: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Video takes").fontWeight(AppTheme.FontWeight.semibold)
                Spacer()
                Button("Close") { presented = false }
                    .buttonStyle(InlineActionButtonStyle())
                    .accessibilityIdentifier("production.render.review-close")
            }
            if takes.isEmpty {
                if loadError == nil {
                    Text("No recorded video takes. Record a completed render to begin review.")
                }
            } else {
                Picker("Take", selection: $selectedID) {
                    Text("Choose a take").tag("")
                    ForEach(takes, id: \.id) { take in
                        Text("\(take.shotID) · \(take.phase) · \(take.recordedAt) · \(take.id.prefix(8))").tag(take.id)
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("production.render.take-picker")
                if let snapshot {
                    VideoPlayer(player: player)
                        .frame(minHeight: AppTheme.Layout.previewMinHeight)
                        .accessibilityIdentifier("production.render.player")
                        .overlay(alignment: .topLeading) {
                            if WorkspaceUIAcceptance.isRequested {
                                AppRelaunchClickProbe(
                                    identifier: "production.render.playback-seconds",
                                    acceptanceValue: String(format: "%.3f", playbackSeconds)
                                )
                                .frame(width: AppTheme.BorderWidth.hairline, height: AppTheme.BorderWidth.hairline)
                                .allowsHitTesting(false)
                            }
                        }
                    Button("Play take") { player?.play() }
                        .buttonStyle(InlineActionButtonStyle())
                        .disabled(player == nil)
                        .accessibilityIdentifier("production.render.play-take")
                    TakeRangeReviewView(
                        snapshot: snapshot,
                        wholeTakePlayer: player,
                        canWrite: canWrite && allowsMutation
                    )
                    .id(snapshot.take.id)
                    TakeRepairView(snapshot: snapshot, canWrite: canWrite && allowsMutation)
                        .id(snapshot.take.id)
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
                        .background(
                            AppRelaunchClickProbe(
                                identifier: "production.render.references.content"
                            )
                        )
                    }
                    .accessibilityIdentifier("production.render.references")
                    Button("Use reviewed take") {
                        busy = true
                        Task {
                            do {
                                try await TakeReview.select(take: snapshot.take, home: snapshot.home, editor: editor)
                                message = "Take selected. Its source and conditioning were revalidated."
                            } catch { message = error.localizedDescription }
                            busy = false
                        }
                    }
                    .buttonStyle(InlineActionButtonStyle(variant: .approval))
                    .disabled(busy || !canSelect || !canWrite || !allowsMutation)
                    .accessibilityIdentifier("production.render.use-take")
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
                        .disabled(!allowsMutation)
                        .accessibilityIdentifier("production.render.finding")
                        TextField("Describe what you observed in this take", text: $observation)
                            .disabled(!allowsMutation)
                            .accessibilityIdentifier("production.render.observation")
                            .background {
                                if WorkspaceUIAcceptance.isRequested {
                                    AppRelaunchClickProbe(
                                        identifier: "production.render.findings-count",
                                        acceptanceValue: String(findings.count)
                                    )
                                    .frame(width: AppTheme.BorderWidth.hairline, height: AppTheme.BorderWidth.hairline)
                                    .allowsHitTesting(false)
                                }
                            }
                        HStack {
                            TextField("Start seconds", value: $start, format: .number)
                            TextField("End seconds", value: $end, format: .number)
                        }
                        .disabled(!allowsMutation)
                        Button("Record pass") {
                            findings.append(.init(pass: pass, verdict: verdict, observation: observation, startSeconds: start, endSeconds: end))
                            observation = ""; verdict = .conforms; start = 0; end = snapshot.durationSeconds
                        }
                        .buttonStyle(InlineActionButtonStyle(variant: .approval))
                        .disabled(!allowsMutation || busy || observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !start.isFinite || !end.isFinite || start < 0 || end <= start || end > snapshot.durationSeconds)
                        .accessibilityIdentifier("production.render.record-pass")
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
                        }
                        .buttonStyle(InlineActionButtonStyle(variant: .approval))
                        .disabled(busy || !canWrite || !allowsMutation)
                        .accessibilityIdentifier("production.render.save-review")
                        Button("Review again") { findings = []; observation = ""; verdict = .conforms; start = 0; end = snapshot.durationSeconds; canSelect = false }
                            .buttonStyle(InlineActionButtonStyle())
                            .disabled(busy || !allowsMutation)
                    }
                }
            }
            if let loadError { Text(loadError).foregroundStyle(AppTheme.Text.secondaryColor) }
            if let message { Text(message).foregroundStyle(AppTheme.Text.secondaryColor) }
            if !effectiveCanWrite {
                Text(readOnlyReason ?? "Take changes are available only during the current Render phase.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
        .padding(AppTheme.Spacing.lg)
        }
        .frame(minWidth: AppTheme.Layout.takeReviewWidth)
        .frame(maxHeight: AppTheme.Layout.takeReviewMaxHeight)
        .interfaceFont(size: AppTheme.Typography.ui)
        .task(id: selectedID) {
            await select()
            guard WorkspaceUIAcceptance.isRequested else { return }
            while !Task.isCancelled {
                let seconds = player?.currentTime().seconds ?? 0
                playbackSeconds = seconds.isFinite ? seconds : 0
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onDisappear { player?.pause() }
    }

    private var effectiveCanWrite: Bool { canWrite && allowsMutation }

    private func load() async {
        loadToken += 1
        let token = loadToken
        let revision = editor.engineStateRevision
        loadError = nil
        guard let home = editor.workingRoot,
              let root = DataRootResolver.dataRoot(of: home) else {
            canWrite = false
            takes = []
            selectedID = ""
            snapshot = nil
            player?.pause()
            player = nil
            return
        }
        let writeAllowed = (try? PipelinePhaseAccess.requireCurrentPhaseAndIntake(
            "render", dataRoot: root,
            declaredPack: editor.declaredPluginName,
            declaredBinding: editor.declaredPluginBinding
        )) != nil
        canWrite = writeAllowed
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let project = try YAMLArtifactStore(dataRoot: root)
                .load(ProjectMeta.self, at: PipelineLayout.projectFile).project
            let values = try ["preview", "final"].flatMap { phase in
                try PipelineRenderTakeStore.load(dataRoot: root, project: project, phase: phase).takeIDs.map { id in
                    try Task.checkCancellation()
                    return try PipelineRenderTakeStore.take(id: id, dataRoot: root)
                }
            }
            try Task.checkCancellation()
            return values
        }
        do {
            let values = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, loadToken == token,
                  editor.workingRoot == home,
                  editor.engineStateRevision == revision else { return }
            takes = values.sorted { $0.recordedAt > $1.recordedAt }
            if !selectedID.isEmpty && !takes.contains(where: { $0.id == selectedID }) {
                selectedID = ""
            }
        } catch {
            guard !Task.isCancelled, loadToken == token,
                  editor.workingRoot == home,
                  editor.engineStateRevision == revision else { return }
            canWrite = false
            loadError = error.localizedDescription
        }
    }

    private func select() async {
        player?.pause(); player = nil; playbackSeconds = 0; snapshot = nil; findings = []; observation = ""; message = nil; canSelect = false
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
