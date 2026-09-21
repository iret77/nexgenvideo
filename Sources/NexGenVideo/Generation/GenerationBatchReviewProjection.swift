import Foundation

struct GenerationBatchReviewProjection: Equatable {
    enum Group: Int, CaseIterable, Equatable, Identifiable {
        case character
        case ensemble
        case location
        case prop
        case look
        case other

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .character: String(localized: "Characters")
            case .ensemble: String(localized: "Ensembles")
            case .location: String(localized: "Locations")
            case .prop: String(localized: "Props")
            case .look: String(localized: "Look")
            case .other: String(localized: "Other")
            }
        }

        static func classify(_ purpose: String) -> Self {
            let leading = purpose
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace || ":/—–-".contains($0) })
                .first
                .map(String.init)
            switch leading {
            case "character", "characters": .character
            case "ensemble", "ensembles": .ensemble
            case "location", "locations": .location
            case "prop", "props": .prop
            case "look": .look
            default: .other
            }
        }
    }

    struct Route: Equatable, Identifiable {
        let id: String
        let label: String
        let count: Int
    }

    struct Item: Equatable, Identifiable {
        let id: String
        let manifestIndex: Int
        let purpose: String
        let group: Group
        let routeID: String
        let routeLabel: String
        let outputCount: Int
        let destination: GenerationPackageV1.Destination
        let destinationLabel: String
        let priceEUR: Double?
        let referenceCount: Int
    }

    struct Section: Equatable, Identifiable {
        let group: Group
        let items: [Item]
        var id: Group { group }
    }

    let sections: [Section]
    let routes: [Route]
    let dominantRouteID: String?
    let commonOutputCount: Int?
    let commonDestinationLabel: String?
    let unknownPriceCount: Int
    let totalEUR: Double?
    let itemCount: Int

    @MainActor
    init(
        batch: GenerationBatch,
        destinationName: (GenerationPackageV1.Destination) -> String = {
            GenerationDestinationPresentation.label($0, editor: nil)
        },
        modelName: (String) -> String = { ModelRegistry.displayName(for: $0) }
    ) {
        var routeOrder: [String] = []
        var routeLabels: [String: String] = [:]
        var routeCounts: [String: Int] = [:]
        var routeBaseLabels: [String: String] = [:]
        for value in batch.payload.items {
            let target = value.package.payload.target
            let routeID = Self.routeID(target)
            routeBaseLabels[routeID] = Self.routeBaseLabel(target, modelName: modelName)
        }
        let ambiguousLabels = Set(Dictionary(grouping: routeBaseLabels.keys) { routeBaseLabels[$0]! }
            .filter { $0.value.count > 1 }
            .map(\.key))
        let items = batch.payload.items.enumerated().map { index, value in
            let target = value.package.payload.target
            let routeID = Self.routeID(target)
            if routeCounts[routeID] == nil { routeOrder.append(routeID) }
            routeCounts[routeID, default: 0] += 1
            let baseLabel = routeBaseLabels[routeID]!
            routeLabels[routeID] = ambiguousLabels.contains(baseLabel)
                ? [baseLabel, target.endpoint, target.binding?.modelParam].compactMap { $0 }.joined(separator: " · ")
                : baseLabel
            return Item(
                id: value.id,
                manifestIndex: index,
                purpose: value.purpose,
                group: Group.classify(value.purpose),
                routeID: routeID,
                routeLabel: routeLabels[routeID]!,
                outputCount: value.package.payload.outputCount,
                destination: value.package.payload.destination,
                destinationLabel: destinationName(value.package.payload.destination),
                priceEUR: value.package.payload.estimate?.eurAmount,
                referenceCount: value.package.payload.references.count
            )
        }
        sections = Group.allCases.compactMap { group in
            let values = items.filter { $0.group == group }
            return values.isEmpty ? nil : Section(group: group, items: values)
        }
        routes = routeOrder.map {
            Route(id: $0, label: routeLabels[$0]!, count: routeCounts[$0]!)
        }.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return routeOrder.firstIndex(of: lhs.id)! < routeOrder.firstIndex(of: rhs.id)!
            }
            return lhs.count > rhs.count
        }
        dominantRouteID = routes.first?.id
        commonOutputCount = Set(items.map(\.outputCount)).count == 1 ? items.first?.outputCount : nil
        commonDestinationLabel = items.first.flatMap { first in
            items.dropFirst().allSatisfy { $0.destination == first.destination }
                ? first.destinationLabel
                : nil
        }
        unknownPriceCount = items.filter { $0.priceEUR == nil }.count
        totalEUR = batch.totalEUR
        itemCount = items.count
    }

    private static func routeID(_ target: ResolvedGenerationTarget) -> String {
        [
            target.modelId,
            target.provider.rawValue,
            target.transport.rawValue,
            target.endpoint,
            target.binding?.modelParam ?? "",
        ].joined(separator: "|")
    }

    private static func routeBaseLabel(
        _ target: ResolvedGenerationTarget,
        modelName: (String) -> String
    ) -> String {
        "\(modelName(target.modelId)) · \(target.provider.displayName) \(target.transport == .api ? "API" : "MCP")"
    }

}

@MainActor
enum GenerationDestinationPresentation {
    static func label(
        _ destination: GenerationPackageV1.Destination,
        editor: EditorViewModel?
    ) -> String {
        switch destination.kind {
        case "media_library":
            if let folderID = destination.folderID,
               let folder = editor?.folder(id: folderID) {
                return String(localized: "Media library · \(folder.name)")
            }
            return String(localized: "Media library")
        case "timeline":
            let frame = destination.startFrame.map(String.init) ?? String(localized: "current")
            let duration = destination.durationSeconds.map {
                String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), $0)
            }
            let frameRate = destination.timelineFPS.map { String(localized: "\($0) fps") }
            return [String(localized: "Timeline · frame \(frame)"), duration, frameRate]
                .compactMap { $0 }
                .joined(separator: " · ")
        case "replace_clip":
            if let clipID = destination.clipID,
               let clip = editor?.clipFor(id: clipID),
               let asset = editor?.mediaAssets.first(where: { $0.id == clip.mediaRef }) {
                let trim = destination.resetTrim == true ? String(localized: " · reset trim") : ""
                return String(localized: "Replace \(asset.userFacingFilename) at frame \(clip.startFrame)\(trim)")
            }
            return String(localized: "Replace selected clip")
        default:
            return String(localized: "Project")
        }
    }
}
