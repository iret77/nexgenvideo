import SwiftUI

@MainActor
final class GenerationBatchReviewRuntimeEvidence {
    struct DetailsActionReceipt {
        let sequence: Int
        let itemID: String
        let expandedItemIDsBefore: Set<String>
        let expandedItemIDsAfter: Set<String>
    }

    private(set) var detailsActionReceipts: [DetailsActionReceipt] = []

    func recordDetailsAction(
        itemID: String,
        expandedItemIDsBefore: Set<String>,
        expandedItemIDsAfter: Set<String>
    ) {
        detailsActionReceipts.append(DetailsActionReceipt(
            sequence: detailsActionReceipts.count + 1,
            itemID: itemID,
            expandedItemIDsBefore: expandedItemIDsBefore,
            expandedItemIDsAfter: expandedItemIDsAfter
        ))
    }
}

struct GenerationBatchReviewControls: Equatable {
    let canEdit: Bool
    let canRetryPricing: Bool
    let canApprove: Bool
    let canApproveWithoutEstimate: Bool

    init(
        hasVerifiedTotal: Bool,
        hasRetryablePricingFailure: Bool,
        isCommitting: Bool,
        isRecovering: Bool
    ) {
        canEdit = !isCommitting
        canRetryPricing = hasRetryablePricingFailure && !isCommitting && !isRecovering
        canApprove = hasVerifiedTotal && !isCommitting && !isRecovering
        canApproveWithoutEstimate = !hasVerifiedTotal && !isCommitting && !isRecovering
    }
}

struct GenerationBatchCard: View {
    @Environment(\.interfaceScale) private var interfaceScale

    let editor: EditorViewModel
    var runtimeEvidenceEnabled = false
    var runtimeEvidence: GenerationBatchReviewRuntimeEvidence? = nil

    @State private var expandedItemIDs: Set<String> = []
    @FocusState private var focusedRemoveItemID: String?

    var body: some View {
        let coordinator = editor.generationBatchCoordinator
        if let batch = coordinator.pending {
            let projection = GenerationBatchReviewProjection(
                batch: batch,
                destinationName: { GenerationDestinationPresentation.label($0, editor: editor) }
            )
            let controls = GenerationBatchReviewControls(
                hasVerifiedTotal: batch.totalEUR != nil,
                hasRetryablePricingFailure: coordinator.canRetryPricing,
                isCommitting: coordinator.approving,
                isRecovering: coordinator.isRecovering
            )
            GenerationBatchDecisionLayout(
                maximumHeight: AppTheme.ComponentSize.agentDecisionMaxHeight * interfaceScale
                    - AppTheme.Spacing.md - AppTheme.Spacing.md,
                minimumBodyHeight: AppTheme.ComponentSize.generationBatchListMinHeight * interfaceScale,
                spacing: AppTheme.Spacing.smMd,
                fillsMaximumHeight: projection.itemCount > 1
            ) {
                header(projection)
                body(batch: batch, projection: projection, controls: controls)
                footer(batch: batch, projection: projection, controls: controls)
            }
            .padding(AppTheme.Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(AppTheme.Background.raisedColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                            .strokeBorder(
                                AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium),
                                lineWidth: AppTheme.BorderWidth.thin
                            )
                    }
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "Review \(projection.itemCount) requests, estimated total \(totalLabel(batch: batch, projection: projection))"
            )
            .accessibilityIdentifier("generationBatch.review")
            .onChange(of: Set(batch.payload.items.map(\.id))) { _, currentIDs in
                expandedItemIDs.formIntersection(currentIDs)
                if runtimeEvidenceEnabled,
                   focusedRemoveItemID.map({ !currentIDs.contains($0) }) ?? true {
                    focusedRemoveItemID = batch.payload.items.first?.id
                }
            }
            .onAppear {
                if runtimeEvidenceEnabled { focusedRemoveItemID = batch.payload.items.first?.id }
            }
        }
    }

    private func header(_ projection: GenerationBatchReviewProjection) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "square.stack.3d.up")
                    .interfaceFont(size: AppTheme.FontSize.md)
                    .foregroundStyle(AppTheme.Accent.primary)
                Text(projection.itemCount == 1
                    ? String(localized: "Review 1 request")
                    : String(localized: "Review \(projection.itemCount) requests"))
                    .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = requestSummary(projection) {
                Text(summary)
                    .interfaceFont(size: AppTheme.FontSize.xxs)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requestSummary(_ projection: GenerationBatchReviewProjection) -> String? {
        let output = projection.commonOutputCount.map {
            $0 == 1 ? String(localized: "1 output each") : String(localized: "\($0) outputs each")
        }
        let route = projection.routes.first.map { route -> String in
            let differing = projection.itemCount - route.count
            guard differing > 0 else { return route.label }
            return "\(route.count) × \(route.label) · " + (differing == 1
                ? String(localized: "1 route differs")
                : String(localized: "\(differing) routes differ"))
        }
        let values = [route, output, projection.commonDestinationLabel].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func body(
        batch: GenerationBatch,
        projection: GenerationBatchReviewProjection,
        controls: GenerationBatchReviewControls
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(projection.sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            if let source = batch.payload.items.first(where: { $0.id == item.id }) {
                                GenerationBatchItemRow(
                                    item: item,
                                    package: source.package,
                                    showsRoute: item.routeID != projection.dominantRouteID,
                                    showsOutputCount: projection.commonOutputCount == nil,
                                    showsDestination: projection.commonDestinationLabel == nil,
                                    isExpanded: expandedItemIDs.contains(item.id),
                                    isRecovering: editor.generationBatchCoordinator.recoveringItemIDs.contains(item.id),
                                    routeOptions: editor.generationBatchCoordinator.routeOptions(itemID: item.id),
                                    canEdit: controls.canEdit,
                                    runtimeEvidenceEnabled: runtimeEvidenceEnabled && item.manifestIndex == 0,
                                    focusedRemoveItemID: $focusedRemoveItemID,
                                    onToggleDetails: { toggleDetails(item.id) },
                                    onRemove: {
                                        expandedItemIDs.remove(item.id)
                                        editor.generationBatchCoordinator.remove(itemID: item.id, editor: editor)
                                    },
                                    onChangeRoute: { option in
                                        Task {
                                            await editor.generationBatchCoordinator.changeRoute(
                                                itemID: item.id,
                                                option: option,
                                                editor: editor
                                            )
                                        }
                                    }
                                )
                            }
                        }
                    } header: {
                        // Not pinned: a pinned header occludes the only visible row in a short viewport.
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Text(section.group.title.uppercased())
                                .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold)
                                .tracking(AppTheme.Tracking.subtle)
                                .foregroundStyle(AppTheme.Text.mutedColor)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            Text("\(section.items.count)")
                                .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium)
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        .padding(.vertical, AppTheme.Spacing.xs)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func footer(
        batch: GenerationBatch,
        projection: GenerationBatchReviewProjection,
        controls: GenerationBatchReviewControls
    ) -> some View {
        let coordinator = editor.generationBatchCoordinator
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            AppDivider()
            priceSummary(batch: batch, projection: projection)
            if let reason = busyReason {
                Text(reason)
                    .interfaceFont(size: AppTheme.FontSize.xxs)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(GenerationBatchRuntimeProbe(
                        identifier: "generation-batch.busy-reason",
                        enabled: runtimeEvidenceEnabled
                    ))
            }
            if let error = coordinator.error {
                Text("The request could not be updated. Try again or ask the agent to revise it.")
                    .interfaceFont(size: AppTheme.FontSize.xxs)
                    .foregroundStyle(AppTheme.Status.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Error details") {
                    Text(error)
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .textSelection(.enabled)
                }
            }
            // Narrow panels fold the secondary actions so the list keeps room for a complete request.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    declineButton(controls)
                    reviseButton(controls)
                    if coordinator.canRetryPricing { retryButton(controls) }
                    Spacer(minLength: AppTheme.Spacing.sm)
                    approveButton(batch: batch, controls: controls)
                }
                VStack(alignment: .trailing, spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        declineButton(controls)
                        reviseButton(controls)
                        if coordinator.canRetryPricing { retryButton(controls) }
                        Spacer(minLength: AppTheme.Spacing.none)
                    }
                    approveButton(batch: batch, controls: controls)
                }
                WrapLayout(spacing: AppTheme.Spacing.sm) {
                    declineButton(controls)
                    moreMenu(controls)
                    approveButton(batch: batch, controls: controls)
                }
            }
        }
    }

    private func reviseButton(_ controls: GenerationBatchReviewControls) -> some View {
        Button("Ask agent to revise") { editor.generationBatchCoordinator.requestRevision(editor: editor) }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .disabled(!controls.canEdit)
            .accessibilityIdentifier("generation-batch.revise")
            .modifier(GenerationBatchRuntimeProbe(
                identifier: "generation-batch.revise",
                enabled: runtimeEvidenceEnabled
            ))
    }

    private func moreMenu(_ controls: GenerationBatchReviewControls) -> some View {
        let coordinator = editor.generationBatchCoordinator
        return Menu {
            Button("Ask agent to revise") { coordinator.requestRevision(editor: editor) }
                .disabled(!controls.canEdit)
            if coordinator.canRetryPricing {
                Button("Retry pricing") { Task { await coordinator.retryPricing(editor: editor) } }
                    .disabled(!controls.canRetryPricing)
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Text("More")
                Image(systemName: "chevron.down").interfaceFont(size: AppTheme.Typography.metadata)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.capsule(.secondary, size: .regular))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!controls.canEdit)
        .accessibilityLabel("More actions")
        .accessibilityIdentifier("generation-batch.more")
        .modifier(GenerationBatchRuntimeProbe(
            identifier: "generation-batch.more",
            enabled: runtimeEvidenceEnabled
        ))
    }

    @ViewBuilder
    private func priceSummary(
        batch: GenerationBatch,
        projection: GenerationBatchReviewProjection
    ) -> some View {
        if let total = batch.totalEUR {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Estimated total")
                    .interfaceFont(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.sm)
                Text(GenerationPackageReviewView.euro(total))
                    .interfaceFont(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
        } else {
            Text(unknownPriceLabel(batch: batch, projection: projection))
                .interfaceFont(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Status.warningColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("Provider charges apply. The cost is recorded only if the provider reports it.")
                .interfaceFont(size: AppTheme.FontSize.xxs)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func unknownPriceLabel(
        batch: GenerationBatch,
        projection: GenerationBatchReviewProjection
    ) -> String {
        let unknown = projection.unknownPriceCount
        guard unknown < projection.itemCount else {
            return unknown == 1
                ? String(localized: "1 request: cost unknown")
                : String(localized: "\(unknown) requests: cost unknown")
        }
        let known = GenerationPackageReviewView.euro(knownEUR(batch))
        return unknown == 1
            ? String(localized: "1 request: cost unknown · Known estimate: \(known)")
            : String(localized: "\(unknown) requests: cost unknown · Known estimate: \(known)")
    }

    private func retryButton(_ controls: GenerationBatchReviewControls) -> some View {
        Button("Retry pricing") {
            Task { await editor.generationBatchCoordinator.retryPricing(editor: editor) }
        }
        .buttonStyle(.capsule(.secondary, size: .regular))
        .disabled(!controls.canRetryPricing)
        .accessibilityIdentifier("generation-batch.retry-pricing")
        .modifier(GenerationBatchRuntimeProbe(
            identifier: "generation-batch.retry-pricing",
            enabled: runtimeEvidenceEnabled
        ))
    }

    private func declineButton(_ controls: GenerationBatchReviewControls) -> some View {
        Button("Decline") { editor.generationBatchCoordinator.decline(editor: editor) }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .keyboardShortcut(.cancelAction)
            .disabled(!controls.canEdit)
            .accessibilityIdentifier("generation-batch.decline")
            .modifier(GenerationBatchRuntimeProbe(
                identifier: "generation-batch.decline",
                enabled: runtimeEvidenceEnabled
            ))
    }

    private func approveButton(
        batch: GenerationBatch,
        controls: GenerationBatchReviewControls
    ) -> some View {
        let count = batch.payload.items.count
        let unpriced = batch.totalEUR == nil
        let label = unpriced
            ? String(localized: "Approve without estimate")
            : count == 1
                ? String(localized: "Approve 1 request")
                : String(localized: "Approve \(count) requests")
        return Button(label) {
            Task {
                await editor.generationBatchCoordinator.approve(
                    editor: editor,
                    expectedBatchID: batch.id,
                    approval: unpriced ? .acceptUnknownPrices : .verifiedPrices
                )
            }
        }
        .buttonStyle(.capsule(.prominent, size: .regular))
        .disabled(unpriced ? !controls.canApproveWithoutEstimate : !controls.canApprove)
        .accessibilityIdentifier("generation-batch.approve")
        .modifier(GenerationBatchRuntimeProbe(
            identifier: "generation-batch.approve",
            enabled: runtimeEvidenceEnabled
        ))
    }

    private func knownEUR(_ batch: GenerationBatch) -> Double {
        batch.payload.items.compactMap { $0.package.payload.estimate?.eurAmount }.reduce(0, +)
    }

    private func totalLabel(
        batch: GenerationBatch,
        projection: GenerationBatchReviewProjection
    ) -> String {
        if let total = batch.totalEUR { return GenerationPackageReviewView.euro(total) }
        return "\(GenerationPackageReviewView.euro(knownEUR(batch))) + \(projection.unknownPriceCount) unknown"
    }

    private var busyReason: String? {
        let coordinator = editor.generationBatchCoordinator
        if coordinator.approving { return String(localized: "Approving the retained requests…") }
        guard coordinator.isRecovering else { return nil }
        let count = coordinator.recoveringItemIDs.count
        return count == 1
            ? String(localized: "Updating 1 request. Approve resumes when it finishes.")
            : String(localized: "Updating \(count) requests. Approve resumes when they finish.")
    }

    private func toggleDetails(_ itemID: String) {
        let before = expandedItemIDs
        var after = before
        if after.contains(itemID) { after.remove(itemID) }
        else { after.insert(itemID) }
        expandedItemIDs = after
        if runtimeEvidenceEnabled {
            runtimeEvidence?.recordDetailsAction(
                itemID: itemID,
                expandedItemIDsBefore: before,
                expandedItemIDsAfter: after
            )
        }
    }
}

private struct GenerationBatchItemRow: View {
    @Environment(\.interfaceScale) private var interfaceScale

    let item: GenerationBatchReviewProjection.Item
    let package: GenerationPackageV1
    let showsRoute: Bool
    let showsOutputCount: Bool
    let showsDestination: Bool
    let isExpanded: Bool
    let isRecovering: Bool
    let routeOptions: [SpendOption]
    let canEdit: Bool
    let runtimeEvidenceEnabled: Bool
    let focusedRemoveItemID: FocusState<String?>.Binding
    let onToggleDetails: () -> Void
    let onRemove: () -> Void
    let onChangeRoute: (SpendOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            AppDivider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    numberBadge
                    purposeBlock
                        .frame(
                            minWidth: AppTheme.ComponentSize.generationBatchPurposeMinWidth * interfaceScale,
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    price
                }
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    numberBadge
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        purposeBlock
                        price.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if item.referenceCount > 0 {
                HStack(alignment: .bottom, spacing: AppTheme.Spacing.xs) {
                    GenerationReferenceThumbnails(package: package, style: .compact, limit: compactReferenceLimit)
                    if item.referenceCount > compactReferenceLimit {
                        Text("+\(item.referenceCount - compactReferenceLimit)")
                            .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium)
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                }
            }
            WrapLayout(spacing: AppTheme.Spacing.sm) {
                Button(isExpanded ? "Hide details" : "Details", action: onToggleDetails)
                    .buttonStyle(InlineActionButtonStyle())
                    .accessibilityIdentifier("generation-batch.details.\(item.id)")
                    .modifier(GenerationBatchRuntimeProbe(
                        identifier: "generation-batch.details.\(item.id)",
                        enabled: runtimeEvidenceEnabled
                    ))
                removeButton
            }
            if isRecovering {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Preparing updated request…")
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    if !routeOptions.isEmpty {
                        NativeChoicePicker(
                            label: String(localized: "Change model"),
                            options: [.init(id: "", title: String(localized: "Keep current model"))]
                                + routeOptions.map {
                                    .init(id: $0.id, title: "\($0.modelName) · \($0.providerLabel)", help: $0.target.endpoint)
                                },
                            selection: Binding(get: { "" }, set: { id in
                                guard let option = routeOptions.first(where: { $0.id == id }) else { return }
                                onChangeRoute(option)
                            })
                        )
                        .disabled(!canEdit || isRecovering)
                    }
                    GenerationPackageReviewView(package: package)
                }
                .padding(AppTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Background.surfaceColor)
                )
                .modifier(GenerationBatchRuntimeProbe(
                    identifier: "generation-batch.expanded.\(item.id)",
                    enabled: runtimeEvidenceEnabled
                ))
            }
        }
        .padding(.vertical, AppTheme.Spacing.sm)
        .modifier(GenerationBatchRuntimeProbe(
            identifier: "generation-batch.item.\(item.id)",
            enabled: runtimeEvidenceEnabled
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request \(item.manifestIndex + 1), \(item.purpose)")
    }

    private var compactReferenceLimit: Int { 3 }

    private var numberBadge: some View {
        Text("\(item.manifestIndex + 1)")
            .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .frame(
                width: AppTheme.IconSize.mdLg * interfaceScale,
                height: AppTheme.IconSize.mdLg * interfaceScale
            )
            .background(Circle().fill(AppTheme.Background.prominentColor))
    }

    private var purposeBlock: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(item.purpose)
                .interfaceFont(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let summary {
                Text(summary)
                    .interfaceFont(size: AppTheme.FontSize.xxs)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var price: some View {
        Text(priceLabel)
            .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold)
            .foregroundStyle(item.priceEUR == nil ? AppTheme.Status.warningColor : AppTheme.Text.primaryColor)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var summary: String? {
        let output = item.outputCount == 1
            ? String(localized: "1 output")
            : String(localized: "\(item.outputCount) outputs")
        let values = [
            showsOutputCount ? output : nil,
            showsDestination ? item.destinationLabel : nil,
            showsRoute ? item.routeLabel : nil,
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var priceLabel: String {
        item.priceEUR.map(GenerationPackageReviewView.euro) ?? String(localized: "Cost unknown")
    }

    private var removeButton: some View {
        Button("Remove", action: onRemove)
            .buttonStyle(InlineActionButtonStyle())
            .disabled(!canEdit)
            .accessibilityLabel("Remove request \(item.manifestIndex + 1), \(item.purpose)")
            .accessibilityIdentifier("generation-batch.remove.\(item.id)")
            .modifier(GenerationBatchRuntimeProbe(
                identifier: "generation-batch.remove.\(item.id)",
                enabled: runtimeEvidenceEnabled
            ))
            .focused(focusedRemoveItemID, equals: item.id)
    }
}

private struct GenerationBatchRuntimeProbe: ViewModifier {
    let identifier: String
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        content.background {
            if enabled {
                AppRelaunchClickProbe(identifier: identifier)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }
}

// Prefers room for one complete request over the usual bound; a shorter offer shrinks only the list.
private struct GenerationBatchDecisionLayout: SwiftUI.Layout {
    let maximumHeight: CGFloat
    let minimumBodyHeight: CGFloat
    let spacing: CGFloat
    let fillsMaximumHeight: Bool

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = finite(proposal.width) ?? subviews.map {
            finite($0.sizeThatFits(.unspecified).width) ?? AppTheme.Spacing.none
        }.max() ?? AppTheme.Spacing.none
        let childProposal = ProposedViewSize(width: width, height: nil)
        let fixed = (finite(subviews[0].sizeThatFits(childProposal).height) ?? AppTheme.Spacing.none)
            + (finite(subviews[2].sizeThatFits(childProposal).height) ?? AppTheme.Spacing.none)
            + spacing + spacing
        let body = finite(subviews[1].sizeThatFits(childProposal).height) ?? minimumBodyHeight
        let ceiling = max(maximumHeight, fixed + minimumBodyHeight)
        let available = min(max(finite(proposal.height) ?? ceiling, fixed), ceiling)
        let height = fillsMaximumHeight ? available : min(fixed + body, available)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) {
        guard subviews.count == 3 else { return }
        let width = finite(bounds.width) ?? AppTheme.Spacing.none
        let fixedProposal = ProposedViewSize(width: width, height: nil)
        let headerHeight = finite(subviews[0].sizeThatFits(fixedProposal).height) ?? AppTheme.Spacing.none
        let footerHeight = finite(subviews[2].sizeThatFits(fixedProposal).height) ?? AppTheme.Spacing.none
        let bodyHeight = max(
            AppTheme.Spacing.none,
            bounds.height - headerHeight - footerHeight - spacing - spacing
        )
        var y = bounds.minY
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: headerHeight)
        )
        y += headerHeight + spacing
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: bodyHeight)
        )
        y += bodyHeight + spacing
        subviews[2].place(
            at: CGPoint(x: bounds.minX, y: y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: footerHeight)
        )
    }

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, AppTheme.Spacing.none), AppTheme.Layout.safeDimensionCeiling)
    }

    func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
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
