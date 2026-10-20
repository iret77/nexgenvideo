import AVKit
import NexGenEngine
import SwiftUI
import UniformTypeIdentifiers

struct ShotBlockoutView: View {
    let expected: ShotPlanningDraftV1
    let shotID: String
    let home: URL
    var onSaved: (ShotPlanningDraftV1) -> Void = { _ in }
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var source: PipelineNativeBlockoutStore.ImportedSource?
    @State private var player: AVPlayer?
    @State private var start = "0"
    @State private var observation = ""
    @State private var reviewed = false
    @State private var importing = false
    @State private var busy = false
    @State private var failure: String?
    @State private var receipt: PipelineNativeBlockoutStore.Receipt?
    @State private var operation: Task<Void, Never>?
    @State private var timing: StoryboardTimingV1?
    @State private var confirmingRemoval = false

    private var shot: ShotPlanningDraftV1.ShotIntent? { expected.shots.first { $0.shotID == shotID } }
    private var active: Bool {
        editor.workingRoot == home && editor.projectState?.nextPhaseName == "shot_planning" && !busy
            && !editor.agentService.isStreaming && !editor.agentService.isComposerBlocked
    }
    private var rangeStart: CMTime? {
        guard let timing, let ticks = try? ProductionTimeEntry.ticks(start, timebase: timing.timebase) else { return nil }
        return CMTime(value: ticks, timescale: Int32(timing.timebase.ticksPerSecond))
    }
    private var canAttach: Bool {
        active && selectedRange != nil && reviewed && !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var selectedRange: CMTimeRange? {
        guard let source, let start = rangeStart, let timing,
              let shot = timing.shots.first(where: { $0.id == shotID }) else { return nil }
        let range = CMTimeRange(start: start,
            duration: CMTime(value: shot.durationTicks, timescale: Int32(timing.timebase.ticksPerSecond)))
        guard CMTimeCompare(range.start, source.videoRange.start) >= 0,
              CMTimeCompare(range.end, source.videoRange.end) <= 0 else { return nil }
        return range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Shot blockout").interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("Export plan/elevation from every confirmed object and camera pose, or attach a reviewed blockout video as geometry conditioning. Appearance and final takes remain separate.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if let receipt, let root = DataRootResolver.dataRoot(of: home) {
                        Text(receipt.kind == .planElevation ? "Plan/elevation schematic · evaluated world-axis mesh bounds" : "Confirmed geometry clip · \(receipt.originalName ?? "Blockout")")
                            .reviewAcceptanceProbe("shot.blockout.current", text: receipt.output.sha256)
                        ProductionInputPreview(reference: receipt.output, dataRoot: root, title: "Current blockout")
                        Text(receipt.observation).textSelection(.enabled)
                        Button("Export MOV…") { export(receipt, root: root) }.buttonStyle(InlineActionButtonStyle()).disabled(busy)
                            .reviewAcceptanceProbe("shot.blockout.export")
                    }
                    if shot?.camera.blockingReference != nil {
                        Button("Remove blockout assignment") { remove(all: false) }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                            .reviewAcceptanceProbe("shot.blockout.remove", state: active)
                    }
                    if expected.shots.contains(where: { $0.camera.blockingReference != nil }) {
                        Button("Remove all blockout assignments…") { confirmingRemoval = true }
                            .buttonStyle(InlineActionButtonStyle()).disabled(!active)
                            .reviewAcceptanceProbe("shot.blockout.remove-all", state: active)
                        Text("If another shot's blockout is out of date, remove the assignments together, then review and attach each clip again. Confirmed poses and original files are retained.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    Button("Create plan/elevation MOV") { attach(imported: nil) }
                        .buttonStyle(InlineActionButtonStyle()).disabled(!active || shot?.camera.spatialState == nil)
                        .reviewAcceptanceProbe("shot.blockout.plan", state: active && shot?.camera.spatialState != nil)
                    Text("Elevation is above Plan. Matching numbers identify the same location. Dashed lines show camera movement; solid arrows show camera direction. The diagram shows bounding boxes, not perspective or appearance, and is not sent to a model.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    AppDivider()
                    Button("Choose blockout MOV…") { importing = true }.buttonStyle(InlineActionButtonStyle()).disabled(!active || timing == nil)
                        .reviewAcceptanceProbe("shot.blockout.choose", state: active && timing != nil)
                    if let source {
                        Text(source.url.lastPathComponent).reviewAcceptanceProbe("shot.blockout.source", text: source.sha256)
                        Text("Available video: \(source.videoRange.start.seconds.formatted())–\(source.videoRange.end.seconds.formatted()) s")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        TextField("Source start (seconds)", text: $start).disabled(!active)
                            .reviewAcceptanceProbe("shot.blockout.start", text: start)
                        if selectedRange == nil {
                            Text("Choose a start within the video with enough time for the complete planned shot.")
                                .foregroundStyle(AppTheme.Status.warningColor)
                        }
                        if let player {
                            VideoPlayer(player: player).frame(height: AppTheme.Layout.productionAssetPreviewHeight)
                                .accessibilityLabel("Selected blockout interval")
                                .reviewAcceptanceProbe("shot.blockout.player", text: source.sha256)
                        }
                        Button("Preview selected interval") { preview() }.buttonStyle(InlineActionButtonStyle()).disabled(!active || selectedRange == nil)
                            .reviewAcceptanceProbe("shot.blockout.preview")
                        Toggle("I watched this interval and confirmed its camera, layout and blocking for this shot", isOn: $reviewed).disabled(!active)
                            .reviewAcceptanceProbe("shot.blockout.reviewed", state: reviewed)
                        TextField("What matches this shot's confirmed state", text: $observation, axis: .vertical).disabled(!active)
                            .reviewAcceptanceProbe("shot.blockout.observation", text: observation)
                        Text("The original file and selected interval are preserved. Confirming replaces any generated Clay conditioning assignment for this shot.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Button("Use geometry clip") { attach(imported: source) }.buttonStyle(CapsuleButtonStyle(variant: .prominent)).disabled(!canAttach)
                            .reviewAcceptanceProbe("shot.blockout.confirm", state: canAttach)
                    }
                    if shot?.camera.spatialState == nil { Text("Confirm a camera and its poses in Plan spatial state first.").foregroundStyle(AppTheme.Status.warningColor) }
                    if busy { ProgressView("Preparing blockout…") }
                    if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled).reviewAcceptanceProbe("shot.blockout.error", text: failure) }
                }
            }
            HStack {
                if busy { Button("Cancel") { operation?.cancel() }.buttonStyle(InlineActionButtonStyle()) }
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Done") { dismiss() }.buttonStyle(InlineActionButtonStyle()).disabled(busy)
                    .reviewAcceptanceProbe("shot.blockout.done", state: !busy)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .interactiveDismissDisabled(busy)
        .alert("Remove all blockout assignments?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove all assignments", role: .destructive) { remove(all: true) }
        } message: {
            Text("This removes \(expected.shots.filter { $0.camera.blockingReference != nil }.count) assignments. Confirmed poses, Clay videos and original files remain. Review each blockout again before reattaching it.")
        }
        .reviewAcceptanceProbe("shot.blockout.sheet")
        .task { await load() }
        .onChange(of: start) { _, _ in reviewed = false; player?.pause() }
        .onDisappear { operation?.cancel(); player?.pause() }
        .onChange(of: editor.openWorkingCopyGeneration) { _, _ in operation?.cancel(); player?.pause(); dismiss() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.quickTimeMovie], allowsMultipleSelection: false) { result in
            guard active else { return }
            do {
                guard let url = try result.get().first else { return }
                busy = true; failure = nil; reviewed = false
                operation = Task {
                    defer { busy = false; operation = nil }
                    do {
                        let value = try await Task.detached(priority: .userInitiated) { try await PipelineNativeBlockoutStore.inspect(url) }.value
                        guard !Task.isCancelled, editor.workingRoot == home else { return }
                        source = value; player = nil
                        if let timing {
                            let firstTick = CMTimeConvertScale(value.videoRange.start,
                                timescale: Int32(timing.timebase.ticksPerSecond), method: .roundTowardPositiveInfinity).value
                            start = ProductionTimeEntry.seconds(firstTick, timebase: timing.timebase)
                        } else { start = "0" }
                    } catch { if !Task.isCancelled { failure = error.localizedDescription } }
                }
            } catch { failure = error.localizedDescription }
        }
    }

    private func load() async {
        guard let root = DataRootResolver.dataRoot(of: home) else { return }
        let expected = expected, target = shot
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                let board = try PlanningWriterIO.storyboard(dataRoot: root)
                let current = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: board)
                guard current == expected else { throw ToolError("Shot Planning changed. Reopen the current shot.") }
                let receipt: PipelineNativeBlockoutStore.Receipt?
                if let target, let reference = target.camera.blockingReference {
                    _ = try PipelineNativeBlockoutStore.references(reference, shot: target, dataRoot: root)
                    receipt = try PipelineNativeBlockoutStore.read(reference, dataRoot: root)
                } else { receipt = nil }
                return (board.timing, receipt)
            }.value
            guard !Task.isCancelled, editor.workingRoot == home else { return }
            timing = value.0; receipt = value.1
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func preview() {
        guard let source, let range = selectedRange else {
            failure = "The selected blockout interval must cover the complete planned shot."; return
        }
        let item = AVPlayerItem(url: source.url)
        item.reversePlaybackEndTime = range.start; item.forwardPlaybackEndTime = range.end
        let value = AVPlayer(playerItem: item); value.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        player?.pause(); player = value; value.play(); failure = nil
    }

    private func attach(imported: PipelineNativeBlockoutStore.ImportedSource?) {
        guard active, imported == nil || canAttach, let start = imported == nil ? CMTime.zero : rangeStart else { return }
        busy = true; failure = nil; player?.pause()
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let result = try await PipelineNativeBlockoutStore.attach(shotID: shotID, expected: expected,
                    imported: imported, start: start, observation: observation, editor: editor)
                onSaved(result); dismiss()
            } catch is CancellationError { failure = "Blockout preparation was cancelled. No assignment was changed." }
            catch { failure = error.localizedDescription }
        }
    }

    private func remove(all: Bool) {
        guard active, let shot else { return }
        let ids: Set<String> = all ? Set(expected.shots.filter { $0.camera.blockingReference != nil }.map(\.shotID)) : [shot.shotID]
        busy = true; failure = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let result = try await PipelineShotPlanningEditor.removeBlockouts(shotIDs: ids, in: expected, editor: editor)
                onSaved(result); dismiss()
            } catch { failure = error.localizedDescription }
        }
    }

    private func export(_ receipt: PipelineNativeBlockoutStore.Receipt, root: URL) {
        let key = editor.openWorkingCopyKey, generation = editor.openWorkingCopyGeneration
        let protected = [Optional(home), editor.projectURL].compactMap { $0 }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = receipt.kind == .planElevation ? "Shot plan and elevation.mov" : (receipt.originalName ?? "Shot blockout.mov")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            guard editor.workingRoot == home, editor.openWorkingCopyKey == key, editor.openWorkingCopyGeneration == generation else {
                failure = "The project changed while choosing an export destination. Export from the current shot again."; return
            }
            busy = true; failure = nil
            operation = Task {
                defer { busy = false; operation = nil }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try PipelineNativeBlockoutStore.requireExportDestination(destination, protectedRoots: protected)
                        let source = try ProjectLocalFile.requireHash(receipt.output.sha256, at: receipt.output.path, dataRoot: root)
                        let bytes = try Data(contentsOf: source)
                        guard FileDigest.sha256(of: bytes) == receipt.output.sha256 else { throw ToolError("The blockout bytes changed.") }
                        try bytes.write(to: destination, options: .atomic)
                    }.value
                } catch { failure = error.localizedDescription }
            }
        }
    }
}
