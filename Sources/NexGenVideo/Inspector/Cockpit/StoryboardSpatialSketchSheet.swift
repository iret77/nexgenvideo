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
    @State private var loading = true
    @State private var loadedGeneration: UUID?
    @State private var failure: String?
    @State private var rendering: Task<Void, Never>?
    @State private var inspecting = false

    private var selected: SpatialSceneHead? { scenes.first { $0.id == sceneID } }
    private var listReady: Bool {
        !loading && loadedGeneration != nil && loadedGeneration == editor.openWorkingCopyGeneration && editor.workingRoot == home
    }
    private var canChooseScene: Bool { listReady && rendering == nil && !scenes.isEmpty }
    private var canChooseCamera: Bool { canChooseScene && selected?.matches(revision) == true && revision?.snapshot.cameras.isEmpty == false }
    private var canRender: Bool {
        guard let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return canChooseCamera
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
                    }.disabled(!canChooseScene)
                        .reviewAcceptanceProbe("storyboard.spatial.locations", state: listReady, text: scenes.map(\.selectionIdentity).joined(separator: "\n"))
                        .reviewAcceptanceProbe("storyboard.spatial.scene", state: canChooseScene, text: sceneID?.uuidString ?? "")
                    Picker("Camera", selection: $cameraID) {
                        Text("Choose camera").tag(String?.none)
                        ForEach(revision?.snapshot.cameras ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(!canChooseCamera)
                        .reviewAcceptanceProbe("storyboard.spatial.cameras", text: revision?.snapshot.cameras.map(\.id).joined(separator: "\n"))
                        .reviewAcceptanceProbe("storyboard.spatial.camera", state: canChooseCamera, text: cameraID ?? "")
                    if listReady && scenes.isEmpty {
                        Text("Create a location and camera in Production Design first.").foregroundStyle(AppTheme.Text.secondaryColor)
                        Button("Open Production Design") { editor.revealCockpit(.productionDesign); dismiss() }
                            .buttonStyle(InlineActionButtonStyle())
                    } else if listReady && !scenes.isEmpty {
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
        .onChange(of: editor.openWorkingCopyGeneration) { _, _ in rendering?.cancel(); dismiss() }
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
        loading = true
        loadedGeneration = nil
        scenes = []; sceneID = nil; failure = nil
        guard let generation = editor.openWorkingCopyGeneration, editor.workingRoot == home,
              let root = DataRootResolver.dataRoot(of: home) else {
            loading = false; failure = "Reopen the project to read its saved locations."
            return
        }
        defer { if !Task.isCancelled { loading = false } }
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: root)
                return try SpatialSceneStore.index(in: root).scenes
            }.value
            guard !Task.isCancelled, editor.workingRoot == home, editor.openWorkingCopyGeneration == generation else { return }
            scenes = value; loadedGeneration = generation
        } catch {
            guard !Task.isCancelled, editor.workingRoot == home, editor.openWorkingCopyGeneration == generation else { return }
            Log.project.error("Saved locations could not be read for the location sketch: \(Log.detail(error))")
            failure = "Saved locations couldn’t be loaded. Reopen the project and try again."
        }
    }

    private func loadScene() async {
        revision = nil; cameraID = nil
        guard listReady, let generation = loadedGeneration, let selected, let root = DataRootResolver.dataRoot(of: home) else { return }
        failure = nil
        do {
            let value = try await Task.detached(priority: .userInitiated) { try SpatialSceneStore.load(selected, in: root) }.value
            guard !Task.isCancelled, listReady, loadedGeneration == generation, self.selected == selected else { return }
            revision = value; failure = nil
        } catch {
            guard !Task.isCancelled, listReady, loadedGeneration == generation, self.selected == selected else { return }
            Log.project.error("Location \(selected.id) could not be read for the location sketch: \(Log.detail(error))")
            failure = "The selected location couldn’t be loaded. Choose another location, or reopen the project."
        }
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
            } catch let error as GateBlocked {
                failure = error.message
            } catch {
                Log.project.error("Location sketch assignment failed shot=\(shotID) moment=\(momentID): \(Log.detail(error))")
                failure = "The location sketch couldn’t be assigned. The Storyboard was not changed."
            }
        }
    }
}
