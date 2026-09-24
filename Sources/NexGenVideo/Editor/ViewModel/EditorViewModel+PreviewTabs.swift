import AppKit

private struct SourceOverwritePlan {
    let targetTrackID: String?
    let linkedAudioTrackID: String?
    let clearTrackIDs: [String]
    let startFrame: Int
    let endFrame: Int
}

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

    var activeTimelineInspectionClipID: String? {
        guard isTimelinePreviewActive else { return nil }
        if let id = explicitTimelineInspectionClipID, findClip(id: id) != nil {
            return id
        }
        guard selectedClipIds.count == 1, let id = selectedClipIds.first,
              findClip(id: id) != nil else { return nil }
        return id
    }

    var timelineInspectorClipIDs: Set<String> {
        if let id = explicitTimelineInspectionClipID, isTimelinePreviewActive,
           findClip(id: id) != nil {
            return [id]
        }
        return selectedClipIds
    }

    var timelineCommandClipIDs: Set<String> {
        if let id = explicitTimelineInspectionClipID, isTimelinePreviewActive,
           findClip(id: id) != nil {
            return expandToLinkGroup([id])
        }
        return selectedClipIds
    }

    var isTimelineBatchSelection: Bool {
        isTimelinePreviewActive
            && explicitTimelineInspectionClipID == nil
            && !isMarqueeSelecting
            && selectedClipIds.count > 1
    }

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
        activeMediaLibraryPurpose = nil
        selectedFolderIds.removeAll()
        selectedMediaAssetIds = [asset.id]
        openPreviewTab(for: asset, atSourceFrame: frame)
        inspectedObject = .mediaAsset(asset.id)
        showMediaPanelMediaTab()
    }

    func openPreviewTab(for asset: MediaAsset, atSourceFrame frame: Int? = nil) {
        let tab = PreviewTab.mediaAsset(id: asset.id, name: asset.name, type: asset.type)
        let wasActive = activePreviewTabId == tab.id
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
        explicitTimelineInspectionClipID = nil
        activePreviewTabId = tab.id
        sourcePlayheadFrame = sourcePreviewState(for: asset.id).playheadFrame
        if wasActive {
            if frame != nil { videoEngine?.seek(to: sourcePlayheadFrame, mode: .exact) }
        } else {
            videoEngine?.activateTab(tab)
        }
        pushPreviewHistory(tab.id)
    }

    func activateMediaAsset(_ asset: MediaAsset, preservingSelection: Bool) {
        activeMediaLibraryPurpose = nil
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

    func activateTimelineSelection() {
        explicitTimelineInspectionClipID = nil
        activateTimelinePreview()
        inspectedObject = InspectedObject.fromSelection(
            clipIDs: selectedClipIds,
            mediaAssetIDs: [],
            isMarquee: isMarqueeSelecting
        )
    }

    func activateTimelineClipContext(_ clipID: String) {
        guard findClip(id: clipID) != nil else { return }
        explicitTimelineInspectionClipID = clipID
        activateTimelinePreview()
        inspectedObject = .clip(clipID)
    }

    func endTimelineClipContext() {
        guard explicitTimelineInspectionClipID != nil else { return }
        explicitTimelineInspectionClipID = nil
        guard isTimelinePreviewActive else { return }
        inspectedObject = InspectedObject.fromSelection(
            clipIDs: selectedClipIds,
            mediaAssetIDs: [],
            isMarquee: isMarqueeSelecting
        )
    }

    private func activateTimelinePreview() {
        let wasActive = activePreviewTabId == PreviewTab.timeline.id
        activePreviewTabId = PreviewTab.timeline.id
        if !wasActive { videoEngine?.activateTab(.timeline) }
        pushPreviewHistory(PreviewTab.timeline.id)
    }

    func activatePreviousSource() {
        guard let asset = adjacentSourceAsset(offset: -1) else { return }
        if let activeMediaLibraryPurpose {
            activateMediaAsset(asset, preservingSelection: false, for: activeMediaLibraryPurpose)
        } else {
            activateMediaAsset(asset, preservingSelection: false)
        }
    }

    func activateNextSource() {
        guard let asset = adjacentSourceAsset(offset: 1) else { return }
        if let activeMediaLibraryPurpose {
            activateMediaAsset(asset, preservingSelection: false, for: activeMediaLibraryPurpose)
        } else {
            activateMediaAsset(asset, preservingSelection: false)
        }
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
              !isMediaOffline(asset.id),
              let frames = sourcePreviewState(for: asset.id).selectedFrames(
                  durationFrames: secondsToFrame(seconds: asset.duration, fps: timeline.fps)
              ) else { return false }
        return sourceOverwritePlan(asset: asset, durationFrames: frames.count) != nil
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
        let overwritePlan: SourceOverwritePlan?
        if ripple {
            guard canInsertSourceAsset(asset) else { return [] }
            overwritePlan = nil
        } else {
            guard let plan = sourceOverwritePlan(asset: asset, durationFrames: frames.count) else {
                return []
            }
            overwritePlan = plan
        }
        let fps = Double(timeline.fps)
        let segment = (Double(frames.lowerBound) / fps)...(Double(frames.upperBound) / fps)
        var created: [String] = []
        withTimelineSwap(actionName: ripple ? "Insert Source" : "Overwrite Source") {
            if ripple {
                let target = sourceEditTrackIndex(for: asset)
                    ?? insertTrack(at: timeline.tracks.count, type: asset.type == .audio ? .audio : .video)
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
            } else if let overwritePlan {
                for trackID in overwritePlan.clearTrackIDs {
                    guard let trackIndex = timeline.tracks.firstIndex(where: { $0.id == trackID }) else {
                        continue
                    }
                    clearRegion(
                        trackIndex: trackIndex,
                        start: overwritePlan.startFrame,
                        end: overwritePlan.endFrame,
                        prune: false
                    )
                }
                let target = overwritePlan.targetTrackID.flatMap { id in
                    timeline.tracks.firstIndex(where: { $0.id == id })
                } ?? insertTrack(
                    at: timeline.tracks.count,
                    type: asset.type == .audio ? .audio : .video
                )
                let needsLinkedAudio = timeline.tracks[target].type == .video
                    && asset.type == .video
                    && asset.hasAudio
                let linkedAudioTrackIndex: Int?
                if needsLinkedAudio {
                    linkedAudioTrackIndex = overwritePlan.linkedAudioTrackID.flatMap { id in
                        timeline.tracks.firstIndex(where: { $0.id == id })
                    } ?? insertTrack(at: timeline.tracks.count, type: .audio)
                } else {
                    linkedAudioTrackIndex = nil
                }
                created = placeClip(
                    asset: asset,
                    trackIndex: target,
                    startFrame: currentFrame,
                    durationFrames: frames.count,
                    linkedAudioTrackIndex: linkedAudioTrackIndex,
                    sourceSegment: segment
                )
                pruneEmptyTracks()
            }
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

    private func sourceOverwritePlan(asset: MediaAsset, durationFrames: Int) -> SourceOverwritePlan? {
        let start = currentFrame
        let end = currentFrame + durationFrames
        let selectedTracks = timeline.tracks.indices.filter { index in
            sourceTrackIsCompatible(timeline.tracks[index], with: asset)
                && timeline.tracks[index].clips.contains { selectedClipIds.contains($0.id) }
        }
        let otherTracks = timeline.tracks.indices.filter { index in
            sourceTrackIsCompatible(timeline.tracks[index], with: asset)
                && !selectedTracks.contains(index)
        }
        for targetIndex in selectedTracks + otherTracks {
            if let plan = sourceOverwritePlan(
                asset: asset,
                targetTrackID: timeline.tracks[targetIndex].id,
                startFrame: start,
                endFrame: end
            ) {
                return plan
            }
        }
        return sourceOverwritePlan(
            asset: asset,
            targetTrackID: nil,
            startFrame: start,
            endFrame: end
        )
    }

    private func sourceOverwritePlan(
        asset: MediaAsset,
        targetTrackID: String?,
        startFrame: Int,
        endFrame: Int
    ) -> SourceOverwritePlan? {
        let needsLinkedAudio = asset.type == .video && asset.hasAudio
        var audioCandidates: [String?] = [nil]
        if needsLinkedAudio {
            let linkedAudioIDs: [String] = targetTrackID.flatMap { id in
                timeline.tracks.firstIndex(where: { $0.id == id })
            }.map { targetIndex in
                let overlapping = timeline.tracks[targetIndex].clips.filter {
                    $0.startFrame < endFrame && startFrame < $0.endFrame
                }
                return overlapping.flatMap { clip in
                    linkedPartnerIds(of: clip.id).compactMap { partnerID in
                        guard let location = findClip(id: partnerID),
                              timeline.tracks[location.trackIndex].type == .audio else { return nil }
                        return timeline.tracks[location.trackIndex].id
                    }
                }
            } ?? []
            let availableAudioID = timeline.tracks.indices.first { index in
                timeline.tracks[index].type == .audio
                    && !timeline.tracks[index].editLocked
                    && !timeline.tracks[index].clips.contains {
                        $0.startFrame < endFrame && startFrame < $0.endFrame
                    }
            }.map { timeline.tracks[$0].id }
            var uniqueLinkedAudioIDs: [String] = []
            for id in linkedAudioIDs where !uniqueLinkedAudioIDs.contains(id) {
                uniqueLinkedAudioIDs.append(id)
            }
            audioCandidates = uniqueLinkedAudioIDs.map { Optional($0) }
            if let availableAudioID, !audioCandidates.contains(where: { $0 == availableAudioID }) {
                audioCandidates.append(availableAudioID)
            }
            audioCandidates.append(nil)
        }

        for audioTrackID in audioCandidates {
            let initial = Set([targetTrackID, audioTrackID].compactMap { $0 })
            guard let clearTrackIDs = overwriteClearTrackIDs(
                initialTrackIDs: initial,
                startFrame: startFrame,
                endFrame: endFrame
            ) else { continue }
            return SourceOverwritePlan(
                targetTrackID: targetTrackID,
                linkedAudioTrackID: audioTrackID,
                clearTrackIDs: clearTrackIDs,
                startFrame: startFrame,
                endFrame: endFrame
            )
        }
        return nil
    }

    private func overwriteClearTrackIDs(
        initialTrackIDs: Set<String>,
        startFrame: Int,
        endFrame: Int
    ) -> [String]? {
        var pending = initialTrackIDs
        var resolved: Set<String> = []
        while let trackID = pending.popFirst() {
            guard let index = timeline.tracks.firstIndex(where: { $0.id == trackID }),
                  !timeline.tracks[index].editLocked,
                  canClearRegion(trackIndex: index, start: startFrame, end: endFrame) else {
                return nil
            }
            guard resolved.insert(trackID).inserted else { continue }
            let overlapping = timeline.tracks[index].clips.filter {
                $0.startFrame < endFrame && startFrame < $0.endFrame
            }
            for partnerID in overlapping.flatMap({ linkedPartnerIds(of: $0.id) }) {
                guard let location = findClip(id: partnerID) else { continue }
                pending.insert(timeline.tracks[location.trackIndex].id)
            }
        }
        return timeline.tracks.compactMap { resolved.contains($0.id) ? $0.id : nil }
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
            explicitTimelineInspectionClipID = nil
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
