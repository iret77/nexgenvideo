import Foundation
import Observation

enum MediaPickerPurpose: Hashable {
    case composer
    case workspace(EditorViewModel.WorkspaceFocus)
    case intake(String)
    case generationSlot(String)
}

@MainActor
@Observable
final class MediaPickerState {
    var query = ""
    var type: ClipType?
    var selectedAssetID: String?
    var scrollAssetID: String?
    var sourceRanges: [String: SourcePreviewState] = [:]
}

extension EditorViewModel {
    func mediaPickerState(for purpose: MediaPickerPurpose) -> MediaPickerState {
        if let state = mediaPickerStates[purpose] { return state }
        let state = MediaPickerState()
        mediaPickerStates[purpose] = state
        return state
    }
}
