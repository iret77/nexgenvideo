import SwiftUI
import UniformTypeIdentifiers

struct MediaFolderTreeView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var selection: String?
    @State private var renamingID: String?
    @State private var renameDraft = ""
    @State private var showsRename = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack {
                Text("Folders")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("New Folder", systemImage: "folder.badge.plus") { createFolder(in: selection) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.inlineAction())
                    .help("New Folder")
            }
            .padding(AppTheme.Spacing.sm)
            Button("Library", systemImage: "photo.on.rectangle") { navigate(nil) }
                .buttonStyle(.inlineAction())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .onDrop(of: [.fileURL, .text], isTargeted: nil) { providers in
                    MediaTab.handleProviderDrop(providers, into: nil, editor: editor)
                    return true
                }
                .contextMenu {
                    Button("New Folder") { createFolder(in: nil) }
                }
            List(selection: $selection) {
                OutlineGroup(MediaFolderTree(folders: editor.folders).roots, children: \.children) { node in
                    Label(node.folder.name, systemImage: "folder")
                        .tag(node.id)
                        .background { acceptanceProbe("media.folder.\(node.id)") }
                        .draggable(MediaTab.folderDragString(forFolderId: node.id))
                        .onDrop(of: [.fileURL, .text], isTargeted: nil) { providers in
                            MediaTab.handleProviderDrop(providers, into: node.id, editor: editor)
                            return true
                        }
                        .contextMenu { folderMenu(node.folder) }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let selection { editor.deleteFolders(ids: [selection]) }
            }
            .onChange(of: selection) { _, value in
                guard editor.workspaceFocus == .media else { return }
                if value != editor.mediaPanelCurrentFolderId { navigate(value) }
            }
            .onChange(of: editor.mediaPanelCurrentFolderId, initial: true) { _, value in
                guard editor.workspaceFocus == .media else { return }
                selection = value
            }
        }
        .alert("Rename Folder", isPresented: $showsRename) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let renamingID { editor.renameFolder(id: renamingID, name: renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
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
            renamingID = folder.id
            renameDraft = folder.name
            showsRename = true
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
        selection = id
        editor.setMediaPanelTab(.assets, for: .media)
        editor.mediaFolderNavigationRequest = MediaFolderNavigationRequest(folderID: id, workspace: .media)
    }

    private func createFolder(in parent: String?) {
        let id = editor.createFolder(name: "New Folder", in: parent)
        navigate(id)
        renamingID = id
        renameDraft = "New Folder"
        showsRename = true
    }
}
