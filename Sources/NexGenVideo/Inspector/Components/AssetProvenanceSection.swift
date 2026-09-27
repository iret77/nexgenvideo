import SwiftUI

struct AssetProvenanceSection: View {
    let asset: MediaAsset
    @Environment(EditorViewModel.self) private var editor
    private struct LoadIdentity: Equatable {
        let assetID: String
        let input: GenerationInput?
        let home: URL?
    }
    private struct LoadedReceipt {
        let identity: LoadIdentity
        let package: GenerationPackageV1?
    }
    @State private var loadedReceipt: LoadedReceipt?

    private var loadIdentity: LoadIdentity {
        LoadIdentity(assetID: asset.id, input: asset.generationInput, home: editor.workingRoot)
    }
    private var package: GenerationPackageV1? {
        loadedReceipt?.identity == loadIdentity ? loadedReceipt?.package : nil
    }
    private var packageUnavailable: Bool {
        loadedReceipt?.identity == loadIdentity && loadedReceipt?.package == nil
    }

    private var events: [GenerationSpendEvent] {
        AssetProvenanceEvidence.events(for: asset.generationInput, in: editor.generationLog.spendEvents)
    }

    var body: some View {
        Group {
            if let input = asset.generationInput {
                InspectorSection("Origin") {
                    row("Model", ModelRegistry.displayName(for: input.model))
                    row("Model ID", input.model)
                    if let target = package?.payload.target {
                        row("Provider", target.provider.displayName)
                        row("Route", target.transport.rawValue.uppercased())
                    } else if let recorded = events.last {
                        row("Provider", recorded.provider.displayName)
                        row("Route", recorded.transport.rawValue.uppercased())
                    } else if let routing = input.productionRouting {
                        row("Provider", GenerationProvider(rawValue: routing.providerID)?.displayName ?? "Unknown")
                        row("Route", ProviderTransport(rawValue: routing.transportID)?.rawValue.uppercased() ?? "Unknown")
                    } else {
                        row("Provider", "Unknown — no recorded route")
                        row("Route", "Unknown")
                    }
                    if let created = input.createdAt { row("Created", created.formatted(date: .abbreviated, time: .shortened)) }
                    row("Generation receipt", package != nil ? "Verified" : input.generationPackageID == nil ? "Not recorded" : packageUnavailable ? "Unavailable" : "Loading…")
                    if let revision = package?.payload.promptRevisionID { row("Prompt revision", revision) }
                }
                InspectorSection("Input Revisions") {
                    let references = package?.payload.references ?? input.referenceReceipts ?? []
                    if references.isEmpty {
                        row("References", input.referenceReceipts == nil && package == nil ? "Unknown — no recorded revisions" : "Not applicable — no reference inputs")
                    }
                    ForEach(references.indices, id: \.self) { index in
                        let reference = references[index]
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text(referenceName(reference, index: index))
                                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                            if let roles = package?.payload.referenceRoles, roles.indices.contains(index) {
                                row("Role", roles[index].replacingOccurrences(of: "_", with: " ").capitalized)
                            }
                            row("Source SHA-256", reference.sourceSHA256)
                            if reference.submittedSHA256 != reference.sourceSHA256 {
                                row("Submitted SHA-256", reference.submittedSHA256)
                            }
                            if let current = editor.mediaAssets.first(where: { $0.id == reference.assetID }) {
                                Button("Show Original") { editor.selectMediaAsset(current) }
                                    .buttonStyle(.inlineAction())
                            } else {
                                row("Original", "Unavailable in this library")
                            }
                        }
                    }
                }
                InspectorSection("Job and Cost") {
                    let jobs = Array(Set(events.compactMap(\.providerRequestId))).sorted()
                    row("Provider job", jobs.isEmpty ? "Not recorded" : jobs.joined(separator: "\n"))
                    let charges = events.filter { $0.kind == .charged }.compactMap(\.money)
                    if charges.isEmpty {
                        row("Booked cost", "Unavailable")
                    } else {
                        ForEach(charges.indices, id: \.self) { index in
                            row("Booked cost", money(charges[index]))
                        }
                    }
                    if !charges.isEmpty {
                        row("Cost evidence", "Ledger amount; may use the approved estimate. Provider invoice not verified.")
                    }
                    if let estimate = package?.payload.estimate ?? events.first(where: { $0.kind == .reserved })?.money {
                        row("Estimate", money(estimate))
                    }
                }
            } else {
                InspectorSection("Origin") {
                    row("Source", "Imported media")
                    row("Generation route", "Not applicable")
                }
            }
        }
        .task(id: loadIdentity) {
            let identity = loadIdentity
            guard let input = identity.input, let id = input.generationPackageID else { return }
            guard let home = identity.home else {
                loadedReceipt = LoadedReceipt(identity: identity, package: nil)
                return
            }
            let loaded = await Task.detached(priority: .utility) {
                try? GenerationPackageV1.load(id: id, home: home)
            }.value
            guard !Task.isCancelled else { return }
            let verified = loaded.flatMap { AssetProvenanceEvidence.matches($0, input: input) ? $0 : nil }
            loadedReceipt = LoadedReceipt(identity: identity, package: verified)
        }
    }

    private func referenceName(_ reference: GenerationReferenceReceipt, index: Int) -> String {
        if let name = MediaFilename.normalized(reference.displayName), !MediaFilename.isContentAddressed(name) { return name }
        return editor.mediaAssets.first(where: { $0.id == reference.assetID })?.libraryDisplayName ?? "Reference \(index + 1)"
    }

    private func money(_ value: GenerationMoney) -> String {
        guard value.nativeAmount.isFinite, value.nativeAmount >= 0 else { return "Unavailable" }
        return String(format: "%.2f", value.nativeAmount) + " " + value.nativeCurrency
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(label)
                .interfaceFont(size: AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(value)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
