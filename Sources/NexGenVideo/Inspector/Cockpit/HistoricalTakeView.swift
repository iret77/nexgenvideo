import NexGenEngine
import SwiftUI

struct HistoricalTakeView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var takes: [PipelineHistoricalTakeStore.Item] = []
    @State private var loadedHome: URL?
    @State private var failure: String?
    @State private var unavailableCount = 0
    @State private var loading = false
    @State private var selectedID: String?
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Takes from previous workflows").fontWeight(AppTheme.FontWeight.semibold)
            Text("These original videos and their recorded direction are preserved for reference. Their old selections do not approve the current production plan.")
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if loading { ProgressView("Reading take history…") }
            if let failure {
                Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                Button("Reload history") { Task { await load() } }.buttonStyle(InlineActionButtonStyle()).disabled(loading)
            }
            if unavailableCount > 0 {
                Text("Unavailable takes: \(unavailableCount). Their video files could not be verified. Restore the original files to view them.")
                    .foregroundStyle(AppTheme.Status.warningColor)
                Button("Reload history") { Task { await load() } }.buttonStyle(InlineActionButtonStyle()).disabled(loading)
            }
            if loadedHome == editor.workingRoot, let home = loadedHome {
                if let selected = takes.first(where: { $0.id == selectedID }) {
                    ProductionInputPreview(reference: selected.media, dataRoot: home, title: selected.shotLabel)
                    if let name = selected.shotName { Text(name).textSelection(.enabled) }
                    Text(selected.take.generationInput.prompt).textSelection(.enabled)
                    Text("\(selected.take.generationInput.model) · \(selected.take.recordedAt)")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                ForEach(takes) { item in
                    Button { selectedID = item.id } label: {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text(item.shotLabel).fontWeight(AppTheme.FontWeight.medium)
                            if let name = item.shotName { Text(name).lineLimit(2) }
                            Text("\(item.take.generationInput.model) · \(item.take.recordedAt)")
                            Text(item.previouslySelected ? "Selected in the previous workflow" : "Previous workflow take")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(AppTheme.Spacing.md)
                        .background(selectedID == item.id ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : AppTheme.Background.raisedColor,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    }.buttonStyle(.plain)
                }
                if takes.isEmpty && !loading && failure == nil && unavailableCount == 0 {
                    Text("No takes were archived by a workflow update.").foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
        }
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
        .onDisappear { generation = UUID() }
        .reviewAcceptanceProbe("take.migration-history")
    }

    private func load() async {
        let token = UUID(); generation = token
        let home = editor.workingRoot
        loading = true; failure = nil; unavailableCount = 0
        if loadedHome != home { takes = []; selectedID = nil; loadedHome = home }
        defer { if generation == token { loading = false } }
        guard let home else { return }
        do {
            let result = try await Task.detached(priority: .userInitiated) { try PipelineHistoricalTakeStore.load(home: home) }.value
            guard !Task.isCancelled, generation == token, editor.workingRoot == home else { return }
            takes = result.items; unavailableCount = result.unavailableCount
            if !result.items.contains(where: { $0.id == selectedID }) { selectedID = nil }
        } catch {
            guard !Task.isCancelled, generation == token, editor.workingRoot == home else { return }
            takes = []; selectedID = nil; failure = error.localizedDescription
        }
    }
}
