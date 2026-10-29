import SwiftUI

private struct ProductionDecisionCompactKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ProductionDecisionReviewActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var productionDecisionCompact: Bool {
        get { self[ProductionDecisionCompactKey.self] }
        set { self[ProductionDecisionCompactKey.self] = newValue }
    }

    var productionDecisionReviewActive: Bool {
        get { self[ProductionDecisionReviewActiveKey.self] }
        set { self[ProductionDecisionReviewActiveKey.self] = newValue }
    }
}

struct ProductionDecisionReview<Content: View, Footer: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let identifier: String
    var runtimeEvidenceEnabled = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
                Text(title)
                    .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.none)
                Button("Done") { dismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("\(identifier).review.close")
                    .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).review.close", enabled: runtimeEvidenceEnabled))
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            AppDivider()
            footer()
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .background(AppTheme.Background.surfaceColor)
        .environment(\.productionDecisionCompact, false)
        .environment(\.productionDecisionReviewActive, true)
        .environment(\.generationDecisionMaximumHeight, nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .modifier(GenerationBatchRuntimeProbe(identifier: "\(identifier).review", enabled: runtimeEvidenceEnabled))
    }
}
