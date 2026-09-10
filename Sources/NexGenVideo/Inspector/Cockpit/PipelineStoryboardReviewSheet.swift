import NexGenEngine
import SwiftUI

struct PipelineStoryboardReviewSheet: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss

    private enum LoadState: Sendable {
        case loading
        case loaded(Storyboard)
        case missing
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                statusState(title: "Storyboard", message: nil, isLoading: true)
            case .loaded(let storyboard):
                StoryboardReviewSheet(storyboard: storyboard)
            case .missing:
                statusState(
                    title: "No Storyboard",
                    message: "This project does not contain a current Storyboard artifact. Return to the Storyboard phase to create or restore it.",
                    isLoading: false
                )
            case .failed(let message):
                statusState(
                    title: "Storyboard Unavailable",
                    message: "The current Storyboard could not be read. \(message)",
                    isLoading: false
                )
            }
        }
        .task(id: editor.workingRoot) { await load() }
    }

    private func load() async {
        state = .loading
        guard let home = editor.workingRoot,
              let root = DataRootResolver.dataRoot(of: home) else {
            state = .failed("Open the project again and retry.")
            return
        }
        let loaded = await Task.detached(priority: .utility) { () -> LoadState in
            do {
                guard let storyboard = try StoryboardStore.load(dataRoot: root) else { return .missing }
                return .loaded(storyboard)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
        guard !Task.isCancelled else { return }
        guard editor.workingRoot == home else {
            state = .failed("The project changed while the Storyboard was loading. Close this sheet and open it again.")
            return
        }
        state = loaded
    }

    private func statusState(title: String, message: String?, isLoading: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            HStack {
                if isLoading {
                    Text(title)
                        .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
                } else {
                    Label(title, systemImage: "exclamationmark.triangle")
                        .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
            }
            if isLoading {
                ProgressView("Loading Storyboard…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message {
                Text(message)
                    .interfaceFont(size: AppTheme.Typography.reading)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(
            minWidth: AppTheme.ComponentSize.formatSheetWidth,
            minHeight: AppTheme.ComponentSize.formatSheetCardListMinHeight,
            alignment: .topLeading
        )
    }
}
