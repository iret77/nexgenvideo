import SwiftUI

struct GenerationBatchCard: View {
    let editor: EditorViewModel

    var body: some View {
        let coordinator = editor.generationBatchCoordinator
        if let batch = coordinator.pending {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Review \(batch.payload.items.count) generations").fontWeight(AppTheme.FontWeight.semibold)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        ForEach(Array(batch.payload.items.enumerated()), id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                HStack {
                                    Text("\(index + 1). \(item.purpose)")
                                    Spacer()
                                    Button("Remove") { coordinator.remove(itemID: item.id, editor: editor) }
                                        .buttonStyle(InlineActionButtonStyle()).disabled(coordinator.approving)
                                }
                                GenerationPackageReviewView(package: item.package)
                            }
                        }
                    }
                }.frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
                if let total = batch.totalEUR {
                    Text("Estimated total: €\(total, specifier: "%.2f")")
                } else {
                    Text("Every generation needs a monetary estimate before this batch can run unattended.")
                        .foregroundStyle(AppTheme.Status.warningColor)
                }
                if let error = coordinator.error { Text(error).foregroundStyle(AppTheme.Status.warningColor) }
                HStack {
                    Button("Decline") { coordinator.decline(editor: editor) }
                        .buttonStyle(.capsule(.secondary, size: .regular)).disabled(coordinator.approving)
                    Spacer()
                    Button("Approve \(batch.payload.items.count) generations") {
                        Task { await coordinator.approve(editor: editor) }
                    }.buttonStyle(.capsule(.prominent, size: .regular))
                        .disabled(coordinator.approving || batch.totalEUR == nil)
                }
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.md).fill(AppTheme.Background.raisedColor))
        }
    }
}

struct GenerationBatchProgressView: View {
    let editor: EditorViewModel

    var body: some View {
        let coordinator = editor.generationBatchCoordinator
        if coordinator.pending == nil, let error = coordinator.error {
            Text(error).foregroundStyle(AppTheme.Status.warningColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
        }
        if !coordinator.snapshots.isEmpty {
            DisclosureGroup("Generation batches") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(coordinator.snapshots, id: \.batch.id) { snapshot in
                            let completed = snapshot.journal.executions.filter { $0.state == .complete }.count
                            Text("\(completed) of \(snapshot.batch.payload.items.count) complete")
                                .fontWeight(AppTheme.FontWeight.semibold)
                            ForEach(snapshot.batch.payload.items) { item in
                                if let execution = snapshot.journal.executions.first(where: { $0.itemID == item.id }) {
                                    Text("\(item.purpose) · \(label(execution.state))")
                                    if let detail = execution.detail { Text(detail).foregroundStyle(AppTheme.Text.secondaryColor) }
                                }
                            }
                            Button("Cancel remaining") { coordinator.cancelRemaining(batchID: snapshot.batch.id, editor: editor) }
                                .buttonStyle(InlineActionButtonStyle())
                                .disabled(!snapshot.journal.executions.contains(where: { $0.state == .queued }))
                            if snapshot.journal.executions.contains(where: { $0.state == .blocked && $0.providerRequestResumable }) {
                                Button("Resume status checks") { coordinator.start(batchID: snapshot.batch.id, editor: editor, resumeBlocked: true) }
                                    .buttonStyle(InlineActionButtonStyle())
                            }
                        }
                    }
                }.frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
        }
    }

    private func label(_ state: GenerationBatchJournal.State) -> String {
        switch state {
        case .queued: String(localized: "Queued")
        case .submitting: String(localized: "Submitting")
        case .running: String(localized: "Running")
        case .complete: String(localized: "Complete")
        case .failed: String(localized: "Failed")
        case .canceled: String(localized: "Canceled")
        case .blocked: String(localized: "Blocked")
        }
    }
}
