import SwiftUI

struct IntentLedgerAttributeView: View {
    let object: InspectedObject
    let key: String
    let attribute: LedgerAttribute
    @Environment(EditorViewModel.self) private var editor
    @State private var showingDetails = false

    private var identifier: String { (LedgerData.ledgerKey(for: object) ?? "unavailable") + "." + key }

    var body: some View {
        Button { showingDetails = true } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                if attribute.locked {
                    Image(systemName: "lock.fill")
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                Text(attribute.tag)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: attribute.locked ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.capsule(.secondary))
        .accessibilityLabel(key + ": " + attribute.tag + (attribute.locked ? ", locked" : ", unlocked"))
        .reviewAcceptanceProbe("ledger.attribute." + identifier, text: attribute.tag)
        .onChange(of: object) { _, _ in showingDetails = false }
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text(key).interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Text(attribute.tag).textSelection(.enabled)
                        LabeledContent("Directive") { Text(attribute.directive).textSelection(.enabled) }
                            .reviewAcceptanceProbe("ledger.directive", text: attribute.directive)
                        LabeledContent("Source") { Text(attribute.source.isEmpty ? "Not recorded" : attribute.source).textSelection(.enabled) }
                            .reviewAcceptanceProbe("ledger.source", text: attribute.source)
                        Text(attribute.locked ? "Locked — generation must honor this attribute." : "Unlocked")
                            .reviewAcceptanceProbe("ledger.locked", state: attribute.locked, text: attribute.locked ? "Locked" : "Unlocked")
                    }
                }.frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
                Button("Revise this attribute…") {
                    guard editor.inspectedObject == object else { showingDetails = false; return }
                    let context = AgentTaskSelectionContext.capture(editor: editor)
                    let task = AgentTask(title: "Revise: " + key, systemImage: "pencil",
                        prompt: "Revise only Ledger key " + key + " on " + object.taskTarget
                            + ". Read its current tag, directive, source and lock first. Preserve other objects and attributes; preserve the existing lock semantics: removing a locked attribute is rejected. Use only current-phase tools.",
                        requiresDirection: true, originContext: context.hint)
                    if editor.agentService.stageTask(task) { showingDetails = false }
                }
                .buttonStyle(.capsule(.secondary))
                .disabled(editor.agentService.isStreaming || editor.agentService.isComposerBlocked)
                .reviewAcceptanceProbe("ledger.revise", state: !editor.agentService.isStreaming && !editor.agentService.isComposerBlocked)
                Button("Done") { showingDetails = false }.buttonStyle(.inlineAction())
                    .reviewAcceptanceProbe("ledger.done")
            }
            .interfaceFont(size: AppTheme.Typography.ui)
            .padding(AppTheme.Spacing.lg)
            .frame(width: AppTheme.Layout.productionDecisionReviewWidth)
            .reviewAcceptanceProbe("ledger.details", text: identifier)
        }
    }
}
