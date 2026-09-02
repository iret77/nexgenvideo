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
                .strokeBorder(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium),
                              lineWidth: AppTheme.BorderWidth.thin)
        )
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .id(approval.id)
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
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Accent.primary)
            Text("Approve \(approval.phaseLabel)")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: onDecline) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
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
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = approval.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Text(notes)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reviewHint {
                Text(reviewHint)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppTheme.Spacing.xxs)
            }
            if isBlocked {
                Text("Finish the running phase before approving.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.warningColor)
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Not yet") { onDecline() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
                .disabled(isWorking || isBlocked)
            Spacer()
            Button {
                onApprove()
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
                .disabled(isWorking || isBlocked)
                .focused($approveFocused)
                .accessibilityHint(
                    isBlocked ? "Finish the running phase before approving" : ""
                )
        }
    }
}
