import SwiftUI

/// Persistent sign in Tasks that every paid agent run of one phase is approved, with its runs and a
/// withdraw action. It disappears when the approval ends.
struct PhaseSpendApprovalIndicator: View {
    let editor: EditorViewModel

    var body: some View {
        if let approval = editor.phaseSpendApproval.current {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "checkmark.seal")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Accent.primary)
                    Text("All paid runs in \(PhaseDisplay.label(approval.phase)) approved")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: AppTheme.Spacing.sm)
                    Button("Withdraw") { editor.phaseSpendApproval.withdraw(editor: editor) }
                        .buttonStyle(.capsule(.secondary, size: .small))
                        .help("Ends when the phase is approved or rewound, when you withdraw it, or when NexGenVideo quits.")
                        .accessibilityIdentifier("phase-approval.withdraw")
                }
                Text("Until the phase is approved or rewound, or NexGenVideo quits.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                if approval.runs.isEmpty {
                    Text("No runs yet")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                } else {
                    DisclosureGroup(approval.runs.count == 1
                        ? String(localized: "1 run")
                        : String(localized: "\(approval.runs.count) runs")) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            ForEach(approval.runs) { run in
                                Text("\(run.label) · \(run.detail)")
                                    .interfaceFont(size: AppTheme.Typography.ui)
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                                    .lineLimit(2)
                                    .help(run.at.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .interfaceFont(size: AppTheme.Typography.ui)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.md)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phase-approval.indicator")
        }
    }
}

/// Shown in place of a card while a run starts under the phase approval.
struct PhaseSpendApprovalStartNotice: View {
    let phase: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Starting under the \(PhaseDisplay.label(phase)) approval")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
