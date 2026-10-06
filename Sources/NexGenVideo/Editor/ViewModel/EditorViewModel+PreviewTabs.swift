import AppKit

/// Preview-tab management: the timeline tab plus any media-asset source tabs
/// opened from the media library. Also hosts preview-specific computed props.
extension EditorViewModel {

    var activePreviewTab: PreviewTab {
        previewTabs.first { $0.id == activePreviewTabId } ?? .timeline
    }

    /// Minimum zoom scale that fits the entire timeline with end padding.
    var minZoomScale: Double {
        let totalFrames = timeline.editingExtentFrames
        guard totalFrames > 0, timelineVisibleWidth > 0 else { return Zoom.min }
        let headerWidth = Double(AppTheme.Layout.trackHeaderWidth)
        let availableWidth = timelineVisibleWidth - headerWidth
        guard availableWidth > 0 else { return Zoom.min }
        let fitAll = availableWidth / (Double(totalFrames) * Zoom.fitAllBuffer)
        return min(Zoom.max, max(Zoom.floor, fitAll))
    }

    var activePreviewDurationFrames: Int {
        switch activePreviewTab {
        case .timeline:
            return timeline.totalFrames
        case .mediaAsset(let id, _, _):
            guard let asset = mediaAssets.first(where: { $0.id == id }) else { return 0 }
            guard asset.duration.isFinite, asset.duration > 0, timeline.fps > 0 else { return 0 }
            return Int(exactly: (asset.duration * Double(timeline.fps)).rounded(.down)) ?? 0
        }
    }

    func selectMediaAsset(_ asset: MediaAsset, atSourceFrame frame: Int? = nil) {
        openPreviewTab(for: asset, atSourceFrame: frame)
        syncSelectionToActiveTab()
        showMediaPanelMediaTab()
    }

    func activateMediaContext(_ asset: MediaAsset) {
        focusedPanel = .media
        if !selectedMediaAssetIds.contains(asset.id) {
            selectedMediaAssetIds = [asset.id]
            selectedFolderIds.removeAll()
        }
        openPreviewTab(for: asset)
        inspectedObject = selectionInspectedObject
    }

    func openPreviewTab(for asset: MediaAsset, atSourceFrame frame: Int? = nil) {
        rememberSourcePosition()
        let tab = PreviewTab.mediaAsset(id: asset.id, name: asset.libraryDisplayName, type: asset.type)
        if !previewTabs.contains(where: { $0.id == tab.id }) {
            previewTabs.append(tab)
        }
        activePreviewTabId = tab.id
        sourcePlayheadFrame = frame.map { asset.duration > 0 ? min(max(0, $0), activePreviewDurationFrames) : max(0, $0) }
            ?? sourcePreviewFrame(for: asset)
        videoEngine?.activateTab(tab)
        pushPreviewHistory(tab.id)
    }

    func closePreviewTab(id: String) {
        guard id != PreviewTab.timeline.id else { return }
        rememberSourcePosition()
        previewTabs.removeAll { $0.id == id }
        previewTabHistory.removeAll { $0 == id }
        if previewTabHistory.isEmpty {
            previewTabHistory = [PreviewTab.timeline.id]
        }
        previewTabHistoryIndex = min(previewTabHistoryIndex, previewTabHistory.count - 1)
        if activePreviewTabId == id {
            let fallbackId = previewTabHistory[previewTabHistoryIndex]
            activePreviewTabId = fallbackId
            restoreSourcePosition()
            syncSelectionToActiveTab()
            videoEngine?.activateTab(activePreviewTab)
        }
    }

    func selectPreviewTab(id: String) {
        guard previewTabs.contains(where: { $0.id == id }) else { return }
        guard activePreviewTabId != id else {
            syncSelectionToActiveTab()
            return
        }
        rememberSourcePosition()
        activePreviewTabId = id
        restoreSourcePosition()
        videoEngine?.activateTab(activePreviewTab)
        syncSelectionToActiveTab()
        pushPreviewHistory(id)
    }

    // MARK: - Tab history (back/forward navigation)

    var canGoBackPreviewTab: Bool { previewTabHistoryIndex > 0 }
    var canGoForwardPreviewTab: Bool { previewTabHistoryIndex < previewTabHistory.count - 1 }

    func goBackPreviewTab() { stepPreviewHistory(-1) }
    func goForwardPreviewTab() { stepPreviewHistory(1) }

    func closeAllPreviewTabs() {
        rememberSourcePosition()
        previewTabs = [.timeline]
        activePreviewTabId = PreviewTab.timeline.id
        previewTabHistory = [PreviewTab.timeline.id]
        previewTabHistoryIndex = 0
        syncSelectionToActiveTab()
        videoEngine?.activateTab(.timeline)
    }

    private func stepPreviewHistory(_ delta: Int) {
        let next = previewTabHistoryIndex + delta
        guard previewTabHistory.indices.contains(next) else { return }
        previewTabHistoryIndex = next
        let id = previewTabHistory[next]
        guard activePreviewTabId != id else { return }
        rememberSourcePosition()
        activePreviewTabId = id
        restoreSourcePosition()
        videoEngine?.activateTab(activePreviewTab)
        syncSelectionToActiveTab()
    }

    private func syncSelectionToActiveTab() {
        switch activePreviewTab {
        case .timeline:
            break
        case .mediaAsset(let id, _, _):
            timelineMarkerPreview = nil
            selectedFolderIds.removeAll()
            selectedMediaAssetIds = [id]
        }
        inspectedObject = selectionInspectedObject
    }

    func rememberSourcePosition() {
        guard case .mediaAsset(let id, _, _) = activePreviewTab, timeline.fps > 0 else { return }
        sourcePreviewStates[id, default: SourcePreviewState()].positionSeconds =
            frameToSeconds(frame: max(0, sourcePlayheadFrame), fps: timeline.fps)
    }

    private func restoreSourcePosition() {
        guard case .mediaAsset(let id, _, _) = activePreviewTab,
              let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        sourcePlayheadFrame = sourcePreviewFrame(for: asset)
    }

    private func sourcePreviewFrame(for asset: MediaAsset) -> Int {
        let seconds = sourcePreviewStates[asset.id]?.positionSeconds ?? 0
        guard seconds.isFinite, timeline.fps > 0 else { return 0 }
        let bounded = asset.duration.isFinite && asset.duration > 0 ? min(seconds, asset.duration) : seconds
        return Int(exactly: (max(0, bounded) * Double(timeline.fps)).rounded()) ?? 0
    }

    private func pushPreviewHistory(_ id: String) {
        let tail = previewTabHistoryIndex + 1
        if tail < previewTabHistory.count {
            previewTabHistory.removeSubrange(tail...)
        }
        guard previewTabHistory.last != id else { return }
        previewTabHistory.append(id)
        previewTabHistoryIndex = previewTabHistory.count - 1
    }
}
