import AVKit
import NexGenEngine
import SwiftUI

struct SequenceReviewView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var snapshot: PipelineSequenceReviewStore.Snapshot?
    @State private var player: AVPlayer?
    @State private var reviewedAdjacentPairs = false
    @State private var reviewedWholePlayback = false
    @State private var scope = SequenceReviewScopeV1.adjacentPair
    @State private var category = SequenceReviewCategoryV1.stateAndProps
    @State private var severity = SequenceReviewSeverityV1.warning
    @State private var action = SequenceReviewActionV1.localRepair
    @State private var shotIDs = ""
    @State private var startFrame = 0
    @State private var endFrame = 0
    @State private var evidence = ""
    @State private var findings: [SequenceReviewFindingV1] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        DisclosureGroup("Sequence review") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Build a canonical reel from the exact selected sources and review cut continuity separately from whole playback.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                if let snapshot {
                    VideoPlayer(player: player)
                        .frame(minHeight: AppTheme.Layout.previewMinHeight)
                    Text("\(snapshot.plan.selectedMedia.count) sources · \(snapshot.reel.durationFrames) frames · exact EDL \(snapshot.reel.edlSHA256.prefix(10))")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Toggle("I reviewed every adjacent cut", isOn: $reviewedAdjacentPairs)
                        .disabled(busy || snapshot.plan.selectedMedia.count < 2)
                    Toggle("I watched the complete reel with audio", isOn: $reviewedWholePlayback)
                        .disabled(busy)
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
                                Button("Remove") { findings.remove(at: index) }
                                    .buttonStyle(InlineActionButtonStyle())
                                    .disabled(busy)
                            }
                        }
                    }
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Button("Rebuild reel") { beginReview() }
                            .buttonStyle(InlineActionButtonStyle())
                            .disabled(busy)
                        Button("Record review") { save(snapshot: snapshot) }
                            .buttonStyle(InlineActionButtonStyle(variant: .approval))
                            .disabled(
                                busy
                                    || !reviewedWholePlayback
                                    || (snapshot.plan.selectedMedia.count > 1 && !reviewedAdjacentPairs)
                            )
                    }
                } else {
                    Button("Build review reel") { beginReview() }
                        .buttonStyle(InlineActionButtonStyle(variant: .approval))
                        .disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                if let message { Text(message).foregroundStyle(AppTheme.Text.secondaryColor) }
            }
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .onDisappear { player?.pause() }
        .onChange(of: editor.workingRoot) { _, _ in reset() }
    }

    private func findingEditor(
        snapshot: PipelineSequenceReviewStore.Snapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Observed finding").fontWeight(AppTheme.FontWeight.semibold)
            HStack(spacing: AppTheme.Spacing.sm) {
                Picker("Scope", selection: $scope) {
                    Text(SequenceReviewScopeV1.adjacentPair.label).tag(SequenceReviewScopeV1.adjacentPair)
                    Text(SequenceReviewScopeV1.wholePlayback.label).tag(SequenceReviewScopeV1.wholePlayback)
                }
                Picker("Category", selection: $category) {
                    ForEach(SequenceReviewCategoryV1.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Picker("Severity", selection: $severity) {
                    Text("Info").tag(SequenceReviewSeverityV1.info)
                    Text("Warning").tag(SequenceReviewSeverityV1.warning)
                    Text("Blocking").tag(SequenceReviewSeverityV1.blocking)
                }
                Picker("Action", selection: $action) {
                    Text("Accept").tag(SequenceReviewActionV1.accept)
                    Text("Local repair").tag(SequenceReviewActionV1.localRepair)
                    Text("Reroll").tag(SequenceReviewActionV1.reroll)
                    Text("Rescue range").tag(SequenceReviewActionV1.rescue)
                    Text("Rewind plan").tag(SequenceReviewActionV1.rewind)
                }
            }
            TextField("Shot IDs, separated by commas", text: $shotIDs)
                .disabled(busy)
            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("First frame", value: $startFrame, format: .number)
                TextField("End frame", value: $endFrame, format: .number)
            }
            TextField("Describe only what you observed", text: $evidence)
                .disabled(busy)
            Button("Add finding") { addFinding(snapshot: snapshot) }
                .buttonStyle(InlineActionButtonStyle())
                .disabled(busy || !validDraft(snapshot: snapshot))
        }
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
        player?.pause()
        busy = true
        message = nil
        Task {
            do {
                let value = try await PipelineSequenceReviewStore.capture(editor: editor)
                snapshot = value
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
                snapshot = nil
                player = nil
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func save(snapshot: PipelineSequenceReviewStore.Snapshot) {
        busy = true
        message = nil
        let recordedFindings = findings
        Task {
            do {
                try await PipelineSequenceReviewStore.save(
                    snapshot: snapshot,
                    adjacentPairCompleted: reviewedAdjacentPairs,
                    wholePlaybackCompleted: reviewedWholePlayback,
                    findings: recordedFindings,
                    editor: editor
                )
                message = recordedFindings.contains { $0.severity == .blocking }
                    ? "Review recorded. Blocking findings remain open for an explicit repair decision."
                    : "Review recorded for this exact reel, cut order and production input set."
                self.snapshot = nil
                player?.pause()
                player = nil
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func reset() {
        player?.pause()
        player = nil
        snapshot = nil
        reviewedAdjacentPairs = false
        reviewedWholePlayback = false
        findings = []
        busy = false
        message = nil
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
