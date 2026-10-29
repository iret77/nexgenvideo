import Foundation
import NexGenEngine
import SwiftUI

enum ProductionObjectNavigation {
    struct Asset: Sendable, Equatable {
        let id: String
        let name: String
        let url: URL
    }
    struct Context: Sendable, Equatable {
        let home: URL
        let key: String
        let generation: UUID
        let declaration: ProjectPackGate.MutationDeclaration
        let timeline: Timeline
        let assets: [Asset]

        @MainActor
        init?(_ editor: EditorViewModel) {
            guard editor.usesProductionPlanningV2, let home = editor.workingRoot,
                  let key = editor.openWorkingCopyKey, let generation = editor.openWorkingCopyGeneration else { return nil }
            self.home = home; self.key = key; self.generation = generation
            declaration = .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                productionContract: editor.declaredProductionContract)
            timeline = editor.timeline
            assets = editor.mediaAssets.map { .init(id: $0.id, name: $0.libraryDisplayName, url: $0.url) }
        }
    }
    struct Link: Sendable, Equatable, Identifiable {
        var id: String { clipID }
        let clipID: String
        let mediaID: String
        let shotID: String
        let trackLabel: String
        let assetName: String
        let startFrame: Int
        let referenceAssetIDs: [String]
        let input: GenerationInput?
        let package: GenerationPackageV1?
    }
    struct UnavailablePlacement: Sendable, Equatable {
        let clipID: String
        let shotID: String
        let mediaID: String?
    }
    struct Snapshot: Sendable, Equatable {
        let planning: ProductionPlanPresentation.Snapshot
        let links: [Link]
        let unavailablePlacements: [UnavailablePlacement]
        var unavailableClipIDs: [String] { unavailablePlacements.map(\.clipID) }

        func hasUnavailableLink(shotID: String) -> Bool {
            unavailablePlacements.contains { $0.shotID == shotID }
        }

        func hasUnavailableLink(mediaID: String) -> Bool {
            unavailablePlacements.contains { $0.mediaID == mediaID }
        }
    }
    struct Origin: Sendable, Equatable {
        let input: GenerationInput
        let package: GenerationPackageV1
    }

    static func read(_ context: Context) throws -> Snapshot {
        try Task.checkCancellation()
        guard let root = DataRootResolver.dataRoot(of: context.home),
              try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: context.declaration.binding,
                expectedProductionContract: context.declaration.productionContract)?.isProductionV2 == true,
              let planning = try ProductionPlanPresentation.load(dataRoot: root) else { throw changed() }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(PipelineProductionAssemblyWriter.receiptPath).path) else {
            throw GateBlocked("Build the current cut to link production shots to timeline clips.")
        }
        let proof = try PipelineProductionAssemblyWriter.requireCurrent(dataRoot: root)
        let receipt = try PlanningWriterIO.read(PipelineProductionAssemblyWriter.Receipt.self,
            at: PipelineProductionAssemblyWriter.receiptPath, dataRoot: root)
        var links: [Link] = []
        var unavailable: [UnavailablePlacement] = []
        var trackLabels: [String: String] = [:], counts: [String: Int] = [:]
        for track in context.timeline.tracks {
            let prefix = track.type.trackLabelPrefix
            counts[prefix, default: 0] += 1
            trackLabels[track.id] = prefix + String(counts[prefix]!)
        }
        for placement in proof.placements {
            try Task.checkCancellation()
            guard let track = context.timeline.tracks.first(where: { $0.id == placement.trackID }),
                  let clip = track.clips.first(where: { $0.id == placement.clipID }),
                  let asset = context.assets.first(where: { $0.id == clip.mediaRef }),
                  receipt.media.contains(where: { $0.mediaID == asset.id && $0.source == placement.output }) else {
                let mediaID = receipt.tracks.first(where: { $0.id == placement.trackID })?.clips.first(where: { $0.id == placement.clipID })?.mediaRef
                unavailable.append(.init(clipID: placement.clipID, shotID: placement.shotID, mediaID: mediaID))
                continue
            }
            guard try FileDigest.sha256(of: asset.url) == placement.output.sha256 else { throw changed() }
            let origin = try generationOrigin(placement: placement, root: root, home: context.home)
            var references: [String] = []
            for ref in origin?.package.payload.references ?? [] {
                try Task.checkCancellation()
                if let original = context.assets.first(where: { $0.id == ref.assetID }),
                   try FileDigest.sha256(of: original.url) == ref.sourceSHA256 { references.append(original.id) }
            }
            links.append(.init(clipID: clip.id, mediaID: asset.id, shotID: placement.shotID,
                trackLabel: trackLabels[track.id] ?? "Track", assetName: asset.name, startFrame: clip.startFrame,
                referenceAssetIDs: references, input: origin?.input, package: origin?.package))
        }
        guard try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: context.declaration.binding,
                expectedProductionContract: context.declaration.productionContract)?.isProductionV2 == true,
              try ProductionPlanPresentation.load(dataRoot: root) == planning else { throw changed() }
        return Snapshot(planning: planning, links: links, unavailablePlacements: unavailable)
    }

    static func origin(mediaID: String, context: Context) throws -> GenerationInput? {
        try verifiedOrigin(mediaID: mediaID, context: context)?.input
    }

    static func verifiedOrigin(mediaID: String, context: Context) throws -> Origin? {
        try Task.checkCancellation()
        guard let root = DataRootResolver.dataRoot(of: context.home),
              try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: context.declaration.binding,
                expectedProductionContract: context.declaration.productionContract)?.isProductionV2 == true else { throw changed() }
        let proof = try PipelineProductionAssemblyWriter.requireCurrent(dataRoot: root)
        let receipt = try PlanningWriterIO.read(PipelineProductionAssemblyWriter.Receipt.self,
            at: PipelineProductionAssemblyWriter.receiptPath, dataRoot: root)
        guard let placement = proof.placements.first(where: { placement in
            receipt.tracks.first(where: { $0.id == placement.trackID })?.clips.contains(where: { $0.id == placement.clipID && $0.mediaRef == mediaID }) == true
        }) else {
            if receipt.media.contains(where: { $0.mediaID == mediaID }) { throw changed() }
            return nil
        }
        guard let asset = context.assets.first(where: { $0.id == mediaID }),
              receipt.media.contains(where: { $0.mediaID == asset.id && $0.source == placement.output }),
              try FileDigest.sha256(of: asset.url) == placement.output.sha256 else { throw changed() }
        return try generationOrigin(placement: placement, root: root, home: context.home)
    }

    private static func generationOrigin(placement: ProductionPlanAssemblyProofV1.Placement, root: URL, home: URL) throws -> Origin? {
        try Task.checkCancellation()
        let completed: GenerationOutputReceipt
        if let takeID = placement.takeID {
            let record = try PipelineProductionRenderWriter.requireRecord(takeID: takeID, dataRoot: root)
            guard record.shotID == placement.shotID, record.output == placement.output else { throw changed() }
            completed = try GenerationOutputReceipt.load(assetID: record.generation.id, home: home)
        } else if placement.sourceKind == .stillImage {
            let still = try PipelineProductionRenderWriter.requireStill(shotID: placement.shotID, dataRoot: root)
            guard still.record.output == placement.output else { throw changed() }
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(still.record.frameReceipt.path, dataRoot: root))
            guard FileDigest.sha256(of: bytes) == still.record.frameReceipt.sha256 else { throw changed() }
            completed = try JSONDecoder().decode(PipelineProductionFramesWriter.Receipt.self, from: bytes).generation
        } else { return nil }
        return try origin(completed: completed, outputSHA256: placement.output.sha256, home: home)
    }

    static func origin(completed: GenerationOutputReceipt, outputSHA256: String, home: URL) throws -> Origin {
        try Task.checkCancellation()
        guard completed.output.sha256 == outputSHA256,
              completed.input.generationPackageID.map({ $0 == completed.package.id }) ?? true else { throw changed() }
        let package = try GenerationPackageV1.load(id: completed.package.id, home: home)
        var input = completed.input
        input.generationPackageID = completed.package.id
        input.spendTransactionId = completed.activity.spendTransactionId
        input.createdAt = completed.activity.createdAt
        guard AssetProvenanceEvidence.matches(package, input: input) else { throw changed() }
        return Origin(input: input, package: package)
    }

    private static func changed() -> GateBlocked {
        GateBlocked("The production source or assembled clip changed. Review the current cut before opening its linked objects.")
    }
}

struct ProductionObjectLinksView: View {
    enum Target: Equatable { case shot(String), media(String) }
    let target: Target
    @Environment(EditorViewModel.self) private var editor
    @State private var loaded: (ProductionObjectNavigation.Context, ProductionObjectNavigation.Snapshot)?
    @State private var failure: String?
    @State private var busy = false

    private var context: ProductionObjectNavigation.Context? { ProductionObjectNavigation.Context(editor) }
    private var snapshot: ProductionObjectNavigation.Snapshot? { loaded?.0 == context ? loaded?.1 : nil }
    private var links: [ProductionObjectNavigation.Link] {
        guard let snapshot else { return [] }
        let selected = snapshot.links.filter { link in
            switch target {
            case .shot(let id): link.shotID == id
            case .media(let id): link.mediaID == id || link.referenceAssetIDs.contains(id)
            }
        }
        guard case .media(let id) = target else { return selected }
        return selected.filter { $0.mediaID == id } + selected.filter { $0.mediaID != id }
    }

    private var hasUnavailableLink: Bool {
        guard let snapshot else { return false }
        switch target {
        case .shot(let id): return snapshot.hasUnavailableLink(shotID: id)
        case .media(let id): return snapshot.hasUnavailableLink(mediaID: id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(target.isShot ? "On timeline" : "Production shots").foregroundStyle(AppTheme.Text.secondaryColor)
            if let snapshot {
                ForEach(links) { link in
                    Button(linkTitle(link, snapshot: snapshot)) {
                        open(link)
                    }.buttonStyle(InlineActionButtonStyle()).disabled(busy)
                        .reviewAcceptanceProbe(target.isShot ? "production.object.clip." + link.clipID : "production.object.shot." + link.shotID,
                            state: !busy, text: linkTitle(link, snapshot: snapshot))
                }
                if links.isEmpty {
                    Text(hasUnavailableLink ? "The original assembled clip or its media is no longer available." : "No current production link for this object.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            } else if failure == nil { ProgressView("Reading production links…") }
            if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled)
                .reviewAcceptanceProbe("production.object.error", text: failure) }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .task(id: context) {
            loaded = nil; failure = nil
            guard let context else { return }
            do {
                let work = Task.detached(priority: .utility) { try ProductionObjectNavigation.read(context) }
                let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, self.context == context else { return }
                loaded = (context, value)
            } catch { if !Task.isCancelled, self.context == context { failure = error.localizedDescription } }
        }
    }

    private func linkTitle(_ link: ProductionObjectNavigation.Link, snapshot: ProductionObjectNavigation.Snapshot) -> String {
        switch target {
        case .shot: link.trackLabel + " · " + link.assetName
        case .media(let id): "Shot \(snapshot.planning.number(link.shotID) ?? 0) · " + (link.mediaID == id ? "Placed clip" : "Reference input")
        }
    }

    private func open(_ link: ProductionObjectNavigation.Link) {
        guard !busy, let context, let loaded, loaded.0 == context else { return }
        busy = true; failure = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let work = Task.detached(priority: .userInitiated) { try ProductionObjectNavigation.read(context) }
                let current = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard self.context == context, current == loaded.1, current.links.contains(link) else {
                    throw GateBlocked("The linked object changed. Select it again from the current cut.")
                }
                switch target {
                case .shot:
                    editor.setWorkspaceFocus(.edit)
                    editor.selectPreviewTab(id: PreviewTab.timeline.id)
                    editor.selectedTimelineRange = nil
                    editor.selectedClipIds = [link.clipID]
                    editor.inspectedObject = .clip(link.clipID)
                    editor.currentFrame = link.startFrame
                    editor.inspectorPanelVisible = true
                case .media:
                    editor.setWorkspaceFocus(.production)
                    editor.revealCockpit(.shotlist)
                    editor.productionPlanSelection = .init(home: context.home, snapshot: current.planning, shotID: link.shotID)
                }
            } catch { failure = error.localizedDescription }
        }
    }
}

private extension ProductionObjectLinksView.Target {
    var isShot: Bool { if case .shot = self { true } else { false } }
}
