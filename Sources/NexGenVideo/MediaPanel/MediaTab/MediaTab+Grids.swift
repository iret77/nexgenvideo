import SwiftUI
import UniformTypeIdentifiers

// MARK: - Grid layout types

extension MediaTab {
    struct MediaCell: Identifiable {
        enum Kind { case folder(MediaFolder), asset(MediaAsset) }
        let kind: Kind

        var id: String {
            switch kind {
            case .folder(let f): return MediaPanelItemKey.folder(f.id)
            case .asset(let a): return a.id
            }
        }

        static func folderId(fromFrameKey key: String) -> String? {
            MediaPanelItemKey.folderId(from: key)
        }
    }

    struct GridLayoutInfo {
        let cols: Int
        let tileWidth: CGFloat
        let spacing: CGFloat
        let cells: [MediaCell]
    }

    struct GridDimensions {
        let cols: Int
        let tileWidth: CGFloat
        let spacing: CGFloat
    }

    func listScroll(cells: [MediaCell]) -> some View {
        let session = editor.mediaLibrarySession(for: mediaPurpose)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(cells) { cell in
                        listCellView(for: cell)
                            .id(cell.id)
                    }
                }
                .padding(AppTheme.Spacing.md)
                .scrollTargetLayout()
            }
            .scrollPosition(
                id: Binding(
                    get: { session.scrollAnchorID },
                    set: { session.scrollAnchorID = $0 }
                ),
                anchor: .center
            )
            .onAppear {
                if editor.mediaPanelColumnCount != 1 { editor.mediaPanelColumnCount = 1 }
            }
            .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                guard workspace == editor.workspaceFocus, let target else { return }
                withAnimation(.easeOut(duration: AppTheme.Anim.hover)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                editor.mediaPanelScrollTarget = nil
            }
        }
    }
}

// MARK: - Layout math

extension MediaTab {
    func gridDimensions(width: CGFloat) -> GridDimensions {
        let spacing = AppTheme.Spacing.xl
        let outerPadding: CGFloat = AppTheme.Spacing.md * 2
        let usable = max(0, width - outerPadding)
        let cols = max(1, Int(floor((usable + spacing) / (thumbnailSize + spacing))))
        let tileWidth = max(thumbnailSize, (usable - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        return GridDimensions(cols: cols, tileWidth: tileWidth, spacing: spacing)
    }

    func computeLayout(width: CGFloat) -> GridLayoutInfo {
        let dims = gridDimensions(width: width)
        var cells: [MediaCell] = []
        for folder in subfoldersInCurrentFolder {
            cells.append(MediaCell(kind: .folder(folder)))
        }
        for asset in assetsInCurrentFolder {
            cells.append(MediaCell(kind: .asset(asset)))
        }
        return GridLayoutInfo(
            cols: dims.cols, tileWidth: dims.tileWidth, spacing: dims.spacing,
            cells: cells
        )
    }

    func clearSelections() {
        if !editor.selectedMediaAssetIds.isEmpty { editor.selectedMediaAssetIds.removeAll() }
        if !editor.selectedFolderIds.isEmpty { editor.selectedFolderIds.removeAll() }
    }

    func publishOrderedIds(_ ids: [String]) {
        guard workspace == editor.workspaceFocus else { return }
        if editor.mediaPanelOrderedItemIds != ids {
            editor.mediaPanelOrderedItemIds = ids
        }
    }
}

// MARK: - Shared scroll/grid scaffolding (folder + flat modes)

extension MediaTab {
    /// Shared scroll/grid/marquee scaffolding for folder and flat modes.
    @ViewBuilder
    fileprivate func gridScroll<Cell: Identifiable, Content: View>(
        cells: [Cell],
        cols: Int,
        tileWidth: CGFloat,
        spacing: CGFloat,
        topPadding: CGFloat,
        @ViewBuilder cellView: @escaping (Cell) -> Content
    ) -> some View where Cell.ID == String {
        let session = editor.mediaLibrarySession(for: mediaPurpose)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                let columns = Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing), count: max(cols, 1))
                LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                    ForEach(cells) { cell in
                        cellView(cell)
                            .frame(width: tileWidth)
                            .id(cell.id)
                    }
                }
                .padding(AppTheme.Spacing.md)
                .padding(.top, topPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollTargetLayout()
            }
            .scrollPosition(
                id: Binding(
                    get: { session.scrollAnchorID },
                    set: { session.scrollAnchorID = $0 }
                ),
                anchor: .center
            )
            .coordinateSpace(name: "mediaGrid")
            .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                guard workspace == editor.workspaceFocus else { return }
                assetFrames = frames
                if editor.mediaPanelColumnCount != cols { editor.mediaPanelColumnCount = cols }
            }
            .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                guard workspace == editor.workspaceFocus, let target else { return }
                withAnimation(.easeOut(duration: AppTheme.Anim.hover)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                editor.mediaPanelScrollTarget = nil
            }
            .onTapGesture { clearSelections() }
            .overlay { marqueeOverlay }
            .gesture(marqueeGesture)
        }
    }
}

// MARK: - Folder mode (drill-in with breadcrumb)

extension MediaTab {
    var mediaGridView: some View {
        GeometryReader { geo in
            let layout = computeLayout(width: geo.size.width)
            gridScroll(
                cells: layout.cells,
                cols: layout.cols,
                tileWidth: layout.tileWidth,
                spacing: layout.spacing,
                topPadding: AppTheme.Spacing.sm
            ) { cell in
                cellView(for: cell)
            }
        }
    }

    var mediaListView: some View {
        let cells = subfoldersInCurrentFolder.map { MediaCell(kind: .folder($0)) }
            + assetsInCurrentFolder.map { MediaCell(kind: .asset($0)) }
        return listScroll(cells: cells)
    }
}

// MARK: - Flat mode (every asset, no folders)

extension MediaTab {
    var flatGridView: some View {
        let assets = sortAndFilter(editor.mediaAssets)
        return GeometryReader { geo in
            let dims = gridDimensions(width: geo.size.width)
            gridScroll(
                cells: assets,
                cols: dims.cols,
                tileWidth: dims.tileWidth,
                spacing: dims.spacing,
                topPadding: AppTheme.Spacing.sm
            ) { asset in
                assetCellView(for: asset)
            }
        }
    }

    var flatListView: some View {
        listScroll(cells: sortAndFilter(editor.mediaAssets).map { MediaCell(kind: .asset($0)) })
    }
}

// MARK: - Grouped mode (folder sections with dividers)

extension MediaTab {
    var groupedVisibleAssetIDs: [String] {
        let bucketed = editor.mediaAssets.reduce(into: [String?: [MediaAsset]]()) { dict, asset in
            dict[asset.folderId, default: []].append(asset)
        }
        let folders = editor.folders
            .map { ($0, editor.folderPath(for: $0.id).map(\.name).joined(separator: " / ")) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        var ids = collapsedGroupedKeys.contains("")
            ? []
            : sortAndFilter(bucketed[nil] ?? []).map(\.id)
        for (folder, _) in folders where !collapsedGroupedKeys.contains(folder.id) {
            ids.append(contentsOf: sortAndFilter(bucketed[folder.id] ?? []).map(\.id))
        }
        return ids
    }

    var groupedGridView: some View {
        // Bucket once so each section is O(1).
        let bucketed = editor.mediaAssets.reduce(into: [String?: [MediaAsset]]()) { dict, asset in
            dict[asset.folderId, default: []].append(asset)
        }
        let rootAssets = sortAndFilter(bucketed[nil] ?? [])
        // Sort by full path so parents land before children, siblings cluster.
        let allFolders = editor.folders
            .map { ($0, editor.folderPath(for: $0.id).map(\.name).joined(separator: " / ")) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        return GeometryReader { geo in
            let dims = gridDimensions(width: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        if !rootAssets.isEmpty {
                            groupedSection(
                                title: "Library",
                                folderId: nil,
                                assets: rootAssets,
                                tileWidth: dims.tileWidth,
                                spacing: dims.spacing
                            )
                        }
                        ForEach(allFolders, id: \.0.id) { folder, path in
                            let assets = sortAndFilter(bucketed[folder.id] ?? [])
                            groupedSection(
                                title: path,
                                folderId: folder.id,
                                assets: assets,
                                tileWidth: dims.tileWidth,
                                spacing: dims.spacing
                            )
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                }
                .scrollPosition(
                    id: Binding(
                        get: { editor.mediaLibrarySession(for: mediaPurpose).scrollAnchorID },
                        set: { editor.mediaLibrarySession(for: mediaPurpose).scrollAnchorID = $0 }
                    ),
                    anchor: .center
                )
                .coordinateSpace(name: "mediaGrid")
                .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                    guard workspace == editor.workspaceFocus else { return }
                    assetFrames = frames
                    if editor.mediaPanelColumnCount != dims.cols { editor.mediaPanelColumnCount = dims.cols }
                }
                .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                    guard workspace == editor.workspaceFocus, let target else { return }
                    withAnimation(.easeOut(duration: AppTheme.Anim.hover)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    editor.mediaPanelScrollTarget = nil
                }
                .onTapGesture { clearSelections() }
                .overlay { marqueeOverlay }
                .gesture(marqueeGesture)
            }
        }
    }

    @ViewBuilder
    fileprivate func groupedSection(
        title: String,
        folderId: String?,
        assets: [MediaAsset],
        tileWidth: CGFloat,
        spacing: CGFloat
    ) -> some View {
        let sectionKey = folderId ?? ""
        let isCollapsed = collapsedGroupedKeys.contains(sectionKey)
        let isTargeted = Binding<Bool>(
            get: { dropTargetGroupedKey == sectionKey },
            set: { dropTargetGroupedKey = $0 ? sectionKey : nil }
        )
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Button {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.selection)) {
                        if isCollapsed { collapsedGroupedKeys.remove(sectionKey) }
                        else { collapsedGroupedKeys.insert(sectionKey) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                        .hoverHighlight(cornerRadius: AppTheme.Radius.xsSm)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(isCollapsed ? "Expand" : "Collapse")

                if let folderId {
                    Button {
                        openFolder(id: folderId)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "folder.fill")
                                .interfaceFont(size: AppTheme.Typography.ui)
                                .foregroundStyle(AppTheme.Accent.primary.opacity(AppTheme.Opacity.emphasis))
                            groupedSectionTitle(title)
                        }
                        .padding(.horizontal, AppTheme.Spacing.xs)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .hoverHighlight(cornerRadius: AppTheme.Radius.xsSm)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Open \(title)")
                    .contextMenu {
                        Button("Open") {
                            openFolder(id: folderId)
                        }
                        Divider() // app-theme: native-menu-divider
                        Button("Delete", role: .destructive) {
                            editor.deleteFolders(ids: [folderId])
                        }
                        .disabled(!editor.canDeleteFolders(ids: [folderId]))
                    }
                } else {
                    groupedSectionTitle(title)
                }
                Text("\(assets.count)")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }

            if !isCollapsed {
                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: AppTheme.BorderWidth.hairline)

                if assets.isEmpty {
                    Text("Empty")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.vertical, AppTheme.Spacing.sm)
                } else {
                    if assetLayout == .list {
                        LazyVStack(spacing: AppTheme.Spacing.xs) {
                            ForEach(assets) { asset in
                                assetListCellView(for: asset)
                                    .id(asset.id)
                            }
                        }
                        .scrollTargetLayout()
                    } else {
                        let columns = [GridItem(.adaptive(minimum: thumbnailSize), spacing: spacing)]
                        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                            ForEach(assets) { asset in
                                assetCellView(for: asset)
                                    .frame(width: tileWidth)
                                    .id(asset.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(isTargeted.wrappedValue ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : AppTheme.Background.clearColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(isTargeted.wrappedValue ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : AppTheme.Background.clearColor, lineWidth: AppTheme.BorderWidth.thin)
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .text], isTargeted: isTargeted) { providers in
            handleProviderDrop(providers, into: folderId)
            return true
        }
    }

    /// Path with parent segments de-emphasized so the leaf reads as the title.
    @ViewBuilder
    fileprivate func groupedSectionTitle(_ path: String) -> some View {
        let segments = path.components(separatedBy: " / ")
        if segments.count <= 1 {
            Text(path)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
        } else {
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                    if idx > 0 {
                        Text("/")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    Text(segment)
                        .interfaceFont(
                            size: idx == segments.count - 1 ? AppTheme.Typography.ui : AppTheme.Typography.ui,
                            weight: idx == segments.count - 1 ? .semibold : .regular
                        )
                        .foregroundStyle(idx == segments.count - 1 ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Cell renderers (asset + folder)

extension MediaTab {
    func assetCellView(for asset: MediaAsset) -> some View {
        AssetThumbnailView(
            asset: asset,
            onMoveToFolderMenu: AnyView(moveToFolderMenu(for: asset)),
            libraryPurpose: mediaPurpose
        )
        .draggable(dragPayload(for: asset)) {
            dragPreview(for: asset)
        }
        .background(assetFrameReader(for: asset.id))
    }

    func assetListCellView(for asset: MediaAsset) -> some View {
        AssetThumbnailView(
            asset: asset,
            onMoveToFolderMenu: AnyView(moveToFolderMenu(for: asset)),
            style: .list,
            libraryPurpose: mediaPurpose
        )
        .draggable(dragPayload(for: asset)) { dragPreview(for: asset) }
        .background(assetFrameReader(for: asset.id))
    }

    @ViewBuilder
    func listCellView(for cell: MediaCell) -> some View {
        switch cell.kind {
        case .folder(let folder):
            folderListRow(folder)
                .background(assetFrameReader(for: cell.id))
        case .asset(let asset):
            assetListCellView(for: asset)
        }
    }

    private func folderListRow(_ folder: MediaFolder) -> some View {
        let dropHover = Binding<Bool>(
            get: { dropTargetFolderId == folder.id },
            set: { dropTargetFolderId = $0 ? folder.id : nil }
        )
        return MediaFolderListRow(
            folder: folder,
            childCount: editor.subfolders(of: folder.id).count + editor.assetsIn(folderId: folder.id).count,
            isSelected: editor.selectedFolderIds.contains(folder.id),
            isDropTargeted: dropTargetFolderId == folder.id,
            isRenaming: Binding(
                get: { renamingFolderId == folder.id },
                set: { renamingFolderId = $0 ? folder.id : nil }
            ),
            onSelect: { handleFolderTap(folder) },
            onOpen: { openFolder(id: folder.id) },
            onRename: { editor.renameFolder(id: folder.id, name: $0) },
            onDelete: { editor.deleteFolders(ids: [folder.id]) }
        )
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "media.browser.folder.\(folder.id)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .draggable(MediaTab.folderDragString(forFolderId: folder.id)) {
            FolderDragPreview(name: folder.name)
        }
        .onDrop(of: [.fileURL, .text], isTargeted: dropHover) { providers in
            handleProviderDrop(providers, into: folder.id)
            return true
        }
    }

    @ViewBuilder
    func cellView(for cell: MediaCell) -> some View {
        switch cell.kind {
        case .folder(let folder):
            folderTile(folder)
                .background(assetFrameReader(for: cell.id))
        case .asset(let asset):
            assetCellView(for: asset)
        }
    }

    fileprivate func folderTile(_ folder: MediaFolder) -> some View {
        let dropHover = Binding<Bool>(
            get: { dropTargetFolderId == folder.id },
            set: { dropTargetFolderId = $0 ? folder.id : nil }
        )
        return ZStack {
            FolderTileView(
                folder: folder,
                isSelected: editor.selectedFolderIds.contains(folder.id),
                isDropHover: dropTargetFolderId == folder.id,
                canDelete: editor.canDeleteFolders(ids: contextFolderIDs(for: folder)),
                deleteTitle: contextFolderIDs(for: folder).count == 1
                    ? "Delete Folder" : "Delete \(contextFolderIDs(for: folder).count) Folders",
                childCount: editor.subfolders(of: folder.id).count + editor.assetsIn(folderId: folder.id).count,
                isRenaming: Binding(
                    get: { renamingFolderId == folder.id },
                    set: { renamingFolderId = $0 ? folder.id : nil }
                ),
                onTap: { handleFolderTap(folder) },
                onOpen: { openFolder(id: folder.id) },
                onCommitRename: { newName in
                    editor.renameFolder(id: folder.id, name: newName)
                    renamingFolderId = nil
                },
                onCancelRename: { renamingFolderId = nil },
                onDelete: {
                    editor.deleteVisibleMedia(folders: contextFolderIDs(for: folder), assets: [])
                },
                onContextActivate: {
                    focusMediaBrowser()
                    if !editor.selectedVisibleMediaFolderIDs.contains(folder.id) {
                        editor.selectedFolderIds = [folder.id]
                        editor.selectedMediaAssetIds.removeAll()
                    }
                },
                shouldAutoFocus: pendingFolderFocusId == folder.id,
                onAutoFocusConsumed: { pendingFolderFocusId = nil }
            )
            .background {
                if WorkspaceUIAcceptance.isRequested {
                    AppRelaunchClickProbe(identifier: "media.browser.folder.\(folder.id)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .draggable(MediaTab.folderDragString(forFolderId: folder.id)) {
                FolderDragPreview(name: folder.name)
            }
        }
        .onDrop(of: [.fileURL, .text], isTargeted: dropHover) { providers in
            handleProviderDrop(providers, into: folder.id)
            return true
        }
    }

    fileprivate func handleFolderTap(_ folder: MediaFolder) {
        focusMediaBrowser()
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift {
            if editor.selectedFolderIds.contains(folder.id) {
                editor.selectedFolderIds.remove(folder.id)
            } else {
                editor.selectedFolderIds.insert(folder.id)
            }
        } else {
            editor.selectedFolderIds = [folder.id]
            editor.selectedMediaAssetIds.removeAll()
        }
    }

    fileprivate func contextFolderIDs(for folder: MediaFolder) -> Set<String> {
        let selected = editor.selectedVisibleMediaFolderIDs
        return selected.contains(folder.id) ? selected : [folder.id]
    }

    @ViewBuilder
    fileprivate func moveToFolderMenu(for asset: MediaAsset) -> some View {
        let targetIds: Set<String> = editor.selectedVisibleMediaAssetIDs.contains(asset.id)
            ? editor.selectedVisibleMediaAssetIDs
            : [asset.id]
        Menu("Move to Folder") {
            Button("New Folder") {
                let id = editor.createFolder(name: "New Folder", in: currentFolderId)
                editor.moveAssetsToFolder(assetIds: targetIds, folderId: id)
                pendingFolderFocusId = id
                renamingFolderId = id
            }
            if currentFolderId != nil || targetIds.contains(where: { id in editor.mediaAssets.first(where: { $0.id == id })?.folderId != nil }) {
                Button("Library") {
                    editor.moveAssetsToFolder(assetIds: targetIds, folderId: nil)
                }
            }
            Divider() // app-theme: native-menu-divider
            ForEach(editor.folders, id: \.id) { folder in
                Button(folder.name) {
                    editor.moveAssetsToFolder(assetIds: targetIds, folderId: folder.id)
                }
            }
        }
    }

    func assetFrameReader(for id: String) -> some View {
        GeometryReader { geo in
            AppTheme.Background.clearColor.preference(
                key: AssetFramePreferenceKey.self,
                value: [id: geo.frame(in: .named("mediaGrid"))]
            )
        }
    }
}

private struct MediaFolderListRow: View {
    let folder: MediaFolder
    let childCount: Int
    let isSelected: Bool
    let isDropTargeted: Bool
    @Binding var isRenaming: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var draft = ""
    @FocusState private var renameFocused: Bool
    @State private var lastClickTime: Date?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "folder.fill")
                .interfaceFont(size: AppTheme.Typography.title)
                .foregroundStyle(AppTheme.Accent.primary.opacity(AppTheme.Opacity.emphasis))
                .frame(width: AppTheme.ComponentSize.searchThumbnailWidth)
            if isRenaming {
                TextField("Folder", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { isRenaming = false }
            } else {
                Text(folder.name)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            Text("\(childCount)")
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(
            isSelected || isDropTargeted
                ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint)
                : AppTheme.Background.clearColor,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
        )
        .contentShape(Rectangle())
        .onTapGesture { handleClick() }
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Rename") { beginRename() }
            Divider()
            Button("Remove", role: .destructive, action: onDelete)
        }
        .onChange(of: isRenaming) { _, value in
            if value { beginRename() }
        }
        .onChange(of: renameFocused) { _, value in
            if !value { commitRename() }
        }
    }

    private func beginRename() {
        draft = folder.name
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != folder.name { onRename(name) }
        isRenaming = false
    }

    private func handleClick() {
        let now = Date()
        if let lastClickTime, now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval {
            onOpen()
            self.lastClickTime = nil
        } else {
            onSelect()
            lastClickTime = now
        }
    }
}

// MARK: - File-private supporting views/types

struct AssetFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct FolderDragPreview: View {
    let name: String
    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "folder.fill")
                .foregroundStyle(AppTheme.Accent.primary)
            Text(name)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .shadow(AppTheme.Shadow.floating)
    }
}
