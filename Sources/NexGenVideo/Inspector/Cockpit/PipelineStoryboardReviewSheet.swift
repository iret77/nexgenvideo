import NexGenEngine
import SwiftUI

struct PipelineStoryboardReviewSheet: View {
    @Environment(EditorViewModel.self) private var editor

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
                ProgressView("Loading Storyboard…")
                    .controlSize(.small)
                    .frame(
                        minWidth: AppTheme.ComponentSize.formatSheetWidth,
                        minHeight: AppTheme.ComponentSize.formatSheetCardListMinHeight
                    )
            case .loaded(let storyboard):
                StoryboardReviewSheet(storyboard: storyboard)
            case .missing:
                missingState(
                    title: "No Storyboard",
                    message: "This project does not contain a current Storyboard artifact. Return to the Storyboard phase to create or restore it."
                )
            case .failed(let message):
                missingState(
                    title: "Storyboard Unavailable",
                    message: "The current Storyboard could not be read. \(message)"
                )
            }
        }
        .task(id: editor.projectURL) { await load() }
    }

    private func load() async {
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
        guard editor.workingRoot == home else { return }
        state = loaded
    }

    private func missingState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            Label(title, systemImage: "exclamationmark.triangle")
                .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            Text(message)
                .interfaceFont(size: AppTheme.Typography.reading)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(
            minWidth: AppTheme.ComponentSize.formatSheetWidth,
            minHeight: AppTheme.ComponentSize.formatSheetCardListMinHeight,
            alignment: .topLeading
        )
    }
}
