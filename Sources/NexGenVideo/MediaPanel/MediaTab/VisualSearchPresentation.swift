import Foundation

enum VisualSearchPresentation {
    static func message(for status: SearchIndexCoordinator.QueryStatus) -> String {
        switch status {
        case .ready: return "Visual search is ready."
        case .indexing: return "Indexing media. Visual results are incomplete."
        case .notIndexed: return "Some media is not indexed yet. Visual results are incomplete."
        case .unavailable(.disabled): return "Visual search is off. Enable it in Settings > Storage to search image contents."
        case .unavailable(.notInstalled): return "Download Smart Search to search image contents. Filename and cached text search remain available."
        case .unavailable(.preparing): return "Preparing visual search. Filename and cached text search remain available."
        case .unavailable(.downloading): return "Downloading Smart Search. Filename and cached text search remain available."
        case .unavailable(.failed): return "The visual search model is unavailable. Retry its download above."
        case .unavailable(.ready), .failed: return "Visual search could not finish. Results are incomplete."
        case .cancelled: return "Visual search was cancelled."
        case .stale: return "The media or search model changed. Search again."
        }
    }

    static func canRepeat(_ status: SearchIndexCoordinator.QueryStatus) -> Bool {
        switch status {
        case .failed, .stale, .cancelled: return true
        default: return false
        }
    }

    static func code(for status: SearchIndexCoordinator.QueryStatus) -> String {
        switch status {
        case .ready: return "ready"
        case .indexing: return "indexing"
        case .notIndexed: return "notIndexed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .stale: return "stale"
        case .unavailable(let availability):
            switch availability {
            case .disabled: return "disabled"
            case .notInstalled: return "modelNotInstalled"
            case .preparing: return "preparing"
            case .downloading: return "downloadingModel"
            case .ready: return "unavailable"
            case .failed: return "modelFailed"
            }
        }
    }
}
