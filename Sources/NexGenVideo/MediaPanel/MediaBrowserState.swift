import Foundation
import Observation

enum MediaBrowserViewMode: String, CaseIterable {
    case folder, flat, grouped, list

    var title: String {
        switch self {
        case .folder: "Folders"
        case .flat: "Grid"
        case .grouped: "Grouped"
        case .list: "List"
        }
    }

    var systemImage: String {
        switch self {
        case .folder: "folder"
        case .flat: "square.grid.2x2"
        case .grouped: "rectangle.split.1x2"
        case .list: "list.bullet"
        }
    }
}

@MainActor
@Observable
final class MediaBrowserState {
    var sortMode: MediaLibraryQuery.SortMode = .dateAdded
    var filterTypes: Set<ClipType> = []
    var filterAI: Bool = false
    var searchQuery: String = ""
    var thumbnailSize: Double = AppTheme.MediaPanel.thumbnailSmall
    var viewMode: MediaBrowserViewMode = .folder
    var currentFolderId: String? = nil
    var folderReturnViewMode: MediaBrowserViewMode? = nil
    var collapsedGroupedKeys: Set<String> = []
    var scrollAssetID: String?
    var sourceRanges: [String: SourcePreviewState] = [:]
}

extension EditorViewModel {
    func mediaBrowserState(for workspace: WorkspaceFocus) -> MediaBrowserState {
        if let state = mediaBrowserStates[workspace] { return state }
        let state = MediaBrowserState()
        if workspace != .media { state.viewMode = .flat }
        mediaBrowserStates[workspace] = state
        return state
    }
}
