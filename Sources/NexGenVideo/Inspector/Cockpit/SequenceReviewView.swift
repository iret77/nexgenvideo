import AVKit
import Combine
import Observation
import NexGenEngine
import SwiftUI

struct SequenceReviewView: View {
    @Environment(EditorViewModel.self) private var editor
    private var expanded: Bool { get { draft.expanded } nonmutating set { draft.expanded = newValue } }
    private var snapshot: PipelineSequenceReviewStore.Snapshot? { get { draft.snapshot } nonmutating set { draft.snapshot = newValue } }
    private var player: AVPlayer? { get { draft.player } nonmutating set { draft.player = newValue } }
    private var playing: Bool { get { draft.playing } nonmutating set { draft.playing = newValue } }
    private var reviewedAdjacentPairs: Bool { get { draft.reviewedAdjacentPairs } nonmutating set { draft.reviewedAdjacentPairs = newValue } }
    private var reviewedWholePlayback: Bool { get { draft.reviewedWholePlayback } nonmutating set { draft.reviewedWholePlayback = newValue } }
    private var scope: SequenceReviewScopeV1 { get { draft.scope } nonmutating set { draft.scope = newValue } }
    private var category: SequenceReviewCategoryV1 { get { draft.category } nonmutating set { draft.category = newValue } }
    private var severity: SequenceReviewSeverityV1 { get { draft.severity } nonmutating set { draft.severity = newValue } }
    private var action: SequenceReviewActionV1 { get { draft.action } nonmutating set { draft.action = newValue } }
    private var shotIDs: String { get { draft.shotIDs } nonmutating set { draft.shotIDs = newValue } }
    private var startFrame: Int { get { draft.startFrame } nonmutating set { draft.startFrame = newValue } }
    private var endFrame: Int { get { draft.endFrame } nonmutating set { draft.endFrame = newValue } }
    private var evidence: String { get { draft.evidence } nonmutating set { draft.evidence = newValue } }
    private var findings: [SequenceReviewFindingV1] { get { draft.findings } nonmutating set { draft.findings = newValue } }
    private var busy: Bool { get { draft.busy } nonmutating set { draft.busy = newValue } }
    private var message: String? { get { draft.message } nonmutating set { draft.message = newValue } }
    private var stale: Bool { get { draft.stale } nonmutating set { draft.stale = newValue } }
    private var operationID: UUID { get { draft.operationID } nonmutating set { draft.operationID = newValue } }

    @Observable @MainActor
    final class Draft {
        let id = UUID()
        var expanded = false
        var snapshot: PipelineSequenceReviewStore.Snapshot?
        var player: AVPlayer?
        var playing = false
        var reviewedAdjacentPairs = false
        var reviewedWholePlayback = false
        var scope = SequenceReviewScopeV1.adjacentPair
        var category = SequenceReviewCategoryV1.stateAndProps
        var severity = SequenceReviewSeverityV1.warning
        var action = SequenceReviewActionV1.localRepair
        var shotIDs = ""
        var startFrame = 0
        var endFrame = 0
        var evidence = ""
        var findings: [SequenceReviewFindingV1] = []
        var busy = false
        var message: String?
        var stale = false
        var operationID = UUID()
        var home: URL?
        var workingCopyKey: String?
        var generation: UUID?
        var revision = 0

        func clear() {
            player?.pause()
            expanded = false
            snapshot = nil
            player = nil
            playing = false
            reviewedAdjacentPairs = false
            reviewedWholePlayback = false
            scope = SequenceReviewScopeV1.adjacentPair
            category = SequenceReviewCategoryV1.stateAndProps
            severity = SequenceReviewSeverityV1.warning
            action = SequenceReviewActionV1.localRepair
            shotIDs = ""
            startFrame = 0
            endFrame = 0
            evidence = ""
            findings = []
            busy = false
            message = nil
            stale = false
            operationID = UUID()
        }
    }

    private var draft: Draft { editor.sequenceReviewDraft }

    private var canOpenFinding: Bool {
        guard !busy, !stale, !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              draft.home == editor.workingRoot, draft.workingCopyKey == editor.openWorkingCopyKey,
              draft.generation == editor.openWorkingCopyGeneration,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Build a canonical reel from the exact selected sources and review cut continuity separately from whole playback.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                if let snapshot {
                    Button(playing ? "Pause reel" : "Play reel") {
                        guard let player else { return }
                        if player.rate > 0 {
                            player.pause()
                        } else {
                            if let duration = player.currentItem?.duration, duration.isNumeric,
                               player.currentTime() >= duration { player.seek(to: .zero) }
                            player.play()
                        }
                    }
                    .buttonStyle(InlineActionButtonStyle())
                    .reviewAcceptanceProbe("sequence.play", state: playing)
                    .disabled(busy)
                    VideoPlayer(player: player)
                        .frame(height: AppTheme.Layout.previewMinHeight)
                        .reviewAcceptanceProbe("sequence.player")
                    Text("\(snapshot.plan.selectedMedia.count) sources · \(snapshot.reel.durationFrames) frames · exact EDL \(snapshot.reel.edlSHA256.prefix(10))")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if stale {
                        Text("The timeline changed. Rebuild the reel before continuing this review.")
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                    Toggle("I reviewed every adjacent cut", isOn: Binding(get: { reviewedAdjacentPairs }, set: { reviewedAdjacentPairs = $0 }))
                        .reviewAcceptanceProbe("sequence.adjacent", state: reviewedAdjacentPairs)
                        .disabled(busy || stale || snapshot.plan.selectedMedia.count < 2)
                    Toggle("I watched the complete reel and checked its sound", isOn: Binding(get: { reviewedWholePlayback }, set: { reviewedWholePlayback = $0 }))
                        .reviewAcceptanceProbe("sequence.whole", state: reviewedWholePlayback)
                        .disabled(busy || stale)
                    findingEditor(snapshot: snapshot)
                    if !findings.isEmpty {
                        ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                    Text("\(finding.category.label) · \(finding.scope.label)")
                                        .fontWeight(AppTheme.FontWeight.semibold)
                                    Text("\(finding.shotIDs.joined(separator: ", ")) · \(finding.startFrame)–\(finding.endFrame): \(finding.evidence)")
                                        .foregroundStyle(AppTheme.Text.secondaryColor)
                                }
                                Spacer(minLength: AppTheme.Spacing.none)
                                Button("Open in timeline") { openFinding(finding, snapshot: snapshot) }
                                    .buttonStyle(InlineActionButtonStyle()).disabled(!canOpenFinding)
                                    .reviewAcceptanceProbe("sequence.finding.open." + finding.id, state: canOpenFinding)
                                Button("Remove") { findings.remove(at: index) }
                                    .buttonStyle(InlineActionButtonStyle())
                                    .reviewAcceptanceProbe("sequence.remove.\(index)")
                                    .disabled(busy)
                            }
                        }
                    }
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Button("Rebuild reel") { beginReview() }
                            .buttonStyle(InlineActionButtonStyle())
                            .reviewAcceptanceProbe("sequence.rebuild")
                            .disabled(busy)
                        Button("Record review") { save(snapshot: snapshot) }
                            .buttonStyle(InlineActionButtonStyle(variant: .approval))
                            .reviewAcceptanceProbe("sequence.record")
                            .disabled(
                                busy || stale
                                    || !reviewedWholePlayback
                                    || (snapshot.plan.selectedMedia.count > 1 && !reviewedAdjacentPairs)
                            )
                    }
                } else {
                    Button("Build review reel") { beginReview() }
                        .buttonStyle(InlineActionButtonStyle(variant: .approval))
                        .reviewAcceptanceProbe("sequence.build")
                        .disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                if let message {
                    Text(message).foregroundStyle(AppTheme.Text.secondaryColor)
                        .reviewAcceptanceProbe("sequence.message", text: message)
                }
            }
            .padding(.vertical, AppTheme.Spacing.sm)
        } label: {
            Text("Sequence review")
                .reviewAcceptanceProbe("sequence.disclosure", state: expanded)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .onReceive(player?.publisher(for: \.rate).eraseToAnyPublisher() ?? Just(Float.zero).eraseToAnyPublisher()) {
            playing = $0 > 0
        }
        .task(id: draft.id) { await prepareDraft() }
        .onDisappear { player?.pause(); playing = false }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            if let item = notification.object as? AVPlayerItem, item === player?.currentItem { playing = false }
        }
        .onChange(of: editor.timelineRenderRevision) { _, _ in if snapshot != nil { stale = true } }
    }

    private func findingEditor(
        snapshot: PipelineSequenceReviewStore.Snapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Observed finding").fontWeight(AppTheme.FontWeight.semibold)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Picker("Scope", selection: Binding(get: { scope }, set: { scope = $0 })) {
                    Text(SequenceReviewScopeV1.adjacentPair.label).tag(SequenceReviewScopeV1.adjacentPair)
                    Text(SequenceReviewScopeV1.wholePlayback.label).tag(SequenceReviewScopeV1.wholePlayback)
                }
                .reviewAcceptanceProbe("sequence.scope", text: scope.rawValue)
                Picker("Category", selection: Binding(get: { category }, set: { category = $0 })) {
                    ForEach(SequenceReviewCategoryV1.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Picker("Severity", selection: Binding(get: { severity }, set: { severity = $0 })) {
                    Text("Info").tag(SequenceReviewSeverityV1.info)
                    Text("Warning").tag(SequenceReviewSeverityV1.warning)
                    Text("Blocking").tag(SequenceReviewSeverityV1.blocking)
                }
                .reviewAcceptanceProbe("sequence.severity", text: severity.rawValue)
                Picker("Action", selection: Binding(get: { action }, set: { action = $0 })) {
                    Text("Accept").tag(SequenceReviewActionV1.accept)
                    Text("Local repair").tag(SequenceReviewActionV1.localRepair)
                    Text("Reroll").tag(SequenceReviewActionV1.reroll)
                    Text("Rescue range").tag(SequenceReviewActionV1.rescue)
                    Text("Rewind plan").tag(SequenceReviewActionV1.rewind)
                }
                .reviewAcceptanceProbe("sequence.action", text: action.rawValue)
            }
            TextField("Shot IDs, separated by commas", text: Binding(get: { shotIDs }, set: { shotIDs = $0 }))
                .reviewAcceptanceProbe("sequence.shots", text: shotIDs)
                .disabled(busy)
            TextField("First frame", value: Binding(get: { startFrame }, set: { startFrame = $0 }), format: .number)
                .reviewAcceptanceProbe("sequence.start", text: String(startFrame))
            TextField("End frame", value: Binding(get: { endFrame }, set: { endFrame = $0 }), format: .number)
                .reviewAcceptanceProbe("sequence.end", text: String(endFrame))
            TextField("Describe only what you observed", text: Binding(get: { evidence }, set: { evidence = $0 }), axis: .vertical)
                .reviewAcceptanceProbe("sequence.evidence", text: evidence)
                .disabled(busy)
            Button("Add finding") { addFinding(snapshot: snapshot) }
                .buttonStyle(InlineActionButtonStyle())
                .reviewAcceptanceProbe("sequence.add")
                .disabled(busy || !validDraft(snapshot: snapshot))
        }
        .disabled(busy || stale)
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.Background.raisedColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private func validDraft(snapshot: PipelineSequenceReviewStore.Snapshot) -> Bool {
        let known = Set(snapshot.plan.selectedMedia.map(\.shotID))
        let submitted = parsedShotIDs
        return !submitted.isEmpty
            && Set(submitted).isSubset(of: known)
            && startFrame >= 0
            && endFrame > startFrame
            && endFrame <= snapshot.reel.durationFrames
            && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var parsedShotIDs: [String] {
        shotIDs.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func addFinding(snapshot: PipelineSequenceReviewStore.Snapshot) {
        guard validDraft(snapshot: snapshot) else { return }
        findings.append(SequenceReviewFindingV1(
            id: UUID().uuidString.lowercased(),
            scope: scope,
            category: category,
            severity: severity,
            shotIDs: parsedShotIDs,
            startFrame: startFrame,
            endFrame: endFrame,
            evidence: evidence.trimmingCharacters(in: .whitespacesAndNewlines),
            recommendedAction: action,
            provenance: .init(kind: .nativeUser, reviewerID: "native-user")
        ))
        shotIDs = ""
        startFrame = 0
        endFrame = 0
        evidence = ""
    }

    private func beginReview() {
        guard !busy else { return }
        let operation = UUID(); operationID = operation
        let home = editor.workingRoot
        let revision = editor.timelineRenderRevision
        player?.pause()
        playing = false
        busy = true
        message = nil
        Task {
            defer { if operationID == operation { busy = false } }
            do {
                let value = try await PipelineSequenceReviewStore.capture(editor: editor)
                guard operationID == operation, editor.workingRoot == home, editor.timelineRenderRevision == revision else { return }
                snapshot = value
                stale = false; draft.revision = editor.timelineRenderRevision
                let dataRoot = try Self.requireDataRoot(value.home)
                let reelURL = try ProjectLocalFile.requireHash(
                    value.reel.sha256,
                    at: value.reel.path,
                    dataRoot: dataRoot
                )
                player = AVPlayer(url: reelURL)
                reviewedAdjacentPairs = value.plan.selectedMedia.count < 2
                reviewedWholePlayback = false
                findings = []
                message = "Review reel ready. Playback observations apply only to these exact bytes."
            } catch {
                guard operationID == operation else { return }
                snapshot = nil
                player = nil
                message = error.localizedDescription
            }
        }
    }

    private func openFinding(_ finding: SequenceReviewFindingV1, snapshot: PipelineSequenceReviewStore.Snapshot) {
        guard canOpenFinding else { return }
        let operation = UUID(); operationID = operation
        player?.pause(); message = nil; busy = true
        Task {
            defer { if operationID == operation { busy = false } }
            do { try await PipelineSequenceReviewStore.openFinding(finding, snapshot: snapshot, editor: editor) }
            catch { if operationID == operation { message = error.localizedDescription } }
        }
    }

    private func save(snapshot: PipelineSequenceReviewStore.Snapshot) {
        guard !busy, !stale else { return }
        let operation = UUID(); operationID = operation
        busy = true
        message = nil
        let recordedFindings = findings
        Task {
            defer { if operationID == operation { busy = false } }
            do {
                try await PipelineSequenceReviewStore.save(
                    snapshot: snapshot,
                    adjacentPairCompleted: reviewedAdjacentPairs,
                    wholePlaybackCompleted: reviewedWholePlayback,
                    findings: recordedFindings,
                    editor: editor
                )
                guard operationID == operation, editor.workingRoot == snapshot.home else { return }
                message = recordedFindings.contains { $0.severity == .blocking }
                    ? "Review recorded. Blocking findings remain open for an explicit repair decision."
                    : "Review recorded for this exact reel, cut order and production input set."
                self.snapshot = nil
                player?.pause()
                playing = false
                player = nil
            } catch {
                guard operationID == operation else { return }
                message = error.localizedDescription
            }
        }
    }

    private func prepareDraft() async {
        if draft.home != editor.workingRoot || draft.workingCopyKey != editor.openWorkingCopyKey
            || draft.generation != editor.openWorkingCopyGeneration { reset() }
        guard !busy else { return }
        if stale || draft.revision != editor.timelineRenderRevision { reset() }
    }

    private func reset() {
        draft.clear()
        draft.home = editor.workingRoot
        draft.workingCopyKey = editor.openWorkingCopyKey
        draft.generation = editor.openWorkingCopyGeneration
        draft.revision = editor.timelineRenderRevision
    }

    private static func requireDataRoot(_ home: URL) throws -> URL {
        guard let root = DataRootResolver.dataRoot(of: home) else {
            throw ToolError("The project review directory is unavailable.")
        }
        return root
    }
}

private extension SequenceReviewScopeV1 {
    var label: String {
        switch self {
        case .adjacentPair: "Adjacent pair"
        case .wholePlayback: "Whole playback"
        }
    }
}

private extension SequenceReviewCategoryV1 {
    var label: String {
        switch self {
        case .identity: "Identity"
        case .stateAndProps: "State and props"
        case .geographyAndScreenDirection: "Geography and screen direction"
        case .actionAndTransition: "Action and transition"
        case .timingAndPacing: "Timing and pacing"
        case .camera: "Camera"
        case .visualArtifact: "Visual artifact"
        case .audio: "Audio"
        }
    }
}

private struct ReviewAcceptanceProbe: View {
    @Environment(\.isEnabled) private var isEnabled
    let identifier: String
    let state: Bool?
    let text: String?

    var body: some View {
        if WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested
            || ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"] != nil {
            AppRelaunchClickProbe(identifier: identifier, acceptanceState: state ?? isEnabled, acceptanceText: text)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func reviewAcceptanceProbe(_ identifier: String, state: Bool? = nil, text: String? = nil) -> some View {
        background { ReviewAcceptanceProbe(identifier: identifier, state: state, text: text) }
    }
}
