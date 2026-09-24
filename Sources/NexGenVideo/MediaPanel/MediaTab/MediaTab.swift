import SwiftUI

struct MediaTab: View {
    @Environment(EditorViewModel.self) var editor
    let workspace: EditorViewModel.WorkspaceFocus

    var mediaPurpose: MediaLibraryPurpose {
        workspace == .media ? .workspace : .editSource
    }

    // Toolbar state
    @State var sortMode: SortMode = .dateAdded
    @State var filterTypes: Set<ClipType> = []
    @State var filterAI = false
    @State var searchQuery: String = ""
    @State var searchScope: MediaLibrarySearchScope = .filename
    @State var thumbnailSize: Double = Double(AppTheme.MediaPanel.thumbnailSmall)
    @State var viewMode: ViewMode = .folder
    @State var assetLayout: MediaLibraryLayout = .grid
    @State var sortAscending = true

    // Navigation + selection state
    @State var currentFolderId: String? = nil
    @State var folderReturnViewMode: ViewMode?
    @State var renamingFolderId: String?
    @State var pendingFolderFocusId: String?
    @State var dropTargetFolderId: String?
    /// Hovered grouped-section key; "" = root.
    @State var dropTargetGroupedKey: String?
    /// Collapsed grouped-section keys; "" = root.
    @State var collapsedGroupedKeys: Set<String> = []

    // Drop + marquee
    @State var isDropTargeted = false
    @State var visualHits: [VisualSearch.Hit] = []
    @State var spokenHits: [TranscriptSearch.Hit] = []
    @State var documentHits: [DocumentSearch.Hit] = []
    @State var collapsedSearchSections: Set<String> = []
    @State var momentSearchTask: Task<Void, Never>?
    @State var assetFrames: [String: CGRect] = [:]
    @State var marqueeSelection = MarqueeSelection()

    @State private var mediaPanelHeight: CGFloat = 600

    enum ViewMode: String, CaseIterable {
        case folder, flat, grouped

        var title: String {
            switch self {
            case .folder: "Folders"
            case .flat: "Flat"
            case .grouped: "Grouped"
            }
        }

        var systemImage: String {
            switch self {
            case .folder: "folder"
            case .flat: "square.grid.2x2"
            case .grouped: "rectangle.split.1x2"
            }
        }
    }

    /// Only media types that can actually appear in the panel. ClipType.text
    /// exists for timeline clips but is never assigned to a MediaAsset.
    private static let filterableTypes: [ClipType] = [.video, .audio, .image, .document, .lottie]

    private enum ThumbnailPreset: String, CaseIterable, Identifiable {
        case small, medium, large, xlarge
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case .xlarge: "Extra Large"
            }
        }
        var size: Double {
            switch self {
            case .small: Double(AppTheme.MediaPanel.thumbnailSmall)
            case .medium: Double(AppTheme.MediaPanel.thumbnailMedium)
            case .large: Double(AppTheme.MediaPanel.thumbnailLarge)
            case .xlarge: Double(AppTheme.MediaPanel.thumbnailExtraLarge)
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            toolbar

            if editor.pendingSwapClipId != nil {
                swapBanner
            }

            ZStack(alignment: .top) {
                MediaPanelDropArea(
                    isTargeted: $isDropTargeted,
                    onDrop: { urls in handlePanelFinderDrop(urls: urls) }
                ) {
                    VStack(spacing: AppTheme.Spacing.none) {
                        if showsEmptyState {
                            emptyStateView
                        } else if !trimmedSearchQuery.isEmpty {
                            searchResults
                        } else {
                            switch (viewMode, assetLayout) {
                            case (.folder, .grid): mediaGridView
                            case (.folder, .list): mediaListView
                            case (.flat, .grid): flatGridView
                            case (.flat, .list): flatListView
                            case (.grouped, _): groupedGridView
                            }
                        }
                    }
                }
                .overlay {
                    if isDropTargeted { dropHighlight.allowsHitTesting(false) }
                }
                .overlay(alignment: .bottom) {
                    if let toast = editor.mediaPanelToast {
                        toastBanner(toast)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: AppTheme.Anim.transition), value: editor.mediaPanelToast)
            }
            .layoutPriority(1)
            .onChange(of: searchQuery) { _, _ in scheduleMomentSearch() }
            .onChange(of: searchScope) { _, _ in scheduleMomentSearch() }
            .onChange(of: filterTypes) { _, _ in scheduleMomentSearch() }
            .onChange(of: filterAI) { _, _ in scheduleMomentSearch() }
            .onChange(of: currentFolderId) { _, _ in scheduleMomentSearch() }
            .onChange(of: viewMode) { _, _ in scheduleMomentSearch() }
            .onChange(of: momentSearchAssetRevision) { _, _ in scheduleMomentSearch() }

            if editor.showGenerationPanel && !mediaAreaCollapsed {
                GenerationView(
                    maxPanelHeight: generationPanelMaxHeight,
                    workspace: workspace
                )
                    .frame(maxHeight: CGFloat(generationPanelMaxHeight), alignment: .bottom)
                    .tourAnchor(.generation)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            mediaPanelHeight = newValue
        }
        .onChange(of: visibleMediaPanelItemIDs, initial: true) { _, ids in
            publishOrderedIds(ids)
        }
        .onExitCommand { if editor.pendingSwapClipId != nil { editor.cancelMediaSwap() } }
        .background(KeyCommandSink(onNewFolder: createNewFolderInCurrent, onNavigateUp: navigateUp))
        .simultaneousGesture(TapGesture().onEnded {
            guard workspace == editor.workspaceFocus else { return }
            focusMediaBrowser()
        })
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(
                    identifier: "media.listMode",
                    acceptanceState: viewMode == .folder && currentFolderId == nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: editor.folders.map(\.id)) { _, _ in pruneStaleFolderState() }
        .onChange(of: editor.mediaPanelRevealAssetId) { _, target in
            guard workspace == editor.workspaceFocus, let target else { return }
            revealAsset(id: target)
            editor.mediaPanelRevealAssetId = nil
        }
        .onChange(of: editor.mediaPanelOpenFolderId, initial: true) { _, target in
            guard workspace == editor.workspaceFocus, let target else { return }
            if target == MediaWorkspaceNavigation.rootRouteID {
                navigateToFolder(nil)
            } else {
                openFolder(
                    id: target,
                    preservingSelection: editor.mediaCommandFocus == .folderTree
                )
            }
            editor.mediaPanelOpenFolderId = nil
        }
        .onChange(of: editor.mediaPanelPasteRequestTick) { _, _ in
            guard workspace == editor.workspaceFocus else { return }
            handleClipboardPaste()
        }
        .onChange(of: currentFolderId) { _, folderId in
            editor.publishMediaPanelFolder(folderId, for: workspace)
            editor.mediaLibrarySession(for: mediaPurpose).folderID = folderId
        }
        .onAppear {
            let session = editor.mediaLibrarySession(for: mediaPurpose)
            searchQuery = session.query
            searchScope = session.searchScope
            filterTypes = session.filterTypes
            filterAI = session.aiOnly
            sortMode = SortMode(session.sort)
            sortAscending = session.sortAscending
            thumbnailSize = session.thumbnailSize
            assetLayout = session.layout
            session.initializeFolderIfNeeded(editor.mediaPanelCurrentFolderId)
            currentFolderId = session.folderID
            editor.publishMediaPanelFolder(currentFolderId, for: workspace)
            if let target = editor.mediaPanelRevealAssetId, workspace == editor.workspaceFocus {
                revealAsset(id: target)
                editor.mediaPanelRevealAssetId = nil
            } else if let anchor = session.scrollAnchorID {
                DispatchQueue.main.async { editor.mediaPanelScrollTarget = anchor }
            }
        }
        .onChange(of: searchQuery) { _, value in editor.mediaLibrarySession(for: mediaPurpose).query = value }
        .onChange(of: searchScope) { _, value in editor.mediaLibrarySession(for: mediaPurpose).searchScope = value }
        .onChange(of: filterTypes) { _, value in editor.mediaLibrarySession(for: mediaPurpose).filterTypes = value }
        .onChange(of: filterAI) { _, value in editor.mediaLibrarySession(for: mediaPurpose).aiOnly = value }
        .onChange(of: sortMode) { _, value in editor.mediaLibrarySession(for: mediaPurpose).sort = value.librarySort }
        .onChange(of: sortAscending) { _, value in editor.mediaLibrarySession(for: mediaPurpose).sortAscending = value }
        .onChange(of: thumbnailSize) { _, value in editor.mediaLibrarySession(for: mediaPurpose).thumbnailSize = value }
        .onChange(of: assetLayout) { _, value in editor.mediaLibrarySession(for: mediaPurpose).layout = value }
        .onChange(of: editor.selectedMediaAssetIds) { _, value in
            guard workspace == editor.workspaceFocus else { return }
            editor.mediaLibrarySession(for: mediaPurpose).selectedAssetIDs = value
        }
        .onChange(of: editor.sourcePreviewStates) { _, _ in
            guard workspace == editor.workspaceFocus, let asset = editor.activeSourceAsset else { return }
            let session = editor.mediaLibrarySession(for: mediaPurpose)
            session.activeAssetID = asset.id
            session.rememberSourceState(editor.sourcePreviewState(for: asset.id), for: asset.id)
        }
    }

    private var swapBanner: some View {
        let tint = Color(nsColor: (editor.pendingSwapClip?.mediaType ?? .video).themeColor)
        return HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "arrow.left.arrow.right")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(tint)
            Text("Pick a replacement for \"\(editor.pendingSwapClipName ?? "clip")\"")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button("Cancel") { editor.cancelMediaSwap() }
                .buttonStyle(.plain)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(tint.opacity(AppTheme.Opacity.faint))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(AppTheme.Opacity.muted))
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private func toastBanner(_ toast: MediaPanelToast) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(toast.kind == .success ? AppTheme.Status.successColor : AppTheme.Accent.timecodeColor)
            Text(toast.message)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.prominentColor)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.bottom, AppTheme.Spacing.lgXl)
        .onTapGesture { editor.dismissMediaPanelToast() }
        .task(id: toast) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            editor.dismissMediaPanelToast()
        }
    }

    /// If the current folder, rename target, or hover target has been deleted,
    /// drop them back to safe defaults. Pops drilled-in views to root.
    private func pruneStaleFolderState() {
        if let id = currentFolderId, editor.folder(id: id) == nil { navigateToFolder(nil) }
        if let id = renamingFolderId, editor.folder(id: id) == nil { renamingFolderId = nil }
        if let id = pendingFolderFocusId, editor.folder(id: id) == nil { pendingFolderFocusId = nil }
        if let id = dropTargetFolderId, editor.folder(id: id) == nil { dropTargetFolderId = nil }
    }

    private func revealAsset(id: String) {
        guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else { return }
        if !assetMatchesRevealState(asset) {
            clearFilters()
            searchQuery = ""
        }
        if viewMode == .folder, currentFolderId != asset.folderId {
            currentFolderId = asset.folderId
        }
        // Auto-expand the asset's grouped section so the scroll target exists.
        if viewMode == .grouped {
            collapsedGroupedKeys.remove(asset.folderId ?? "")
        }
        let session = editor.mediaLibrarySession(for: mediaPurpose)
        session.folderID = asset.folderId
        editor.selectMediaAsset(asset, for: mediaPurpose)
        editor.mediaPanelScrollTarget = id
    }

    private func assetMatchesRevealState(_ asset: MediaAsset) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty || searchScope == .filename else { return false }
        return passesFilters(asset)
    }

    func focusMediaBrowser() {
        if editor.mediaCommandFocus == .folderTree {
            editor.selectedFolderIds.removeAll()
        }
        editor.focusedPanel = workspace == .media ? .preview : .media
        editor.mediaCommandFocus = .browser
    }

    func openFolder(id: String, preservingSelection: Bool = false) {
        guard editor.folder(id: id) != nil else { return }
        if viewMode != .folder {
            folderReturnViewMode = viewMode
        }
        currentFolderId = id
        viewMode = .folder
        if !preservingSelection { editor.selectedFolderIds.removeAll() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            actionsRow
            searchControlsRow
            contextBar
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.top, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.xs)
        .background(AppTheme.Background.surfaceColor)
    }

    private var actionsRow: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            toolbarButton(title: "Import", systemImage: "plus", action: importMedia)
                .help("Copy media into the project")
                .tourAnchor(.importButton)
            toolbarButton(title: "Generate", systemImage: "sparkles", filled: true, accentStyle: AnyShapeStyle(AppTheme.aiGradient), action: toggleGenerationPanel)
                .tourAnchor(.generateButton)

            overflowMenu

            Spacer(minLength: 0)

            searchIndexStatus
                .tourAnchor(.smartSearch)
        }
        .frame(minHeight: AppTheme.Layout.panelHeaderHeight)
    }

    private var searchControlsRow: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            searchField
                .layoutPriority(1)

            displayControls
        }
        .frame(minHeight: AppTheme.Layout.panelHeaderHeight)
    }

    // MARK: - Context bar (breadcrumb + count)

    var breadcrumbItems: [BreadcrumbItem] {
        var items: [BreadcrumbItem] = [BreadcrumbItem(folderId: nil, name: "Library")]
        for f in editor.folderPath(for: currentFolderId) {
            items.append(BreadcrumbItem(folderId: f.id, name: f.name))
        }
        return items
    }

    struct BreadcrumbItem: Identifiable {
        let folderId: String?
        let name: String
        var id: String { folderId ?? "__root__" }
    }

    private var contextBar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            contextPath
                .layoutPriority(1)

            Spacer(minLength: AppTheme.Spacing.xs)

            itemCountText
        }
        .frame(height: AppTheme.MediaPanel.contextRowHeight)
    }

    @ViewBuilder
    private var contextPath: some View {
        if viewMode == .folder {
            breadcrumbBar
        } else {
            Text(viewMode.title)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(Array(breadcrumbItems.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .interfaceFont(size: AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    breadcrumbChip(item: item, isLeaf: idx == breadcrumbItems.count - 1)
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var displayControls: some View {
        toolbarMenuIcon(
            systemName: "rectangle.grid.2x2",
            acceptanceIdentifier: "media.layout",
            acceptanceState: assetLayout == .list
        ) {
            Section("Layout") {
                Button {
                    assetLayout = .grid
                } label: {
                    Label("Grid", systemImage: assetLayout == .grid ? "checkmark" : "rectangle.grid.2x2")
                }
                Button {
                    assetLayout = .list
                } label: {
                    Label("List", systemImage: assetLayout == .list ? "checkmark" : "list.bullet")
                }
            }
            Divider() // app-theme: native-menu-divider
            Section("View") {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button {
                        setViewMode(mode)
                    } label: {
                        Label(mode.title, systemImage: viewMode == mode ? "checkmark" : mode.systemImage)
                    }
                }
            }
            Divider() // app-theme: native-menu-divider
            Section("Thumbnail Size") {
                ForEach(ThumbnailPreset.allCases) { preset in
                    Button {
                        thumbnailSize = preset.size
                    } label: {
                        Label(preset.title, systemImage: thumbnailSize == preset.size ? "checkmark" : "")
                    }
                }
            }
        }

        toolbarMenuIcon(
            systemName: "arrow.up.arrow.down",
            acceptanceIdentifier: "media.sort",
            acceptanceState: sortMode == .name
        ) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button {
                        if sortMode == mode {
                            sortAscending.toggle()
                        } else {
                            sortMode = mode
                            sortAscending = true
                        }
                    } label: {
                        Label(mode.title, systemImage: sortMode == mode ? "checkmark" : "")
                    }
                }
        }

        toolbarMenuIcon(
            systemName: "line.3.horizontal.decrease",
            foregroundStyle: hasActiveFilters ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor,
            acceptanceIdentifier: "media.filter",
            acceptanceState: filterTypes.contains(.video)
        ) {
            ForEach(Self.filterableTypes, id: \.self) { type in
                Button { toggleFilter(type) } label: {
                    Label(
                        type == .document ? "Text" : type.trackLabel,
                        systemImage: filterTypes.contains(type) ? "checkmark" : ""
                    )
                }
            }
            Divider() // app-theme: native-menu-divider
            Button { filterAI.toggle() } label: {
                Label("AI Generated", systemImage: filterAI ? "checkmark" : "")
            }
            Divider() // app-theme: native-menu-divider
            Button("Clear Filters", action: clearFilters)
        }
    }

    private func breadcrumbChip(item: BreadcrumbItem, isLeaf: Bool) -> some View {
        let textColor = isLeaf ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor
        return Button {
            if !isLeaf { navigateToFolder(item.folderId) }
        } label: {
            Text(item.name)
                .interfaceFont(size: AppTheme.Typography.ui, weight: isLeaf ? .semibold : .regular)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .hoverHighlight(cornerRadius: AppTheme.Radius.xsSm)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onDrop(of: [.fileURL, .text], isTargeted: nil) { providers in
            handleProviderDrop(providers, into: item.folderId)
            return true
        }
    }

    // MARK: - Selection / state derivations

    var selectedMediaAssetsInOrder: [MediaAsset] {
        editor.mediaAssets.filter { editor.selectedMediaAssetIds.contains($0.id) }
    }

    var visibleMediaPanelItemIDs: [String] {
        if showsEmptyState { return [] }
        if !trimmedSearchQuery.isEmpty { return visibleSearchResultAssetIDs }
        switch viewMode {
        case .folder:
            return subfoldersInCurrentFolder.map { MediaPanelItemKey.folder($0.id) }
                + assetsInCurrentFolder.map(\.id)
        case .flat:
            return sortAndFilter(editor.mediaAssets).map(\.id)
        case .grouped:
            return groupedVisibleAssetIDs
        }
    }

    private var showsEmptyState: Bool {
        editor.mediaAssets.isEmpty && editor.folders.isEmpty && !editor.showGenerationPanel
    }

    // MARK: - Sort & Filter

    enum SortMode: CaseIterable {
        case name, dateAdded, duration, type

        var title: String {
            switch self {
            case .name: "Name"
            case .dateAdded: "Date Added"
            case .duration: "Duration"
            case .type: "Type"
            }
        }

        init(_ sort: MediaLibrarySort) {
            switch sort {
            case .name: self = .name
            case .dateAdded: self = .dateAdded
            case .duration: self = .duration
            case .type: self = .type
            }
        }

        var librarySort: MediaLibrarySort {
            switch self {
            case .name: .name
            case .dateAdded: .dateAdded
            case .duration: .duration
            case .type: .type
            }
        }
    }

    private var hasActiveFilters: Bool {
        !filterTypes.isEmpty || filterAI
    }

    private func toggleFilter(_ type: ClipType) {
        if filterTypes.contains(type) {
            filterTypes.remove(type)
        } else {
            filterTypes.insert(type)
        }
    }

    private func clearFilters() {
        filterTypes.removeAll()
        filterAI = false
    }

    var assetsInCurrentFolder: [MediaAsset] {
        sortAndFilter(editor.assetsIn(folderId: currentFolderId))
    }

    var subfoldersInCurrentFolder: [MediaFolder] {
        let folders = editor.subfolders(of: currentFolderId)
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    func passesFilters(_ asset: MediaAsset) -> Bool {
        MediaLibraryProjection.matchesFilters(
            asset,
            query: searchQuery,
            searchScope: searchScope,
            filterTypes: filterTypes,
            aiOnly: filterAI
        )
    }

    var momentSearchAssetRevision: [String] {
        editor.mediaAssets.map {
            "\($0.id)|\($0.folderId ?? "")|\($0.type.rawValue)|\($0.isGenerated)"
        }
    }

    func sortAndFilter(_ assets: [MediaAsset]) -> [MediaAsset] {
        let filtered = assets.filter(passesFilters)
        var sorted = switch sortMode {
        case .dateAdded: filtered
        case .name: filtered.sorted { $0.userFacingFilename.localizedCaseInsensitiveCompare($1.userFacingFilename) == .orderedAscending }
        case .duration: filtered.sorted { $0.duration < $1.duration }
        case .type: filtered.sorted { $0.type.rawValue < $1.type.rawValue }
        }
        if !sortAscending { sorted.reverse() }
        return sorted
    }

    private var currentFolderItemCount: Int {
        subfoldersInCurrentFolder.count + assetsInCurrentFolder.count
    }

    // MARK: - Toolbar helpers

    private var itemCountText: some View {
        Text(currentFolderItemCount == 1 ? "1 item" : "\(currentFolderItemCount) items")
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(AppTheme.Text.mutedColor)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.plain)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .background {
                    if WorkspaceUIAcceptance.isRequested {
                        AppRelaunchClickProbe(
                            identifier: "media.search",
                            acceptanceState: searchQuery == "selection"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }
                }
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Clear search")
            }
            Menu {
                ForEach(MediaLibrarySearchScope.allCases, id: \.self) { scope in
                    Button {
                        searchScope = scope
                    } label: {
                        Label(scope.label, systemImage: searchScope == scope ? "checkmark" : "")
                    }
                }
            } label: {
                Text(searchScope.label)
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Search scope")
        }
        .padding(.leading, AppTheme.Spacing.smMd)
        .padding(.trailing, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func toolbarButton(
        title: String,
        systemImage: String,
        filled: Bool = false,
        accentStyle: AnyShapeStyle? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: systemImage)
                Text(title)
            }
        }
        .buttonStyle(.capsule(filled ? .prominent : .secondary, fill: accentStyle))
        .focusable(false)
        .help(title)
    }

    private var mediaAreaCollapsed: Bool {
        !editor.mediaPanelVisible
            || (editor.maximizedPanel != nil && editor.maximizedPanel != .media)
    }

    private var generationPanelMaxHeight: Double {
        Double(max(0, mediaPanelHeight - AppTheme.GenerationPanel.mediaAreaMinHeight))
    }

    private func toggleGenerationPanel() {
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            editor.showGenerationPanel.toggle()
        }
    }

    private var overflowMenu: some View {
        let canOrganize = !editor.mediaAssets.isEmpty
        return toolbarMenuIcon(systemName: "ellipsis") {
            Button(action: createNewFolderInCurrent) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            if canOrganize {
                Button(action: organizeWithAgent) {
                    Label("Organize with Agent", systemImage: "wand.and.stars")
                }
            }
        }
    }

    private func organizeWithAgent() {
        let folderHint = currentFolderId.map { _ in " Work within the current folder." } ?? ""
        let service = editor.agentService
        service.newChat()
        service.draft = "Organize my media library. Review the assets, group related ones into clearly named folders, and give generically-named assets short descriptive names — inspect an asset when its name is unclear. Don't delete anything or change the timeline.\(folderHint)"
        editor.agentPanelVisible = true
    }

    private func toolbarMenuIcon<Content: View>(
        systemName: String,
        foregroundStyle: some ShapeStyle = AppTheme.Text.tertiaryColor,
        acceptanceIdentifier: String? = nil,
        acceptanceState: Bool? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            Image(systemName: systemName)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(foregroundStyle)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .hoverHighlight()
        .background {
            if WorkspaceUIAcceptance.isRequested, let acceptanceIdentifier {
                AppRelaunchClickProbe(
                    identifier: acceptanceIdentifier,
                    acceptanceState: acceptanceState
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Folder commands

    private func createNewFolderInCurrent() {
        let id = editor.createFolder(name: "New Folder", in: currentFolderId)
        pendingFolderFocusId = id
        renamingFolderId = id
    }

    private func navigateUp() {
        guard let id = currentFolderId, let folder = editor.folder(id: id) else { return }
        navigateToFolder(folder.parentFolderId)
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        folderReturnViewMode = nil
    }

    func navigateToFolder(_ folderId: String?) {
        currentFolderId = folderId
        if folderId == nil, let returnMode = folderReturnViewMode {
            viewMode = returnMode
            folderReturnViewMode = nil
        }
    }

    // MARK: - Marquee Selection

    var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("mediaGrid"))
            .onChanged { value in
                if !marqueeSelection.isActive {
                    let startOnCell = assetFrames.values.contains { $0.contains(value.startLocation) }
                    if startOnCell { return }
                    let extending = NSEvent.modifierFlags.contains(.shift)
                    marqueeSelection.begin(
                        baseAssets: extending ? editor.selectedMediaAssetIds : [],
                        baseFolders: extending ? editor.selectedFolderIds : []
                    )
                }

                let rect = marqueeRect(from: value)
                marqueeSelection.rect = rect
                var assetIds = marqueeSelection.baseAssets
                var folderIds = marqueeSelection.baseFolders

                // Frame keys are either raw asset ids or "folder-<id>".
                for (id, frame) in assetFrames where rect.intersects(frame) {
                    if let folderId = MediaCell.folderId(fromFrameKey: id) {
                        folderIds.insert(folderId)
                    } else {
                        assetIds.insert(id)
                    }
                }

                if assetIds != editor.selectedMediaAssetIds {
                    editor.selectedMediaAssetIds = assetIds
                }
                if folderIds != editor.selectedFolderIds {
                    editor.selectedFolderIds = folderIds
                }
            }
            .onEnded { _ in
                marqueeSelection.reset()
            }
    }

    @ViewBuilder
    var marqueeOverlay: some View {
        if let rect = marqueeSelection.rect {
            Rectangle()
                .stroke(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong), style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thin, dash: AppTheme.Border.shortDash))
                .background(Rectangle().fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.soft)))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private func marqueeRect(from value: DragGesture.Value) -> CGRect {
        CGRect(
            x: min(value.startLocation.x, value.location.x),
            y: min(value.startLocation.y, value.location.y),
            width: abs(value.location.x - value.startLocation.x),
            height: abs(value.location.y - value.startLocation.y)
        )
    }

    // MARK: - Empty state + drop highlight

    private var emptyStateView: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Spacer()

            Image(systemName: "photo.on.rectangle.angled")
                .interfaceFont(size: AppTheme.Typography.hero, weight: AppTheme.FontWeight.light)
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            VStack(spacing: AppTheme.Spacing.xs) {
                Text("No media yet")
                    .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.light)
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)

                Text("Drop files here or copy them into the project")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
            .strokeBorder(
                AppTheme.Accent.primary.opacity(AppTheme.Opacity.disabled),
                style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thick, dash: AppTheme.Border.longDash)
            )
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.subtle))
            )
            .padding(AppTheme.Spacing.xs)
    }

    // MARK: - Import

    private func importMedia() {
        MediaImportFlow.present(editor: editor, destinationFolderId: currentFolderId)
    }
}

// MARK: - Marquee state

struct MarqueeSelection {
    var rect: CGRect?
    var isActive = false
    var baseAssets: Set<String> = []
    var baseFolders: Set<String> = []

    mutating func begin(baseAssets: Set<String>, baseFolders: Set<String>) {
        isActive = true
        self.baseAssets = baseAssets
        self.baseFolders = baseFolders
    }

    mutating func reset() {
        rect = nil
        isActive = false
        baseAssets = []
        baseFolders = []
    }
}

// MARK: - Cmd+Shift+N / Cmd+Up keyboard shortcuts

private struct KeyCommandSink: NSViewRepresentable {
    let onNewFolder: () -> Void
    let onNavigateUp: () -> Void

    func makeNSView(context: Context) -> SinkView {
        let v = SinkView()
        v.onNewFolder = onNewFolder
        v.onNavigateUp = onNavigateUp
        return v
    }

    func updateNSView(_ nsView: SinkView, context: Context) {
        nsView.onNewFolder = onNewFolder
        nsView.onNavigateUp = onNavigateUp
    }

    final class SinkView: NSView {
        var onNewFolder: (() -> Void)?
        var onNavigateUp: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            if cmd, shift, event.charactersIgnoringModifiers?.lowercased() == "n" {
                onNewFolder?()
                return
            }
            if cmd, event.keyCode == 126 {
                onNavigateUp?()
                return
            }
            super.keyDown(with: event)
        }
    }
}
