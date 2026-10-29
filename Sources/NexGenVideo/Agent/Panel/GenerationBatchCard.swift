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

    private(set) var focusedRemoveItemID: String?
    private(set) var focusedDetailsItemID: String?

    func recordRemoveFocus(_ itemID: String?) {
        focusedRemoveItemID = itemID
    }

    func recordDetailsFocus(_ itemID: String?) {
        focusedDetailsItemID = itemID
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
        isRecovering: Bool,
        referencesReady: Bool = true
    ) {
        canEdit = !isCommitting
        canRetryPricing = hasRetryablePricingFailure && !isCommitting && !isRecovering
        canApprove = hasVerifiedTotal && !isCommitting && !isRecovering && referencesReady
        canApproveWithoutEstimate = !hasVerifiedTotal && !isCommitting && !isRecovering && referencesReady
    }
}

struct GenerationBatchCard: View {
    @Environment(\.productionDecisionCompact) private var compact
    let editor: EditorViewModel
    var runtimeEvidenceEnabled = false
    var runtimeEvidence: GenerationBatchReviewRuntimeEvidence? = nil

    @State private var expandedItemIDs: Set<String> = []
    @FocusState private var focusedRemoveItemID: String?
    @FocusState private var focusedDetailsItemID: String?

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
                isRecovering: coordinator.isRecovering,
                referencesReady: coordinator.canApprovePending
            )
            GenerationApprovalCard(
                title: [GenerationApprovalPresentation.actionLabel(packages: batch.payload.items.map(\.package)),
                    batch.payload.phase.map(PhaseDisplay.label)].compactMap { $0 }.joined(separator: " · "),
                fillsMaximumHeight: projection.itemCount > 1,
                identifier: "generation-batch",
                runtimeEvidenceEnabled: runtimeEvidenceEnabled
            ) {
                body(batch: batch, projection: projection, controls: controls)
            } footer: {
                footer(batch: batch, projection: projection, controls: controls)
            }
            .accessibilityIdentifier("generationBatch.review")
            .task(id: coordinator.preflightKey(editor: editor)) {
                await coordinator.preflight(editor: editor, expectedBatchID: batch.id)
            }
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
            .onChange(of: focusedRemoveItemID, initial: true) { _, itemID in
                if runtimeEvidenceEnabled { runtimeEvidence?.recordRemoveFocus(itemID) }
            }
            .onChange(of: focusedDetailsItemID, initial: true) { _, itemID in
                if runtimeEvidenceEnabled { runtimeEvidence?.recordDetailsFocus(itemID) }
            }
        }
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
        let destination = projection.commonDestinationLabel.map { String(localized: "Results: \($0)") }
        let values = [route, output, destination].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func body(
        batch: GenerationBatch,
        projection: GenerationBatchReviewProjection,
        controls: GenerationBatchReviewControls
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if compact { decisionMessages }
                if let summary = requestSummary(projection) {
                    Text(summary)
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if batch.totalEUR == nil {
                    Text("Provider charges apply. The cost is recorded only if the provider reports it.")
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                                    runtimeEvidenceEnabled: runtimeEvidenceEnabled && (
                                        item.manifestIndex == 0 || item.id == projection.sections.last?.items.last?.id
                                    ),
                                    focusedRemoveItemID: $focusedRemoveItemID,
                                    focusedDetailsItemID: $focusedDetailsItemID,
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
            .modifier(GenerationBatchRuntimeProbe(identifier: "generation-batch.list", enabled: runtimeEvidenceEnabled))
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
                .modifier(GenerationBatchRuntimeProbe(identifier: "generation-batch.cost", enabled: runtimeEvidenceEnabled))
            if !compact { decisionMessages }
            GenerationApprovalActions(
                actionLabel: GenerationApprovalPresentation.actionLabel(packages: batch.payload.items.map(\.package)),
                phase: batch.payload.phase,
                canApprove: controls.canApprove || controls.canApproveWithoutEstimate,
                canEdit: controls.canEdit,
                onApprove: {
                    if let phase = batch.payload.phase { editor.revealReviewSurface(for: phase) }
                    Task {
                        await coordinator.approve(editor: editor, expectedBatchID: batch.id,
                            approval: batch.totalEUR == nil ? .acceptUnknownPrices : .verifiedPrices)
                    }
                },
                onDecline: { coordinator.decline(editor: editor) },
                onApprovePhase: {
                    if let phase = batch.payload.phase { editor.revealReviewSurface(for: phase) }
                    Task { await coordinator.approveForPhase(editor: editor, expectedBatchID: batch.id) }
                },
                onRevise: { coordinator.requestRevision(editor: editor) },
                onRetryPricing: coordinator.canRetryPricing
                    ? { Task { await coordinator.retryPricing(editor: editor) } } : nil,
                canRetryPricing: controls.canRetryPricing,
                identifier: "generation-batch",
                runtimeEvidenceEnabled: runtimeEvidenceEnabled,
                revisionRequired: coordinator.preflightIssue != nil
            )
        }
    }

    private var decisionMessages: some View {
        let coordinator = editor.generationBatchCoordinator
        return Group {
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
            if let issue = coordinator.preflightIssue {
                Text("Generation cannot start. Ask the agent to revise this request.")
                    .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(issue)
                    .interfaceFont(size: AppTheme.FontSize.xxs)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(GenerationBatchRuntimeProbe(
                        identifier: "generation-batch.preflight-issue",
                        enabled: runtimeEvidenceEnabled,
                        acceptanceText: issue
                    ))
            } else if let error = coordinator.error {
                Text(error.hasPrefix("Generation approval failed:")
                    ? String(localized: "Generation approval failed.")
                    : String(localized: "The generation request could not be changed."))
                    .interfaceFont(size: AppTheme.FontSize.xxs)
                    .foregroundStyle(AppTheme.Status.errorColor)
                DisclosureGroup("Error details") {
                    Text(error).interfaceFont(size: AppTheme.FontSize.xxs).textSelection(.enabled)
                }
            }
        }
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
            Text(compact
                ? unknownPriceLabel(batch: batch, projection: projection) + String(localized: " · Provider charges apply")
                : unknownPriceLabel(batch: batch, projection: projection))
                .interfaceFont(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold)
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

    private func knownEUR(_ batch: GenerationBatch) -> Double {
        batch.payload.items.compactMap { $0.package.payload.estimate?.eurAmount }.reduce(0, +)
    }

    private var busyReason: String? {
        let coordinator = editor.generationBatchCoordinator
        if coordinator.preflighting { return String(localized: "Checking generation inputs…") }
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
    let focusedDetailsItemID: FocusState<String?>.Binding
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
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text("Input")
                            .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium)
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        GenerationReferenceThumbnails(package: package, style: .compact, limit: compactReferenceLimit)
                    }
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
                    .focused(focusedDetailsItemID, equals: item.id)
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
            .foregroundStyle(item.priceEUR == nil ? AppTheme.Text.secondaryColor : AppTheme.Text.primaryColor)
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

struct GenerationBatchRuntimeProbe: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let identifier: String
    let enabled: Bool
    var acceptanceText: String? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        content.background {
            if enabled {
                // The probe's NSView must not answer the accessibility hit test of the control it measures.
                AppRelaunchClickProbe(identifier: identifier, acceptanceState: isEnabled, acceptanceText: acceptanceText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// Prefers room for one complete request over the usual bound; a shorter offer shrinks only the list.
struct GenerationBatchDecisionLayout: SwiftUI.Layout {
    let maximumHeight: CGFloat
    let minimumBodyHeight: CGFloat
    let spacing: CGFloat
    let fillsMaximumHeight: Bool
    var hasExplicitHeightLimit = false

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
        let measuredBody = finite(subviews[1].sizeThatFits(childProposal).height) ?? minimumBodyHeight
        let minimumBody = hasExplicitHeightLimit
            ? min(minimumBodyHeight, AppTheme.ComponentSize.generationBatchCompactBodyMinHeight) : minimumBodyHeight
        let body = hasExplicitHeightLimit ? max(measuredBody, minimumBody) : measuredBody
        let proposedHeight = finite(proposal.height)
        let preferredMaximum = fillsMaximumHeight && !hasExplicitHeightLimit
            ? max(maximumHeight, proposedHeight ?? maximumHeight) : maximumHeight
        let ceiling = max(preferredMaximum, fixed + (hasExplicitHeightLimit ? AppTheme.Spacing.none : minimumBody))
        let available = min(max(proposedHeight ?? ceiling, fixed), ceiling)
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
    var batchID: String? = nil
    @State private var expanded = false

    var body: some View {
        let coordinator = editor.generationBatchCoordinator
        if coordinator.pending == nil, let error = coordinator.error {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Generation needs attention. Open AI activity to continue.")
                DisclosureGroup("Diagnostic details") { Text(error).textSelection(.enabled) }
            }
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
        }
        let snapshots = coordinator.snapshots.filter { batchID == nil || $0.batch.id == batchID }
        if !snapshots.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(snapshots, id: \.batch.id) { snapshot in
                            let completed = snapshot.journal.executions.filter { $0.state == .complete }.count
                            Text("\(completed) of \(snapshot.batch.payload.items.count) complete")
                                .reviewAcceptanceProbe("generation-batch.summary." + snapshot.batch.id, text: String(completed))
                                .fontWeight(AppTheme.FontWeight.semibold)
                            if let count = snapshot.journal.pricingOverrideItemIDs?.count {
                                Text("Approved without estimate for \(count) requests")
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                            }
                            if !snapshot.authorityAvailable {
                                Text("Execution authority is not available on this Mac. This batch is history only.")
                                    .reviewAcceptanceProbe("generation-batch.authority-missing." + snapshot.batch.id,
                                        text: "Execution authority is not available on this Mac. This batch is history only.")
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                            }
                            ForEach(snapshot.batch.payload.items) { item in
                                if let execution = snapshot.journal.executions.first(where: { $0.itemID == item.id }) {
                                    Text("\(item.purpose) · \(label(execution.state))")
                                        .reviewAcceptanceProbe("generation-batch.state." + item.id, text: execution.state.rawValue)
                                    if let detail = execution.detail {
                                        DisclosureGroup("Diagnostic details") {
                                            Text(detail).foregroundStyle(AppTheme.Text.secondaryColor).textSelection(.enabled)
                                        }
                                    }
                                    ForEach(execution.outputAssetIDs, id: \.self) { id in
                                        if let asset = editor.mediaAssets.first(where: { $0.id == id }) {
                                            Button("Open \(asset.libraryDisplayName)") { editor.selectMediaAsset(asset) }
                                                .reviewAcceptanceProbe("generation-batch.open." + id)
                                                .buttonStyle(InlineActionButtonStyle())
                                        }
                                    }
                                }
                            }
                            if let pause = coordinator.pausedBatches[snapshot.batch.id] {
                                Text(pause.reason == .hostBusy ? "Waiting for other pipeline work." : "Request not sent. Resolve the issue, then continue or cancel the remaining requests.")
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                                    .reviewAcceptanceProbe("generation-batch.paused." + snapshot.batch.id, text: pause.reason.rawValue)
                                DisclosureGroup("Diagnostic details") {
                                    Text(pause.detail).foregroundStyle(AppTheme.Text.secondaryColor).textSelection(.enabled)
                                }
                            }
                            if let continuation = coordinator.continuation(for: snapshot, editor: editor) {
                                Button(continuation == .queuedRequests ? "Continue approved requests" : "Resume status checks") {
                                    coordinator.continueBatch(batchID: snapshot.batch.id, editor: editor)
                                }
                                    .disabled(!coordinator.canContinue(snapshot, editor: editor))
                                    .reviewAcceptanceProbe((continuation == .queuedRequests ? "generation-batch.continue." : "generation-batch.resume.") + snapshot.batch.id,
                                        state: coordinator.canContinue(snapshot, editor: editor))
                                    .buttonStyle(InlineActionButtonStyle())
                            }
                            if snapshot.authorityAvailable, coordinator.activeBatchID != snapshot.batch.id,
                               snapshot.journal.executions.contains(where: { $0.state == .queued }) {
                                Button("Cancel remaining requests") {
                                    coordinator.cancelRemaining(batchID: snapshot.batch.id, editor: editor)
                                }
                                .disabled(coordinator.approving || coordinator.isRecovering)
                                .reviewAcceptanceProbe("generation-batch.cancel-remaining." + snapshot.batch.id,
                                    state: !coordinator.approving && !coordinator.isRecovering)
                                .buttonStyle(InlineActionButtonStyle())
                            }

                        }
                    }
                }.frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
            } label: {
                if batchID != nil, let snapshot = snapshots.first {
                    let completed = snapshot.journal.executions.filter { $0.state == .complete }.count
                    Text("\(completed) of \(snapshot.batch.payload.items.count) complete")
                } else { Text("Generation batches") }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .reviewAcceptanceProbe("generation-batch.history", text: expanded ? "open" : "closed")
            .onAppear { if batchID != nil { expanded = true } }
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
