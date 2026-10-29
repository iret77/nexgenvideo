import Foundation

// Armed swap session: pick a replacement source from the media panel for a clip, preserving its state.
extension EditorViewModel {
    var pendingSwapClip: Clip? {
        guard let id = pendingSwapClipId, let loc = findClip(id: id) else { return nil }
        return timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
    }

    var pendingSwapClipName: String? {
        guard let clip = pendingSwapClip else { return nil }
        return mediaAssets.first { $0.id == clip.mediaRef }?.name
    }

    func beginMediaSwap(clipId: String) {
        guard findClip(id: clipId) != nil else { return }
        pendingSwapClipId = clipId
        revealMediaTools()
    }

    func cancelMediaSwap() {
        pendingSwapClipId = nil
    }

    func isAssetCompatibleWithPendingSwap(_ asset: MediaAsset) -> Bool {
        guard let clip = pendingSwapClip else { return false }
        return mediaSwapProblem(asset, replacing: clip) == nil
    }

    func completeMediaSwap(with asset: MediaAsset) {
        guard let clip = pendingSwapClip else { pendingSwapClipId = nil; return }
        if let problem = mediaSwapProblem(asset, replacing: clip) {
            mediaPanelToast = MediaPanelToast(message: problem)
            return
        }
        pendingSwapClipId = nil
        guard asset.id != clip.mediaRef else { return }
        replaceClipMediaRef(clipId: clip.id, newAssetId: asset.id)
    }

    private func mediaSwapProblem(_ asset: MediaAsset, replacing clip: Clip) -> String? {
        guard mediaAssets.contains(where: { $0 === asset }), clip.mediaType == asset.type else {
            return "Choose a \(clip.mediaType.trackLabel.lowercased()) source from this project."
        }
        guard asset.generationStatus == .none, mediaResolver.resolveURL(for: asset.id) != nil,
              !offlineMediaRefs.contains(asset.id), !unprocessableMediaRefs.contains(asset.id) else {
            return "Choose a finished, readable source."
        }
        let affected = linkedClipIdsSharingMedia(anchor: clip.id).compactMap { clipFor(id: $0) }
        if affected.contains(where: { $0.mediaType == .audio }), asset.type == .video, !asset.hasAudio {
            return "This source has no audio for the linked audio clip. Unlink the clips to replace only the picture."
        }
        guard affected.allSatisfy({ $0.mediaType == asset.type || ($0.mediaType == .audio && asset.type == .video && asset.hasAudio) }) else {
            return "Choose a source that supports every linked clip. Unlink the clips to replace only this clip."
        }
        if [.video, .audio, .lottie].contains(asset.type) {
            guard timeline.fps > 0, asset.duration.isFinite, asset.duration > 0,
                  affected.allSatisfy({ clip in
                      guard clip.speed.isFinite, clip.speed > 0, clip.durationFrames > 0,
                            let consumed = Int(exactly: (Double(clip.durationFrames) * clip.speed).rounded()) else { return false }
                      let end = clip.trimStartFrame.addingReportingOverflow(consumed)
                      return !end.overflow && clip.trimStartFrame >= 0
                          && Double(end.partialValue) <= asset.duration * Double(timeline.fps) + 0.001
                  }) else { return "This source is too short for the clip’s trim and speed. Choose a longer source." }
        }
        return nil
    }

}
