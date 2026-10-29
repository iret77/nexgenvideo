import AppKit
import NexGenEngine
import SwiftUI

struct BibleSpatialViewSheet: View {
    let home: URL
    let locationID: String
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var location: Location?
    @State private var bibleSHA256 = ""
    @State private var scenes: [SpatialSceneHead] = []
    @State private var sceneID: UUID?
    @State private var scene: SpatialSceneRevision?
    @State private var cameraID: String?
    @State private var viewID = ""
    @State private var purpose = ""
    @State private var loading = false
    @State private var operation: Task<Void, Never>?
    @State private var saving = false
    @State private var prepared: PipelineSpatialDerivationWriter.PreparedBibleView?
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var inspecting = false
    @State private var previewSHA256 = ""

    private var active: Bool {
        guard editor.workingRoot == home, editor.projectState?.nextPhaseName == "bible",
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil && !loading && operation == nil && !saving
    }
    private var ready: Bool {
        active && location != nil && scene != nil && cameraID != nil && !bibleSHA256.isEmpty
            && viewID.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
            && !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("Location view · \(location?.name ?? "Bible")")
                .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if loading { ProgressView("Reading locations…") }
                    if let prepared, let image {
                        Text(prepared.purpose).textSelection(.enabled)
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(height: AppTheme.Layout.productionAssetPreviewHeight).frame(maxWidth: .infinity)
                            .accessibilityLabel("Rendered location view")
                            .reviewAcceptanceProbe("bible.spatial.image", text: previewSHA256)
                        Button("Inspect image") { inspecting = true }.buttonStyle(InlineActionButtonStyle())
                            .reviewAcceptanceProbe("bible.spatial.inspect")
                        Text("Rendered from the selected saved location camera. Confirm this geometry view for the Bible.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Button("Change view…") { self.prepared = nil; self.image = nil }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                            .reviewAcceptanceProbe("bible.spatial.change", state: active)
                    } else {
                        Text("Render a saved location camera, inspect the result, then assign it to a Bible view.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Picker("Location geometry", selection: $sceneID) {
                            Text("Choose location").tag(UUID?.none)
                            ForEach(scenes) { Text($0.name).tag(Optional($0.id)) }
                        }.disabled(!active)
                            .reviewAcceptanceProbe("bible.spatial.scene", text: sceneID?.uuidString ?? "")
                        Picker("Camera", selection: $cameraID) {
                            Text("Choose camera").tag(String?.none)
                            ForEach(scene?.snapshot.cameras ?? []) { Text($0.name).tag(Optional($0.id)) }
                        }.disabled(!active || scene == nil)
                            .reviewAcceptanceProbe("bible.spatial.camera", text: cameraID ?? "")
                        if let location, !location.sheets.isEmpty {
                            Menu("Use an existing Bible view") {
                                ForEach(location.sheets.keys.sorted(), id: \.self) { key in
                                    Button(key.replacingOccurrences(of: "_", with: " ").capitalized) {
                                        viewID = key; purpose = location.viewPurpose[key] ?? ""
                                    }
                                }
                            }.disabled(!active)
                        }
                        TextField("View identifier", text: $viewID).disabled(!active)
                            .reviewAcceptanceProbe("bible.spatial.view-id", text: viewID)
                        Text("Use a short identifier such as entrance_wide; letters, numbers, underscores and hyphens.")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        TextField("What this view must show", text: $purpose, axis: .vertical).disabled(!active)
                            .reviewAcceptanceProbe("bible.spatial.purpose", text: purpose)
                        Button("Render preview") { render() }.buttonStyle(InlineActionButtonStyle()).disabled(!ready)
                            .reviewAcceptanceProbe("bible.spatial.render", state: ready)
                    }
                    if location?.sheets[viewID] != nil {
                        Text("Confirming replaces this view's assignment. The previous image stays in the project history.")
                            .foregroundStyle(AppTheme.Status.warningColor)
                    }
                    if scenes.isEmpty && !loading {
                        Text("Create location geometry and a camera in Production Design first.").foregroundStyle(AppTheme.Text.secondaryColor)
                        Button("Open Production Design") { editor.revealCockpit(.productionDesign); dismiss() }.buttonStyle(InlineActionButtonStyle())
                    }
                    if operation != nil { ProgressView("Rendering location view…") }
                    if let failure {
                        Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                            .reviewAcceptanceProbe("bible.spatial.failure", text: failure)
                        Button("Reload Bible and locations") {
                            prepared = nil; image = nil; previewSHA256 = ""; scene = nil; sceneID = nil; cameraID = nil
                            Task { await load() }
                        }.buttonStyle(InlineActionButtonStyle()).disabled(!active)
                            .reviewAcceptanceProbe("bible.spatial.reload", state: active)
                    }
                }
            }
            HStack {
                Button(operation == nil ? "Cancel" : "Cancel render") {
                    if let operation { operation.cancel() } else { dismiss() }
                }.buttonStyle(InlineActionButtonStyle()).keyboardShortcut(.cancelAction).disabled(saving)
                    .reviewAcceptanceProbe("bible.spatial.cancel", state: !saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Assign Bible view") { confirm() }.buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(!active || prepared == nil || image == nil)
                    .reviewAcceptanceProbe("bible.spatial.assign", state: active && prepared != nil && image != nil)
            }
        }
        .padding(AppTheme.Spacing.lg).interfaceFont(size: AppTheme.Typography.ui)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .reviewAcceptanceProbe("bible.spatial.sheet")
        .task { await load() }.task(id: sceneID) { await loadScene() }
        .interactiveDismissDisabled(operation != nil || saving)
        .onDisappear { operation?.cancel() }
        .onChange(of: editor.workingRoot) { _, value in if value != home { operation?.cancel(); dismiss() } }
        .sheet(isPresented: $inspecting) {
            if let full = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ProductionImageInspectionView(image: full, title: prepared?.purpose ?? "Location view")
            }
        }
    }

    private func load() async {
        guard let root = DataRootResolver.dataRoot(of: home) else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                let bible = try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile)
                try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: root)
                return (bible.locations.first { $0.id == locationID }, try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)),
                    try SpatialSceneStore.index(in: root).scenes)
            }.value
            guard !Task.isCancelled, editor.workingRoot == home else { return }
            location = value.0; bibleSHA256 = value.1; scenes = value.2
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func loadScene() async {
        scene = nil; cameraID = nil
        guard let selected = scenes.first(where: { $0.id == sceneID }), let root = DataRootResolver.dataRoot(of: home) else { return }
        do {
            let value = try await Task.detached(priority: .userInitiated) { try SpatialSceneStore.load(selected, in: root) }.value
            guard !Task.isCancelled, editor.workingRoot == home, sceneID == selected.id else { return }
            scene = value; failure = nil
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func render() {
        guard ready, let selected = scenes.first(where: { $0.id == sceneID }), let cameraID else { return }
        let viewID = viewID, purpose = purpose, expected = bibleSHA256
        failure = nil
        operation = Task {
            defer { operation = nil }
            do {
                let result = try await PipelineSpatialDerivationWriter.prepareBibleView(locationID: locationID, viewID: viewID,
                    purpose: purpose, scene: selected, cameraID: cameraID, expectedBibleSHA256: expected, editor: editor)
                guard editor.workingRoot == home, !Task.isCancelled else { return }
                guard let decoded = NSImage(data: result.imageData) else { throw GateBlocked("The rendered view could not be displayed. Render the preview again.") }
                prepared = result; image = decoded; previewSHA256 = FileDigest.sha256(of: result.imageData)
            } catch is CancellationError { failure = "The render was cancelled. The Bible was not changed." }
            catch { failure = error.localizedDescription }
        }
    }

    private func confirm() {
        guard active, let prepared else { return }
        saving = true; failure = nil
        Task {
            defer { saving = false }
            do { try await PipelineSpatialDerivationWriter.confirmBibleView(prepared, editor: editor); dismiss() }
            catch { failure = error.localizedDescription }
        }
    }
}
