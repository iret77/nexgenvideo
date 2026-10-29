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
        active && source != nil && rangeStart != nil && reviewed && !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        Button("Remove blockout assignment") { remove() }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                            .reviewAcceptanceProbe("shot.blockout.remove", state: active)
                    }
                    Button("Create plan/elevation MOV") { attach(imported: nil) }
                        .buttonStyle(InlineActionButtonStyle()).disabled(!active || shot?.camera.spatialState == nil)
                        .reviewAcceptanceProbe("shot.blockout.plan", state: active && shot?.camera.spatialState != nil)
                    Text("The diagram shows bounding boxes and camera directions in plan and elevation. It does not render perspective or appearance and is not sent to a model.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Divider()
                    Button("Choose blockout MOV…") { importing = true }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                        .reviewAcceptanceProbe("shot.blockout.choose", state: active)
                    if let source {
                        Text(source.url.lastPathComponent).reviewAcceptanceProbe("shot.blockout.source", text: source.sha256)
                        TextField("Source start (seconds)", text: $start).disabled(!active)
                            .reviewAcceptanceProbe("shot.blockout.start", text: start)
                        if let player {
                            VideoPlayer(player: player).frame(height: AppTheme.Layout.productionAssetPreviewHeight)
                                .accessibilityLabel("Selected blockout interval")
                                .reviewAcceptanceProbe("shot.blockout.player", text: source.sha256)
                        }
                        Button("Preview selected interval") { preview() }.buttonStyle(InlineActionButtonStyle()).disabled(!active || rangeStart == nil)
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
                        source = value; player = nil; start = "0"
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
        guard let source, let start = rangeStart, let timing,
              let shotTiming = timing.shots.first(where: { $0.id == shotID }) else { return }
        let duration = CMTime(value: shotTiming.durationTicks, timescale: Int32(timing.timebase.ticksPerSecond))
        guard CMTimeCompare(CMTimeAdd(start, duration), source.duration) <= 0 else {
            failure = "The selected blockout interval must cover the complete planned shot."; return
        }
        let item = AVPlayerItem(url: source.url)
        item.reversePlaybackEndTime = start; item.forwardPlaybackEndTime = CMTimeAdd(start, duration)
        let value = AVPlayer(playerItem: item); value.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
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

    private func remove() {
        guard let shot else { return }
        busy = true; failure = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let camera = shot.camera
                let replacement = PipelineNativeBlockoutStore.replacing(shot, camera: .init(framing: camera.framing,
                    movement: camera.movement, movementDetail: camera.movementDetail, blocking: camera.blocking,
                    sceneReference: camera.sceneReference, spatialState: camera.spatialState,
                    spatialCameraID: camera.spatialCameraID, spatialDerivation: camera.spatialDerivation))
                let result = try await PipelineShotPlanningEditor.replace(replacement, in: expected, editor: editor)
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
