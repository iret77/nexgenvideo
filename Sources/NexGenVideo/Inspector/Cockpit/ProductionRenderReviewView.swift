import NexGenEngine
import SwiftUI

@Observable final class ProductionRenderReviewDraft {
    var fingerprint: String?
    var inspected: Set<String> = []
    var findings: [RenderReviewV1.Finding] = []
    var note = ""
    var shotID = ""
    var category: SequenceReviewCategoryV1 = .stateAndProps
    var kind: RenderReviewV1.Finding.Kind = .unresolved

    var hasChanges: Bool { !inspected.isEmpty || !findings.isEmpty || !note.isEmpty }

    func reset(fingerprint: String) {
        self.fingerprint = fingerprint
        inspected = []; findings = []; note = ""; shotID = ""
    }
}

struct ProductionRenderReviewView: View {
    @Environment(EditorViewModel.self) private var editor
    @Bindable var draft: ProductionRenderReviewDraft
    @State private var snapshot: PipelineRenderReviewWriter.Snapshot?
    @State private var review: RenderReviewV1?
    @State private var reviewIsCurrent = false
    @State private var loadedHome: URL?
    @State private var loading = false
    @State private var saving = false
    @State private var failure: String?
    @State private var generation = UUID()
    @State private var loadTask: Task<Void, Never>?
    @State private var accepting: RenderReviewV1.Finding?
    @State private var acceptanceReason = ""

    private var current: PipelineRenderReviewWriter.Snapshot? { loadedHome == editor.workingRoot ? snapshot : nil }
    private var stale: Bool { current.map { draft.hasChanges && draft.fingerprint != $0.fingerprint } ?? false }
    private var writable: Bool {
        guard !saving, !loading, !stale, editor.projectState?.nextPhaseName == "render_review",
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                Text("Review inputs before rendering").interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                Text("Inspect each shot's actual images or source video together with its final direction. Recording this inspection does not authorize generation costs.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                AgentReviewProgressView()
                if loading { ProgressView("Reading current render inputs…") }
                if let current, let home = loadedHome, let root = DataRootResolver.dataRoot(of: home) {
                    if stale {
                        Text("The render inputs changed. Your notes are preserved; inspect the new inputs before recording another review.")
                            .foregroundStyle(AppTheme.Status.warningColor)
                        Button("Discard review draft and reload") { draft.reset(fingerprint: current.fingerprint); Task { await load() } }
                            .buttonStyle(InlineActionButtonStyle()).disabled(saving)
                    }
                    if let review { existingReview(review, snapshot: current) }
                    ForEach(Array(current.shots.enumerated()), id: \.element.shotID) { index, shot in
                        shotCard(shot, number: index + 1, root: root, snapshot: current)
                    }
                    findingEditor(current)
                    if !draft.findings.isEmpty {
                        Text("Your findings").fontWeight(AppTheme.FontWeight.semibold)
                        ForEach(draft.findings, id: \.id) { finding in
                            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                    Text(label(finding.kind)).fontWeight(AppTheme.FontWeight.medium)
                                    Text(finding.message).textSelection(.enabled)
                                }
                                Spacer(minLength: AppTheme.Spacing.sm)
                                Button("Remove") { draft.findings.removeAll { $0.id == finding.id } }
                                    .buttonStyle(InlineActionButtonStyle()).disabled(!writable)
                            }
                        }
                    }
                    HStack {
                        Text("\(draft.inspected.intersection(Set(current.shots.map(\.shotID))).count) of \(current.shots.count) shots inspected")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Button(saving ? "Recording…" : "Record my inspection") { Task { await record(current) } }
                            .buttonStyle(.capsule(.prominent, size: .regular))
                            .disabled(!writable || current.shots.isEmpty || !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || draft.inspected != Set(current.shots.map(\.shotID)))
                            .reviewAcceptanceProbe("render-review.record-native", state: writable && !current.shots.isEmpty
                                && draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && draft.inspected == Set(current.shots.map(\.shotID)))
                    }
                    if editor.projectState?.nextPhaseName != "render_review" {
                        Text("Reopen Render Review to record changes.").foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                    Button("Reload render inputs") { Task { await load() } }.buttonStyle(InlineActionButtonStyle()).disabled(loading || saving)
                }
            }.padding(AppTheme.Spacing.lg).frame(maxWidth: .infinity, alignment: .leading)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { if !saving { await load() } }
        .onDisappear { generation = UUID(); loadTask?.cancel() }
        .sheet(isPresented: Binding(get: { accepting != nil }, set: { if !$0 { accepting = nil } })) {
            if let finding = accepting {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("Keep this creative decision").fontWeight(AppTheme.FontWeight.semibold)
                    Text(finding.message).textSelection(.enabled)
                    TextField("Why is this acceptable?", text: $acceptanceReason, axis: .vertical).textFieldStyle(.roundedBorder)
                    if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
                    HStack {
                        Button("Cancel") { accepting = nil }.keyboardShortcut(.cancelAction)
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Button("Record decision") { Task { await accept(finding) } }
                            .buttonStyle(.capsule(.prominent, size: .regular))
                            .disabled(!writable || acceptanceReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(AppTheme.Spacing.lg).frame(width: AppTheme.Layout.productionDecisionReviewWidth)
            }
        }
        .reviewAcceptanceProbe("render-review.workspace", text: current?.fingerprint)
    }

    private func shotCard(_ shot: PipelineRenderReviewWriter.CapturedShot, number: Int, root: URL,
                          snapshot: PipelineRenderReviewWriter.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Shot \(number)").fontWeight(AppTheme.FontWeight.semibold)
            if let planned = snapshot.projection.shots.first(where: { $0.id == shot.shotID }) {
                Text(planned.primaryAction).textSelection(.enabled)
            }
            if let model = shot.modelID { Text(model).foregroundStyle(AppTheme.Text.secondaryColor) }
            if let prompt = shot.compiledPrompt {
                Text("Final direction").fontWeight(AppTheme.FontWeight.medium)
                Text(prompt).textSelection(.enabled)
                    .reviewAcceptanceProbe("render-review.final-direction.\(shot.shotID)", text: prompt)
            }
            if let source = shot.sourceInput {
                ProductionInputPreview(reference: source, dataRoot: root, title: "Original source · selected range",
                    sourceRange: sourceRange(source, shot: shot))
                    .reviewAcceptanceProbe("render-review.preview.\(shot.shotID).\(source.id)", text: source.sha256)
            }
            let conditioning = mediaReferences(shot.review.conditioning).filter { $0.path != shot.sourceInput?.path }
            if !conditioning.isEmpty {
                Text("Actual generation inputs").fontWeight(AppTheme.FontWeight.medium)
                ForEach(Array(conditioning.enumerated()), id: \.element.path) { index, reference in
                    ProductionInputPreview(reference: reference, dataRoot: root, title: "Input \(index + 1) · \(inputLabel(reference))")
                        .reviewAcceptanceProbe("render-review.preview.\(shot.shotID).\(reference.id)", text: reference.sha256)
                }
            }
            let inputPaths = Set(shot.review.conditioning.map(\.path) + [shot.sourceInput?.path].compactMap { $0 })
            let planning = mediaReferences(shot.review.evidence).filter { !inputPaths.contains($0.path) }
            if !planning.isEmpty {
                DisclosureGroup("Storyboard and review references") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        ForEach(Array(planning.enumerated()), id: \.element.path) { index, reference in
                            ProductionInputPreview(reference: reference, dataRoot: root, title: "Review reference \(index + 1)")
                        .reviewAcceptanceProbe("render-review.preview.\(shot.shotID).\(reference.id)", text: reference.sha256)
                        }
                    }
                }
            }
            if let predecessor = shot.review.predecessor {
                let position = snapshot.shots.firstIndex(where: { $0.shotID == predecessor.predecessorShotID }).map { String($0 + 1) } ?? "unavailable"
                Text(predecessor.strategy == .frameContinuation
                    ? "Continues from the selected end frame of Shot \(position). That frame becomes available after the preceding take is selected."
                    : "Extends the selected video of Shot \(position). The exact predecessor video is bound when its take is selected.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .reviewAcceptanceProbe("render-review.predecessor." + shot.shotID,
                        text: predecessor.strategy.rawValue + ":" + predecessor.predecessorShotID)
            }
            Toggle("I inspected these inputs and the final direction", isOn: Binding(get: { draft.inspected.contains(shot.shotID) }, set: { inspected in
                if inspected { draft.inspected.insert(shot.shotID) } else { draft.inspected.remove(shot.shotID) }
            })).disabled(!writable).reviewAcceptanceProbe("render-review.inspected.\(shot.shotID)", state: draft.inspected.contains(shot.shotID))
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private func existingReview(_ value: RenderReviewV1, snapshot: PipelineRenderReviewWriter.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(!reviewIsCurrent ? "Earlier review — inputs have changed" : value.reviewer.kind == .nativeUser ? "Recorded user inspection" : "Recorded model review")
                .fontWeight(AppTheme.FontWeight.semibold)
            if let model = value.reviewer.modelID { Text(model).foregroundStyle(AppTheme.Text.secondaryColor) }
            ForEach(value.findings, id: \.id) { finding in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("\(label(finding.kind)) · \(label(finding.category))").fontWeight(AppTheme.FontWeight.medium)
                    Text(finding.message).textSelection(.enabled)
                    Text(finding.shotIDs.compactMap { id in snapshot.shots.firstIndex { $0.shotID == id }.map { "Shot \($0 + 1)" } }.joined(separator: ", "))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if let reason = finding.acceptanceReason { Text("Accepted: \(reason)").foregroundStyle(AppTheme.Text.secondaryColor) }
                    else if finding.kind == .semanticConcern || finding.kind == .creativeAdvice {
                        Button("Keep intentionally…") { acceptanceReason = ""; accepting = finding }
                            .buttonStyle(InlineActionButtonStyle()).disabled(!writable || !reviewIsCurrent)
                    }
                }
            }
            if value.findings.isEmpty { Text("No findings recorded.").foregroundStyle(AppTheme.Text.secondaryColor) }
        }
    }

    private func findingEditor(_ snapshot: PipelineRenderReviewWriter.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Add a finding").fontWeight(AppTheme.FontWeight.semibold)
            Picker("Shot", selection: $draft.shotID) {
                Text("Choose shot").tag("")
                ForEach(Array(snapshot.shots.enumerated()), id: \.element.shotID) { index, shot in Text("Shot \(index + 1)").tag(shot.shotID) }
            }
            Picker("Category", selection: $draft.category) {
                ForEach(SequenceReviewCategoryV1.allCases, id: \.self) { category in Text(label(category)).tag(category) }
            }
            Picker("Finding", selection: $draft.kind) {
                ForEach([RenderReviewV1.Finding.Kind.unresolved, .semanticConcern, .creativeAdvice, .information], id: \.self) { kind in Text(label(kind)).tag(kind) }
            }
            TextField("Describe what needs attention", text: $draft.note, axis: .vertical).textFieldStyle(.roundedBorder)
            Button("Add finding") {
                guard let shot = snapshot.shots.first(where: { $0.shotID == draft.shotID }) else { return }
                draft.findings.append(.init(id: "finding-" + UUID().uuidString.lowercased(), kind: draft.kind,
                    category: draft.category, shotIDs: [shot.shotID], message: draft.note,
                    evidence: shot.review.evidence))
                draft.note = ""
            }.buttonStyle(InlineActionButtonStyle())
                .disabled(draft.shotID.isEmpty || draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.disabled(!writable)
    }

    private func record(_ value: PipelineRenderReviewWriter.Snapshot) async {
        guard writable else { return }
        let home = editor.workingRoot, targetDraft = draft
        saving = true; defer { saving = false }
        do {
            let result = try await PipelineRenderReviewWriter.recordNativeReview(snapshot: value, findings: targetDraft.findings, editor: editor)
            targetDraft.reset(fingerprint: value.fingerprint)
            guard home == editor.workingRoot else { return }
            review = result; reviewIsCurrent = true; failure = nil
            await editor.refreshEngineState()
        } catch { if home == editor.workingRoot { failure = error.localizedDescription } }
    }

    private func accept(_ finding: RenderReviewV1.Finding) async {
        guard writable, reviewIsCurrent, let review else { return }
        let home = editor.workingRoot
        saving = true; defer { saving = false }
        do {
            let result = try await PipelineRenderReviewWriter.acceptFinding(id: finding.id, reason: acceptanceReason,
                expectedFingerprint: PipelineRenderReviewWriter.fingerprint(review), editor: editor)
            guard home == editor.workingRoot else { return }
            self.review = result; reviewIsCurrent = true; accepting = nil; failure = nil
            await editor.refreshEngineState()
        } catch { if home == editor.workingRoot { failure = error.localizedDescription } }
    }

    private func load() async {
        let previous = loadTask
        previous?.cancel()
        let token = UUID(); generation = token
        let home = editor.workingRoot, targetDraft = draft
        loading = true; failure = nil
        if loadedHome != home { loadedHome = home; snapshot = nil; review = nil; accepting = nil }
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, generation == token, editor.workingRoot == home,
                  let home, let root = DataRootResolver.dataRoot(of: home) else { return }
            do {
                let value = try await PipelineRenderReviewWriter.capture(editor: editor)
                let stored = try await Task.detached(priority: .userInitiated) {
                    let review = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: root)
                    let isCurrent = review.map { (try? PipelineRenderReviewWriter.requireCurrent($0, root, approval: false)) != nil } ?? false
                    return (review, isCurrent)
                }.value
                guard !Task.isCancelled, generation == token, editor.workingRoot == home else { return }
                snapshot = value; review = stored.0; reviewIsCurrent = stored.1
                if !targetDraft.hasChanges { targetDraft.reset(fingerprint: value.fingerprint) }
            } catch {
                guard !Task.isCancelled, generation == token, editor.workingRoot == home else { return }
                snapshot = nil; review = nil; failure = error.localizedDescription
            }
        }
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == token {
            loadTask = nil
            loading = false
        }
    }

    private func mediaReferences(_ references: [CanonicalArtifactReferenceV1]) -> [CanonicalArtifactReferenceV1] {
        var seen = Set<String>()
        return references.filter {
            let ext = ($0.path as NSString).pathExtension.lowercased()
            return (ProjectMediaExtensions.images.contains(ext) || ProjectMediaExtensions.videos.contains(ext)
                || AudioProjectLayout.audioExtensions.contains(ext)) && seen.insert($0.path).inserted
        }
    }

    private func inputLabel(_ ref: CanonicalArtifactReferenceV1) -> String {
        switch ref.role {
        case "start", "first_frame", "video.first_frame", "core.first-frame": "Start frame"
        case "end", "last_frame", "video.last_frame", "core.last-frame": "End frame"
        case "source_video", "video.source_video", "core.source-video": "Prepared source video"
        case "reference_image", "video.reference_images", "core.reference-anchor": "Reference image"
        case "core.audio-timing", "audio.timing": "Timing audio"
        case "core.voice-reference": "Voice reference"
        default:
            if ProjectMediaExtensions.images.contains((ref.path as NSString).pathExtension.lowercased()) { "Image" }
            else if AudioProjectLayout.audioExtensions.contains((ref.path as NSString).pathExtension.lowercased()) { "Audio" }
            else { "Video" }
        }
    }

    private func sourceRange(_ ref: CanonicalArtifactReferenceV1, shot: PipelineRenderReviewWriter.CapturedShot) -> ProductionInputRange? {
        guard shot.sourceInput?.path == ref.path, shot.sourceInput?.sha256 == ref.sha256,
              ProjectMediaExtensions.videos.contains((ref.path as NSString).pathExtension.lowercased()),
              let range = shot.sourceInputRange else { return nil }
        return .init(timebase: range.timebase, startTicks: range.startTicks, durationTicks: range.durationTicks)
    }

    private func label(_ kind: RenderReviewV1.Finding.Kind) -> String {
        switch kind {
        case .structuralError: "Structural error"
        case .unresolved: "Unresolved issue"
        case .semanticConcern: "Continuity concern"
        case .creativeAdvice: "Creative suggestion"
        case .information: "Information"
        }
    }

    private func label(_ category: SequenceReviewCategoryV1) -> String {
        switch category {
        case .identity: "Identity"
        case .stateAndProps: "State and props"
        case .geographyAndScreenDirection: "Geography and screen direction"
        case .actionAndTransition: "Action and transition"
        case .timingAndPacing: "Timing and pacing"
        case .camera: "Camera"
        case .visualArtifact: "Image quality"
        case .audio: "Audio"
        }
    }
}
