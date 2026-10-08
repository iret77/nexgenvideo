import SwiftUI

struct MediaTab: View {
    @Environment(EditorViewModel.self) var editor
    @Environment(\.projectPalette) private var palette
    let workspace: EditorViewModel.WorkspaceFocus

    var browserState: MediaBrowserState { editor.mediaBrowserState(for: workspace) }
    var scrollAssetBinding: Binding<String?> {
        Binding(get: { browserState.scrollAssetID }, set: { browserState.scrollAssetID = $0 })
    }

    var sortMode: SortMode {
        get { browserState.sortMode }
        nonmutating set { browserState.sortMode = newValue }
    }
    var filterTypes: Set<ClipType> {
        get { browserState.filterTypes }
        nonmutating set { browserState.filterTypes = newValue }
    }
    var filterAI: Bool {
        get { browserState.filterAI }
        nonmutating set { browserState.filterAI = newValue }
    }
    var searchQuery: String {
        get { browserState.searchQuery }
        nonmutating set { browserState.searchQuery = newValue }
    }
    var thumbnailSize: Double {
        get { browserState.thumbnailSize }
        nonmutating set { browserState.thumbnailSize = newValue }
    }
    var viewMode: ViewMode {
        get { browserState.viewMode }
        nonmutating set { browserState.viewMode = newValue }
    }

    // Navigation + selection state
    var currentFolderId: String? {
        get { browserState.currentFolderId }
        nonmutating set { browserState.currentFolderId = newValue }
    }
    var folderReturnViewMode: ViewMode? {
        get { browserState.folderReturnViewMode }
        nonmutating set { browserState.folderReturnViewMode = newValue }
    }
    @State var renamingFolderId: String?
    @State var pendingFolderFocusId: String?
    @State var dropTargetFolderId: String?
    /// Hovered grouped-section key; "" = root.
    @State var dropTargetGroupedKey: String?
    /// Collapsed grouped-section keys; "" = root.
    var collapsedGroupedKeys: Set<String> {
        get { browserState.collapsedGroupedKeys }
        nonmutating set { browserState.collapsedGroupedKeys = newValue }
    }

    // Drop + marquee
    @State var isDropTargeted = false
    @State var visualHits: [VisualSearch.Hit] = []
    @State var spokenHits: [TranscriptSearch.Hit] = []
    @State var documentSearch = DocumentContentSearch.Result()
    @State var isSearchingContents = false
    @State var collapsedSearchSections: Set<String> = []
    @State var momentSearchTask: Task<Void, Never>?
    @State var assetFrames: [String: CGRect] = [:]
    @State var marqueeSelection = MarqueeSelection()

    @State private var mediaPanelHeight: CGFloat = 600

    typealias ViewMode = MediaBrowserViewMode

    private static let filterableTypes: [ClipType] = [.video, .audio, .image, .subtitle, .document, .lottie]


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
            case .small: AppTheme.MediaPanel.thumbnailSmall
            case .medium: AppTheme.MediaPanel.thumbnailMedium
            case .large: AppTheme.MediaPanel.thumbnailLarge
            case .xlarge: AppTheme.MediaPanel.thumbnailXlarge
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
                            switch viewMode {
                            case .folder: mediaGridView
                            case .flat: flatGridView
                            case .grouped: groupedGridView
                            case .list: mediaListView
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
            .onChange(of: filterTypes) { _, _ in scheduleMomentSearch() }
            .onChange(of: filterAI) { _, _ in scheduleMomentSearch() }
            .onChange(of: editor.mediaAssets.map(\.id)) { _, _ in scheduleMomentSearch() }
            .onChange(of: editor.mediaAssets.map(\.url)) { _, _ in scheduleMomentSearch() }

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
        .onExitCommand { if editor.pendingSwapClipId != nil { editor.cancelMediaSwap() } }
        .background {
            if workspace == .media {
                KeyCommandSink(onNewFolder: createNewFolderInCurrent, onNavigateUp: navigateUp)
            }
        }
        .onChange(of: browserState.pendingRenameFolderID, initial: true) { _, id in
            guard workspace == editor.workspaceFocus, let id, editor.folder(id: id) != nil else { return }
            pendingFolderFocusId = id
            renamingFolderId = id
            browserState.pendingRenameFolderID = nil
        }
        .onChange(of: editor.folders.map(\.id)) { _, _ in pruneStaleFolderState() }
        .onChange(of: editor.mediaPanelRevealAssetId, initial: true) { _, target in
            guard workspace == editor.workspaceFocus, let target else { return }
            revealAsset(id: target)
            editor.mediaPanelRevealAssetId = nil
        }
        .onChange(of: editor.mediaFolderNavigationRequest, initial: true) { _, request in
            guard let request, request.workspace == workspace, workspace == editor.workspaceFocus else { return }
            if let id = request.folderID, editor.folder(id: id) == nil { return }
            currentFolderId = request.folderID
            searchQuery = ""
            if viewMode != .list { viewMode = .folder }
            editor.mediaFolderNavigationRequest = nil
        }
        .onChange(of: editor.mediaPanelOpenFolderId, initial: true) { _, target in
            guard workspace == editor.workspaceFocus, let target else { return }
            openFolder(id: target)
            editor.mediaPanelOpenFolderId = nil
        }
        .onChange(of: editor.mediaPanelPasteRequestTick) { _, _ in
            guard workspace == editor.workspaceFocus else { return }
            handleClipboardPaste()
        }
        .onChange(of: currentFolderId, initial: true) { _, folderId in
            editor.publishMediaPanelFolder(folderId, for: workspace)
        }
        .confirmationDialog(
            "Choose an Audio Track",
            isPresented: Binding(
                get: { editor.pendingAudioTrackSelection != nil },
                set: { presented in
                    if !presented, editor.pendingAudioTrackSelection != nil {
                        editor.cancelAudioTrackSelection()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let request = editor.pendingAudioTrackSelection {
                ForEach(request.tracks) { track in
                    Button(track.label) { editor.selectAudioTrack(track) }
                }
            }
            Button("Cancel", role: .cancel) { editor.cancelAudioTrackSelection() }
        } message: {
            if let request = editor.pendingAudioTrackSelection {
                Text("\"\(request.sourceName)\" contains multiple audio tracks.")
            }
        }
        .onAppear {
            editor.publishMediaPanelFolder(currentFolderId, for: workspace)
            scheduleMomentSearch()
        }
        .onDisappear { momentSearchTask?.cancel() }

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
        if sortAndFilter([asset]).isEmpty {
            clearFilters()
            searchQuery = ""
        }
        if (viewMode == .folder || viewMode == .list), currentFolderId != asset.folderId {
            currentFolderId = asset.folderId
        }
        // Auto-expand the asset's grouped section so the scroll target exists.
        if viewMode == .grouped {
            collapsedGroupedKeys.remove(asset.folderId ?? "")
        }
        editor.mediaPanelScrollTarget = id
    }

    func openFolder(id: String) {
        guard editor.folder(id: id) != nil else { return }
        if viewMode != .folder {
            folderReturnViewMode = viewMode
        }
        currentFolderId = id
        viewMode = .folder
        editor.selectedFolderIds.removeAll()
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
        WrapLayout(spacing: AppTheme.Spacing.xs) {
            creationActions
            organizationActions
            searchIndexStatus.tourAnchor(.smartSearch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: AppTheme.Layout.panelHeaderHeight)
    }

    @ViewBuilder
    private var creationActions: some View {
        toolbarButton(title: "Import", systemImage: "plus", action: importMedia)
            .help("Copy media into the project")
            .tourAnchor(.importButton)
        toolbarButton(title: "Generate", systemImage: "sparkles", isSelected: editor.showGenerationPanel, action: toggleGenerationPanel)
            .help(editor.showGenerationPanel ? "Hide generator" : "Open generator")
            .accessibilityValue(editor.showGenerationPanel ? "Shown" : "Hidden")
            .tourAnchor(.generateButton)
    }

    @ViewBuilder
    private var organizationActions: some View {
        if workspace == .media {
            toolbarButton(title: "New Folder", systemImage: "folder.badge.plus", action: createNewFolderInCurrent)
            if !editor.mediaAssets.isEmpty {
                toolbarButton(title: "Organize", systemImage: "folder.badge.gearshape", action: organizeWithAgent)
                    .disabled(editor.agentService.isStreaming || editor.agentService.isComposerBlocked)
                    .help("Organize media with Agent")
            }
        } else {
            toolbarButton(title: "Media", systemImage: "folder") {
                editor.revealMediaTools()
                editor.setWorkspaceFocus(.media)
            }
            .help("Organize in Media")
        }
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
        .interfaceControlHeight()
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
        toolbarMenuIcon(systemName: "rectangle.grid.2x2", title: "View") {
            Section("View") {
                ForEach(ViewMode.allCases.filter { workspace == .media || $0 == .flat || $0 == .list }, id: \.self) { mode in
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

        toolbarMenuIcon(systemName: "arrow.up.arrow.down", title: "Sort") {
            ForEach(SortMode.allCases, id: \.self) { mode in
                Button {
                    sortMode = mode
                } label: {
                    Label(mode.title, systemImage: sortMode == mode ? "checkmark" : "")
                }
            }
        }

        toolbarMenuIcon(
            systemName: "line.3.horizontal.decrease",
            title: "Filter",
            foregroundStyle: hasActiveFilters ? palette.accent : AppTheme.Text.tertiaryColor,
            isActive: hasActiveFilters
        ) {
            ForEach(Self.filterableTypes, id: \.self) { type in
                Button { toggleFilter(type) } label: {
                    Label(type.trackLabel, systemImage: filterTypes.contains(type) ? "checkmark" : "")
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

    private var showsEmptyState: Bool {
        editor.mediaAssets.isEmpty && editor.folders.isEmpty && !editor.showGenerationPanel
    }

    // MARK: - Sort & Filter

    typealias SortMode = MediaLibraryQuery.SortMode

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

    func sortAndFilter(_ assets: [MediaAsset]) -> [MediaAsset] {
        MediaLibraryQuery(
            text: searchQuery, types: filterTypes, generatedOnly: filterAI, sort: sortMode
        ).apply(to: assets)
    }

    private var currentFolderItemCount: Int {
        if viewMode == .list, trimmedSearchQuery.isEmpty { return listAssets.count }
        if viewMode != .folder || !trimmedSearchQuery.isEmpty {
            return sortAndFilter(editor.mediaAssets).count
        }
        return subfoldersInCurrentFolder.count + assetsInCurrentFolder.count
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
            TextField("Search", text: Binding(get: { searchQuery }, set: { searchQuery = $0 }))
                .background {
                    if WorkspaceUIAcceptance.isRequested {
                        AppRelaunchClickProbe(identifier: "media.search")
                            .allowsHitTesting(false)
                    }
                }
                .textFieldStyle(.plain)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.primaryColor)
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
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: systemImage)
                Text(title)
            }
        }
        .buttonStyle(.capsule(.secondary, isSelected: isSelected))
        .fixedSize(horizontal: true, vertical: false)
        .help(title)
    }

    private var mediaAreaCollapsed: Bool {
        (workspace != .media && !editor.mediaPanelVisible)
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

    private func organizeWithAgent() {
        let scope: String
        let title: String
        if let id = currentFolderId {
            guard let folder = editor.folder(id: id) else { return }
            scope = "Work only within media folder ID \(id) (\(folder.name))."
            title = "Organize \(folder.name)"
        } else {
            scope = "Work within this project's media library."
            title = "Organize media library"
        }
        _ = editor.agentService.stageTask(AgentTask(
            title: title, systemImage: "folder.badge.gearshape",
            prompt: "Review the assets, group related ones into clearly named folders, and give generically named assets descriptive names. Inspect an asset when its name is unclear. Do not delete assets or change the timeline. \(scope)"
        ))
    }

    private func toolbarMenuIcon<Content: View>(
        systemName: String,
        title: String,
        showsTitle: Bool = false,
        foregroundStyle: Color = AppTheme.Text.tertiaryColor,
        isActive: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: systemName)
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                if showsTitle { Text(title) }
            }
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(foregroundStyle)
        }
        .accessibilityLabel(title)
        .help(title)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(foregroundStyle)
        .hoverHighlight(isActive: isActive)
        .accessibilityValue(isActive ? "Active" : "")
    }

    // MARK: - Folder commands

    private func createNewFolderInCurrent() {
        let id = editor.createFolder(name: "New Folder", in: currentFolderId)
        editor.requestMediaFolderRename(id, workspace: workspace)
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
        WorkspaceStateView(
            title: "No media yet",
            message: "Drop files here or import them into the project.",
            systemImage: "photo.on.rectangle.angled"
        ) {
            Button("Import Media", action: importMedia)
                .buttonStyle(.capsule(.prominent, size: .regular))
        }
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
