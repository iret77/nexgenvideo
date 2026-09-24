import AppKit
import SwiftUI

struct MediaWorkspaceNavigation: View {
    static let rootRouteID = "__media_library_root__"
    @Environment(EditorViewModel.self) private var editor
    @State private var selection: Set<String> = []
    @State private var isDropTargeted = false
    @State private var renameFolderID: String?
    @State private var renameDraft = ""
    @State private var pendingDelete: Set<String> = []
    @State private var synchronizedSelection: Set<String>?

    private struct Node: Identifiable {
        let folder: MediaFolder
        let children: [Node]?
        var id: String { folder.id }
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            header
            MediaPanelDropArea(
                isTargeted: $isDropTargeted,
                onDrop: importDroppedItems
            ) {
                folderList
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(
                            AppTheme.Accent.primary,
                            style: StrokeStyle(
                                lineWidth: AppTheme.BorderWidth.thick,
                                dash: AppTheme.Border.longDash
                            )
                        )
                        .padding(AppTheme.Spacing.xs)
                        .allowsHitTesting(false)
                }
            }
            footer
        }
        .background(AppTheme.Background.surfaceColor)
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "media.workspace.folderTree")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            synchronizedSelection = editor.selectedFolderIds
            selection = editor.selectedFolderIds
        }
        .simultaneousGesture(TapGesture().onEnded {
            DispatchQueue.main.async {
                editor.focusMediaFolderTree(selection: selection)
            }
        })
        .onChange(of: editor.mediaPanelCurrentFolderId) { _, folderID in
            guard editor.workspaceFocus == .media else { return }
            let value = folderID.map { Set([$0]) } ?? []
            synchronizedSelection = value
            selection = value
        }
        .onChange(of: selection) { _, value in
            if synchronizedSelection == value {
                synchronizedSelection = nil
                return
            }
            synchronizedSelection = nil
            editor.focusedPanel = .media
            editor.mediaCommandFocus = .folderTree
            editor.selectedFolderIds = value
            editor.selectedMediaAssetIds.removeAll()
            guard value.count == 1, let folderID = value.first else { return }
            openFolder(folderID)
        }
        .onChange(of: editor.mediaPanelDeleteFolderRequest) { _, folderIDs in
            guard !folderIDs.isEmpty else { return }
            pendingDelete = folderIDs
        }
        .alert("Rename Folder", isPresented: renameAlertPresented) {
            TextField("Folder name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameFolderID = nil }
            Button("Rename") { commitRename() }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            pendingDelete.count == 1 ? "Remove Folder?" : "Remove Folders?",
            isPresented: deleteConfirmationPresented
        ) {
            Button("Remove", role: .destructive) {
                editor.deleteFolders(ids: pendingDelete)
                selection.subtract(pendingDelete)
                pendingDelete.removeAll()
                editor.mediaPanelDeleteFolderRequest = []
            }
            Button("Cancel", role: .cancel) {
                pendingDelete.removeAll()
                editor.mediaPanelDeleteFolderRequest = []
            }
        } message: {
            Text("Assets move to Imports. Asset IDs and edit references stay unchanged.")
        }
        .accessibilityIdentifier("media.folderTree")
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Folders")
                .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button {
                createFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help("New Folder")
            .accessibilityLabel("New Folder")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.workspaceHeaderHeight)
        .panelHeaderBar()
    }

    private var folderList: some View {
        List(selection: $selection) {
            Button {
                selection.removeAll()
                editor.selectedFolderIds.removeAll()
                editor.selectedMediaAssetIds.removeAll()
                editor.mediaCommandFocus = .folderTree
                editor.mediaPanelOpenFolderId = Self.rootRouteID
                editor.publishMediaPanelFolder(nil, for: .media)
                editor.mediaLibrarySession(for: .workspace).folderID = nil
            } label: {
                Label("Library", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("media.folder.library")
            .background {
                if WorkspaceUIAcceptance.isRequested {
                    AppRelaunchClickProbe(identifier: "media.folder.library")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }

            OutlineGroup(folderNodes, children: \.children) { node in
                folderRow(node.folder)
                    .tag(node.id)
                    .contextMenu { folderContextMenu(node.folder) }
            }
        }
        .listStyle(.sidebar)
    }

    private func folderRow(_ folder: MediaFolder) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "folder")
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(folder.name)
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.xs)
            Text("\(editor.assetsIn(folderId: folder.id).count)")
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openFolder(folder.id) }
        .accessibilityIdentifier("media.folder.\(folder.id)")
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "media.folder.row.\(folder.id)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: MediaFolder) -> some View {
        Button("Open") { openFolder(folder.id) }
        Button("New Subfolder") { createFolder(in: folder.id) }
        Button("Rename") { beginRename(folder) }
        Divider()
        Button("Remove", role: .destructive) { pendingDelete = [folder.id] }
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button {
                createFolder()
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.capsule(.secondary))

            Button {
                guard selection.count == 1,
                      let id = selection.first,
                      let folder = editor.folder(id: id)
                else { return }
                beginRename(folder)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .buttonStyle(.capsule(.secondary))
            .disabled(selection.count != 1)

            Menu {
                Button("Relink Offline Media from Folder\u{2026}", action: presentRelinkPanel)
                    .disabled(editor.offlineMediaRefs.isEmpty)
                Divider()
                Button("Remove", role: .destructive) { pendingDelete = selection }
                    .disabled(selection.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .menuStyle(.button)
            .help("Folder Actions")
            .accessibilityLabel("Folder Actions")
        }
        .controlSize(.small)
        .padding(AppTheme.Spacing.sm)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private var folderNodes: [Node] {
        makeNodes(parentID: nil, visited: [])
    }

    private func makeNodes(parentID: String?, visited: Set<String>) -> [Node] {
        editor.subfolders(of: parentID).compactMap { folder in
            guard !visited.contains(folder.id) else { return nil }
            var nextVisited = visited
            nextVisited.insert(folder.id)
            let children = makeNodes(parentID: folder.id, visited: nextVisited)
            return Node(folder: folder, children: children.isEmpty ? nil : children)
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renameFolderID != nil },
            set: { if !$0 { renameFolderID = nil } }
        )
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { !pendingDelete.isEmpty },
            set: {
                if !$0 {
                    pendingDelete.removeAll()
                    editor.mediaPanelDeleteFolderRequest = []
                }
            }
        )
    }

    private func createFolder(in parentID: String? = nil) {
        let destination = parentID ?? selection.first
        let id = editor.createFolder(name: "New Folder", in: destination)
        selection = [id]
        if let folder = editor.folder(id: id) { beginRename(folder) }
    }

    private func beginRename(_ folder: MediaFolder) {
        renameFolderID = folder.id
        renameDraft = folder.name
    }

    private func commitRename() {
        guard let id = renameFolderID else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { editor.renameFolder(id: id, name: name) }
        renameFolderID = nil
    }

    private func openFolder(_ id: String) {
        guard editor.folder(id: id) != nil else { return }
        editor.mediaPanelOpenFolderId = id
        editor.mediaLibrarySession(for: .workspace).folderID = id
    }

    private func importDroppedItems(_ urls: [URL]) {
        let folderID = selection.count == 1 ? selection.first : nil
        Task { await MediaImportFlow.importItems(urls, into: folderID, editor: editor) }
    }

    private func presentRelinkPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink"
        panel.message = "Choose a folder containing the missing original files."
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in
                let result = await editor.relinkOfflineAssets(fromFolder: folder)
                if let failure = result.failure {
                    editor.mediaPanelToast = MediaPanelToast(message: failure)
                } else {
                    editor.mediaPanelToast = "Relinked \(result.relinked) of \(result.total) offline files."
                }
            }
        }
    }
}
