import NexGenEngine
import SwiftUI
import UniformTypeIdentifiers

struct StorySourceChoiceView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var selection: PipelineStorySourceWriter.ConfirmedSelection?
    @State private var failure: String?
    @State private var pasteDrafts: [String: String] = [:]
    @State private var selectionHome: URL?
    @State private var choosingFile = false
    @State private var loading = false
    @State private var importHome: URL?
    @State private var loadGeneration = UUID()

    private var projectKey: String { editor.workingRoot?.path ?? "" }
    private var pastedStory: Binding<String> {
        let key = projectKey
        return Binding(get: { pasteDrafts[key] ?? "" }, set: { pasteDrafts[key] = $0 })
    }

    private var editable: Bool {
        guard !loading, editor.projectState?.nextPhaseName == "brief",
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Story material").fontWeight(AppTheme.FontWeight.semibold)
            if loading { ProgressView().controlSize(.small) }
            if selectionHome == editor.workingRoot, let selection {
                Text(selection.disposition == .greenfield ? "Develop a new story from the Brief." : selection.displayName)
                    .reviewAcceptanceProbe("story-source.selected", text: selection.disposition == .greenfield ? "greenfield" : "imported")
            } else {
                Text("Start with your own story or develop one from scratch.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if !editable, selection != nil {
                Text("Reopen Brief to change the story source.").foregroundStyle(AppTheme.Text.secondaryColor)
            }
            WrapLayout(spacing: AppTheme.Spacing.sm) {
                Button("Develop from scratch") { confirm { try PipelineStorySourceWriter.confirmGreenfield(editor: editor) } }
                    .reviewAcceptanceProbe("story-source.greenfield")
                Button("Use existing story…") { importHome = editor.workingRoot; choosingFile = true }
                    .reviewAcceptanceProbe("story-source.file")
            }
            .buttonStyle(.capsule(.secondary, size: .regular)).disabled(!editable)
            DisclosureGroup("Paste story") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    TextField("Story text", text: pastedStory, axis: .vertical)
                        .textFieldStyle(.roundedBorder).disabled(!editable)
                    Button("Use this story") {
                        let key = projectKey, text = pasteDrafts[key] ?? ""
                        if confirm({ try PipelineStorySourceWriter.confirmPastedSource(text: text, editor: editor) }) {
                            pasteDrafts.removeValue(forKey: key)
                        }
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(!editable || pastedStory.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, AppTheme.Spacing.sm)
            }
            if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            switch result {
            case .failure(let error): failure = error.localizedDescription
            case .success(let url):
                guard editor.workingRoot == importHome else { failure = "The project changed. Choose the story file again."; return }
                confirm { try PipelineStorySourceWriter.confirmImportedSource(from: url, editor: editor) }
            }
        }
    }

    @discardableResult
    private func confirm(_ action: () throws -> Void) -> Bool {
        do {
            try action(); failure = nil
            Task { await editor.refreshEngineState(); await load() }
            return true
        } catch { failure = error.localizedDescription; return false }
    }

    private func load() async {
        let generation = UUID(); loadGeneration = generation
        let home = editor.workingRoot
        if selectionHome != home { selection = nil; selectionHome = home }
        let binding = editor.declaredProductionContract
        loading = true
        defer { if generation == loadGeneration { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home), binding == .current else {
            selection = nil; loading = false; return
        }
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: nil,
                    expectedProductionContract: binding) else { throw GateBlocked("The production workflow is unavailable.") }
                return try PipelineStorySourceWriter.confirmedSelection(dataRoot: root, workflowID: workflow.contractID)
            }.value
            guard !Task.isCancelled, editor.workingRoot == home, generation == loadGeneration else { return }
            selection = value; failure = nil
        } catch {
            guard !Task.isCancelled, editor.workingRoot == home, generation == loadGeneration else { return }
            selection = nil; failure = error.localizedDescription
        }
    }
}
