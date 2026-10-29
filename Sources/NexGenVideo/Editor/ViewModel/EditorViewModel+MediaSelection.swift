import AppKit

extension EditorViewModel {
    func updateMediaPanelItems(_ keys: [String]) {
        var seen: Set<String> = []
        let ordered = keys.filter { key in
            guard seen.insert(key).inserted else { return false }
            if let id = MediaPanelItemKey.folderId(from: key) { return folder(id: id) != nil }
            return mediaAssets.contains { $0.id == key }
        }
        mediaPanelOrderedItemIds = ordered
        let visible = Set(ordered)
        selectedMediaAssetIds.formIntersection(visible)
        selectedFolderIds = selectedFolderIds.filter { visible.contains(MediaPanelItemKey.folder($0)) }
        if let anchor = mediaPanelSelectionAnchor, !visible.contains(anchor) { mediaPanelSelectionAnchor = nil }
        if focusedPanel == .media { inspectedObject = selectedFolderIds.isEmpty ? selectionInspectedObject : nil }
    }

    func selectAllMediaPanelItems() {
        selectMediaPanelKeys(Set(mediaPanelOrderedItemIds))
        mediaPanelSelectionAnchor = mediaPanelOrderedItemIds.first
    }

    func selectMediaPanelItem(_ key: String, modifiers: NSEvent.ModifierFlags = []) {
        let folderID = MediaPanelItemKey.folderId(from: key)
        let asset = mediaAssets.first { $0.id == key }
        guard asset != nil || folderID.flatMap({ folder(id: $0) }) != nil else { return }
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        var selection = command ? selectedMediaAssetIds.union(selectedFolderIds.map(MediaPanelItemKey.folder)) : []
        if shift, let anchor = mediaPanelSelectionAnchor,
           let start = mediaPanelOrderedItemIds.firstIndex(of: anchor), let end = mediaPanelOrderedItemIds.firstIndex(of: key) {
            selection.formUnion(mediaPanelOrderedItemIds[min(start, end)...max(start, end)])
        } else if command {
            if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
        } else {
            selection = [key]
        }
        if !shift || mediaPanelSelectionAnchor == nil { mediaPanelSelectionAnchor = key }
        if let asset {
            if !command && !shift { selectMediaAsset(asset) }
            else { openPreviewTab(for: asset) }
        }
        selectMediaPanelKeys(selection)
        mediaPanelScrollTarget = key
    }

    func clearMediaPanelSelection() {
        selectedMediaAssetIds.removeAll()
        selectedFolderIds.removeAll()
        mediaPanelSelectionAnchor = nil
        if focusedPanel == .media { inspectedObject = selectedFolderIds.isEmpty ? selectionInspectedObject : nil }
    }

    func selectMediaPanelMarquee(assets: Set<String>, folders: Set<String>) {
        let keys = assets.union(folders.map(MediaPanelItemKey.folder))
        selectMediaPanelKeys(keys.intersection(Set(mediaPanelOrderedItemIds)))
        mediaPanelSelectionAnchor = nil
    }

    private func selectMediaPanelKeys(_ keys: Set<String>) {
        focusedPanel = .media
        selectedFolderIds = Set(keys.compactMap(MediaPanelItemKey.folderId).filter { folder(id: $0) != nil })
        selectedMediaAssetIds = keys.intersection(Set(mediaAssets.map(\.id)))
        inspectedObject = selectedFolderIds.isEmpty ? selectionInspectedObject : nil
    }
}
