import Foundation

struct MediaLibraryDestination: Sendable {
    let root: URL?
    let key: String?
    let generation: UUID?
    let folderID: String?

    @MainActor init(_ editor: EditorViewModel, folderID: String?) {
        root = editor.workingRoot?.standardizedFileURL
        key = editor.openWorkingCopyKey
        generation = editor.openWorkingCopyGeneration
        self.folderID = folderID
    }

    @MainActor func validate(_ editor: EditorViewModel) throws {
        guard root == editor.workingRoot?.standardizedFileURL,
              key == editor.openWorkingCopyKey, generation == editor.openWorkingCopyGeneration else {
            throw MediaImportError.projectChanged
        }
        if let folderID, editor.folder(id: folderID) == nil { throw MediaImportError.destinationChanged }
    }

    @MainActor func isCurrent(_ editor: EditorViewModel) -> Bool {
        do { try validate(editor); return true }
        catch { editor.mediaPanelToast = MediaPanelToast(message: error.localizedDescription); return false }
    }
}
