import SwiftUI

/// Commits a deferred gate only after the user approves it here.
struct GateApprovalCard: View {
    let approval: GateApproval
    let error: String?
    let isWorking: Bool
    var isBlocked: Bool = false
    let onApprove: () -> Void
    let onDecline: () -> Void
    @FocusState private var approveFocused: Bool
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.productionDecisionCompact) private var compact
    @Environment(\.generationDecisionMaximumHeight) private var availableHeight
    @State private var review = GateReviewModel()
    @State private var showsDiagnostics = false
    @State private var showsChanges = false
    @State private var showsReviewDetails = false

    private var reviewDestination: String {
        PipelineSurfaceRouting.reviewDestinationLabel(for: approval.phase, contract: editor.uiContract,
            availablePackSurfaces: editor.availableCockpitPackSurfaces)
    }

    private var reviewHint: String {
        approval.isRewind ? "Inspect the approved work before allowing a revision." : "Review in \(reviewDestination) before approving."
    }

    var body: some View {
        Group {
            if compact { compactCard }
            else { expandedCard }
        }
        .id(approval.id)
        .task(id: "\(approval.id):\(editor.engineStateRevision):\(isBlocked)") {
            await review.refresh(approval: approval, editor: editor)
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                approveFocused = !isBlocked
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(approval.decisionTitle)
        .sheet(isPresented: $showsReviewDetails) {
            ProductionDecisionReview(title: approval.decisionTitle, identifier: "agent.gate", runtimeEvidenceEnabled: evidenceEnabled) {
                ScrollView {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                EmptyView()
            }
        }
    }

    private var compactCard: some View {
        GenerationBatchDecisionLayout(
            maximumHeight: availableHeight ?? AppTheme.ComponentSize.agentDecisionMaxHeight,
            minimumBodyHeight: AppTheme.ComponentSize.productionDecisionSummaryMinHeight,
            spacing: AppTheme.Spacing.sm,
            fillsMaximumHeight: false,
            hasExplicitHeightLimit: availableHeight != nil
        ) {
            HStack(spacing: AppTheme.Spacing.md) {
                openButton
                    .buttonStyle(.inlineAction(.neutral))
                Spacer(minLength: AppTheme.Spacing.none)
                Button("Details") { showsReviewDetails = true }
                    .buttonStyle(.inlineAction(.neutral))
                    .accessibilityIdentifier("agent.gate.review.open")
                    .background { acceptanceProbe("review.open", enabled: true) }
            }
            ScrollView {
                compactSummary.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            footerRow
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            if let comparison = priorComparisonText { Text(comparison).foregroundStyle(AppTheme.Text.primaryColor) }
            if case .rewind(_, let phases) = approval.action {
                Text("Resets approvals from \(approval.phaseLabel): \(phases.map(PhaseDisplay.label).joined(separator: ", ")). Existing media is kept.")
                    .foregroundStyle(AppTheme.Text.primaryColor)
            } else {
                Text("Continue production. Generation costs require separate approval.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if isBlocked {
                Text("Finish the running phase before approving.").foregroundStyle(AppTheme.Status.warningColor)
            } else if let blocker = review.blocker {
                Text(blocker).foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if let error { Text(error).foregroundStyle(AppTheme.Status.errorColor) }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            ScrollView {
                summary
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            openButton
                .buttonStyle(.capsule(.secondary, size: .regular))
            if let blocker = review.blocker, !isBlocked {
                Text(blocker)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                .strokeBorder(editor.projectPalette.accent.opacity(AppTheme.Opacity.medium),
                              lineWidth: AppTheme.BorderWidth.thin)
        )
        .padding(.horizontal, AppTheme.Spacing.mdLg)
    }

    private var openButton: some View {
        Button("Open \(reviewDestination)") { editor.revealReviewSurface(for: approval.phase) }
            .disabled(isWorking || isBlocked)
            .background { acceptanceProbe("open", enabled: !(isWorking || isBlocked), text: reviewDestination) }
    }

    private var evidenceEnabled: Bool {
        WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested || GenerationBatchReviewSelfTest.isRequested
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "checkmark.seal")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(editor.projectPalette.accent)
            Text(approval.decisionTitle)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: onDecline) {
                Image(systemName: "xmark")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
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
            if case .rewind(_, let phases) = approval.action {
                Text("The agent proposes revising previously approved work. Continuing will reset these approvals: " + phases.map(PhaseDisplay.label).joined(separator: ", ") + ". Existing artifacts are kept. This does not approve new content or spending.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = approval.notes { Text(reason).fixedSize(horizontal: false, vertical: true) }
            } else {
                Text("Approve the current \(approval.phaseLabel) as the basis for the next production step. This does not authorize generation costs.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .fixedSize(horizontal: false, vertical: true)
                if let comparison = priorComparisonText {
                    Text(comparison)
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let changes = approval.priorChanges, !changes.lines.isEmpty {
                    DisclosureGroup(isExpanded: $showsChanges) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                            ForEach(Array(changes.lines.enumerated()), id: \.offset) { _, line in
                                Text("\(line.kind == .removed ? "−" : "+") \(line.number)  \(line.text)")
                                    .interfaceFont(size: AppTheme.Typography.metadata, design: .monospaced)
                                    .foregroundStyle(line.kind == .removed
                                        ? AppTheme.Status.errorColor : AppTheme.Status.successColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            if changes.isTruncated {
                                Text("Showing \(changes.lines.count) of \(changes.totalChangedLines) changed lines.")
                                    .interfaceFont(size: AppTheme.Typography.metadata)
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                            }
                        }
                    } label: {
                        Text("Show changes since your approval (\(changes.totalChangedLines) lines)")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
            }
            Text(approval.isRewind ? (review.isReady ? "Confirm only if you want to revise this approved work." : "Checking whether a revision can start…")
                 : isBlocked ? "\(approval.phaseLabel) is still being processed. Approval is not available yet."
                 : review.isReady ? "Review \(approval.phaseLabel), then approve here to continue."
                 : "Checking whether \(approval.phaseLabel) can be approved…")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = approval.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                DisclosureGroup(isExpanded: $showsDiagnostics) {
                    Text(notes)
                        .interfaceFont(size: AppTheme.Typography.metadata, design: .monospaced)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } label: {
                    Text(approval.isRewind ? "Revision reason" : "Approval notes")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            Text(reviewHint)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppTheme.Spacing.xxs)
            }
            if isBlocked {
                Text("Finish the running phase before approving.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.warningColor)
            }
        }
    }

    private var priorComparisonText: String? {
        switch approval.priorComparison {
        case nil: nil
        case .identical:
            "Unchanged since your earlier approval. The host compared the exact bytes."
        case .changed(let reason?) where !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            "Changed since your earlier approval. Revision reason: \(reason)"
        case .changed:
            "Changed since your earlier approval. Review the new version before approving."
        }
    }

    private var footerRow: some View {
        approvalActions
    }

    private var approvalActions: some View {
        WrapLayout(spacing: AppTheme.Spacing.sm, trailingLastItem: true) {
            Button("Not yet") { onDecline() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking || isBlocked)
                .background { acceptanceProbe("decline", enabled: !(isWorking || isBlocked)) }
            Button {
                Task {
                    await review.refresh(approval: approval, editor: editor)
                    if review.isReady { onApprove() }
                }
            } label: {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(approval.decisionTitle)
                }
            }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(isWorking || isBlocked || !review.isReady)
                .background {
                    acceptanceProbe("approve", enabled: !(isWorking || isBlocked || !review.isReady),
                        text: review.isReady ? nil : review.blocker)
                }
                .focused($approveFocused)
                .accessibilityHint(
                    isBlocked ? "Finish the running phase before approving" : ""
                )
        }
    }

    @ViewBuilder
    private func acceptanceProbe(_ part: String, enabled: Bool, text: String? = nil) -> some View {
        if evidenceEnabled {
            AppRelaunchClickProbe(identifier: "agent.gate.\(part)", acceptanceState: enabled, acceptanceText: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
}

extension EditorViewModel {
    func revealReviewSurface(for phase: String) {
        selectProductionPhase(phase)
        setWorkspaceFocus(.production)
    }

    func selectProductionPhase(_ phase: String) {
        if productionSelectedPhase != phase { inspectedObject = nil }
        let route = PipelineSurfaceRouting.route(for: phase, contract: uiContract,
            availablePackSurfaces: availableCockpitPackSurfaces)
        switch route?.destination {
        case .tab(let tab):
            cockpitTab = tab
            cockpitPackSurfaceID = nil
        case .pack(let id, _):
            cockpitTab = .pipeline
            cockpitPackSurfaceID = id
        case nil:
            cockpitTab = .pipeline
            cockpitPackSurfaceID = nil
        }
        productionSelectedPhase = phase
    }
}
