import Foundation

struct MediaLibraryQuery {
    enum SortMode: CaseIterable {
        case name, dateAdded, duration, type

        var title: String {
            switch self {
            case .name: "Name"
            case .dateAdded: "Date Added"
            case .duration: "Duration"
            case .type: "Type"
            }
        }
    }

    var text = ""
    var types: Set<ClipType> = []
    var generatedOnly = false
    var sort: SortMode = .dateAdded

    @MainActor
    func apply(to assets: [MediaAsset]) -> [MediaAsset] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = assets.filter {
            (types.isEmpty || types.contains($0.type))
                && (!generatedOnly || $0.isGenerated)
                && (query.isEmpty || $0.libraryDisplayName.localizedCaseInsensitiveContains(query)
                    || $0.userFacingFilename.localizedCaseInsensitiveContains(query))
        }
        switch sort {
        case .dateAdded: return matching
        case .name:
            return matching.sorted { $0.libraryDisplayName.localizedStandardCompare($1.libraryDisplayName) == .orderedAscending }
        case .duration: return matching.sorted { $0.duration > $1.duration }
        case .type: return matching.sorted { $0.type.rawValue < $1.type.rawValue }
        }
    }
}
