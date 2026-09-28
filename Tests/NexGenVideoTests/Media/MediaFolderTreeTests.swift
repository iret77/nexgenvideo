import Testing
@testable import NexGenVideo

@Suite("Media folder tree")
@MainActor
struct MediaFolderTreeTests {
    @Test("nested folders keep canonical IDs and parents without loading media")
    func nestedFolders() {
        let folders = [
            MediaFolder(id: "root", name: "Production"),
            MediaFolder(id: "shots", name: "Shots", parentFolderId: "root"),
            MediaFolder(id: "takes", name: "Takes", parentFolderId: "shots"),
            MediaFolder(id: "audio", name: "Audio", parentFolderId: "root"),
        ]
        let tree = MediaFolderTree(folders: folders)
        #expect(tree.roots.map(\.id) == ["root"])
        #expect(tree.roots.first?.children?.map(\.id) == ["audio", "shots"])
        #expect(tree.roots.first?.children?.last?.children?.first?.folder == folders[2])
    }

    @Test("malformed legacy parents and cycles remain visible once without recursion loops")
    func legacyParents() {
        let folders = [
            MediaFolder(id: "a", name: "A", parentFolderId: "b"),
            MediaFolder(id: "b", name: "B", parentFolderId: "a"),
            MediaFolder(id: "orphan", name: "Orphan", parentFolderId: "missing"),
            MediaFolder(id: "self", name: "Self", parentFolderId: "self"),
        ]
        func flatten(_ nodes: [MediaFolderTree.Node]) -> [String] {
            nodes.flatMap { [$0.id] + flatten($0.children ?? []) }
        }
        let ids = flatten(MediaFolderTree(folders: folders).roots)
        #expect(ids.count == folders.count)
        #expect(Set(ids) == Set(folders.map(\.id)))
    }
}
