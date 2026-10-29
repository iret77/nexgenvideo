import NexGenEngine
import SwiftUI

struct ScriptSceneEditor: View {
    let script: ScriptV1
    let scene: ScriptV1.Scene
    let home: URL
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var adaptation: String
    @State private var actions: [String: String]
    @State private var dialogue: [String: String]
    @State private var failure: String?
    @State private var showsComparison = false

    init(script: ScriptV1, scene: ScriptV1.Scene, home: URL) {
        self.script = script; self.scene = scene; self.home = home
        _title = State(initialValue: scene.title); _adaptation = State(initialValue: scene.adaptation)
        _actions = State(initialValue: Dictionary(uniqueKeysWithValues: scene.events.map { ($0.id, $0.action) }))
        _dialogue = State(initialValue: Dictionary(uniqueKeysWithValues: scene.events.map { ($0.id, $0.dialogue ?? "") }))
    }

    private var replacement: ScriptV1.Scene {
        .init(id: scene.id, title: title, adaptation: adaptation, events: scene.events.map { event in
            let spoken = dialogue[event.id] ?? ""
            return .init(id: event.id, action: actions[event.id] ?? event.action,
                dialogue: spoken.isEmpty ? nil : spoken, treatmentBeatIDs: event.treatmentBeatIDs, sourceAnchors: event.sourceAnchors)
        })
    }

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !adaptation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && replacement.events.allSatisfy { !$0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Edit Script scene").interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    TextField("Scene title", text: $title)
                        .reviewAcceptanceProbe("script.scene.title", text: title)
                    TextField("Adaptation from Treatment", text: $adaptation, axis: .vertical)
                    Toggle("Show previous wording", isOn: $showsComparison)
                    ForEach(scene.events, id: \.id) { event in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            if showsComparison {
                                Text(event.action).foregroundStyle(AppTheme.Text.secondaryColor).textSelection(.enabled)
                                if let spoken = event.dialogue { Text(spoken).italic().foregroundStyle(AppTheme.Text.secondaryColor) }
                            }
                            TextField("Action", text: Binding(get: { actions[event.id] ?? "" }, set: { actions[event.id] = $0 }), axis: .vertical)
                            TextField("Dialogue (optional)", text: Binding(get: { dialogue[event.id] ?? "" }, set: { dialogue[event.id] = $0 }), axis: .vertical)
                        }
                    }
                }.textFieldStyle(.roundedBorder)
            }
            if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .reviewAcceptanceProbe("script.scene.cancel")
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Apply scene changes") {
                    guard editor.workingRoot == home else { failure = "The project changed. Open the scene again."; return }
                    do { try PipelineScriptEditor.replaceScene(replacement, in: script, editor: editor); dismiss() }
                    catch { failure = error.localizedDescription }
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(!valid || replacement == scene)
                .keyboardShortcut(.defaultAction)
                .reviewAcceptanceProbe("script.scene.apply", state: valid && replacement != scene)
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
    }
}
