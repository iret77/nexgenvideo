import SwiftUI

struct GenerationBatchCard: View {
    let editor: EditorViewModel

    var body: some View {
        if let batch = editor.generationBatchCoordinator.pending {
            GenerationBatchReviewContent(editor: editor, batch: batch)
                .id(batch.payload.nonce)
        }
    }
}

private struct GenerationBatchReviewContent: View {
    let editor: EditorViewModel
    let batch: GenerationBatch
    @State private var selection: GenerationBatchReviewSelection

    init(editor: EditorViewModel, batch: GenerationBatch) {
        self.editor = editor
        self.batch = batch
        _selection = State(initialValue: .init(batch: batch))
    }

    private var coordinator: GenerationBatchCoordinator { editor.generationBatchCoordinator }
    private var actions: GenerationBatchReviewActions { .init(editor: editor) }
    private var isBusy: Bool { coordinator.approving || coordinator.recoveringPricing }
    private var policy: GenerationBatchReviewPolicy { .init(batch: batch, selectedIDs: selection.selectedIDs, isBusy: isBusy) }
    private var commonRoute: String? {
        let routes = Set(batch.payload.items.map { GenerationPackagePresentation.route($0.package) })
        return routes.count == 1 ? routes.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(batch.payload.items.count == 1 ? String(localized: "Review 1 generation")
                    : String(localized: "Review \(batch.payload.items.count) generations"))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                if let commonRoute {
                    Text(commonRoute).font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.secondaryColor).lineLimit(1).help(commonRoute)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                    ForEach(selection.rows(in: batch)) { row in
                        GenerationBatchReviewRow(row: row, projectHome: editor.workingRoot,
                            showsRoute: commonRoute == nil, pricingFailure: coordinator.pricingFailure(for: row.item.package),
                            isBusy: isBusy, isSelected: selected(row.id), onRemovalKey: handleRemovalKey)
                        AppDivider()
                    }
                    if let error = coordinator.error {
                        DisclosureGroup("Diagnostic details") {
                            Text(error).textSelection(.enabled)
                        }
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            footer.fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .padding(AppTheme.Spacing.md)
        .frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.md).fill(AppTheme.Background.raisedColor))
        .onChange(of: batch.id) { _, _ in selection.reconcile(batch: batch) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review generations")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            AppDivider()
            if policy.showsPricingRecovery {
                Text(coordinator.recoveringPricing ? "Refreshing prices…" : "Price unavailable")
                    .foregroundStyle(AppTheme.Status.warningColor)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.smMd) { recoveryActions }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) { recoveryActions }
                }
            }
            if coordinator.error != nil {
                Text("Review could not be updated. Try again.")
                    .font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Status.warningColor)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.sm) { total; Spacer(minLength: AppTheme.Spacing.sm); removeButton }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) { total; removeButton }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.sm) { declineButton; Spacer(minLength: AppTheme.Spacing.sm); approveButton }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) { approveButton; declineButton }
            }
        }
    }

    @ViewBuilder private var total: some View {
        if let amount = batch.totalEUR {
            Text("Estimated total: €\(amount, specifier: "%.2f")").monospacedDigit()
        } else {
            Text("Verified estimate required").foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    @ViewBuilder private var recoveryActions: some View {
        Button(coordinator.recoveringPricing ? "Retrying…" : "Retry Pricing") {
            Task { await actions.retryPricing(batchID: batch.id) }
        }
        .buttonStyle(InlineActionButtonStyle()).disabled(!policy.canRetryPricing)
        Button("Change Route") { actions.changeRoute(batchID: batch.id, itemIDs: selection.selectedIDs) }
            .buttonStyle(InlineActionButtonStyle()).disabled(!policy.canChangeRoute)
            .help("Select unpriced generations to change route")
    }

    private var removeButton: some View {
        Button("Remove") { actions.remove(batchID: batch.id, itemIDs: selection.selectedIDs) }
            .buttonStyle(InlineActionButtonStyle()).disabled(!policy.canRemove)
            .help("Remove selected generations (Delete)")
            .onKeyPress(phases: .down) { handleRemovalKey($0) }
    }

    private var declineButton: some View {
        Button("Decline") { coordinator.decline(editor: editor) }
            .buttonStyle(.capsule(.secondary, size: .regular)).disabled(isBusy)
    }

    private var approveButton: some View {
        Button(approveLabel) {
            Task { await actions.approve(batchID: batch.id) }
        }
        .buttonStyle(.capsule(.prominent, size: .regular)).disabled(!policy.canApprove)
    }

    private var approveLabel: String {
        if coordinator.approving { return String(localized: "Approving…") }
        return batch.payload.items.count == 1 ? String(localized: "Approve 1 generation")
            : String(localized: "Approve \(batch.payload.items.count) generations")
    }

    private func selected(_ id: String) -> Binding<Bool> {
        Binding(get: { selection.selectedIDs.contains(id) }, set: { value in
            guard !isBusy else { return }
            if value { selection.selectedIDs.insert(id) } else { selection.selectedIDs.remove(id) }
        })
    }

    private func handleRemovalKey(_ press: KeyPress) -> KeyPress.Result {
        actions.handleRemovalKey(press.key, modifiers: press.modifiers, batchID: batch.id,
            itemIDs: selection.selectedIDs) ? .handled : .ignored
    }
}

struct GenerationBatchProgressView: View {
    let editor: EditorViewModel

    var body: some View {
        let coordinator = editor.generationBatchCoordinator
        if coordinator.pending == nil, let error = coordinator.error {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Generation batch needs attention.").foregroundStyle(AppTheme.Status.warningColor)
                DisclosureGroup("Diagnostic details") { Text(error).textSelection(.enabled) }
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }.padding(.horizontal, AppTheme.Spacing.sm)
        }
        if !coordinator.snapshots.isEmpty {
            DisclosureGroup("Generation batches") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(coordinator.snapshots, id: \.batch.id) { snapshot in
                            let completed = snapshot.journal.executions.filter { $0.state == .complete }.count
                            Text("\(completed) of \(snapshot.batch.payload.items.count) complete")
                                .fontWeight(AppTheme.FontWeight.semibold)
                            if !snapshot.authorityAvailable {
                                Text("Execution authority is not available on this Mac. This batch is history only.")
                                    .foregroundStyle(AppTheme.Status.warningColor)
                            }
                            ForEach(snapshot.batch.payload.items) { item in
                                if let execution = snapshot.journal.executions.first(where: { $0.itemID == item.id }) {
                                    Text("\(item.purpose) · \(label(execution.state))")
                                    if let detail = execution.detail {
                                        DisclosureGroup("Diagnostic details") { Text(detail).textSelection(.enabled) }
                                            .foregroundStyle(AppTheme.Text.secondaryColor)
                                    }
                                    ForEach(execution.outputAssetIDs, id: \.self) { id in
                                        if let asset = editor.mediaAssets.first(where: { $0.id == id }) {
                                            Button("Open \(asset.name)") { editor.selectMediaAsset(asset) }
                                                .buttonStyle(InlineActionButtonStyle())
                                        }
                                    }
                                }
                            }
                            Button("Cancel remaining") { coordinator.cancelRemaining(batchID: snapshot.batch.id, editor: editor) }
                                .buttonStyle(InlineActionButtonStyle())
                                .disabled(!snapshot.authorityAvailable || !snapshot.journal.executions.contains(where: { $0.state == .queued }))
                            if snapshot.authorityAvailable && snapshot.journal.executions.contains(where: { $0.state == .blocked && $0.providerRequestResumable }) {
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
