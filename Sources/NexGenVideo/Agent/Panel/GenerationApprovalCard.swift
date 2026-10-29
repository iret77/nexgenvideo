import SwiftUI

private struct GenerationDecisionHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var generationDecisionMaximumHeight: CGFloat? {
        get { self[GenerationDecisionHeightKey.self] }
        set { self[GenerationDecisionHeightKey.self] = newValue }
    }
}

struct GenerationApprovalCard<Content: View, Footer: View>: View {
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.generationDecisionMaximumHeight) private var availableHeight
    @Environment(\.productionDecisionCompact) private var compact
    @State private var showsReview = false
    let title: String
    var subtitle: String? = nil
    var fillsMaximumHeight = false
    var identifier = "generation-approval"
    var runtimeEvidenceEnabled = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        GenerationBatchDecisionLayout(
            maximumHeight: max(AppTheme.Spacing.none,
                (availableHeight ?? AppTheme.ComponentSize.agentDecisionMaxHeight * interfaceScale)
                    - cardPadding - cardPadding),
            minimumBodyHeight: AppTheme.ComponentSize.generationBatchListMinHeight * interfaceScale,
            spacing: AppTheme.Spacing.smMd,
            fillsMaximumHeight: fillsMaximumHeight,
            hasExplicitHeightLimit: availableHeight != nil
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                if compact {
                    Button("Review inputs…", systemImage: "arrow.up.left.and.arrow.down.right") { showsReview = true }
                        .buttonStyle(.inlineAction(.neutral))
                        .accessibilityLabel("Review inputs for \(title)")
                        .accessibilityIdentifier("\(identifier).review.open")
                        .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).review.open", enabled: evidenceEnabled))
                } else {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Label(title, systemImage: "sparkles")
                            .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle {
                            Text(subtitle)
                                .interfaceFont(size: AppTheme.FontSize.xxs)
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if !showsReview { content() }
                else {
                    Text("Input review is open.")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
                if !showsReview { footer() }
            }
        }
        .padding(cardPadding)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .strokeBorder(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium),
                            lineWidth: AppTheme.BorderWidth.thin)
                }
        }
        .padding(.horizontal, compact ? AppTheme.Spacing.none : AppTheme.Spacing.mdLg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .sheet(isPresented: $showsReview) {
            ProductionDecisionReview(title: title, identifier: identifier, runtimeEvidenceEnabled: evidenceEnabled) {
                content()
            } footer: {
                footer()
            }
        }
    }

    private var cardPadding: CGFloat { compact ? AppTheme.Spacing.none : AppTheme.Spacing.md }

    private var evidenceEnabled: Bool {
        runtimeEvidenceEnabled || WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested
            || GenerationBatchReviewSelfTest.isRequested
    }
}

struct GenerationApprovalActions: View {
    @Environment(\.productionDecisionCompact) private var compact
    @Environment(\.productionDecisionReviewActive) private var reviewActive
    let actionLabel: String
    let phase: String?
    let canApprove: Bool
    let canEdit: Bool
    let onApprove: () -> Void
    let onDecline: () -> Void
    var onApprovePhase: (() -> Void)? = nil
    var onRevise: (() -> Void)? = nil
    var onRetryPricing: (() -> Void)? = nil
    var canRetryPricing = false
    var identifier = "generation-approval"
    var runtimeEvidenceEnabled = false
    var revisionRequired = false

    var body: some View {
        if compact {
            compactActions
        } else {
            expandedActions
        }
    }

    private var compactActions: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
            Button("Decline", action: onDecline)
                .buttonStyle(.capsule(.secondary, size: .regular))
                .keyboardShortcut(reviewActive ? nil : .cancelAction)
                .accessibilityIdentifier("\(identifier).decline")
                .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).decline", enabled: runtimeEvidenceEnabled))
                .disabled(!canEdit)
                .fixedSize()
            if hasSecondaryActions {
                Menu {
                    if let onRevise {
                        Button("Ask agent to revise", action: onRevise)
                            .accessibilityIdentifier("\(identifier).revise")
                            .disabled(!canEdit)
                    }
                    if let onRetryPricing {
                        Button("Retry pricing", action: onRetryPricing)
                            .accessibilityIdentifier("\(identifier).retry-pricing")
                            .disabled(!canRetryPricing)
                    }
                    if let onApprovePhase, let phase {
                        Section("Until phase approval, rewind, withdrawal or app quit") {
                            Button("Allow all paid AI runs in \(PhaseDisplay.label(phase))", action: onApprovePhase)
                                .accessibilityIdentifier("\(identifier).approve-phase")
                                .disabled(!canApprove)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More generation actions")
                .accessibilityIdentifier("\(identifier).actions")
                .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).actions", enabled: runtimeEvidenceEnabled))
                .help("Revision, pricing and phase approval")
            }
            Button(action: onApprove) {
                Text(actionLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .accessibilityIdentifier("\(identifier).approve")
            .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).approve", enabled: runtimeEvidenceEnabled))
            .disabled(!canApprove)
        }
    }

    private var hasSecondaryActions: Bool {
        onRevise != nil || onRetryPricing != nil || (onApprovePhase != nil && phase != nil)
    }

    private var expandedActions: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let phase, onApprovePhase != nil {
                Text("Allow all paid AI runs in \(PhaseDisplay.label(phase)) until phase approval, rewind, withdrawal or app quit.")
                    .interfaceFont(size: AppTheme.FontSize.xxs)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WrapLayout(spacing: AppTheme.Spacing.sm, trailingLastItem: true) {
                Button("Decline", action: onDecline)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(reviewActive ? nil : .cancelAction)
                    .accessibilityIdentifier("\(identifier).decline")
                    .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).decline", enabled: runtimeEvidenceEnabled))
                    .disabled(!canEdit)
                if let onRevise {
                    Button("Ask agent to revise", action: onRevise)
                        .buttonStyle(.capsule(revisionRequired ? .prominent : .secondary, size: .regular))
                        .accessibilityIdentifier("\(identifier).revise")
                        .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).revise", enabled: runtimeEvidenceEnabled))
                        .disabled(!canEdit)
                }
                if let onRetryPricing {
                    Button("Retry pricing", action: onRetryPricing)
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .accessibilityIdentifier("\(identifier).retry-pricing")
                        .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).retry-pricing", enabled: runtimeEvidenceEnabled))
                        .disabled(!canRetryPricing)
                }
                if let onApprovePhase, phase != nil {
                    Button("Allow phase", action: onApprovePhase)
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .accessibilityIdentifier("\(identifier).approve-phase")
                        .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).approve-phase", enabled: runtimeEvidenceEnabled))
                        .disabled(!canApprove)
                }
                Button(actionLabel, action: onApprove)
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .accessibilityIdentifier("\(identifier).approve")
                    .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).approve", enabled: runtimeEvidenceEnabled))
                    .disabled(!canApprove)
            }
        }
    }
}

enum GenerationApprovalPresentation {
    static func actionLabel(packages: [GenerationPackageV1]) -> String {
        let count = packages.reduce(0) { $0 + $1.payload.outputCount }
        switch Set(packages.map { $0.payload.modality }) {
        case ["image"]: return count == 1 ? String(localized: "Generate 1 image") : String(localized: "Generate \(count) images")
        case ["video"]: return count == 1 ? String(localized: "Generate 1 video") : String(localized: "Generate \(count) videos")
        case ["audio"]: return String(localized: "Generate \(count) audio files")
        default: return String(localized: "Generate \(count) outputs")
        }
    }
}
