import AppKit
import SwiftUI

struct GenerationPackageReviewView: View {
    let package: GenerationPackageV1

    var showsDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("\(ModelRegistry.displayName(for: package.payload.target.modelId)) · \(package.payload.target.provider.displayName)")
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("\(outputLabel) · \(destinationLabel)")
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let estimate = package.payload.estimate {
                Text("Estimated cost: €\(estimate.eurAmount, specifier: "%.2f")")
            } else {
                Text("Cost unknown").foregroundStyle(AppTheme.Status.warningColor)
            }
            if showsDetails {
                DisclosureGroup("Request details") { details }
            }
        }
    }

    var details: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ForEach(Array(package.payload.references.enumerated()), id: \.offset) { index, reference in
                Text("\(roleLabel(package.payload.referenceRoles[index])) · \(reference.displayName ?? String(localized: "Reference"))")
            }
            if let failure = package.payload.pricingFailure {
                Text(pricingFailureLabel(failure.reason)).foregroundStyle(AppTheme.Status.warningColor)
                Text(failure.detail).textSelection(.enabled)
            }
            Text(package.payload.prompt).textSelection(.enabled)
            Button("Copy provider prompt") { copy(package.payload.prompt) }
                .buttonStyle(InlineActionButtonStyle())
            Text(package.renderID).textSelection(.enabled)
            Text(package.payload.requestParametersJSON).textSelection(.enabled)
            if package.payload.routeReceipt.checks.isEmpty {
                Text("Route capabilities come from reference data. No live check is recorded.")
            }
            ForEach(Array(package.payload.routeReceipt.checks.enumerated()), id: \.offset) { _, check in
                Text("\(checkLabel(check.scope)): \(check.observedAt) · \(check.source)")
                    .textSelection(.enabled)
            }
            Text("Package: \(package.id)").textSelection(.enabled)
            Button("Copy package details") {
                if let data = try? GenerationPackageV1.canonicalData(package), let text = String(data: data, encoding: .utf8) { copy(text) }
            }.buttonStyle(InlineActionButtonStyle())
        }
        .foregroundStyle(AppTheme.Text.secondaryColor)
    }

    private var outputLabel: String {
        switch package.payload.modality {
        case "image": package.payload.outputCount == 1 ? String(localized: "1 image") : String(localized: "\(package.payload.outputCount) images")
        case "video": package.payload.outputCount == 1 ? String(localized: "1 video") : String(localized: "\(package.payload.outputCount) videos")
        case "audio": String(localized: "\(package.payload.outputCount) audio files")
        default: String(localized: "\(package.payload.outputCount) outputs")
        }
    }

    private var destinationLabel: String {
        switch package.payload.destination.kind {
        case "media_library": String(localized: "Media library")
        case "timeline": String(localized: "Timeline")
        case "replace_clip": String(localized: "Replace selected clip")
        default: String(localized: "Project")
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "source_video": String(localized: "Source video")
        case "start_frame": String(localized: "Start frame")
        case "end_frame": String(localized: "End frame")
        case "image_reference": String(localized: "Image reference")
        case "video_reference": String(localized: "Video reference")
        case "audio_reference": String(localized: "Audio reference")
        default: String(localized: "Reference")
        }
    }

    private func checkLabel(_ scope: GenerationRouteReceipt.Scope) -> String {
        switch scope {
        case .modelCatalog: String(localized: "Model catalog checked")
        case .accountEntitlement: String(localized: "Account entitlement checked")
        case .toolSchema: String(localized: "Tool schema checked")
        }
    }

    private func pricingFailureLabel(_ reason: GenerationPricingFailure.Reason) -> String {
        switch reason {
        case .unsupportedCombination: String(localized: "No verified price for these options")
        case .priceQueryUnavailable: String(localized: "Provider pricing unavailable")
        case .exchangeRateUnavailable: String(localized: "EUR conversion unavailable")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
