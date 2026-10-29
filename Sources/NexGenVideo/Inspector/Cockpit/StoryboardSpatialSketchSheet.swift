import BpyRuntimeProtocol
import NexGenEngine
import SwiftUI

struct StoryboardSpatialSketchSheet: View {
    let home: URL
    let shotID: String
    let momentID: String
    let intent: String
    let fingerprint: String
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var scenes: [SpatialSceneHead] = []
    @State private var sceneID: UUID?
    @State private var revision: SpatialSceneRevision?
    @State private var cameraID: String?
    @State private var loading = false
    @State private var failure: String?
    @State private var rendering: Task<Void, Never>?
    @State private var inspecting = false

    private var selected: SpatialSceneHead? { scenes.first { $0.id == sceneID } }
    private var canRender: Bool {
        guard let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return !loading && rendering == nil && selected != nil
            && revision?.snapshot.cameras.contains(where: { $0.id == cameraID }) == true
            && editor.workingRoot == home && editor.projectState?.nextPhaseName == "storyboard"
            && !editor.agentService.isStreaming && !editor.agentService.isComposerBlocked
            && editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("Create sketch from location")
                .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text(intent).textSelection(.enabled)
                    Text("Use a saved location camera to make a local Clay image for this moment. This sketch shows geometry and framing.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if loading { ProgressView("Reading saved locations…") }
                    Picker("Location", selection: $sceneID) {
                        Text("Choose location").tag(UUID?.none)
                        ForEach(scenes) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(rendering != nil || loading)
                        .reviewAcceptanceProbe("storyboard.spatial.scene", state: rendering == nil && !loading, text: sceneID?.uuidString ?? "")
                    Picker("Camera", selection: $cameraID) {
                        Text("Choose camera").tag(String?.none)
                        ForEach(revision?.snapshot.cameras ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(rendering != nil || loading || revision == nil)
                        .reviewAcceptanceProbe("storyboard.spatial.camera", state: rendering == nil && !loading && revision != nil, text: cameraID ?? "")
                    if scenes.isEmpty && !loading {
                        Text("Create a location and camera in Production Design first.").foregroundStyle(AppTheme.Text.secondaryColor)
                        Button("Open Production Design") { editor.revealCockpit(.productionDesign); dismiss() }
                            .buttonStyle(InlineActionButtonStyle())
                    } else {
                        Button("Inspect location and cameras…") { inspecting = true }.buttonStyle(InlineActionButtonStyle())
                            .disabled(rendering != nil)
                    }
                    if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                        .reviewAcceptanceProbe("storyboard.spatial.failure", text: failure) }
                    if rendering != nil { ProgressView("Rendering location view…") }
                }
            }
            HStack {
                Button(rendering == nil ? "Cancel" : "Cancel render") {
                    if let rendering { rendering.cancel() } else { dismiss() }
                }.buttonStyle(InlineActionButtonStyle()).keyboardShortcut(.cancelAction)
                    .reviewAcceptanceProbe("storyboard.spatial.cancel", text: rendering == nil ? "cancel" : "cancel-render")
                Spacer()
                Button("Create and assign sketch") { render() }
                    .buttonStyle(.capsule(.prominent, size: .regular)).disabled(!canRender)
                    .reviewAcceptanceProbe("storyboard.spatial.assign", state: canRender)
            }
        }
        .padding(AppTheme.Spacing.lg).interfaceFont(size: AppTheme.Typography.ui)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .reviewAcceptanceProbe("storyboard.spatial.sheet", text: momentID)
        .task { await loadLocations() }
        .task(id: sceneID) { await loadScene() }
        .onDisappear { rendering?.cancel() }
        .onChange(of: editor.workingRoot) { _, value in if value != home { rendering?.cancel(); dismiss() } }
        .interactiveDismissDisabled(rendering != nil)
        .sheet(isPresented: $inspecting) {
            VStack {
                HStack { Spacer(); Button("Done") { inspecting = false }.keyboardShortcut(.cancelAction) }
                    .padding(AppTheme.Spacing.md)
                SpatialSceneWorkspaceView().environment(editor)
            }.frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        }
    }

    private func loadLocations() async {
        guard let root = DataRootResolver.dataRoot(of: home), editor.workingRoot == home else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: root)
                return try SpatialSceneStore.index(in: root).scenes
            }.value
            guard !Task.isCancelled, editor.workingRoot == home else { return }
            scenes = value
        } catch { failure = error.localizedDescription }
    }

    private func loadScene() async {
        revision = nil; cameraID = nil
        guard let selected, let root = DataRootResolver.dataRoot(of: home) else { return }
        do {
            let value = try await Task.detached(priority: .userInitiated) { try SpatialSceneStore.load(selected, in: root) }.value
            guard !Task.isCancelled, editor.workingRoot == home, sceneID == selected.id else { return }
            revision = value; failure = nil
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func render() {
        guard canRender, let selected, let cameraID else { return }
        failure = nil
        rendering = Task {
            defer { rendering = nil }
            do {
                _ = try await PipelineSpatialDerivationWriter.renderStoryboard(shotID: shotID, momentID: momentID,
                    scene: selected, cameraID: cameraID, expectedFingerprint: fingerprint, editor: editor)
                dismiss()
            } catch is CancellationError {
                failure = "The render was cancelled. The Storyboard was not changed."
            } catch { failure = error.localizedDescription }
        }
    }
}
