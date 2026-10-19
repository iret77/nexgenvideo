import AVKit
import Combine
import NexGenEngine
import SwiftUI

struct ProductionSequenceReviewView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var expanded = true
    @State private var snapshot: PipelineProductionSequenceReviewStore.Snapshot?
    @State private var player: AVPlayer?
    @State private var busy = false
    @State private var busyLabel = String(localized: "Preparing film review…")
    @State private var operationID = UUID()
    @State private var persistedBlocking: Set<String> = []
    @State private var resolutions: [String: String] = [:]
    @State private var stale = false
    @State private var message: String?
    @State private var adjacent = false
    @State private var whole = false
    @State private var cut = 0
    @State private var scope = SequenceReviewScopeV1.wholePlayback
    @State private var category = SequenceReviewCategoryV1.stateAndProps
    @State private var severity = SequenceReviewSeverityV1.warning
    @State private var action = SequenceReviewActionV1.localRepair
    @State private var selectedShots: Set<String> = []
    @State private var start = 0
    @State private var end = 0
    @State private var observation = ""
    @State private var findings: [SequenceReviewFindingV1] = []
    @State private var musicObservations: [String: CoverageDraft] = [:]

    private struct CoverageDraft {
        var visible = false
        var startFrame = 0
        var endFrame = 0
        var evidence = ""
    }

    private var available: Bool {
        guard !busy, !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        DisclosureGroup("Film review", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("Review the actual edited film, including its picture, transitions and sound. Changes to the cut, sources or output range require another review.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                if let snapshot {
                    VideoPlayer(player: player)
                        .frame(height: AppTheme.Layout.previewMinHeight)
                        .reviewAcceptanceProbe("sequence.player")
                    Text("\(snapshot.durationFrames) frames · \(snapshot.cutFrames.count) picture boundaries · \(snapshot.input.references.count) bound sources and production records")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            playbackButtons
                            if !snapshot.cutFrames.isEmpty { boundaryPicker(snapshot); inspectButton(snapshot) }
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            playbackButtons
                            if !snapshot.cutFrames.isEmpty { boundaryPicker(snapshot); inspectButton(snapshot) }
                        }
                    }
                    if stale {
                        Text("The timeline changed. Build the current film before recording its review.")
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                    Toggle("I reviewed every picture boundary and adjacent cut", isOn: $adjacent)
                        .disabled(busy || stale || snapshot.cutFrames.isEmpty)
                        .reviewAcceptanceProbe("sequence.adjacent", state: adjacent)
                    Toggle("I watched the complete film and checked its sound", isOn: $whole)
                        .disabled(busy || stale)
                        .reviewAcceptanceProbe("sequence.whole", state: whole)
                    musicCoverageEditor(snapshot)
                    findingEditor(snapshot)
                    ForEach(findings, id: \.id) { finding in
                        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                            Text("\(label(finding.category)) · frames \(finding.startFrame)–\(finding.endFrame): \(finding.evidence)")
                                .textSelection(.enabled)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                if finding.severity == .blocking {
                                    TextField("Explain how this finding was resolved", text: Binding(get: { resolutions[finding.id] ?? "" },
                                        set: { resolutions[finding.id] = $0 }), axis: .vertical)
                                        .reviewAcceptanceProbe("sequence.finding.resolution." + finding.id, text: resolutions[finding.id] ?? "")
                                }
                                Button("Remove") { findings.removeAll { $0.id == finding.id }; resolutions[finding.id] = nil }
                                    .buttonStyle(InlineActionButtonStyle()).disabled(busy || persistedBlocking.contains(finding.id))
                            }
                        }
                    }
                    Button("Record film review") { save(snapshot) }
                        .buttonStyle(InlineActionButtonStyle(variant: .approval))
                        .disabled(!available || stale || !whole || (!snapshot.cutFrames.isEmpty && !adjacent) || !coverageComplete(snapshot))
                        .reviewAcceptanceProbe("sequence.record", state: available && !stale && whole && (snapshot.cutFrames.isEmpty || adjacent) && coverageComplete(snapshot))
                }
                Button(snapshot == nil ? "Build review film" : "Rebuild review film") { build() }
                    .buttonStyle(InlineActionButtonStyle()).disabled(!available)
                    .reviewAcceptanceProbe(snapshot == nil ? "sequence.build" : "sequence.rebuild", state: available)
                if busy { ProgressView(busyLabel).controlSize(.small) }
                if let message {
                    Text(message).foregroundStyle(AppTheme.Text.secondaryColor)
                        .reviewAcceptanceProbe("sequence.message", text: message)
                }
            }
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .reviewAcceptanceProbe("sequence.disclosure", state: expanded)
        .task(id: editor.workingRoot) { reset(); await loadExisting() }
        .onChange(of: editor.timelineRenderRevision) { _, _ in if snapshot != nil { stale = true } }
        .onDisappear { player?.pause() }
        .onChange(of: severity) { _, value in if value == .blocking && action == .accept { action = .localRepair } }
    }

    private var playbackButtons: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Play film") { player?.play() }
                .buttonStyle(InlineActionButtonStyle()).disabled(busy).reviewAcceptanceProbe("sequence.play")
            Button("Pause") { player?.pause() }.buttonStyle(InlineActionButtonStyle()).disabled(busy).reviewAcceptanceProbe("sequence.pause")
        }
    }

    private func boundaryPicker(_ snapshot: PipelineProductionSequenceReviewStore.Snapshot) -> some View {
        Picker("Picture boundary", selection: $cut) {
            ForEach(snapshot.cutFrames, id: \.self) { frame in Text("Frame \(frame)").tag(frame) }
        }.disabled(busy).reviewAcceptanceProbe("sequence.cut", text: String(cut))
    }

    private func inspectButton(_ snapshot: PipelineProductionSequenceReviewStore.Snapshot) -> some View {
        Button("Inspect boundary") { inspectCut(snapshot) }.buttonStyle(InlineActionButtonStyle()).disabled(busy)
            .reviewAcceptanceProbe("sequence.inspect-boundary")
    }

    private func loadExisting() async {
        let operation = UUID(); operationID = operation; busyLabel = String(localized: "Loading film review…"); busy = true
        defer { if operationID == operation { busy = false } }
        do {
            guard let saved = try await PipelineProductionSequenceReviewStore.loadCurrent(editor: editor) else { return }
            guard operationID == operation, !Task.isCancelled, editor.workingRoot == saved.0.home,
                  let root = DataRootResolver.dataRoot(of: saved.0.home) else { return }
            let url = try await Task.detached { try ProjectLocalFile.requireHash(saved.0.reel.sha256, at: saved.0.reel.path, dataRoot: root) }.value
            guard operationID == operation, !Task.isCancelled, editor.workingRoot == saved.0.home else { return }
            snapshot = saved.0; player = AVPlayer(url: url); stale = false
            adjacent = saved.1.adjacentPairCompleted; whole = saved.1.wholePlaybackCompleted; findings = saved.1.findings
            persistedBlocking = Set(saved.1.findings.filter { $0.severity == .blocking }.map(\.id))
            resolutions = Dictionary(uniqueKeysWithValues: saved.1.findingResolutions.map { ($0.findingID, $0.reason) })
            cut = saved.0.cutFrames.first ?? 0; end = saved.0.durationFrames
            musicObservations = Dictionary(uniqueKeysWithValues: saved.1.musicCoverage.map {
                ($0.id, CoverageDraft(visible: $0.visible, startFrame: $0.startFrame, endFrame: $0.endFrame, evidence: $0.evidence))
            })
            message = hasBlockingFindings || saved.1.musicCoverage.contains { !$0.visible }
                ? "Current film review loaded. Blocking findings still prevent delivery."
                : "Current film review loaded. The unchanged cut remains reviewed."
        } catch { if operationID == operation { message = error.localizedDescription; stale = true } }
    }

    @ViewBuilder
    private func musicCoverageEditor(_ snapshot: PipelineProductionSequenceReviewStore.Snapshot) -> some View {
        if !snapshot.input.musicRequirements.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("Music and spatial performance review").fontWeight(AppTheme.FontWeight.semibold)
                Text("Inspect each requirement in this exact final film. Source-camera coverage does not prove visibility in the edited picture.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                ForEach(snapshot.input.musicRequirements) { requirement in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Text(requirement.roleID).fontWeight(AppTheme.FontWeight.semibold)
                        ForEach(Array(requirement.checks.enumerated()), id: \.offset) { _, text in Text(text) }
                        Toggle("Visible and correct in the final film", isOn: coverageBinding(requirement.id, \.visible))
                            .reviewAcceptanceProbe("sequence.music.visible." + requirement.id,
                                state: musicObservations[requirement.id]?.visible ?? false)
                        TextField("Observed first frame", value: coverageBinding(requirement.id, \.startFrame), format: .number)
                            .reviewAcceptanceProbe("sequence.music.start." + requirement.id,
                                text: String(musicObservations[requirement.id]?.startFrame ?? 0))
                        TextField("Observed end frame", value: coverageBinding(requirement.id, \.endFrame), format: .number)
                            .reviewAcceptanceProbe("sequence.music.end." + requirement.id,
                                text: String(musicObservations[requirement.id]?.endFrame ?? 0))
                        TextField("Describe the visible role, hands, body or mouth timing", text: coverageBinding(requirement.id, \.evidence), axis: .vertical)
                            .reviewAcceptanceProbe("sequence.music.evidence." + requirement.id,
                                text: musicObservations[requirement.id]?.evidence ?? "")
                    }
                }
            }.disabled(busy || stale)
        }
    }

    private func coverageBinding<Value>(_ id: String, _ path: WritableKeyPath<CoverageDraft, Value>) -> Binding<Value> {
        Binding(get: { (musicObservations[id] ?? CoverageDraft())[keyPath: path] }, set: { value in
            var draft = musicObservations[id] ?? CoverageDraft()
            draft[keyPath: path] = value
            musicObservations[id] = draft
        })
    }

    private func coverageComplete(_ snapshot: PipelineProductionSequenceReviewStore.Snapshot) -> Bool {
        snapshot.input.musicRequirements.allSatisfy { requirement in
            guard let value = musicObservations[requirement.id], value.startFrame >= 0,
                  value.endFrame > value.startFrame, value.endFrame <= snapshot.durationFrames,
                  !value.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return !value.visible || Double(value.endFrame - value.startFrame) / snapshot.input.edl.timebase.framesPerSecond >= requirement.minimumContinuousSeconds
        }
    }

    private func findingEditor(_ snapshot: PipelineProductionSequenceReviewStore.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Observed finding").fontWeight(AppTheme.FontWeight.semibold)
            Picker("Scope", selection: $scope) {
                Text("Complete playback").tag(SequenceReviewScopeV1.wholePlayback)
                Text("Adjacent cut").tag(SequenceReviewScopeV1.adjacentPair)
            }.reviewAcceptanceProbe("sequence.scope", text: scope.rawValue)
            Picker("Category", selection: $category) {
                ForEach(SequenceReviewCategoryV1.allCases, id: \.self) { category in Text(label(category)).tag(category) }
            }.reviewAcceptanceProbe("sequence.category", text: category.rawValue)
            Picker("Severity", selection: $severity) {
                Text("Info").tag(SequenceReviewSeverityV1.info)
                Text("Warning").tag(SequenceReviewSeverityV1.warning)
                Text("Blocking").tag(SequenceReviewSeverityV1.blocking)
            }.reviewAcceptanceProbe("sequence.severity", text: severity.rawValue)
            Picker("Recommended action", selection: $action) {
                Text("Accept").tag(SequenceReviewActionV1.accept)
                Text("Local repair").tag(SequenceReviewActionV1.localRepair)
                Text("Reroll").tag(SequenceReviewActionV1.reroll)
                Text("Rescue range").tag(SequenceReviewActionV1.rescue)
                Text("Rewind planning").tag(SequenceReviewActionV1.rewind)
            }.reviewAcceptanceProbe("sequence.action", text: action.rawValue)
            DisclosureGroup("Affected planned shots (optional for editorial additions)") {
                ForEach(Array(snapshot.shotIDs.enumerated()), id: \.element) { index, id in
                    Toggle("Shot \(index + 1)", isOn: Binding(get: { selectedShots.contains(id) }, set: { active in
                        if active { selectedShots.insert(id) } else { selectedShots.remove(id) }
                    }))
                }
            }
            TextField("First frame in the review film", value: $start, format: .number)
                .reviewAcceptanceProbe("sequence.start", text: String(start))
            TextField("End frame", value: $end, format: .number)
                .reviewAcceptanceProbe("sequence.end", text: String(end))
            TextField("Describe what you observed", text: $observation, axis: .vertical)
                .reviewAcceptanceProbe("sequence.evidence", text: observation)
            Button("Add finding") {
                findings.append(.init(id: UUID().uuidString.lowercased(), scope: scope, category: category,
                    severity: severity, shotIDs: snapshot.shotIDs.filter { selectedShots.contains($0) }, startFrame: start,
                    endFrame: end, evidence: observation.trimmingCharacters(in: .whitespacesAndNewlines), recommendedAction: action,
                    provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review")))
                observation = ""; selectedShots = []
            }
            .buttonStyle(InlineActionButtonStyle())
            .disabled(!validFinding(snapshot) || busy || stale)
            .reviewAcceptanceProbe("sequence.add", state: validFinding(snapshot) && !busy && !stale)
        }
        .disabled(busy || stale)
    }

    private func validFinding(_ snapshot: PipelineProductionSequenceReviewStore.Snapshot) -> Bool {
        start >= 0 && end > start && end <= snapshot.durationFrames && !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (severity != .blocking || action != .accept)
            && (scope != .adjacentPair || snapshot.cutFrames.contains { start <= $0 && end > $0 })
    }

    private func inspectCut(_ snapshot: PipelineProductionSequenceReviewStore.Snapshot) {
        let fps = snapshot.input.edl.timebase.framesPerSecond
        let frame = max(0, cut - Int(fps.rounded(.up)))
        player?.seek(to: CMTime(seconds: Double(frame) / fps, preferredTimescale: Int32(snapshot.input.edl.timebase.ticksPerSecond)),
            toleranceBefore: .zero, toleranceAfter: .zero)
        scope = .adjacentPair; start = frame; end = min(snapshot.durationFrames, cut + Int(fps.rounded(.up)))
    }

    private func build() {
        guard available else { return }
        let operation = UUID(); operationID = operation
        let previousInput = snapshot?.input
        let previousFindings = findings
        let previousCoverage = musicObservations
        player?.pause(); busyLabel = String(localized: "Preparing film review…"); busy = true; stale = true; message = nil
        Task {
            defer { if operationID == operation { busy = false } }
            do {
                let value = try await PipelineProductionSequenceReviewStore.capture(editor: editor)
                let recorded = try await PipelineProductionSequenceReviewStore.loadCurrent(editor: editor, matchingInputFingerprint: value.input.fingerprint)
                guard operationID == operation, editor.workingRoot == value.home,
                      let root = DataRootResolver.dataRoot(of: value.home) else { return }
                let url = try await Task.detached { try ProjectLocalFile.requireHash(value.reel.sha256, at: value.reel.path, dataRoot: root) }.value
                guard operationID == operation, editor.workingRoot == value.home else { return }
                snapshot = value; player = AVPlayer(url: url); stale = false
                adjacent = value.cutFrames.isEmpty; whole = false
                var retained = Dictionary(uniqueKeysWithValues: (recorded?.1.findings ?? []).map { ($0.id, $0) })
                if previousInput == value.input { for finding in previousFindings where retained[finding.id] == nil { retained[finding.id] = finding } }
                findings = retained.values.sorted { $0.id < $1.id }
                persistedBlocking = Set((recorded?.1.findings ?? []).filter { $0.severity == .blocking }.map(\.id))
                resolutions = Dictionary(uniqueKeysWithValues: (recorded?.1.findingResolutions ?? []).map { ($0.findingID, $0.reason) })
                cut = value.cutFrames.first ?? 0
                start = 0; end = value.durationFrames; observation = ""; selectedShots = []
                musicObservations = Dictionary(uniqueKeysWithValues: value.input.musicRequirements.map {
                    var draft = previousInput == value.input ? previousCoverage[$0.id] ?? CoverageDraft(endFrame: value.durationFrames)
                        : CoverageDraft(endFrame: value.durationFrames)
                    draft.visible = false
                    return ($0.id, draft)
                })
                message = "Review film ready. Observations apply to these exact picture and sound bytes."
            } catch { if operationID == operation { message = error.localizedDescription } }
        }
    }

    private func save(_ value: PipelineProductionSequenceReviewStore.Snapshot) {
        guard available, !stale else { return }
        let operation = UUID(); operationID = operation
        busyLabel = String(localized: "Saving film review…"); busy = true; player?.pause(); message = nil
        let recordedFindings = findings
        let recordedResolutions = findings.filter { $0.severity == .blocking }.compactMap { finding -> ProductionSequenceReviewV2.FindingResolution? in
            guard let reason = resolutions[finding.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return nil }
            return .init(findingID: finding.id, reason: reason)
        }
        let coverage = value.input.musicRequirements.compactMap { requirement -> ProductionMusicCoverageObservationV2? in
            guard let draft = musicObservations[requirement.id] else { return nil }
            return .init(id: requirement.id, visible: draft.visible, startFrame: draft.startFrame,
                endFrame: draft.endFrame, evidence: draft.evidence.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        Task {
            defer { if operationID == operation { busy = false } }
            do {
                try await PipelineProductionSequenceReviewStore.save(snapshot: value, adjacentPairCompleted: adjacent,
                    wholePlaybackCompleted: whole, findings: recordedFindings, musicCoverage: coverage,
                    findingResolutions: recordedResolutions, editor: editor)
                guard operationID == operation, editor.workingRoot == value.home else { return }
                persistedBlocking.formUnion(recordedFindings.filter { $0.severity == .blocking }.map(\.id))
                message = hasBlockingFindings || coverage.contains { !$0.visible }
                    ? "Review recorded. Resolve the blocking findings before delivery."
                    : "Film review recorded for the current cut."
            } catch { if operationID == operation { message = error.localizedDescription } }
        }
    }

    private var hasBlockingFindings: Bool { findings.contains { $0.severity == .blocking && (resolutions[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) } }

    private func reset() { persistedBlocking = []; resolutions = [:]; operationID = UUID(); busy = false; player?.pause(); player = nil; snapshot = nil; findings = []; musicObservations = [:]; stale = false; whole = false; adjacent = false; message = nil }

    private func label(_ category: SequenceReviewCategoryV1) -> String {
        switch category {
        case .identity: "Identity"
        case .stateAndProps: "State and props"
        case .geographyAndScreenDirection: "Geography and screen direction"
        case .actionAndTransition: "Action and transition"
        case .camera: "Camera"
        case .visualArtifact: "Visual artifacts"
        case .timingAndPacing: "Timing and pacing"
        case .audio: "Audio"
        }
    }
}
