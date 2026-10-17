import SwiftUI

struct GenerationApprovalCard<Content: View, Footer: View>: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let title: String
    var subtitle: String? = nil
    var fillsMaximumHeight = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        GenerationBatchDecisionLayout(
            maximumHeight: AppTheme.ComponentSize.agentDecisionMaxHeight * interfaceScale
                - AppTheme.Spacing.md - AppTheme.Spacing.md,
            minimumBodyHeight: AppTheme.ComponentSize.generationBatchListMinHeight * interfaceScale,
            spacing: AppTheme.Spacing.smMd,
            fillsMaximumHeight: fillsMaximumHeight
        ) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            content()
            footer()
        }
        .padding(AppTheme.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .strokeBorder(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium),
                            lineWidth: AppTheme.BorderWidth.thin)
                }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct GenerationApprovalActions: View {
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
                    .keyboardShortcut(.cancelAction)
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
