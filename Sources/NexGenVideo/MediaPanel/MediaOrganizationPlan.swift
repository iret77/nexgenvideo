import Foundation

struct MediaOrganizationScope: Codable, Equatable, Sendable {
    var folderID: String?
}

struct MediaOrganizationPlan: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        let assetID: String
        let name: String?
        let folderPath: [String]?
    }

    struct Row: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let sourceURL: URL
        let originalName: String
        let originalFolderID: String?
        let filename: String
        let before: String
        let name: String
        let folderPath: [String]
        let destination: String

        var after: String { destination }
    }

    let projectID: String
    let scope: MediaOrganizationScope
    let folders: [MediaFolder]
    let rows: [Row]

    @MainActor
    static func prepare(_ changes: [Change], scope: MediaOrganizationScope, editor: EditorViewModel) throws -> Self {
        guard let projectID = editor.projectId, !changes.isEmpty, changes.count <= 500,
              Set(changes.map(\.assetID)).count == changes.count else {
            throw ToolError("Provide 1–500 unique library assets in a saved project.")
        }
        if let id = scope.folderID, editor.folder(id: id) == nil { throw ToolError("The selected media folder no longer exists.") }
        let descendants = scope.folderID.map { editor.folderIDsIncludingDescendants([$0]) }
        let scopePath = editor.folderPath(for: scope.folderID).map(\.name)
        let rows = try changes.compactMap { change -> Row? in
            guard let asset = editor.mediaAssets.first(where: { $0.id == change.assetID }), !asset.isGenerating else {
                throw ToolError("Media asset is missing or still generating: " + change.assetID)
            }
            if let descendants, !descendants.contains(asset.folderId ?? "") { throw ToolError("Media asset is outside the selected organization folder: " + asset.libraryDisplayName) }
            let name = change.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? asset.name
            let beforePath = editor.folderPath(for: asset.folderId).map(\.name)
            let folderPath = change.folderPath ?? Array(beforePath.dropFirst(scopePath.count))
            guard (change.name == nil || !name.isEmpty), name.count <= 200,
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), folderPath.count <= 12,
                  folderPath.allSatisfy(validFolderName) else { throw ToolError("Use a nonempty display name and up to 12 plain folder names.") }
            try validateDestination(folderPath, scope: scope, folders: editor.folders)
            if name == asset.name && scopePath + folderPath == beforePath { return nil }
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let visibleName = displayName.isEmpty || MediaFilename.isContentAddressed(displayName) ? asset.userFacingFilename : displayName
            return Row(id: asset.id, sourceURL: asset.url, originalName: asset.name, originalFolderID: asset.folderId,
                       filename: asset.userFacingFilename, before: (beforePath + [asset.libraryDisplayName]).joined(separator: " / "),
                       name: name, folderPath: folderPath, destination: (scopePath + folderPath + [visibleName]).joined(separator: " / "))
        }
        guard !rows.isEmpty else { throw ToolError("The proposed names and folders already match the library. No changes are needed.") }
        return .init(projectID: projectID, scope: scope, folders: editor.folders, rows: rows)
    }

    @MainActor
    func apply(selected: Set<String>, editor: EditorViewModel) throws -> Int {
        guard !selected.isEmpty, selected.isSubset(of: Set(rows.map(\.id))) else { throw ToolError("Select the changes to apply.") }
        let current = try Self.prepare(rows.map { .init(assetID: $0.id, name: $0.name == $0.originalName ? nil : $0.name, folderPath: $0.folderPath) }, scope: scope, editor: editor)
        guard current == self else { throw ToolError("The library changed since this proposal. Discard it and request a new plan.") }
        let accepted = rows.filter { selected.contains($0.id) }
        for row in accepted { try Self.validateDestination(row.folderPath, scope: scope, folders: editor.folders) }
        let previous: [EditorViewModel.OrganizedAssetState] = accepted.map { .init(id: $0.id, name: $0.originalName, folderID: $0.originalFolderID) }
        let existingFolders = Set(editor.folders.map(\.id))
        editor.undoManager?.disableUndoRegistration()
        for row in accepted {
            var parent = scope.folderID
            for name in row.folderPath {
                if let folder = editor.folders.first(where: { $0.parentFolderId == parent && $0.name == name }) { parent = folder.id }
                else { parent = editor.createFolder(name: name, in: parent) }
            }
            if row.originalName != row.name { editor.renameMediaAsset(id: row.id, name: row.name) }
            editor.moveAssetsToFolder(assetIds: [row.id], folderId: parent)
        }
        editor.undoManager?.enableUndoRegistration()
        editor.undoManager?.beginUndoGrouping()
        editor.registerMediaOrganizationUndo(previous, removing: editor.folders.filter { !existingFolders.contains($0.id) })
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Organize Media")
        return accepted.count
    }

    var dialog: AgentDialog {
        .init(id: UUID().uuidString, title: "Review media organization", symbol: "folder.badge.gearshape",
              intro: "Select the proposed changes to apply. Original files and timeline clips are preserved.", costHint: nil,
              confirmLabel: "Apply Selected", textField: nil,
              sections: [.init(id: "organization", label: "Proposed changes", kind: .choices(options: rows.map {
                  .init(id: $0.id, label: $0.before + " → " + $0.after, shortLabel: $0.name)
              }, multiSelect: true))], purpose: .mediaOrganization, mediaOrganization: self)
    }

    private static func validFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 200 && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func validateDestination(_ path: [String], scope: MediaOrganizationScope, folders: [MediaFolder]) throws {
        var parent = scope.folderID
        for name in path {
            let matches = folders.filter { $0.parentFolderId == parent && $0.name == name }
            guard matches.count <= 1 else { throw ToolError("More than one destination folder is named “" + name + "”. Rename the duplicate before organizing.") }
            guard let existing = matches.first else { return }
            parent = existing.id
        }
    }
}
