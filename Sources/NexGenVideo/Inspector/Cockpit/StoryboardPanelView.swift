import NexGenEngine
import SwiftUI

struct StoryboardPanelView: View {
    @Environment(EditorViewModel.self) private var editor

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded(StoryboardReviewSnapshot?)
        case failed(CockpitError)
    }

    /// The project and approval request a finished load was read for.
    private struct Source: Equatable {
        let root: URL?
        let approvalID: String?
    }

    @State private var state: LoadState = .idle
    @State private var source: Source?
    @State private var binding: StoryboardReviewBinding = .unrelated
    @State private var loadToken = 0

    private var currentSource: Source {
        Source(root: editor.workingRoot, approvalID: editor.agentService.pendingGateApproval?.id)
    }

    /// The binding of the read on screen; nil while a read for the current project and request is pending.
    private var settledBinding: StoryboardReviewBinding? {
        guard source == currentSource else { return nil }
        switch state {
        case .idle, .loading: return nil
        case .loaded, .failed: return binding
        }
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            if source == currentSource {
                if scrollsState {
                    ScrollView { stateContent }
                        .scrollBounceBehavior(.basedOnSize)
                } else {
                    stateContent
                }
            } else {
                centeredProgress()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { acceptanceProbe("storyboard.review", text: settledBinding?.rawValue) }
        .task(id: currentSource) { await load() }
        .onChange(of: editor.engineStateRevision) { _, _ in Task { await load() } }
    }

    private var scrollsState: Bool {
        switch state {
        case .loaded(nil), .failed: true
        default: false
        }
    }

    private var stateContent: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            if settledBinding == .changed { changedNotice }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            centeredProgress()
        case .failed(let error):
            CockpitStateView.error(error, title: "Couldn't load the storyboard",
                                   subject: "the storyboard",
                                   activePack: InstalledPack.named(editor.activePluginName),
                                   startProduction: { editor.startProduction() },
                                   isStarting: editor.productionStarting, hasProduction: editor.hasProductionPipeline) { Task { await load() } }
        case .loaded(nil):
            CockpitStateView.empty(icon: "rectangle.split.3x1", title: "No storyboard yet",
                                   message: "This project doesn't have a storyboard.")
        case .loaded(.some(let snapshot)):
            StoryboardDocumentView(storyboard: snapshot.storyboard)
                .background { acceptanceProbe("storyboard.document", text: snapshot.sha256) }
        }
    }

    private var changedNotice: some View {
        Label("Storyboard changed after approval was requested. Request a new approval for this version.",
              systemImage: "exclamationmark.triangle.fill")
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(AppTheme.Status.warningColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.top, AppTheme.Spacing.md)
    }

    @ViewBuilder
    private func acceptanceProbe(_ identifier: String, text: String?) -> some View {
        if WorkspaceUIAcceptance.isRequested {
            AppRelaunchClickProbe(identifier: identifier, acceptanceText: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }

    private func centeredProgress() -> some View {
        VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        let requested = currentSource
        loadToken += 1
        let token = loadToken
        guard let dir = requested.root else {
            source = requested
            binding = .unrelated
            state = .failed(.noProject)
            return
        }
        state = .loading
        let read = await CockpitDataService.storyboard(
            projectDir: dir,
            approval: editor.agentService.pendingGateApproval
        )
        guard token == loadToken else { return }
        source = requested
        binding = read.binding
        switch read.result {
        case .success(let snapshot): state = .loaded(snapshot)
        case .failure(let error): state = .failed(error)
        }
    }
}
