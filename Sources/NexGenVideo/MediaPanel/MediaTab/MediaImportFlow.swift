import AppKit
import UniformTypeIdentifiers

@MainActor
enum MediaImportFlow {
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.movie, .image, .audio, .json, .plainText]
        // `.plainText` does not cover these pipeline source formats.
        for ext in ["md", "markdown", "rtf", "fountain"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        if let lottie = UTType(filenameExtension: "lottie") { types.append(lottie) }
        return types
    }

    static func present(editor: EditorViewModel, destinationFolderId: String?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Select media files or folders to copy into the project. Originals stay in place."
        panel.allowedContentTypes = allowedContentTypes
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                await importItems(urls, into: destinationFolderId, editor: editor)
            }
        }
    }

    static func importItems(_ urls: [URL], into destinationFolderId: String?, editor: EditorViewModel) async {
        await editor.importFinderItems(urls, into: destinationFolderId)
    }
}
