import Foundation

struct MediaFolderTree {
    struct Node: Identifiable {
        let folder: MediaFolder
        var children: [Node]?
        var id: String { folder.id }
    }

    let roots: [Node]

    init(folders: [MediaFolder]) {
        let ordered = folders.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        let ids = Set(ordered.map(\.id))
        let children = Dictionary(grouping: ordered, by: \.parentFolderId)
        var visited: Set<String> = []
        func node(_ folder: MediaFolder) -> Node? {
            guard visited.insert(folder.id).inserted else { return nil }
            let descendants = (children[folder.id] ?? []).compactMap(node)
            return Node(folder: folder, children: descendants.isEmpty ? nil : descendants)
        }
        var result = ordered.filter { $0.parentFolderId.map { !ids.contains($0) } ?? true }.compactMap(node)
        for folder in ordered where !visited.contains(folder.id) {
            if let remaining = node(folder) { result.append(remaining) }
        }
        roots = result
    }
}

struct MediaFolderNavigationRequest: Equatable {
    let folderID: String?
    let workspace: EditorViewModel.WorkspaceFocus
    let revision = UUID()
}
