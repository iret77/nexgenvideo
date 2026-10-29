import NexGenEngine
import SwiftUI

@Observable final class PlaybackRangeDraft {
    var kind: PlaybackRangeV1.Kind = .fullSong
    var start = ""
    var end = ""
    var baseline: PipelinePlaybackRangeWriter.Snapshot?

    var hasChanges: Bool {
        guard let baseline else { return false }
        return kind != baseline.kind || start != ProductionTimeEntry.seconds(baseline.startTicks, timebase: baseline.timebase)
            || end != ProductionTimeEntry.seconds(baseline.startTicks + baseline.durationTicks, timebase: baseline.timebase)
    }

    func seed(_ value: PipelinePlaybackRangeWriter.Snapshot) {
        baseline = value; kind = value.kind
        start = ProductionTimeEntry.seconds(value.startTicks, timebase: value.timebase)
        end = ProductionTimeEntry.seconds(value.startTicks + value.durationTicks, timebase: value.timebase)
    }
}

struct PlaybackRangeView: View {
    @Environment(EditorViewModel.self) private var editor
    @Bindable var draft: PlaybackRangeDraft
    @State private var snapshot: PipelinePlaybackRangeWriter.Snapshot?
    @State private var snapshotHome: URL?
    @State private var loading = false
    @State private var saving = false
    @State private var failure: String?
    @State private var generation = UUID()
    @State private var audio = PlaybackRangeAudioController()

    private var current: PipelinePlaybackRangeWriter.Snapshot? {
        snapshotHome == editor.workingRoot ? snapshot : nil
    }

    private var editable: Bool {
        guard !loading, !saving, editor.projectState?.nextPhaseName == "brief",
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    private var staleDraft: Bool {
        guard let current, let baseline = draft.baseline else { return false }
        return draft.hasChanges && baseline.fingerprint != current.fingerprint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Song range").fontWeight(AppTheme.FontWeight.semibold)
            Text("Choose the part of the track used by the Storyboard, Animatic and final video.")
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if loading { ProgressView("Reading track…").controlSize(.small) }
            if let current {
                if editable || draft.hasChanges {
                    Picker("Range", selection: $draft.kind) {
                        Text("Full song").tag(PlaybackRangeV1.Kind.fullSong)
                        Text("Excerpt").tag(PlaybackRangeV1.Kind.excerpt)
                    }.pickerStyle(.segmented).disabled(!editable)
                        .reviewAcceptanceProbe("playback-range.kind")
                    if draft.kind == .excerpt {
                        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
                            LabeledContent("Start (s)") {
                                TextField("Start", text: $draft.start).textFieldStyle(.roundedBorder)
                                    .reviewAcceptanceProbe("playback-range.start")
                            }
                            LabeledContent("End (s)") {
                                TextField("End", text: $draft.end).textFieldStyle(.roundedBorder)
                                    .reviewAcceptanceProbe("playback-range.end")
                            }
                        }.disabled(!editable)
                    }
                    if let validation = inputFailure(current) {
                        Text(validation).foregroundStyle(AppTheme.Status.errorColor)
                    }
                    if staleDraft {
                        Text("The saved range changed. Your edits are preserved. Reload the saved range before applying new edits.")
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                    WrapLayout(spacing: AppTheme.Spacing.sm) {
                        Button(saving ? "Applying…" : "Apply range") { Task { await save() } }
                            .buttonStyle(.capsule(.prominent, size: .regular))
                            .disabled(!editable || !draft.hasChanges || staleDraft || inputFailure(current) != nil)
                            .reviewAcceptanceProbe("playback-range.apply")
                        if draft.hasChanges {
                            Button("Discard range edits") { audio.stop(); draft.seed(current); failure = nil }
                                .buttonStyle(.capsule(.secondary, size: .regular)).disabled(saving)
                        }
                    }
                }
                Text(savedDescription(current)).foregroundStyle(AppTheme.Text.secondaryColor)
                    .reviewAcceptanceProbe("playback-range.saved", text: savedDescription(current))
                if !editable && !saving && !loading {
                    Text(editor.projectState?.nextPhaseName == "brief"
                        ? "Wait for the current production action before changing the range."
                        : "Reopen Brief to change the song range.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                HStack(spacing: AppTheme.Spacing.md) {
                    Button(audio.playing || audio.preparing ? "Stop preview" : "Preview range") {
                        if audio.playing || audio.preparing { audio.stop() }
                        else { Task { await preview(current) } }
                    }.buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(saving || loading || (!audio.playing && !audio.preparing && inputFailure(current) != nil))
                        .reviewAcceptanceProbe("playback-range.preview")
                    if audio.preparing { ProgressView().controlSize(.small) }
                    if audio.playing {
                        Text("\(ProductionTimeEntry.seconds(audio.positionTicks, timebase: current.timebase)) s")
                            .monospacedDigit().foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
            } else if !loading && failure == nil {
                Text("Approve Audio Analysis to choose the song range in Brief.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            if let failure = audio.failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            if failure != nil {
                Button("Reload range") { Task { await load() } }
                    .buttonStyle(.capsule(.secondary, size: .regular)).disabled(loading || saving)
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { if !saving { await load() } }
        .onChange(of: draft.kind) { _, _ in audio.stop() }
        .onChange(of: draft.start) { _, _ in audio.stop() }
        .onChange(of: draft.end) { _, _ in audio.stop() }
        .onDisappear { generation = UUID(); audio.stop() }
    }

    private func proposed(_ value: PipelinePlaybackRangeWriter.Snapshot) throws -> (start: Int64, end: Int64) {
        guard draft.baseline != nil else { return (value.startTicks, value.startTicks + value.durationTicks) }
        if draft.kind == .fullSong { return (0, value.audioDurationTicks) }
        let start = try ProductionTimeEntry.ticks(draft.start, timebase: value.timebase)
        let end = try ProductionTimeEntry.ticks(draft.end, timebase: value.timebase)
        guard end > start, end <= value.audioDurationTicks else {
            throw ToolError("Choose an end after the start and within the track's duration.")
        }
        return (start, end)
    }

    private func inputFailure(_ value: PipelinePlaybackRangeWriter.Snapshot) -> String? {
        do { _ = try proposed(value); return nil } catch { return error.localizedDescription }
    }

    private func savedDescription(_ value: PipelinePlaybackRangeWriter.Snapshot) -> String {
        let start = ProductionTimeEntry.seconds(value.startTicks, timebase: value.timebase)
        let end = ProductionTimeEntry.seconds(value.startTicks + value.durationTicks, timebase: value.timebase)
        return value.kind == .fullSong ? "Saved: full song · \(end) s" : "Saved: excerpt · \(start)–\(end) s"
    }

    private func preview(_ value: PipelinePlaybackRangeWriter.Snapshot) async {
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }), snapshotHome == editor.workingRoot else { return }
        do {
            let range = try proposed(value)
            await audio.play(audio: value.audio, timebase: value.timebase, startTicks: range.start, endTicks: range.end, dataRoot: root)
        } catch { failure = error.localizedDescription }
    }

    private func save() async {
        guard editable, !staleDraft, let current else { return }
        let home = editor.workingRoot
        let targetDraft = draft
        audio.stop(); saving = true
        defer { saving = false }
        do {
            let range = try proposed(current)
            let result: PipelinePlaybackRangeWriter.Snapshot
            if draft.kind == .fullSong {
                result = try await PipelinePlaybackRangeWriter.selectFullSong(expectedFingerprint: current.fingerprint, editor: editor)
            } else {
                result = try await PipelinePlaybackRangeWriter.selectExcerpt(startTicks: range.start, durationTicks: range.end - range.start,
                    expectedFingerprint: current.fingerprint, editor: editor)
            }
            targetDraft.seed(result)
            guard editor.workingRoot == home else { return }
            snapshot = result; snapshotHome = home; failure = nil
            await editor.refreshEngineState()
        } catch {
            guard editor.workingRoot == home else { return }
            failure = error.localizedDescription
        }
    }

    private func load() async {
        let token = UUID(); generation = token
        let home = editor.workingRoot
        let targetDraft = draft
        audio.stop(); loading = true
        if snapshotHome != home { snapshot = nil; snapshotHome = home }
        defer { if generation == token { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home) else { return }
        do {
            let value: PipelinePlaybackRangeWriter.Snapshot?
            if editor.projectState?.nextPhaseName == "brief" {
                value = try await PipelinePlaybackRangeWriter.capture(editor: editor)
            } else {
                let pack = editor.declaredPluginBinding
                let core = editor.declaredProductionContract
                value = try await Task.detached(priority: .userInitiated) {
                    guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: pack,
                        expectedProductionContract: core), workflow.isProductionV2, workflow.packID == "musicvideo" else {
                        throw ToolError("The project's Music Video workflow is unavailable.")
                    }
                    let path = root.appendingPathComponent(PlaybackRangeV1.currentPath)
                    guard FileManager.default.fileExists(atPath: path.path) else { return nil as PipelinePlaybackRangeWriter.Snapshot? }
                    let range = try PlanningWriterIO.read(PlaybackRangeV1.self, at: PlaybackRangeV1.currentPath, dataRoot: root)
                    try PipelinePlaybackRangeWriter.requireCanonicalCurrent(range, dataRoot: root, workflowID: workflow.contractID)
                    guard let audio = range.header.inputs.first(where: { $0.role == "musicvideo.track" }) else {
                        throw ToolError("The selected track is missing from the saved range.")
                    }
                    let fingerprint = try FileDigest.sha256(of: Data(contentsOf: ProjectLocalFile.resolve(PlaybackRangeV1.currentPath, dataRoot: root)))
                    return PipelinePlaybackRangeWriter.Snapshot(projectID: range.header.projectID, workflowID: workflow.contractID,
                        analysis: range.analysis, audio: audio, timebase: range.timebase, audioDurationTicks: range.audioDurationTicks,
                        kind: range.kind, startTicks: range.startTicks, durationTicks: range.durationTicks,
                        fingerprint: fingerprint, selectionReceipt: range.selectionReceipt)
                }.value
            }
            guard !Task.isCancelled, editor.workingRoot == home, generation == token else { return }
            if let value, !targetDraft.hasChanges { targetDraft.seed(value) }
            snapshot = value; snapshotHome = home; failure = nil
        } catch {
            guard !Task.isCancelled, editor.workingRoot == home, generation == token else { return }
            snapshot = nil; failure = error.localizedDescription
        }
    }
}
