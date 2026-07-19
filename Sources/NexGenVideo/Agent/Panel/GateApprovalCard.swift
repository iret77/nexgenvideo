import SwiftUI

/// The user's confirmation of an agent-initiated phase-gate approval (HAX G11). Docked in the composer
/// exactly where the spend card and generative dialog live — never a modal. The agent's approve_gate /
/// set_gate_state tool-call is suspended until Approve or Not yet; the gate is written only on Approve.
struct GateApprovalCard: View {
    let approval: GateApproval
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            summary
            footerRow
        }
        .padding(AppTheme.Spacing.md)
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
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Accent.primary)
            Text("Approve \(approval.phaseLabel)")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: onDecline) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Not yet (Esc)")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("The agent finished \(approval.phaseLabel) and is asking you to approve it.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = approval.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Text(notes)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Review it in the Story / Review tab first.")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    private var footerRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Not yet") { onDecline() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
            Spacer()
            Button("Approve \(approval.phaseLabel)") { onApprove() }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.small)
        }
    }
}
