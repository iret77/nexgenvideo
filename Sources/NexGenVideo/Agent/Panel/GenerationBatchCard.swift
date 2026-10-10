import SwiftUI

struct GenerationBatchReviewControls: Equatable {
    let canEdit: Bool
    let canRetryPricing: Bool
    let canApprove: Bool
    let canApproveWithoutEstimate: Bool

    init(hasVerifiedTotal: Bool, hasRetryablePricingFailure: Bool, isBusy: Bool) {
        canEdit = !isBusy
        canRetryPricing = hasRetryablePricingFailure && !isBusy
        canApprove = hasVerifiedTotal && !isBusy
        canApproveWithoutEstimate = !hasVerifiedTotal && !isBusy
    }
}

struct GenerationBatchCard: View {
    let editor: EditorViewModel

    var body: some View {
        let coordinator = editor.generationBatchCoordinator
        if let batch = coordinator.pending {
            let controls = GenerationBatchReviewControls(
                hasVerifiedTotal: batch.totalEUR != nil,
                hasRetryablePricingFailure: coordinator.canRetryPricing,
                isBusy: coordinator.approving || coordinator.isRecovering
            )
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Review \(batch.payload.items.count) requests")
                    .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                priceSummary(batch)
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        ForEach(Array(batch.payload.items.enumerated()), id: \.element.id) { index, item in
                            requestRow(item, index: index, controls: controls)
                        }
                        if let error = coordinator.error {
                            Text("The request could not be updated. Try again or ask the agent to revise it.")
                                .foregroundStyle(AppTheme.Status.warningColor)
                            DisclosureGroup("Error details") { Text(error).textSelection(.enabled) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                WrapLayout(spacing: AppTheme.Spacing.sm, trailingLastItem: true) {
                    Button("Decline") { coordinator.decline(editor: editor) }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(!controls.canEdit)
                    Button("Ask agent to revise") { coordinator.requestRevision(editor: editor) }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(!controls.canEdit)
                    if coordinator.canRetryPricing {
                        Button("Retry pricing") {
                            Task { await coordinator.retryPricing(editor: editor) }
                        }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(!controls.canRetryPricing)
                    }
                    Button(batch.totalEUR == nil
                        ? String(localized: "Approve without estimate")
                        : String(localized: "Approve \(batch.payload.items.count) requests")) {
                        Task {
                            await coordinator.approve(editor: editor, expectedBatchID: batch.id,
                                approval: batch.totalEUR == nil ? .acceptUnknownPrices : .verifiedPrices)
                        }
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(!controls.canApprove && !controls.canApproveWithoutEstimate)
                    .accessibilityIdentifier("generationBatch.approve")
                }
            }
            .interfaceFont(size: AppTheme.Typography.ui)
            .padding(AppTheme.Spacing.md)
            .frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.md).fill(AppTheme.Background.raisedColor))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("generationBatch.review")
        }
    }

    @ViewBuilder
    private func priceSummary(_ batch: GenerationBatch) -> some View {
        if let total = batch.totalEUR {
            Text("Estimated total: €\(total, specifier: "%.2f")")
        } else {
            let unknown = batch.payload.items.filter { $0.package.payload.estimate == nil }.count
            let known = batch.payload.items.compactMap { $0.package.payload.estimate?.eurAmount }.reduce(0, +)
            Group {
                if unknown == batch.payload.items.count {
                    Text("\(unknown) requests: cost unknown")
                } else {
                    Text("\(unknown) requests: cost unknown · Known estimate: €\(known, specifier: "%.2f")")
                }
            }
            .foregroundStyle(AppTheme.Status.warningColor)
            .fixedSize(horizontal: false, vertical: true)
            Text("Provider charges apply. The project budget cannot be guaranteed for this batch.")
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func requestRow(_ item: GenerationBatch.Item, index: Int, controls: GenerationBatchReviewControls) -> some View {
        let coordinator = editor.generationBatchCoordinator
        let options = coordinator.routeOptions(itemID: item.id)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("\(index + 1). \(item.purpose)")
                .fontWeight(AppTheme.FontWeight.semibold)
                .lineLimit(2)
                .help(item.purpose)
            GenerationPackageReviewView(package: item.package, showsDetails: false)
            DisclosureGroup("Details and options") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(item.purpose).textSelection(.enabled)
                    if !options.isEmpty {
                        NativeChoicePicker(label: "Change model", options:
                            [.init(id: "", title: String(localized: "Keep current model"))]
                                + options.map { .init(id: $0.id, title: "\($0.modelName) · \($0.providerLabel)", help: $0.target.endpoint) },
                            selection: Binding(get: { "" }, set: { id in
                                guard let option = options.first(where: { $0.id == id }) else { return }
                                Task { await coordinator.changeRoute(itemID: item.id, option: option, editor: editor) }
                            }))
                            .disabled(!controls.canEdit)
                    }
                    Button("Remove request") { coordinator.remove(itemID: item.id, editor: editor) }
                        .buttonStyle(InlineActionButtonStyle())
                        .disabled(!controls.canEdit)
                    GenerationPackageReviewView(package: item.package).details
                }
            }
            if coordinator.recoveringItemIDs.contains(item.id) {
                Text("Preparing updated request…").foregroundStyle(AppTheme.Text.secondaryColor)
            }
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
                            if let count = snapshot.journal.pricingOverrideItemIDs?.count {
                                Text("Approved without estimate for \(count) requests")
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                            }
                            if !snapshot.authorityAvailable {
                                Text("Execution authority is not available on this Mac. This batch is history only.")
                                    .foregroundStyle(AppTheme.Status.warningColor)
                            }
                            ForEach(snapshot.batch.payload.items) { item in
                                if let execution = snapshot.journal.executions.first(where: { $0.itemID == item.id }) {
                                    Text("\(item.purpose) · \(label(execution.state))")
                                    if let detail = execution.detail { Text(detail).foregroundStyle(AppTheme.Text.secondaryColor) }
                                    ForEach(execution.outputAssetIDs, id: \.self) { id in
                                        if let asset = editor.mediaAssets.first(where: { $0.id == id }) {
                                            Button("Open \(asset.libraryDisplayName)") { editor.selectMediaAsset(asset) }
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
