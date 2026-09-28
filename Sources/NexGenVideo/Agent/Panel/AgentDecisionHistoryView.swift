import SwiftUI

struct AgentDecisionHistoryView: View {
    let messages: [AgentMessage]
    @Environment(\.dismiss) private var dismiss

    static func records(in messages: [AgentMessage]) -> [AgentMessage] {
        messages.filter {
            $0.userPresentation?.workflowRecord != nil || $0.userPresentation?.choiceRecord != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Decision History")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Done") { dismiss() }
                    .buttonStyle(.inlineAction())
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    let records = Self.records(in: messages)
                    if records.isEmpty {
                        Text("No recorded decisions in this session.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    ForEach(records) { message in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            if let record = message.userPresentation?.workflowRecord {
                                if let phase = record.phase {
                                    Text(PhaseDisplay.label(phase))
                                        .interfaceFont(size: AppTheme.Typography.metadata)
                                        .foregroundStyle(AppTheme.Text.secondaryColor)
                                }
                                AgentReceiptView(receipt: .init(id: message.id, content: .workflow(record)))
                            }
                            if let choice = message.userPresentation?.choiceRecord {
                                AgentReceiptView(receipt: .init(id: message.id, content: .choice(choice)))
                            }
                            if let note = message.userPresentation?.typedText, !note.isEmpty {
                                Text(note)
                                    .interfaceFont(size: AppTheme.Typography.ui)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.chatColumnMax, height: AppTheme.ComponentSize.agentAssetPickerHeight)
    }
}
