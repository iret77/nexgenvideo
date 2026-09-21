import AppKit
import SwiftUI

struct GenerationPackageReviewView: View {
    @Environment(EditorViewModel.self) private var editor

    let package: GenerationPackageV1

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(routeLabel)
                .interfaceFont(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(outputLabel) · \(destinationLabel)")
                .interfaceFont(size: AppTheme.FontSize.xxs)
                .foregroundStyle(AppTheme.Text.secondaryColor)
            pricing
            if !package.payload.references.isEmpty {
                Text("References")
                    .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                GenerationReferenceThumbnails(package: package, style: .labeled)
            }
            DisclosureGroup("Request details") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("Provider prompt")
                        .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text(package.payload.prompt)
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .textSelection(.enabled)
                    Button("Copy provider prompt") { copy(package.payload.prompt) }
                        .buttonStyle(InlineActionButtonStyle())
                    Text("Exact request parameters")
                        .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text(package.payload.requestParametersJSON)
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .textSelection(.enabled)
                    Text(exactRouteLabel)
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                    Text("Compiler inputs: \(package.payload.compilerInputsSHA256)")
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                    ForEach(Array(package.payload.references.enumerated()), id: \.offset) { index, receipt in
                        Text(
                            "Reference \(index + 1): source \(receipt.sourceSHA256) · submitted \(receipt.submittedSHA256)"
                        )
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                    }
                    routeEvidence
                    Text("Render: \(package.renderID)")
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                    Text("Package: \(package.id)")
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                    Button("Copy package details") {
                        if let data = try? GenerationPackageV1.canonicalData(package),
                           let text = String(data: data, encoding: .utf8) {
                            copy(text)
                        }
                    }
                    .buttonStyle(InlineActionButtonStyle())
                }
                .padding(.top, AppTheme.Spacing.xs)
            }
        }
    }

    private var routeLabel: String {
        "\(ModelRegistry.displayName(for: package.payload.target.modelId)) · \(package.payload.target.provider.displayName)"
    }

    private var outputLabel: String {
        package.payload.outputCount == 1
            ? String(localized: "1 output")
            : String(localized: "\(package.payload.outputCount) outputs")
    }

    private var exactRouteLabel: String {
        let target = package.payload.target
        var values = [
            "Provider: \(target.provider.displayName)",
            "Transport: \(target.transport.rawValue)",
            "Endpoint: \(target.endpoint)",
        ]
        if let parameter = target.binding?.modelParam { values.append("Model parameter: \(parameter)") }
        return values.joined(separator: " · ")
    }

    @ViewBuilder
    private var pricing: some View {
        if let estimate = package.payload.estimate {
            Text("Estimated cost: \(Self.euro(estimate.eurAmount))")
                .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.primaryColor)
        } else if let failure = package.payload.pricingFailure {
            Text(pricingFailureLabel(failure.reason))
                .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Status.warningColor)
            Text(failure.detail)
                .interfaceFont(size: AppTheme.FontSize.xxs)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        } else {
            Text("Pricing record unavailable. Prepare this request again.")
                .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Status.warningColor)
        }
    }

    @ViewBuilder
    private var routeEvidence: some View {
        if package.payload.routeReceipt.checks.isEmpty {
            Text("Route capabilities come from recorded reference data. No live check is recorded for this offering.")
                .interfaceFont(size: AppTheme.FontSize.xxs)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        } else {
            ForEach(Array(package.payload.routeReceipt.checks.enumerated()), id: \.offset) { _, check in
                Text("\(checkLabel(check.scope)): \(check.observedAt) · \(check.source)")
                    .interfaceFont(size: AppTheme.FontSize.xxs)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .textSelection(.enabled)
            }
            Text("Catalog presence and schema checks do not establish output quality.")
                .interfaceFont(size: AppTheme.FontSize.xxs)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private var destinationLabel: String {
        GenerationDestinationPresentation.label(package.payload.destination, editor: editor)
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

    static func euro(_ amount: Double) -> String {
        "€" + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
    }
}

struct GenerationReferenceThumbnails: View {
    enum Style: Equatable {
        case compact
        case labeled
    }

    let package: GenerationPackageV1
    let style: Style
    var limit: Int? = nil

    var body: some View {
        WrapLayout(spacing: AppTheme.Spacing.xs) {
            ForEach(Array(package.payload.references.indices.prefix(limit ?? Int.max)), id: \.self) { index in
                GenerationReferenceThumbnail(
                    receipt: package.payload.references[index],
                    role: roleLabel(package.payload.referenceRoles[index]),
                    style: style
                )
            }
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
}

private struct GenerationReferenceThumbnail: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.interfaceScale) private var interfaceScale

    let receipt: GenerationReferenceReceipt
    let role: String
    let style: GenerationReferenceThumbnails.Style

    @State private var loadedImage: NSImage?

    private var asset: MediaAsset? {
        editor.mediaAssets.first { $0.id == receipt.assetID && $0.type.rawValue == receipt.type }
    }

    private var name: String {
        if let receiptName = MediaFilename.normalized(receipt.displayName),
           !MediaFilename.isContentAddressed(receiptName) {
            return receiptName
        }
        return asset?.userFacingFilename ?? String(localized: "Reference")
    }

    var body: some View {
        Button {
            if let asset { editor.selectMediaAsset(asset) }
        } label: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ZStack {
                    Rectangle().fill(AppTheme.Background.overlayColor)
                    if let image = asset?.thumbnail ?? loadedImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: placeholderSymbol)
                            .interfaceFont(size: AppTheme.FontSize.md)
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                }
                .frame(
                    width: AppTheme.ComponentSize.generationReferenceWidth * interfaceScale,
                    height: AppTheme.ComponentSize.generationReferenceHeight * interfaceScale
                )
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .strokeBorder(
                            AppTheme.Border.primaryColor,
                            lineWidth: AppTheme.BorderWidth.hairline
                        )
                )
                if style == .labeled {
                    Text(role)
                        .interfaceFont(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                    Text(name)
                        .interfaceFont(size: AppTheme.FontSize.xxs)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                }
            }
            .frame(
                width: AppTheme.ComponentSize.generationReferenceWidth * interfaceScale,
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
        .disabled(asset == nil)
        .help(asset == nil ? "\(role): \(name) is unavailable" : "Open \(role.lowercased()): \(name)")
        .accessibilityLabel("Open \(role), \(name)")
        .task(id: asset?.url) { await loadImageIfNeeded() }
    }

    private var placeholderSymbol: String {
        switch receipt.type {
        case ClipType.video.rawValue: "film"
        case ClipType.audio.rawValue: "waveform"
        default: "photo"
        }
    }

    private func loadImageIfNeeded() async {
        guard asset?.thumbnail == nil, let asset, asset.type == .image else {
            loadedImage = nil
            return
        }
        let url = asset.url
        let bytes = await Task.detached(priority: .utility) { () -> Data? in
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard !Task.isCancelled, self.asset?.url == url else { return }
        loadedImage = bytes.flatMap { NSImage(data: $0) }
    }
}
