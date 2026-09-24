import AppKit

enum NativeTimelineCommand: Equatable {
    case copy
    case cut
    case delete
    case rippleDelete
    case duplicate
    case split
    case trimStart
    case trimEnd
    case paste
    case link
    case unlink
}

enum NativeSourceCommand {
    case markIn
    case markOut
    case clearRange
    case insert
    case overwrite
}

enum NativeTrackCommand: Equatable {
    case mute
    case visibility
    case editLock
    case syncLock
    case remove
}

extension EditorViewModel {
    func canCopyVisibleMediaPaths(_ ids: Set<String>) -> Bool {
        !ids.isEmpty && ids.isSubset(of: selectedVisibleMediaAssetIDs)
            && ids.allSatisfy { id in mediaAssets.contains { $0.id == id } }
    }

    @discardableResult
    func copyVisibleMediaPaths(_ ids: Set<String>) -> Bool {
        guard canCopyVisibleMediaPaths(ids) else { return false }
        let paths = mediaAssets.filter { ids.contains($0.id) }.map(\.url.path)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func canPerformTrackCommand(_ command: NativeTrackCommand, trackID: String) -> Bool {
        guard allowsTimelineEditChrome, !theaterActive,
              let track = timeline.tracks.first(where: { $0.id == trackID }) else { return false }
        if command == .remove { return !track.editLocked && track.clips.isEmpty }
        return true
    }

    @discardableResult
    func performTrackCommand(_ command: NativeTrackCommand, trackID: String) -> Bool {
        guard canPerformTrackCommand(command, trackID: trackID),
              let index = timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return false }
        switch command {
        case .mute: toggleTrackMute(trackIndex: index)
        case .visibility: toggleTrackHidden(trackIndex: index)
        case .editLock: toggleTrackEditLock(trackIndex: index)
        case .syncLock: toggleTrackSyncLock(trackIndex: index)
        case .remove: removeTrack(id: trackID)
        }
        return true
    }

    func canPerformTimelineCommand(
        _ command: NativeTimelineCommand,
        clipIDs explicitIDs: Set<String>? = nil,
        atTrack trackIndex: Int? = nil,
        atFrame frame: Int? = nil
    ) -> Bool {
        guard allowsTimelineEditChrome, !theaterActive else { return false }
        if command == .rippleDelete, let gap = selectedGap, explicitIDs == nil {
            return timeline.tracks.indices.contains(gap.trackIndex)
                && !timeline.tracks[gap.trackIndex].editLocked
        }
        if command == .paste {
            if let trackIndex {
                return canPasteClips(atTrack: trackIndex, atFrame: frame)
            }
            return canPasteClips
        }
        let ids = explicitIDs ?? timelineCommandClipIDs
        guard !ids.isEmpty,
              ids.allSatisfy({ findClip(id: $0) != nil }) else { return false }
        if command == .copy { return true }
        guard !ids.contains(where: isClipEditLocked) else { return false }
        switch command {
        case .duplicate:
            let sources = ids.compactMap { id -> (track: Int, clip: Clip)? in
                guard let location = findClip(id: id) else { return nil }
                return (location.trackIndex, timeline.tracks[location.trackIndex].clips[location.clipIndex])
            }
            guard sources.count == ids.count,
                  let firstFrame = sources.map({ $0.clip.startFrame }).min() else { return false }
            return sources.allSatisfy { source in
                let destination = currentFrame + source.clip.startFrame - firstFrame
                let end = destination + source.clip.durationFrames
                return destination >= 0 && !timeline.tracks[source.track].clips.contains { existing in
                    existing.startFrame < end && existing.endFrame > destination
                }
            }
        case .split, .trimStart, .trimEnd:
            return ids.contains { id in
                guard let location = findClip(id: id) else { return false }
                let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
                return currentFrame > clip.startFrame && currentFrame < clip.endFrame
            }
        case .link:
            let clips = ids.compactMap { id -> Clip? in
                guard let location = findClip(id: id) else { return nil }
                return timeline.tracks[location.trackIndex].clips[location.clipIndex]
            }
            let types = Set(clips.map(\.mediaType))
            let groups = Set(clips.compactMap(\.linkGroupId))
            return ids.count >= 2 && types.count >= 2
                && !(groups.count == 1 && clips.allSatisfy { $0.linkGroupId != nil })
        case .unlink:
            return !expandToLinkGroup(ids).contains(where: isClipEditLocked) && ids.contains { id in
                guard let location = findClip(id: id) else { return false }
                return timeline.tracks[location.trackIndex].clips[location.clipIndex].linkGroupId != nil
            }
        case .copy, .cut, .delete, .rippleDelete, .paste:
            return true
        }
    }

    @discardableResult
    func performTimelineCommand(
        _ command: NativeTimelineCommand,
        clipIDs explicitIDs: Set<String>? = nil,
        atTrack trackIndex: Int? = nil,
        atFrame frame: Int? = nil
    ) -> Bool {
        guard canPerformTimelineCommand(command, clipIDs: explicitIDs, atTrack: trackIndex, atFrame: frame) else {
            return false
        }
        let ids = explicitIDs ?? timelineCommandClipIDs
        switch command {
        case .copy:
            copyClipsToClipboard(ids: ids)
        case .cut:
            copyClipsToClipboard(ids: ids)
            removeClips(ids: ids)
        case .delete:
            removeClips(ids: ids)
        case .rippleDelete:
            if selectedGap != nil && explicitIDs == nil { rippleDeleteSelectedGap() }
            else { rippleDeleteSelectedClips() }
        case .duplicate:
            let sources = ids.compactMap { id -> (track: Int, clip: Clip)? in
                guard let location = findClip(id: id) else { return nil }
                return (location.trackIndex, timeline.tracks[location.trackIndex].clips[location.clipIndex])
            }
            guard let firstFrame = sources.map({ $0.clip.startFrame }).min() else { return false }
            duplicateClipsToPositions(sources.map { source in
                (clipId: source.clip.id,
                 toTrack: source.track,
                 toFrame: currentFrame + source.clip.startFrame - firstFrame)
            })
        case .split:
            splitAtPlayhead(clipIDs: ids)
        case .trimStart:
            trimStartToPlayhead(clipIDs: ids)
        case .trimEnd:
            trimEndToPlayhead(clipIDs: ids)
        case .paste:
            if let trackIndex { pasteClips(atTrack: trackIndex, atFrame: frame ?? activeFrame) }
            else { pasteClipsAtPlayhead() }
        case .link:
            linkClips(ids: ids)
        case .unlink:
            unlinkClips(ids: ids)
        }
        return true
    }

    func canPerformSourceCommand(_ command: NativeSourceCommand, assetID: String? = nil) -> Bool {
        let asset: MediaAsset?
        if let assetID { asset = mediaAssets.first { $0.id == assetID } }
        else { asset = activeSourceAsset }
        guard let asset else { return false }
        switch command {
        case .markIn, .markOut:
            return asset.type == .video || asset.type == .audio || asset.type == .lottie
        case .clearRange:
            let state = sourcePreviewState(for: asset.id)
            return (asset.type == .video || asset.type == .audio || asset.type == .lottie)
                && (state.inFrame != nil || state.outFrame != nil)
        case .insert:
            return canInsertSourceAsset(asset)
        case .overwrite:
            return canOverwriteSourceAsset(asset)
        }
    }

    func canDeleteVisibleMedia(folders folderIDs: Set<String>, assets assetIDs: Set<String>) -> Bool {
        guard !folderIDs.isEmpty || !assetIDs.isEmpty else { return false }
        return (folderIDs.isEmpty || (folderIDs.isSubset(of: selectedVisibleMediaFolderIDs)
            && canDeleteFolders(ids: folderIDs)))
            && (assetIDs.isEmpty || (assetIDs.isSubset(of: selectedVisibleMediaAssetIDs)
            && canDeleteMediaAssets(ids: assetIDs)))
    }

    @discardableResult
    func deleteVisibleMedia(folders folderIDs: Set<String>, assets assetIDs: Set<String>) -> Bool {
        guard canDeleteVisibleMedia(folders: folderIDs, assets: assetIDs) else { return false }
        undoManager?.beginUndoGrouping()
        if !folderIDs.isEmpty { deleteFolders(ids: folderIDs) }
        if !assetIDs.isEmpty { deleteMediaAssets(ids: assetIDs) }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Delete Media")
        return true
    }

    @discardableResult
    func performSourceCommand(_ command: NativeSourceCommand, assetID: String? = nil) -> Bool {
        guard canPerformSourceCommand(command, assetID: assetID) else { return false }
        if let assetID, activeSourceAsset?.id != assetID,
           let asset = mediaAssets.first(where: { $0.id == assetID }) {
            activateMediaAsset(asset, preservingSelection: true)
        }
        switch command {
        case .markIn: markSourceIn()
        case .markOut: markSourceOut()
        case .clearRange: clearSourceRange()
        case .insert: _ = insertActiveSource()
        case .overwrite: _ = overwriteActiveSource()
        }
        return true
    }
}
