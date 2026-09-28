import SwiftUI

extension MediaTab {
    var listAssets: [MediaAsset] {
        sortAndFilter(currentFolderId == nil ? editor.mediaAssets : editor.assetsIn(folderId: currentFolderId))
    }

    var mediaListView: some View {
        let assets = listAssets
        let ids = assets.map(\.id)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.xxs) {
                    ForEach(assets) { asset in
                        AssetThumbnailView(
                            asset: asset,
                            onMoveToFolderMenu: workspace == .media ? AnyView(moveToFolderMenu(for: asset)) : nil,
                            isListRow: true
                        )
                        .draggable(dragPayload(for: asset)) { dragPreview(for: asset) }
                        .background(assetFrameReader(for: asset.id))
                        .id(asset.id)
                    }
                }
                .scrollTargetLayout()
                .padding(AppTheme.Spacing.sm)
            }
            .scrollPosition(id: scrollAssetBinding)
            .coordinateSpace(name: "mediaGrid")
            .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                guard workspace == editor.workspaceFocus else { return }
                assetFrames = frames
                editor.mediaPanelColumnCount = 1
            }
            .onAppear { publishOrderedIds(ids) }
            .onChange(of: ids) { _, value in publishOrderedIds(value) }
            .onChange(of: editor.mediaPanelScrollTarget) { _, target in
                guard workspace == editor.workspaceFocus, let target else { return }
                proxy.scrollTo(target, anchor: .center)
                editor.mediaPanelScrollTarget = nil
            }
            .onTapGesture { clearSelections() }
            .overlay { marqueeOverlay }
            .gesture(marqueeGesture)
        }
    }
}
