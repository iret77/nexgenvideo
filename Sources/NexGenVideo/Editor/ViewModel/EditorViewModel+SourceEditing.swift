import Foundation

extension EditorViewModel {
    enum SourceEditOperation: Equatable { case insert, overwrite }

    func sourceFrameRange(for asset: MediaAsset) -> Range<Int>? {
        guard [.video, .audio, .lottie].contains(asset.type), timeline.fps > 0,
              asset.duration.isFinite, asset.duration > 0,
              let total = Int(exactly: (asset.duration * Double(timeline.fps)).rounded(.down)),
              total > 0 else { return nil }
        let state = sourcePreviewStates[asset.id] ?? SourcePreviewState()
        func frame(_ seconds: Double?, fallback: Int) -> Int {
            guard let seconds, seconds.isFinite,
                  let value = Int(exactly: (seconds * Double(timeline.fps)).rounded()) else { return fallback }
            return min(total, max(0, value))
        }
        let start = min(total - 1, frame(state.inSeconds, fallback: 0))
        let end = max(start + 1, frame(state.outSeconds, fallback: total))
        return start..<end
    }

    func markSourceIn(_ asset: MediaAsset) {
        guard case .mediaAsset(let id, _, _) = activePreviewTab, id == asset.id,
              let range = sourceFrameRange(for: asset) else { return }
        let frame = max(0, min(sourcePlayheadFrame, activePreviewDurationFrames - 1))
        sourcePreviewStates[id, default: SourcePreviewState()].inSeconds =
            frameToSeconds(frame: frame, fps: timeline.fps)
        if frame >= range.upperBound { sourcePreviewStates[id]?.outSeconds = nil }
    }

    func markSourceOut(_ asset: MediaAsset) {
        guard case .mediaAsset(let id, _, _) = activePreviewTab, id == asset.id,
              let range = sourceFrameRange(for: asset) else { return }
        let frame = max(1, min(sourcePlayheadFrame, activePreviewDurationFrames))
        sourcePreviewStates[id, default: SourcePreviewState()].outSeconds =
            frameToSeconds(frame: frame, fps: timeline.fps)
        if frame <= range.lowerBound { sourcePreviewStates[id]?.inSeconds = nil }
    }

    func clearSourceRange(_ asset: MediaAsset) {
        sourcePreviewStates[asset.id]?.inSeconds = nil
        sourcePreviewStates[asset.id]?.outSeconds = nil
    }

    func sourceEditUnavailableReason(for asset: MediaAsset) -> String? {
        guard workspaceFocus == .edit else { return "Open Edit to place source media." }
        guard case .mediaAsset(let id, _, _) = activePreviewTab, id == asset.id,
              mediaAssets.contains(where: { $0.id == id }) else { return "Select this source first." }
        guard asset.type.isPlaceable else { return "Documents cannot be placed on the timeline." }
        guard !asset.isGenerating else { return "Wait for this media to finish." }
        guard asset.url.isFileURL, !offlineMediaRefs.contains(id), !unprocessableMediaRefs.contains(id),
              FileManager.default.isReadableFile(atPath: asset.url.path) else { return "Relink this media before inserting it." }
        if case .failed = asset.generationStatus { return "This media is unavailable." }
        guard timeline.fps > 0, currentFrame >= 0 else { return "The timeline timebase is unavailable." }
        guard asset.duration.isFinite, asset.duration >= 0,
              Int(exactly: (asset.duration * Double(timeline.fps)).rounded(.down)) != nil else {
            return "The source duration is unavailable."
        }
        if asset.type != .image && asset.type != .text && sourceFrameRange(for: asset) == nil {
            return "Choose a valid source range."
        }
        if let target = sourcePreviewStates[id]?.targetTrackID {
            guard let track = timeline.tracks.first(where: { $0.id == target }),
                  track.type.isCompatible(with: asset.type) else { return "Choose an available compatible track." }
        }
        let duration = sourceFrameRange(for: asset)?.count ?? clipDurationFrames(for: asset, segment: nil)
        guard duration > 0, !currentFrame.addingReportingOverflow(duration).overflow,
              !timeline.totalFrames.addingReportingOverflow(duration).overflow else {
            return "The source range is too large for this timeline."
        }
        return nil
    }

    @discardableResult
    func editSource(_ requestedAsset: MediaAsset, operation: SourceEditOperation) -> Bool {
        guard let asset = mediaAssets.first(where: { $0.id == requestedAsset.id }) else { return false }
        guard sourceEditUnavailableReason(for: asset) == nil else { return false }
        let range = sourceFrameRange(for: asset)
        let duration = range?.count ?? clipDurationFrames(for: asset, segment: nil)
        let targetID = sourcePreviewStates[asset.id]?.targetTrackID
        let insertionFrame = currentFrame
        withTimelineSwap(actionName: operation == .insert ? "Insert Source" : "Overwrite Source") {
            let target = targetID.flatMap { id in timeline.tracks.firstIndex { $0.id == id } }
                ?? insertTrack(at: timeline.tracks.count, type: asset.type == .audio ? .audio : .video)
            switch operation {
            case .insert:
                let sourceTotal = range.map { _ in secondsToFrame(seconds: asset.duration, fps: timeline.fps) }
                _ = rippleInsertClips(specs: [.init(
                    asset: asset, durationFrames: duration,
                    trimStartFrame: range?.lowerBound,
                    trimEndFrame: range.flatMap { bounds in sourceTotal.map { total in max(0, total - bounds.upperBound) } }
                )], trackIndex: target, atFrame: insertionFrame)
            case .overwrite:
                let linkedAudio = asset.type == .video && asset.hasAudio
                    ? timeline.tracks.firstIndex(where: { $0.type == .audio }) : nil
                addClips(
                    assets: [asset], trackIndex: target, startFrame: insertionFrame,
                    linkedAudioTrackIndex: linkedAudio,
                    sourceFrameRanges: range.map { [asset.id: $0] } ?? [:]
                )
            }
        }
        return true
    }
}
