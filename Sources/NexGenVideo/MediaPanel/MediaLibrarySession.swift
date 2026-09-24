import Foundation

enum MediaLibraryPurpose: Hashable, Sendable {
    case workspace
    case editSource
    case productionSource
    case postproductionSource
    case agentReference
    case workflowIntake(String)
    case generationInput(String)

    var accessibilitySuffix: String {
        switch self {
        case .workspace: "workspace"
        case .editSource: "edit"
        case .productionSource: "production"
        case .postproductionSource: "postproduction"
        case .agentReference: "agent"
        case .workflowIntake(let id): "intake-\(id)"
        case .generationInput(let id): "generation-\(id)"
        }
    }
}

enum MediaLibrarySearchScope: String, CaseIterable, Sendable {
    case filename
    case content
    case transcript

    var label: String {
        switch self {
        case .filename: "Filename"
        case .content: "Content"
        case .transcript: "Transcript"
        }
    }
}

enum MediaLibrarySort: String, CaseIterable, Sendable {
    case dateAdded
    case name
    case duration
    case type

    var label: String {
        switch self {
        case .dateAdded: "Date Added"
        case .name: "Name"
        case .duration: "Duration"
        case .type: "Type"
        }
    }
}

enum MediaLibraryLayout: String, CaseIterable, Sendable {
    case grid
    case list
}

@Observable
@MainActor
final class MediaLibrarySession {
    let purpose: MediaLibraryPurpose
    var query = ""
    var searchScope: MediaLibrarySearchScope = .filename
    var folderID: String?
    var filterTypes: Set<ClipType> = []
    var aiOnly = false
    var sort: MediaLibrarySort = .dateAdded
    var sortAscending = true
    var layout: MediaLibraryLayout = .grid
    var thumbnailSize = Double(AppTheme.MediaPanel.thumbnailSmall)
    var scrollAnchorID: String?
    var selectedAssetIDs: Set<String> = []
    var activeAssetID: String?
    var sourceStates: [String: SourcePreviewState] = [:]

    init(purpose: MediaLibraryPurpose) {
        self.purpose = purpose
    }

    func sourceState(for assetID: String) -> SourcePreviewState {
        sourceStates[assetID] ?? SourcePreviewState()
    }

    func rememberSourceState(_ state: SourcePreviewState, for assetID: String) {
        sourceStates[assetID] = state
    }
}

@MainActor
enum MediaLibraryProjection {
    static func assets(
        from assets: [MediaAsset],
        session: MediaLibrarySession
    ) -> [MediaAsset] {
        let query = session.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var output = assets.filter { asset in
            guard session.folderID == nil || asset.folderId == session.folderID else { return false }
            guard session.filterTypes.isEmpty || session.filterTypes.contains(asset.type) else { return false }
            guard !session.aiOnly || asset.isGenerated else { return false }
            guard query.isEmpty || session.searchScope != .filename
                    || asset.userFacingFilename.localizedCaseInsensitiveContains(query)
                    || asset.name.localizedCaseInsensitiveContains(query)
            else { return false }
            return true
        }

        switch session.sort {
        case .dateAdded:
            break
        case .name:
            output.sort {
                $0.userFacingFilename.localizedCaseInsensitiveCompare($1.userFacingFilename) == .orderedAscending
            }
        case .duration:
            output.sort { $0.duration < $1.duration }
        case .type:
            output.sort {
                if $0.type == $1.type {
                    return $0.userFacingFilename.localizedCaseInsensitiveCompare($1.userFacingFilename) == .orderedAscending
                }
                return $0.type.rawValue < $1.type.rawValue
            }
        }
        if !session.sortAscending { output.reverse() }
        return output
    }
}
