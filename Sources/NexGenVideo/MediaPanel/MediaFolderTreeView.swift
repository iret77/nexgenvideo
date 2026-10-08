import SwiftUI
import UniformTypeIdentifiers

struct MediaFolderTreeView: View {
    @Environment(EditorViewModel.self) private var editor
    private enum Selection: Hashable {
        case library
        case folder(String)

        var folderID: String? {
            if case .folder(let id) = self { return id }
            return nil
        }
    }

    @State private var selection: Selection? = .library
    @State private var expandedFolderIDs: Set<String> = []

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack {
                Text("Folders")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.sm)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .panelHeaderBar()
            List(selection: $selection) {
                Label("Library", systemImage: "photo.on.rectangle")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .tag(Selection.library)
                    .onDrop(of: [.fileURL, .text], isTargeted: nil) { providers in
                        MediaTab.handleProviderDrop(providers, into: nil, editor: editor)
                        return true
                    }
                    .contextMenu { Button("New Folder") { createFolder(in: nil) } }
                ForEach(MediaFolderTree(folders: editor.folders).roots) { node in
                    FolderBranch(node: node, expanded: $expandedFolderIDs) { node in
                        folderRow(node)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppTheme.Background.surfaceColor)
            .onDeleteCommand {
                if let id = selection?.folderID { editor.deleteFolders(ids: [id]) }
            }
            .onChange(of: selection) { _, value in
                guard editor.workspaceFocus == .media, let value else { return }
                if value.folderID != editor.mediaPanelCurrentFolderId { navigate(value.folderID) }
            }
            .onChange(of: editor.mediaPanelCurrentFolderId, initial: true) { _, value in
                guard editor.workspaceFocus == .media else { return }
                selection = value.map(Selection.folder) ?? .library
                expandedFolderIDs.formUnion(editor.folderPath(for: value).map(\.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.surfaceColor)
    }

    private func folderRow(_ node: MediaFolderTree.Node) -> some View {
        Label(node.folder.name, systemImage: "folder")
            .interfaceFont(size: AppTheme.Typography.ui)
            .background { acceptanceProbe("media.folder.\(node.id)") }
            .draggable(MediaTab.folderDragString(forFolderId: node.id))
            .onDrop(of: [.fileURL, .text], isTargeted: nil) { providers in
                MediaTab.handleProviderDrop(providers, into: node.id, editor: editor)
                return true
            }
            .contextMenu { folderMenu(node.folder) }
    }

    private struct FolderBranch<Row: View>: View {
        let node: MediaFolderTree.Node
        @Binding var expanded: Set<String>
        @ViewBuilder let row: (MediaFolderTree.Node) -> Row

        var body: some View {
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(node.id) },
                    set: { if $0 { expanded.insert(node.id) } else { expanded.remove(node.id) } }
                )) {
                    ForEach(children) { child in
                        FolderBranch(node: child, expanded: $expanded, row: row)
                    }
                } label: { row(node) }
                .tag(Selection.folder(node.id))
            } else {
                row(node).tag(Selection.folder(node.id))
            }
        }
    }

    @ViewBuilder
    private func acceptanceProbe(_ identifier: String) -> some View {
        if WorkspaceUIAcceptance.isRequested {
            AppRelaunchClickProbe(identifier: identifier)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: MediaFolder) -> some View {
        Button("Open") { navigate(folder.id) }
        Button("New Folder") { createFolder(in: folder.id) }
        Button("Rename…") {
            editor.requestMediaFolderRename(folder.id)
        }
        Menu("Move To") {
            Button("Library") { editor.moveFoldersToFolder(folderIds: [folder.id], parentFolderId: nil) }
                .disabled(folder.parentFolderId == nil)
            ForEach(editor.folders.filter { $0.id != folder.id }) { destination in
                Button(editor.folderPath(for: destination.id).map(\.name).joined(separator: " / ")) {
                    editor.moveFoldersToFolder(folderIds: [folder.id], parentFolderId: destination.id)
                }
                .disabled(destination.id == folder.parentFolderId
                          || editor.folderPath(for: destination.id).contains { $0.id == folder.id })
            }
        }
        Divider() // app-theme: native-menu-divider
        Button("Delete", role: .destructive) { editor.deleteFolders(ids: [folder.id]) }
    }

    private func navigate(_ id: String?) {
        selection = id.map(Selection.folder) ?? .library
        editor.setMediaPanelTab(.assets, for: .media)
        editor.mediaFolderNavigationRequest = MediaFolderNavigationRequest(folderID: id, workspace: .media)
    }

    private func createFolder(in parent: String?) {
        let id = editor.createFolder(name: "New Folder", in: parent)
        editor.requestMediaFolderRename(id)
    }
}
