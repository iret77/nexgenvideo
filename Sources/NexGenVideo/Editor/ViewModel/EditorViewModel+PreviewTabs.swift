import AppKit

/// Preview identity and activation; tabs remain internal remembered-source state.
extension EditorViewModel {

    var activePreviewTab: PreviewTab {
        previewTabs.first { $0.id == activePreviewTabId } ?? .timeline
    }

    /// Minimum zoom scale that fits the entire timeline with end padding.
    var minZoomScale: Double {
        let totalFrames = timeline.totalFrames
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
            return secondsToFrame(seconds: asset.duration, fps: timeline.fps)
        }
    }

    var activeSourceAsset: MediaAsset? {
        guard case .mediaAsset(let id, _, _) = activePreviewTab else { return nil }
        return mediaAssets.first { $0.id == id }
    }

    var isTimelinePreviewActive: Bool { activePreviewTab == .timeline }
    var isSourcePreviewActive: Bool { activeSourceAsset != nil }

    func sourcePreviewState(for assetID: String) -> SourcePreviewState {
        let duration = mediaAssets.first { $0.id == assetID }
            .map { secondsToFrame(seconds: $0.duration, fps: timeline.fps) } ?? 0
        return (sourcePreviewStates[assetID] ?? SourcePreviewState()).clamped(to: duration)
    }

    var activeSourcePreviewState: SourcePreviewState? {
        guard let asset = activeSourceAsset else { return nil }
        return sourcePreviewState(for: asset.id)
    }

    var activeSourceSelectedFrames: Range<Int>? {
        guard let asset = activeSourceAsset else { return nil }
        return sourcePreviewState(for: asset.id).selectedFrames(
            durationFrames: secondsToFrame(seconds: asset.duration, fps: timeline.fps)
        )
    }

    var rememberedSourceAssets: [MediaAsset] {
        previewTabs.compactMap { tab in
            guard case .mediaAsset(let id, _, _) = tab else { return nil }
            return mediaAssets.first { $0.id == id }
        }
    }

    var canActivatePreviousSource: Bool { adjacentSourceAsset(offset: -1) != nil }
    var canActivateNextSource: Bool { adjacentSourceAsset(offset: 1) != nil }

    func selectMediaAsset(_ asset: MediaAsset, atSourceFrame frame: Int? = nil) {
        selectedFolderIds.removeAll()
        selectedMediaAssetIds = [asset.id]
        openPreviewTab(for: asset, atSourceFrame: frame)
        inspectedObject = .mediaAsset(asset.id)
        showMediaPanelMediaTab()
    }

    func openPreviewTab(for asset: MediaAsset, atSourceFrame frame: Int? = nil) {
        let tab = PreviewTab.mediaAsset(id: asset.id, name: asset.name, type: asset.type)
        if !previewTabs.contains(where: { $0.id == tab.id }) {
            previewTabs.append(tab)
        }
        if let frame {
            var state = sourcePreviewState(for: asset.id)
            state.playheadFrame = frame
            sourcePreviewStates[asset.id] = state.clamped(
                to: secondsToFrame(seconds: asset.duration, fps: timeline.fps)
            )
        }
        activePreviewTabId = tab.id
        sourcePlayheadFrame = sourcePreviewState(for: asset.id).playheadFrame
        videoEngine?.activateTab(tab)
        pushPreviewHistory(tab.id)
    }

    func activateMediaAsset(_ asset: MediaAsset, preservingSelection: Bool) {
        selectedFolderIds.removeAll()
        if !preservingSelection {
            selectedMediaAssetIds = [asset.id]
        }
        openPreviewTab(for: asset)
        inspectedObject = .mediaAsset(asset.id)
    }

    func toggleMediaAssetSelection(_ asset: MediaAsset) {
        selectedFolderIds.removeAll()
        if selectedMediaAssetIds.contains(asset.id) {
            selectedMediaAssetIds.remove(asset.id)
        } else {
            selectedMediaAssetIds.insert(asset.id)
        }
        activateMediaAsset(asset, preservingSelection: true)
    }

    func activateTimelineSelection(inspectedClipID: String? = nil) {
        activePreviewTabId = PreviewTab.timeline.id
        videoEngine?.activateTab(.timeline)
        pushPreviewHistory(PreviewTab.timeline.id)

        if let inspectedClipID, findClip(id: inspectedClipID) != nil {
            inspectedObject = .clip(inspectedClipID)
        } else {
            inspectedObject = InspectedObject.fromSelection(
                clipIDs: selectedClipIds,
                mediaAssetIDs: [],
                isMarquee: isMarqueeSelecting
            )
        }
    }

    func activatePreviousSource() {
        guard let asset = adjacentSourceAsset(offset: -1) else { return }
        activateMediaAsset(asset, preservingSelection: false)
    }

    func activateNextSource() {
        guard let asset = adjacentSourceAsset(offset: 1) else { return }
        activateMediaAsset(asset, preservingSelection: false)
    }

    func markSourceIn() {
        guard let asset = activeSourceAsset, asset.type != .document else { return }
        var state = sourcePreviewState(for: asset.id)
        state.inFrame = sourcePlayheadFrame
        if let out = state.outFrame, out <= sourcePlayheadFrame { state.outFrame = nil }
        sourcePreviewStates[asset.id] = state
    }

    func markSourceOut() {
        guard let asset = activeSourceAsset, asset.type != .document else { return }
        var state = sourcePreviewState(for: asset.id)
        let duration = secondsToFrame(seconds: asset.duration, fps: timeline.fps)
        state.outFrame = min(duration, max(sourcePlayheadFrame, (state.inFrame ?? -1) + 1))
        sourcePreviewStates[asset.id] = state
    }

    func clearSourceRange() {
        guard let asset = activeSourceAsset else { return }
        var state = sourcePreviewState(for: asset.id)
        state.inFrame = nil
        state.outFrame = nil
        sourcePreviewStates[asset.id] = state
    }

    var canEditActiveSourceRange: Bool {
        guard let asset = activeSourceAsset else { return false }
        return asset.type == .video || asset.type == .audio || asset.type == .lottie
    }

    var canPlaceActiveSource: Bool {
        guard let asset = activeSourceAsset else { return false }
        return canOverwriteSourceAsset(asset)
    }

    var canInsertActiveSource: Bool {
        guard let asset = activeSourceAsset else { return false }
        return canInsertSourceAsset(asset)
    }

    func canInsertSourceAsset(_ asset: MediaAsset) -> Bool {
        guard canOverwriteSourceAsset(asset),
              let frames = sourcePreviewState(for: asset.id).selectedFrames(
                  durationFrames: secondsToFrame(seconds: asset.duration, fps: timeline.fps)
              ) else { return false }
        return canRippleInsertSource(
            asset: asset,
            durationFrames: frames.count,
            trackIndex: sourceEditTrackIndex(for: asset),
            atFrame: currentFrame
        )
    }

    var canOverwriteActiveSource: Bool { canPlaceActiveSource }

    func canOverwriteSourceAsset(_ asset: MediaAsset) -> Bool {
        guard asset.type.isPlaceable,
              !asset.isGenerating,
              !isMediaOffline(asset.id) else { return false }
        return sourcePreviewState(for: asset.id).selectedFrames(
            durationFrames: secondsToFrame(seconds: asset.duration, fps: timeline.fps)
        ) != nil
    }

    @discardableResult
    func insertActiveSource() -> [String] {
        placeActiveSource(ripple: true)
    }

    @discardableResult
    func overwriteActiveSource() -> [String] {
        placeActiveSource(ripple: false)
    }

    private func placeActiveSource(ripple: Bool) -> [String] {
        guard let asset = activeSourceAsset,
              asset.type.isPlaceable,
              !asset.isGenerating,
              !isMediaOffline(asset.id),
              let frames = activeSourceSelectedFrames else { return [] }
        guard ripple ? canInsertActiveSource : canOverwriteActiveSource else { return [] }
        let fps = Double(timeline.fps)
        let segment = (Double(frames.lowerBound) / fps)...(Double(frames.upperBound) / fps)
        let previousIDs = Set(timeline.tracks.flatMap(\.clips).map(\.id))
        var created: [String] = []
        withTimelineSwap(actionName: ripple ? "Insert Source" : "Overwrite Source") {
            let target = (ripple
                ? sourceEditTrackIndex(for: asset)
                : sourceOverwriteTrackIndex(for: asset, durationFrames: frames.count))
                ?? insertTrack(at: timeline.tracks.count, type: asset.type == .audio ? .audio : .video)
            if ripple {
                let sourceDuration = secondsToFrame(seconds: asset.duration, fps: timeline.fps)
                created = rippleInsertClips(
                    specs: [RippleInsertSpec(
                        asset: asset,
                        durationFrames: frames.count,
                        trimStartFrame: frames.lowerBound,
                        trimEndFrame: max(0, sourceDuration - frames.upperBound)
                    )],
                    trackIndex: target,
                    atFrame: currentFrame
                )
            } else {
                addClips(
                    assets: [asset],
                    trackIndex: target,
                    startFrame: currentFrame,
                    segments: [asset.id: segment]
                )
            }
            created = timeline.tracks.flatMap(\.clips).map(\.id).filter { !previousIDs.contains($0) }
        }
        return created
    }

    private func canRippleInsertSource(
        asset: MediaAsset,
        durationFrames: Int,
        trackIndex: Int?,
        atFrame: Int
    ) -> Bool {
        let targetIsVideo = trackIndex.map { timeline.tracks[$0].type == .video }
            ?? (asset.type != .audio)
        let needsLinkedAudio = targetIsVideo && asset.type == .video && asset.hasAudio
        return !rippleInsertTouchesLockedTrack(
            trackIndex: trackIndex,
            atFrame: atFrame,
            pushAmount: durationFrames,
            needsLinkedAudio: needsLinkedAudio
        )
    }

    private func sourceEditTrackIndex(for asset: MediaAsset) -> Int? {
        for track in timeline.tracks where !track.editLocked
            && track.clips.contains(where: { selectedClipIds.contains($0.id) }) {
            if let index = timeline.tracks.firstIndex(where: { $0.id == track.id }),
               sourceTrackIsCompatible(track, with: asset) {
                return index
            }
        }
        return timeline.tracks.firstIndex {
            !$0.editLocked && sourceTrackIsCompatible($0, with: asset)
        }
    }

    private func sourceOverwriteTrackIndex(for asset: MediaAsset, durationFrames: Int) -> Int? {
        let selected = timeline.tracks.indices.first {
            !timeline.tracks[$0].editLocked
                && sourceTrackIsCompatible(timeline.tracks[$0], with: asset)
                && timeline.tracks[$0].clips.contains(where: { selectedClipIds.contains($0.id) })
                && canClearRegion(
                    trackIndex: $0,
                    start: currentFrame,
                    end: currentFrame + durationFrames
                )
        }
        if let selected { return selected }
        return timeline.tracks.indices.first {
            !timeline.tracks[$0].editLocked
                && sourceTrackIsCompatible(timeline.tracks[$0], with: asset)
                && canClearRegion(
                    trackIndex: $0,
                    start: currentFrame,
                    end: currentFrame + durationFrames
                )
        }
    }

    private func sourceTrackIsCompatible(_ track: Track, with asset: MediaAsset) -> Bool {
        asset.type == .audio ? track.type == .audio : track.type == .video
    }

    private func adjacentSourceAsset(offset: Int) -> MediaAsset? {
        let sources = rememberedSourceAssets
        guard !sources.isEmpty else { return nil }
        guard let active = activeSourceAsset,
              let index = sources.firstIndex(where: { $0.id == active.id }) else {
            return offset < 0 ? sources.last : sources.first
        }
        let next = index + offset
        guard sources.indices.contains(next) else { return nil }
        return sources[next]
    }

    func closePreviewTab(id: String) {
        guard id != PreviewTab.timeline.id else { return }
        previewTabs.removeAll { $0.id == id }
        if id.hasPrefix("media_") {
            sourcePreviewStates.removeValue(forKey: String(id.dropFirst("media_".count)))
        }
        previewTabHistory.removeAll { $0 == id }
        if previewTabHistory.isEmpty {
            previewTabHistory = [PreviewTab.timeline.id]
        }
        previewTabHistoryIndex = min(previewTabHistoryIndex, previewTabHistory.count - 1)
        if activePreviewTabId == id {
            activateTimelineSelection()
        }
    }

    func selectPreviewTab(id: String) {
        guard previewTabs.contains(where: { $0.id == id }),
              activePreviewTabId != id else { return }
        activePreviewTabId = id
        if case .mediaAsset(let assetID, _, _) = activePreviewTab {
            sourcePlayheadFrame = sourcePreviewState(for: assetID).playheadFrame
        }
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
        previewTabs = [.timeline]
        activePreviewTabId = PreviewTab.timeline.id
        previewTabHistory = [PreviewTab.timeline.id]
        previewTabHistoryIndex = 0
        sourcePreviewStates.removeAll()
        videoEngine?.activateTab(.timeline)
    }

    private func stepPreviewHistory(_ delta: Int) {
        let next = previewTabHistoryIndex + delta
        guard previewTabHistory.indices.contains(next) else { return }
        previewTabHistoryIndex = next
        let id = previewTabHistory[next]
        guard activePreviewTabId != id else { return }
        activePreviewTabId = id
        if case .mediaAsset(let assetID, _, _) = activePreviewTab {
            sourcePlayheadFrame = sourcePreviewState(for: assetID).playheadFrame
        }
        videoEngine?.activateTab(activePreviewTab)
        syncSelectionToActiveTab()
    }

    private func syncSelectionToActiveTab() {
        switch activePreviewTab {
        case .timeline:
            inspectedObject = InspectedObject.fromSelection(
                clipIDs: selectedClipIds,
                mediaAssetIDs: [],
                isMarquee: isMarqueeSelecting
            )
        case .mediaAsset(let id, _, _):
            selectedFolderIds.removeAll()
            if !selectedMediaAssetIds.contains(id) { selectedMediaAssetIds = [id] }
            inspectedObject = .mediaAsset(id)
        }
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
