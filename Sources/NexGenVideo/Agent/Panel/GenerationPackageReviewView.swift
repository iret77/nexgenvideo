import AppKit
import SwiftUI

struct GenerationPackageReviewView: View {
    let package: GenerationPackageV1
    var projectHome: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(GenerationPackagePresentation.route(package)).fontWeight(AppTheme.FontWeight.semibold)
            Text(GenerationPackagePresentation.output(package))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let estimate = package.payload.estimate {
                Text("Estimated cost: €\(estimate.eurAmount, specifier: "%.2f")")
            } else {
                Text("Price unavailable").foregroundStyle(AppTheme.Status.warningColor)
            }
            GenerationReferencePreviewStrip(package: package, projectHome: projectHome)
            DisclosureGroup("Request details") {
                GenerationPackageRequestDetails(package: package, projectHome: projectHome)
            }
        }
    }
}

struct GenerationPackageRequestDetails: View {
    let package: GenerationPackageV1
    let projectHome: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ForEach(Array(package.payload.references.enumerated()), id: \.offset) { index, reference in
                HStack(spacing: AppTheme.Spacing.sm) {
                    if reference.type == "image" {
                        GenerationReferenceThumbnail(package: package, referenceIndex: index, projectHome: projectHome)
                    }
                    Text("\(index + 1). \(GenerationPackagePresentation.role(package.payload.referenceRoles[index])) · \(reference.displayName ?? String(localized: "Reference"))")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            Text(package.payload.prompt).textSelection(.enabled)
            Button("Copy provider prompt") { copy(package.payload.prompt) }
                .buttonStyle(InlineActionButtonStyle())
            Text(package.payload.requestParametersJSON).textSelection(.enabled)
            if package.payload.routeReceipt.checks.isEmpty {
                Text("No live route check recorded.").foregroundStyle(AppTheme.Text.secondaryColor)
            } else {
                ForEach(Array(package.payload.routeReceipt.checks.enumerated()), id: \.offset) { _, check in
                    Text("\(checkLabel(check.scope)): \(check.observedAt) · \(check.source)")
                        .foregroundStyle(AppTheme.Text.secondaryColor).textSelection(.enabled)
                }
            }
            Text("Package: \(package.id)").textSelection(.enabled)
            Button("Copy package details") {
                if let data = try? GenerationPackageV1.canonicalData(package) { copy(String(decoding: data, as: UTF8.self)) }
            }.buttonStyle(InlineActionButtonStyle())
        }
        .font(.system(size: AppTheme.FontSize.xxs))
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    private func checkLabel(_ scope: GenerationRouteReceipt.Scope) -> String {
        switch scope {
        case .modelCatalog: String(localized: "Model catalog checked")
        case .accountEntitlement: String(localized: "Account entitlement checked")
        case .toolSchema: String(localized: "Tool schema checked")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum GenerationPackagePresentation {
    @MainActor static func route(_ package: GenerationPackageV1) -> String {
        "\(package.payload.target.provider.displayName) · \(ModelRegistry.displayName(for: package.payload.target.modelId))"
    }

    static func output(_ package: GenerationPackageV1) -> String {
        let count = package.payload.outputCount
        let kind: String = switch package.payload.modality {
        case "image": count == 1 ? String(localized: "image") : String(localized: "images")
        case "video": count == 1 ? String(localized: "video") : String(localized: "videos")
        case "audio": count == 1 ? String(localized: "audio file") : String(localized: "audio files")
        default: count == 1 ? String(localized: "output") : String(localized: "outputs")
        }
        return "\(count) \(kind) · \(destination(package))"
    }

    private static func destination(_ package: GenerationPackageV1) -> String {
        switch package.payload.destination.kind {
        case "media_library": String(localized: "Media library")
        case "timeline": String(localized: "Timeline")
        case "replace_clip": String(localized: "Replace selected clip")
        default: String(localized: "Project")
        }
    }

    static func role(_ role: String) -> String {
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

    static func pricingMessage(_ failure: GenerationPricingFailure) -> String {
        switch failure {
        case .unsupportedOption: String(localized: "Pricing is unavailable for these options. Change route to prepare another model.")
        case .providerPricingUnavailable: String(localized: "Provider pricing is unavailable. Retry pricing or change route.")
        case .exchangeRateUnavailable: String(localized: "EUR pricing is unavailable. Retry pricing.")
        }
    }
}
