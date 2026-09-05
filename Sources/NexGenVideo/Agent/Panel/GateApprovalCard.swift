import SwiftUI

/// Commits a deferred gate only after the user approves it here.
struct GateApprovalCard: View {
    let approval: GateApproval
    let error: String?
    let surface: String?
    let isWorking: Bool
    var isBlocked: Bool = false
    let onApprove: () -> Void
    let onDecline: () -> Void
    @FocusState private var approveFocused: Bool
    @Environment(EditorViewModel.self) private var editor
    @State private var review = GateReviewModel()
    @State private var showsStoryboard = false

    private var reviewHint: String? {
        if approval.phase == "analysis" {
            return "Review the exact measured sections in Analysis first."
        }
        switch surface ?? "" {
        case "review": return "Read it in the Review tab first."
        case "prose": return "Read it in the Story tab first."
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            ScrollView {
                summary
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            if approval.phase == "storyboard" {
                Button("Open Storyboard") {
                    Task {
                        await review.refresh(approval: approval, editor: editor)
                        showsStoryboard = review.storyboard != nil
                    }
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(isWorking || isBlocked)
            }
            if let blocker = review.blocker, !isBlocked {
                Text(blocker)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footerRow
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(editor.projectPalette.accent.opacity(AppTheme.Opacity.medium),
                              lineWidth: AppTheme.BorderWidth.thin)
        )
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .id(approval.id)
        .task(id: "\(approval.id):\(editor.engineStateRevision):\(isBlocked)") {
            await review.refresh(approval: approval, editor: editor)
        }
        .sheet(isPresented: $showsStoryboard) {
            if let storyboard = review.storyboard {
                StoryboardReviewSheet(storyboard: storyboard)
            } else {
                VStack(spacing: AppTheme.Spacing.lgXl) {
                    Text(review.blocker ?? "Checking the storyboard…")
                    Button("Done") { showsStoryboard = false }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                }
                .padding(AppTheme.Spacing.xlXxl)
            }
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                approveFocused = !isBlocked
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approve \(approval.phaseLabel)")
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "checkmark.seal")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(editor.projectPalette.accent)
            Text("Approve \(approval.phaseLabel)")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: onDecline) {
                Image(systemName: "xmark")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isBlocked)
            .keyboardShortcut(.cancelAction)
            .help("Not yet (Esc)")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("The agent is asking you to approve \(approval.phaseLabel).")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = approval.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Text(notes)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reviewHint {
                Text(reviewHint)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppTheme.Spacing.xxs)
            }
            if isBlocked {
                Text("Finish the running phase before approving.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.warningColor)
            }
        }
    }

    private var footerRow: some View {
        ViewThatFits(in: .horizontal) {
            approvalActions(horizontal: true)
            approvalActions(horizontal: false)
        }
    }

    private func approvalActions(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: AppTheme.Spacing.sm))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Spacing.sm))
        return layout {
            Button("Not yet") { onDecline() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
                .disabled(isWorking || isBlocked)
            if horizontal { Spacer() }
            Button {
                Task {
                    await review.refresh(approval: approval, editor: editor)
                    if review.isReady { onApprove() }
                }
            } label: {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Approve \(approval.phaseLabel)")
                }
            }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.small)
                .disabled(isWorking || isBlocked || !review.isReady)
                .focused($approveFocused)
                .accessibilityHint(
                    isBlocked ? "Finish the running phase before approving" : ""
                )
        }
    }
}
