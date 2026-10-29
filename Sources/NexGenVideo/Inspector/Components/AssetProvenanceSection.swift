import NexGenEngine
import SwiftUI

struct AssetProvenanceSection: View {
    let asset: MediaAsset
    @Environment(EditorViewModel.self) private var editor
    private struct LoadIdentity: Equatable, Sendable {
        let assetID: String
        let input: GenerationInput?
        let home: URL?
        let url: URL
        let production: ProductionObjectNavigation.Context?
    }
    private struct LoadedReceipt: Sendable {
        let identity: LoadIdentity
        let input: GenerationInput?
        let package: GenerationPackageV1?
        let failure: String?
    }
    @State private var loadedReceipt: LoadedReceipt?
    @State private var originalFailure: String?
    @State private var checkingOriginal = false

    private var loadIdentity: LoadIdentity {
        LoadIdentity(assetID: asset.id, input: asset.generationInput, home: editor.workingRoot,
            url: asset.url, production: ProductionObjectNavigation.Context(editor))
    }
    private var resolvedInput: GenerationInput? {
        asset.generationInput ?? (loadedReceipt?.identity == loadIdentity ? loadedReceipt?.input : nil)
    }
    private var loadFailure: String? { loadedReceipt?.identity == loadIdentity ? loadedReceipt?.failure : nil }

    private var package: GenerationPackageV1? {
        loadedReceipt?.identity == loadIdentity ? loadedReceipt?.package : nil
    }
    private var packageUnavailable: Bool {
        loadedReceipt?.identity == loadIdentity && loadedReceipt?.package == nil
    }

    private var events: [GenerationSpendEvent] {
        AssetProvenanceEvidence.events(for: resolvedInput, in: editor.generationLog.spendEvents)
    }

    var body: some View {
        Group {
            if let input = resolvedInput {
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
                    if let prompt = package?.payload.prompt { row("Submitted prompt", prompt) }
                    if let loadFailure {
                        Text(loadFailure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                            .reviewAcceptanceProbe("asset.production-origin.error", text: loadFailure)
                    }
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
                                Button("Show Original") { showOriginal(current, receipt: reference) }
                                    .buttonStyle(.inlineAction()).disabled(checkingOriginal)
                                    .background {
                                        if WorkspaceUIAcceptance.isRequested {
                                            AppRelaunchClickProbe(identifier: "asset.\(asset.id).original.\(current.id)")
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .allowsHitTesting(false)
                                        }
                                    }
                            } else {
                                row("Original", "Unavailable in this library")
                            }
                        }
                    }
                }
                if let originalFailure {
                    Text(originalFailure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                        .reviewAcceptanceProbe("asset.original.error", text: originalFailure)
                }
                InspectorSection("Job and Cost") {
                    let jobs = Array(Set(events.compactMap(\.providerRequestId))).sorted()
                    row("Provider job", jobs.isEmpty ? "Not recorded" : jobs.joined(separator: "\n"))
                    let billed = events.filter { $0.kind == .charged }.compactMap(\.money).filter(\.isProviderBilled)
                    let reported = events.compactMap(\.providerCost)
                    if billed.isEmpty && reported.isEmpty {
                        row("Cost", "Unknown")
                    }
                    ForEach(billed.indices, id: \.self) { index in
                        row("Billed cost", money(billed[index]))
                    }
                    ForEach(reported.indices, id: \.self) { index in
                        row("Provider cost", "\(reported[index].amount.formatted(.number.precision(.fractionLength(0...2)))) \(reported[index].unit)")
                    }
                    if !billed.isEmpty {
                        row("Cost evidence", "Provider billing record")
                    } else if !reported.isEmpty {
                        row("Cost evidence", reported.map(\.source).joined(separator: "\n"))
                    }
                    if let estimate = package?.payload.estimate ?? events.first(where: { $0.kind == .reserved })?.money {
                        row("Estimate", money(estimate))
                    }
                }
            } else if let loadFailure {
                InspectorSection("Origin") { row("Source", "Unavailable — production provenance needs review")
                    Text(loadFailure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                        .reviewAcceptanceProbe("asset.production-origin.error", text: loadFailure)
                }
            } else if loadedReceipt?.identity != loadIdentity {
                ProgressView("Reading source provenance…")
            } else {
                InspectorSection("Origin") {
                    row("Source", "Imported media")
                    row("Generation route", "Not applicable")
                }
            }
            if editor.usesProductionPlanningV2 { ProductionObjectLinksView(target: .media(asset.id)) }
        }
        .task(id: loadIdentity) {
            let identity = loadIdentity
            originalFailure = nil
            let loaded = await Task.detached(priority: .utility) { () -> LoadedReceipt in
                do {
                    var input = identity.input
                    if input == nil, let context = identity.production,
                       let root = DataRootResolver.dataRoot(of: context.home),
                       FileManager.default.fileExists(atPath: root.appendingPathComponent(PipelineProductionAssemblyWriter.receiptPath).path) {
                        let receipt = try PlanningWriterIO.read(PipelineProductionAssemblyWriter.Receipt.self,
                            at: PipelineProductionAssemblyWriter.receiptPath, dataRoot: root)
                        if receipt.media.contains(where: { $0.mediaID == identity.assetID }) {
                            input = try ProductionObjectNavigation.origin(mediaID: identity.assetID, context: context)
                        }
                    }
                    guard let input else { return LoadedReceipt(identity: identity, input: nil, package: nil, failure: nil) }
                    guard let id = input.generationPackageID, let home = identity.home else {
                        return LoadedReceipt(identity: identity, input: input, package: nil, failure: nil)
                    }
                    let package = try GenerationPackageV1.load(id: id, home: home)
                    guard AssetProvenanceEvidence.matches(package, input: input) else {
                        throw GateBlocked("The stored generation receipt no longer matches this source revision.")
                    }
                    return LoadedReceipt(identity: identity, input: input, package: package, failure: nil)
                } catch {
                    return LoadedReceipt(identity: identity, input: identity.input, package: nil, failure: error.localizedDescription)
                }
            }.value
            guard !Task.isCancelled, loadIdentity == identity else { return }
            loadedReceipt = loaded
        }
    }

    private func showOriginal(_ current: MediaAsset, receipt: GenerationReferenceReceipt) {
        guard !checkingOriginal else { return }
        let identity = loadIdentity, id = current.id, url = current.url
        checkingOriginal = true; originalFailure = nil
        Task { @MainActor in
            defer { checkingOriginal = false }
            do {
                let hash = try await Task.detached(priority: .utility) { try FileDigest.sha256(of: url) }.value
                guard loadIdentity == identity, hash == receipt.sourceSHA256,
                      let original = editor.mediaAssets.first(where: { $0.id == id && $0.url == url }) else {
                    throw GateBlocked("The original input revision changed. Relink the recorded source before opening it.")
                }
                editor.selectMediaAsset(original)
            } catch { if loadIdentity == identity { originalFailure = error.localizedDescription } }
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
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "asset.\(asset.id).origin.\(label)", acceptanceText: value)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }
}
