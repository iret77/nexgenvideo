import NexGenEngine
import SwiftUI

struct ScriptPanelView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var review: ProductionPlanningPresentation.ScriptReview?
    @State private var failure: String?
    @State private var loading = false
    @State private var loadGeneration = UUID()
    @State private var editing: SceneEdit?

    private struct SceneEdit: Identifiable {
        let id = UUID()
        let script: ScriptV1
        let scene: ScriptV1.Scene
        let home: URL
    }

    private var editable: Bool {
        guard !loading, editor.projectState?.nextPhaseName == "script",
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                if loading { ProgressView().controlSize(.small) }
                if let failure {
                    Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                    Button("Reload Script") { Task { await load() } }.buttonStyle(InlineActionButtonStyle())
                } else if let review {
                    let script = review.script
                    Text(script.summary).textSelection(.enabled)
                    ForEach(script.scenes, id: \.id) { scene in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                            Text(scene.title).interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                            Text(scene.adaptation).foregroundStyle(AppTheme.Text.secondaryColor).textSelection(.enabled)
                            Button("Edit scene…") {
                                if let home = editor.workingRoot { editing = .init(script: script, scene: scene, home: home) }
                            }
                            .buttonStyle(InlineActionButtonStyle()).disabled(!editable)
                            .reviewAcceptanceProbe("script.scene.edit.\(scene.id)", state: editable)
                            .help(editable ? "Edit this scene and compare it with its previous wording." : "Reopen Script before changing an approved scene.")
                            ForEach(scene.events, id: \.id) { event in
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                    Text(event.action).textSelection(.enabled)
                                    if let dialogue = event.dialogue { Text(dialogue).italic().textSelection(.enabled) }
                                    DisclosureGroup("Treatment and source references") {
                                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                            Text("Treatment").fontWeight(AppTheme.FontWeight.medium)
                                            ForEach(Array((review.treatmentExcerpts[event.id] ?? []).enumerated()), id: \.offset) { _, excerpt in
                                                Text(excerpt).textSelection(.enabled)
                                            }
                                            if let excerpts = review.sourceExcerpts[event.id], !excerpts.isEmpty {
                                                Text("Original story").fontWeight(AppTheme.FontWeight.medium)
                                                ForEach(Array(excerpts.enumerated()), id: \.offset) { _, excerpt in
                                                    Text(excerpt).textSelection(.enabled)
                                                }
                                            }
                                        }
                                        .foregroundStyle(AppTheme.Text.secondaryColor)
                                    }
                                }
                                .reviewAcceptanceProbe("script.event.\(event.id)", text: event.action)
                            }
                        }
                        .padding(AppTheme.Spacing.lg)
                        .background(AppTheme.Background.raisedColor)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    }
                } else if !loading {
                    CockpitStateView.empty(icon: "doc.text", title: "No Script yet",
                        message: "The Script turns the approved Treatment into scenes and actions for the Storyboard.")
                }
            }
            .interfaceFont(size: AppTheme.Typography.ui)
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .reviewAcceptanceProbe("script.workspace")
        .sheet(item: $editing) { item in ScriptSceneEditor(script: item.script, scene: item.scene, home: item.home).environment(editor) }
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
    }

    private func load() async {
        let home = editor.workingRoot
        let generation = UUID()
        loadGeneration = generation
        review = nil; failure = nil; loading = true
        defer { if loadGeneration == generation { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home) else { return }
        do {
            _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(ScriptV1.currentPath).path) else { return }
            let value = try await Task.detached(priority: .userInitiated) { try ProductionPlanningPresentation.scriptReview(dataRoot: root) }.value
            guard !Task.isCancelled, editor.workingRoot == home, loadGeneration == generation else { return }
            review = value
        } catch {
            guard !Task.isCancelled, editor.workingRoot == home, loadGeneration == generation else { return }
            failure = error.localizedDescription
        }
    }
}
