import SwiftUI

struct AgentReviewProgressView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var failure: String?
    @State private var preparing = false

    private var reviewActionUnavailableReason: String? {
        if preparing || editor.renderReviewRun.isPreparingInputs {
            return "Wait for review preparation to finish."
        }
        if let reason = editor.agentService.reviewParentIdleReason { return reason }
        if editor.projectState?.nextPhaseName != "render_review" {
            return "Review inputs during the Render Review phase."
        }
        if editor.pipelinePhaseRunCoordinator.hasRunningJobs {
            return "Wait for the current production action to finish."
        }
        return nil
    }

    var body: some View {
        let run = editor.renderReviewRun
        let unavailableReason = reviewActionUnavailableReason
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("AI input review")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
            if let proposal = run.proposal {
                Text("Pages: \(proposal.pageCount) · Remaining: \(proposal.remainingPages) · Summaries: up to \(proposal.maximumSynthesisContexts)")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text("\(proposal.backend) · \(proposal.modelID ?? "Model confirmed by the first response")")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(proposal.costDescription).textSelection(.enabled)
                Text("Your conversation stays unchanged during the review.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if run.state == .running || run.state == .stopping || run.state == .preparing {
                ProgressView(run.currentStage)
                Text("Pages recorded: \(run.completedPages)")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if let error = run.errorMessage ?? failure {
                Text(error).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
            }
            if run.state != .running && run.state != .stopping && run.state != .preparing,
               let unavailableReason {
                Text(unavailableReason).foregroundStyle(AppTheme.Text.secondaryColor)
                    .reviewAcceptanceProbe("render-review.agent.unavailable", text: unavailableReason)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                if run.state == .awaitingApproval {
                    Button(run.proposal?.isResume == true ? "Resume review" : "Start review") {
                        do { failure = nil; try run.approve(editor: editor) }
                        catch { failure = error.localizedDescription }
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(unavailableReason != nil)
                    .reviewAcceptanceProbe("render-review.agent.approve", state: unavailableReason == nil,
                        text: run.proposal?.isResume == true ? "Resume review" : "Start review")
                    Button("Not now") { Task { await run.cancel() } }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .reviewAcceptanceProbe("render-review.agent.decline")
                } else if run.state == .running || run.state == .preparing || run.state == .stopping {
                    Button("Cancel review") { Task { await run.cancel() } }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(run.state == .stopping)
                        .reviewAcceptanceProbe("render-review.agent.cancel", state: run.state != .stopping)
                } else {
                    Button(run.state == .interrupted || run.state == .failed ? "Prepare review again" : "Prepare AI review") {
                        guard reviewActionUnavailableReason == nil else { return }
                        preparing = true; failure = nil
                        Task { @MainActor in
                            defer { preparing = false }
                            do { try await run.prepare(editor: editor) }
                            catch { failure = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(unavailableReason != nil)
                    .reviewAcceptanceProbe("render-review.agent.prepare", state: unavailableReason == nil)
                    if run.state == .interrupted || run.state == .failed {
                        Button("Prepare a new review") {
                            guard reviewActionUnavailableReason == nil else { return }
                            preparing = true; failure = nil
                            Task { @MainActor in
                                defer { preparing = false }
                                do { try await run.prepareNewReview(editor: editor) }
                                catch { failure = error.localizedDescription }
                            }
                        }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(unavailableReason != nil)
                        .help("Prepare every page again with the selected backend and model. Usage requires a new approval; earlier receipts remain saved.")
                        .reviewAcceptanceProbe("render-review.agent.restart", state: unavailableReason == nil)
                    }
                }
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.raisedColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .reviewAcceptanceProbe("render-review.agent.state", text: run.currentStage)
    }
}
