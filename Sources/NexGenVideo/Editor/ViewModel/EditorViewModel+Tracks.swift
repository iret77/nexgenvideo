import AppKit

/// Track-level mutations: add/remove, visibility toggles, height, sync-lock.
extension EditorViewModel {

    // MARK: - Add / remove

    @discardableResult
    func insertTrack(at index: Int, type: ClipType) -> Int {
        let clamped = partitionedInsertionIndex(for: type, requested: index)
        let track = Track(type: type)
        withTimelineSwap(actionName: "Add Track") {
            timeline.tracks.insert(track, at: clamped)
        }
        return clamped
    }

    /// "V1", "A1", "I1" label for the track at the given index.
    func timelineTrackDisplayLabel(at trackIndex: Int) -> String {
        guard timeline.tracks.indices.contains(trackIndex) else { return "" }
        let type = timeline.tracks[trackIndex].type
        var n = 0
        if type == .audio {
            for i in 0...trackIndex where timeline.tracks[i].type == type {
                n += 1
            }
        } else {
            for i in trackIndex..<max(trackIndex + 1, zones.firstAudioIndex) where timeline.tracks[i].type == type {
                n += 1
            }
        }
        return "\(type.trackLabelPrefix)\(n)"
    }

    /// Clamp `requested` so that visual (video/image) tracks always sit above every audio track.
    private func partitionedInsertionIndex(for type: ClipType, requested: Int) -> Int {
        let z = zones
        let bounded = max(0, min(requested, z.trackCount))
        switch type {
        case .video, .image, .text, .lottie:
            // Visual tracks must come at or before the first audio track.
            return min(bounded, z.firstAudioIndex)
        case .audio:
            // Audio tracks must come at or after the first audio track
            return max(bounded, z.firstAudioIndex)
        case .document:
            // Never placed on a track (isPlaceable == false), so there is no zone to clamp into.
            return bounded
        }
    }

    func removeTrack(id: String) {
        removeTracks(ids: [id])
    }

    func removeTracks(ids: [String]) {
        let set = Set(ids)
        guard timeline.tracks.contains(where: { set.contains($0.id) }) else { return }
        withTimelineSwap(actionName: set.count == 1 ? "Remove Track" : "Remove Tracks") {
            timeline.tracks.removeAll { set.contains($0.id) }
        }
    }

    func pruneEmptyTracks() {
        timeline.tracks.removeAll(where: \.clips.isEmpty)
    }

    // MARK: - Flag toggles

    func toggleTrackMute(trackIndex: Int) {
        toggleTrackFlag(trackIndex: trackIndex, keyPath: \.muted, onName: "Mute Track", offName: "Unmute Track")
    }

    func toggleTrackHidden(trackIndex: Int) {
        toggleTrackFlag(trackIndex: trackIndex, keyPath: \.hidden, onName: "Hide Track", offName: "Show Track")
    }

    func toggleTrackSyncLock(trackIndex: Int) {
        toggleTrackFlag(trackIndex: trackIndex, keyPath: \.syncLocked, onName: "Sync Lock Track", offName: "Unlock Track Sync")
    }

    private func toggleTrackFlag(
        trackIndex: Int,
        keyPath: WritableKeyPath<Track, Bool>,
        onName: String,
        offName: String
    ) {
        guard timeline.tracks.indices.contains(trackIndex) else { return }
        let was = timeline.tracks[trackIndex][keyPath: keyPath]
        withTimelineSwap(actionName: was ? offName : onName) {
            timeline.tracks[trackIndex][keyPath: keyPath].toggle()
        }
    }

    // MARK: - Sizing

    func setTrackHeight(trackIndex: Int, height: CGFloat) {
        guard timeline.tracks.indices.contains(trackIndex), height.isFinite else { return }
        let clamped = max(AppTheme.Timeline.trackMinHeight, min(AppTheme.Timeline.trackMaxHeight, height))
        withTimelineSwap(actionName: "Resize Track") {
            timeline.tracks[trackIndex].displayHeight = clamped
        }
    }
}
