import AppKit
import NexGenEngine
import SwiftUI

struct SpatialSceneWorkspaceView: View {
    private struct OpenRequest: Equatable {
        let home: URL?
        let key: String?
        let generation: UUID?
        let retry: UUID
    }

    @Environment(EditorViewModel.self) private var editor
    @State private var session: SpatialSceneSession?
    @State private var sessionHome: URL?
    @State private var failure: String?
    @State private var runtimePresentation: BpyRuntimePresentation?
    @State private var reloadPending = false
    @State private var retry = UUID()
    @State private var openingID: UUID?

    private var editingEnabled: Bool {
        guard editor.projectState?.nextPhaseName == "production_design", !editor.agentService.isStreaming,
              !editor.agentService.isComposerBlocked, let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if !editingEnabled {
                Text(editor.projectState?.nextPhaseName == "production_design"
                    ? "Wait for the current production action before changing locations."
                    : "Reopen Production Design to change locations. You can inspect the saved scene and its cameras here.")
                    .foregroundStyle(AppTheme.Text.secondaryColor).padding(.horizontal, AppTheme.Spacing.md)
            }
            if let session, sessionHome == editor.workingRoot {
                SpatialSceneView(session: session, editingEnabled: editingEnabled)
            } else if let failure {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                        .reviewAcceptanceProbe("spatial.workspace.error", text: failure)
                    Button("Open location editor") { retry = UUID() }.buttonStyle(InlineActionButtonStyle())
                }.padding(AppTheme.Spacing.lg)
            } else {
                ProgressView("Opening location editor…").padding(AppTheme.Spacing.lg)
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .task(id: OpenRequest(home: editor.workingRoot, key: editor.openWorkingCopyKey,
            generation: editor.openWorkingCopyGeneration, retry: retry)) { await open() }
        .onChange(of: editor.engineStateRevision) { _, _ in
            guard sessionHome == editor.workingRoot, let session else { return }
            if session.busy { reloadPending = true }
            else { session.reload() }
        }
        .onChange(of: session?.busy) { _, busy in
            if busy == false, reloadPending, sessionHome == editor.workingRoot {
                reloadPending = false
                session?.reload()
            }
        }
        .onDisappear {
            openingID = nil
            session?.cancel()
            if let runtimePresentation { BpyRuntimeHost.shared.releasePresentation(runtimePresentation) }
            runtimePresentation = nil
            session = nil; sessionHome = nil
        }
    }

    @MainActor private func open() async {
        let request = UUID()
        openingID = request
        session?.cancel(); session = nil; sessionHome = nil; failure = nil; reloadPending = false
        if let runtimePresentation { BpyRuntimeHost.shared.releasePresentation(runtimePresentation) }
        runtimePresentation = nil
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let key = editor.openWorkingCopyKey, let generation = editor.openWorkingCopyGeneration,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
                .first(where: { $0.editorViewModel === editor }) else {
            failure = "Open a production project before editing locations."
            return
        }
        guard let presentation = BpyRuntimeHost.shared.register(document: document, documentID: key) else {
            failure = "The location runtime is unavailable for this project."
            return
        }
        runtimePresentation = presentation
        var retained = false
        defer {
            if !retained, runtimePresentation == presentation {
                BpyRuntimeHost.shared.releasePresentation(presentation)
                runtimePresentation = nil
            }
        }
        do {
            let runtime = try await BpyRuntimeHost.shared.session(for: document, presentation: presentation)
            try Task.checkCancellation()
            guard openingID == request, runtimePresentation == presentation,
                  editor.workingRoot == home, editor.openWorkingCopyKey == key,
                  editor.openWorkingCopyGeneration == generation else { return }
            let authority = try PipelineSpatialSceneAuthority(editor: editor, runtime: runtime)
            let value = SpatialSceneSession(pipelineRoot: root, runtime: runtime, authority: authority)
            value.reload()
            sessionHome = home
            session = value
            runtimePresentation = presentation
            retained = true
        } catch is CancellationError {
        } catch {
            if openingID == request, !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}

struct ProductionDesignWorkspaceView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var locations = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            if editor.usesProductionPlanningV2 {
                Picker("Production Design view", selection: $locations) {
                    Text("Design").tag(false)
                    Text("Locations · 3D").tag(true)
                }.pickerStyle(.segmented).reviewAcceptanceProbe("production-design.view", text: locations ? "locations" : "design").padding(.horizontal, AppTheme.Spacing.md).padding(.top, AppTheme.Spacing.md)
            }
            if locations && editor.usesProductionPlanningV2 { SpatialSceneWorkspaceView() }
            else { ProductionDesignMaterialsView() }
        }
    }
}
