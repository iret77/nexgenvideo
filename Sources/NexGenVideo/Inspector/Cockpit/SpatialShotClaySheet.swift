import BpyRuntimeProtocol
import NexGenEngine
import SwiftUI

struct SpatialShotClaySheet: View {
    let home: URL
    let shotID: String
    let number: Int
    var onSaved: (ShotPlanningDraftV1) -> Void = { _ in }
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var state: CanonicalArtifactReferenceV1?
    @State private var video: CanonicalArtifactReferenceV1?
    @State private var proof: CanonicalArtifactReferenceV1?
    @State private var duration: String?
    @State private var loading = false
    @State private var operation: Task<Void, Never>?
    @State private var readLifetime = BpyOperationCancellation()
    @State private var failure: String?
    @State private var notice: String?

    private var active: Bool {
        guard !loading, operation == nil, editor.workingRoot == home, editor.projectState?.nextPhaseName == "shot_planning",
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("Clay video · Shot \(number)").interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("Render the confirmed camera and object poses across the whole shot. This local video shows geometry and motion for planning and generation.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if let duration { Text("Planned duration: \(duration) s").monospacedDigit() }
                    if loading {
                        ProgressView("Reading shot state…").reviewAcceptanceProbe("shot-planning.clay.loading", state: true)
                    }
                    if let video, let root = DataRootResolver.dataRoot(of: home) {
                        ProductionInputPreview(reference: video, dataRoot: root, title: "Rendered Clay video")
                            .reviewAcceptanceProbe("shot-planning.clay.video", text: video.sha256)
                            .reviewAcceptanceProbe("shot-planning.clay.proof", text: proof?.sha256)
                    }
                    if state == nil && !loading { Text("Confirm the shot's spatial state before rendering.").foregroundStyle(AppTheme.Status.warningColor) }
                    if operation != nil {
                        ProgressView("Rendering planned shot…").reviewAcceptanceProbe("shot-planning.clay.rendering", state: true)
                    }
                    if let notice {
                        Text(notice).foregroundStyle(AppTheme.Text.secondaryColor)
                            .reviewAcceptanceProbe("shot-planning.clay.cancelled", text: notice)
                    }
                    if let failure {
                        Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                            .reviewAcceptanceProbe("shot-planning.clay.failure", text: failure)
                        Button("Reload shot state") { Task { await load() } }.buttonStyle(InlineActionButtonStyle()).disabled(loading || operation != nil)
                    }
                }
            }
            HStack {
                Button(operation == nil ? "Done" : "Cancel render") {
                    if let operation { operation.cancel() } else { dismiss() }
                }.buttonStyle(InlineActionButtonStyle()).keyboardShortcut(.cancelAction)
                    .reviewAcceptanceProbe("shot-planning.clay.close", text: operation == nil ? "done" : "cancel")
                Spacer()
                Button(video == nil ? "Render Clay video" : "Render again") { render() }
                    .buttonStyle(.capsule(.prominent, size: .regular)).disabled(!active || state == nil || failure != nil)
                    .reviewAcceptanceProbe("shot-planning.clay.render", state: active && state != nil && failure == nil)
            }
        }
        .padding(AppTheme.Spacing.lg).interfaceFont(size: AppTheme.Typography.ui)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .reviewAcceptanceProbe("shot-planning.clay.sheet", state: !loading && operation == nil, text: shotID)
        .task { await load() }.onDisappear { operation?.cancel(); readLifetime.cancel() }
        .onChange(of: editor.workingRoot) { _, value in if value != home { operation?.cancel(); dismiss() } }
        .interactiveDismissDisabled(operation != nil)
    }

    private func load() async {
        guard let root = DataRootResolver.dataRoot(of: home) else { return }
        loading = true; failure = nil
        defer { loading = false }
        let cancellation = BpyOperationCancellation()
        cancellation.follow(readLifetime)
        do {
            let value = try await PipelineSpatialDerivationWriter.background(cancellation: cancellation, dataRoot: root) {
                let board = try PlanningWriterIO.storyboard(dataRoot: root)
                let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: board)
                guard let shot = draft.shots.first(where: { $0.shotID == shotID }),
                      let timing = board.timing.shots.first(where: { $0.id == shotID }) else { throw PipelineSpatialDerivationWriter.changed() }
                var video: CanonicalArtifactReferenceV1?
                if let state = shot.camera.spatialState, let camera = shot.camera.spatialCameraID, let scene = shot.camera.sceneReference {
                    _ = try PipelineSpatialDerivationWriter.requirePlanningState(reference: state, cameraID: camera,
                        sceneReference: scene, shotID: shotID, dataRoot: root)
                    if let derivation = shot.camera.spatialDerivation {
                        video = try PipelineSpatialDerivationWriter.planningDerivationReferences(reference: derivation,
                            stateReference: state, cameraID: camera, sceneReference: scene, shotID: shotID, dataRoot: root)
                            .first { $0.role == "core.shot-clay-video" }
                    }
                }
                return (shot.camera.spatialState, video, ProductionTimeEntry.seconds(timing.durationTicks, timebase: board.timing.timebase), shot.camera.spatialDerivation)
            }
            guard !Task.isCancelled, editor.workingRoot == home else { return }
            state = value.0; video = value.1; duration = value.2; proof = value.3
        } catch { if !Task.isCancelled { state = nil; video = nil; proof = nil; failure = error.localizedDescription } }
    }

    private func render() {
        guard active, let state else { return }
        failure = nil; notice = nil
        operation = Task {
            var handedOff = false
            defer { if !handedOff { operation = nil } }
            do {
                let written = try await PipelineSpatialDerivationWriter.renderPlanning(shotID: shotID, expectedState: state, editor: editor)
                guard editor.workingRoot == home else { return }
                onSaved(written)
                handedOff = true
                loading = true; operation = nil
                await Task { await load() }.value
            } catch {
                if Task.isCancelled {
                    failure = nil; notice = "Render cancelled. Clay video unchanged."
                    handedOff = true
                    loading = true; operation = nil
                    await Task { await load() }.value
                } else if error is CancellationError || (error as? BpyAdmissionFailure) == .cancelled {
                    failure = "The shot or location changed. Reload the shot state before rendering again."
                } else { failure = error.localizedDescription }
            }
        }
    }
}
