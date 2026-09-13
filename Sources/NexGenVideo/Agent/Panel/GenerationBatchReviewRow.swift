import SwiftUI

struct GenerationBatchReviewRow: View {
    let row: GenerationBatchReviewSelection.Row
    let projectHome: URL?
    let showsRoute: Bool
    let pricingFailure: GenerationPricingFailure?
    let isBusy: Bool
    @Binding var isSelected: Bool
    let onRemovalKey: (KeyPress) -> KeyPress.Result
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Toggle(isOn: $isSelected) { Text("\(row.number).") }
                    .toggleStyle(.checkbox).fixedSize()
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .accessibilityLabel("Select generation \(row.number): \(row.item.purpose)")
                    .disabled(isBusy)
                    .onKeyPress(phases: .down, action: onRemovalKey)
                Text(row.item.purpose).lineLimit(1).help(row.item.purpose)
                    .frame(maxWidth: .infinity, alignment: .leading)
                price
                Button(expanded ? "Hide" : "Details") { expanded.toggle() }
                    .buttonStyle(InlineActionButtonStyle())
                    .accessibilityLabel("\(expanded ? "Hide" : "Show") details for generation \(row.number)")
            }
            Text(GenerationPackagePresentation.output(row.item.package))
                .font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Text.secondaryColor)
            if showsRoute {
                Text(GenerationPackagePresentation.route(row.item.package))
                    .font(.system(size: AppTheme.FontSize.xxs)).foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1).help(GenerationPackagePresentation.route(row.item.package))
            }
            GenerationReferencePreviewStrip(package: row.item.package, projectHome: projectHome)
            if expanded {
                Text(row.item.purpose).textSelection(.enabled)
                if let pricingFailure {
                    Text(GenerationPackagePresentation.pricingMessage(pricingFailure))
                        .foregroundStyle(AppTheme.Status.warningColor)
                }
                GenerationPackageRequestDetails(package: row.item.package, projectHome: projectHome)
            }
        }
        .padding(.vertical, AppTheme.Spacing.sm)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var price: some View {
        if let estimate = row.item.package.payload.estimate {
            Text("€\(estimate.eurAmount, specifier: "%.2f")").monospacedDigit().fixedSize()
        } else {
            Text("Unpriced").foregroundStyle(AppTheme.Status.warningColor).fixedSize()
        }
    }
}
