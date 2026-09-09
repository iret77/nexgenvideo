import AppKit
import SwiftUI

struct GenerationPackageReviewView: View {
    let package: GenerationPackageV1

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(package.renderID).fontWeight(AppTheme.FontWeight.semibold).textSelection(.enabled)
            Text("Outputs: \(package.payload.outputCount) · \(destinationLabel)")
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if let estimate = package.payload.estimate {
                Text("Estimated cost: €\(estimate.eurAmount, specifier: "%.2f")")
            } else {
                Text("Monetary estimate unavailable").foregroundStyle(AppTheme.Status.warningColor)
            }
            ForEach(Array(package.payload.references.enumerated()), id: \.offset) { index, reference in
                Text("\(index + 1). \(roleLabel(package.payload.referenceRoles[index])) · \(reference.displayName ?? String(localized: "Reference"))")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            DisclosureGroup("Request details") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(package.payload.prompt).textSelection(.enabled)
                    Button("Copy provider prompt") { copy(package.payload.prompt) }
                        .buttonStyle(InlineActionButtonStyle())
                    Text(package.payload.requestParametersJSON).textSelection(.enabled)
                    if package.payload.routeReceipt.checks.isEmpty {
                        Text("Route capabilities come from recorded reference data. No live check is recorded for this offering.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    } else {
                        ForEach(Array(package.payload.routeReceipt.checks.enumerated()), id: \.offset) { _, check in
                            Text("\(checkLabel(check.scope)): \(check.observedAt) · \(check.source)")
                                .foregroundStyle(AppTheme.Text.secondaryColor).textSelection(.enabled)
                        }
                        Text("Catalog presence and schema checks do not establish output quality.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    Text("Package: \(package.id)").textSelection(.enabled)
                    Button("Copy package details") {
                        if let data = try? GenerationPackageV1.canonicalData(package), let text = String(data: data, encoding: .utf8) { copy(text) }
                    }.buttonStyle(InlineActionButtonStyle())
                }
            }
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

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
