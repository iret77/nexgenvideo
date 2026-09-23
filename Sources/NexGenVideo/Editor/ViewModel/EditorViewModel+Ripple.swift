import AppKit

private enum RippleInsertError: Error {
    case invalidatedPlan
}

struct RippleRangesReport: Sendable {
    let removedFrames: Int
    let clearedTracks: Int
    let shiftedClips: Int
    let anchorTrackIndex: Int
    let resultingFragments: [(clipId: String, startFrame: Int, durationFrames: Int)]
    let removedClipIds: [String]
}

enum RippleRangesOutcome: Sendable {
    case ok(RippleRangesReport)
    case refused(String)
}

/// Ripple editing: trim, delete, insert, and the sync-lock machinery that keeps
/// other tracks aligned with the edit. See `RippleEngine` for the pure math.
extension EditorViewModel {

    // MARK: - Public API

    /// Trim one or more clips in a single undo group. Overwrite-style: each clip
    /// resizes in place — no adjacent-clip shift on the same track, no sync-lock
    /// push to other tracks.
    func trimClips(_ edits: [(clipId: String, trimStartFrame: Int, trimEndFrame: Int)]) {
        guard !edits.isEmpty,
              !edits.contains(where: { isClipEditLocked($0.clipId) }) else { return }
        undoManager?.beginUndoGrouping()
        for e in edits {
            trimClipInternal(clipId: e.clipId, trimStartFrame: e.trimStartFrame, trimEndFrame: e.trimEndFrame)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(edits.count == 1 ? "Trim Clip" : "Trim Clips")
    }

    /// Ripple delete: remove selected clips and close the gaps. Sync-locked tracks shift
    /// along to preserve cross-track alignment; refuses if any would collide.
    func rippleDeleteSelectedClips() {
        let ids = timelineCommandClipIDs
        guard !ids.isEmpty, !ids.contains(where: isClipEditLocked) else { return }

        // Merged ranges used to shift sync-locked tracks that have no deletions of their own.
        let globalRemovedRanges: [FrameRange] = timeline.tracks
            .flatMap(\.clips)
            .filter { ids.contains($0.id) }
            .map { FrameRange(start: $0.startFrame, end: $0.endFrame) }

        var shiftsByTrack: [Int: [ClipShift]] = [:]
        for ti in timeline.tracks.indices {
            let track = timeline.tracks[ti]
            let hasOwnRemovals = track.clips.contains { ids.contains($0.id) }
            if hasOwnRemovals {
                shiftsByTrack[ti] = RippleEngine.computeRippleShifts(clips: track.clips, removedIds: ids)
            } else if track.syncLocked {
                let shifts = RippleEngine.computeRippleShiftsForRanges(
                    clips: track.clips,
                    removedRanges: globalRemovedRanges
                )
                guard !track.editLocked || shifts.isEmpty else {
                    refuseRipple(reason: "The edit would move clips on a locked track.")
                    return
                }
                shiftsByTrack[ti] = shifts
                if let reason = validateShifts(trackIndex: ti, shifts: shifts) {
                    refuseRipple(reason: reason)
                    return
                }
            }
        }

        withTimelineSwap(actionName: "Ripple Delete") {
            removeClips(ids: ids)
            for shifts in shiftsByTrack.values { applyShifts(shifts) }
        }
    }

    @discardableResult
    func applyShifts(_ shifts: [ClipShift]) -> Int {
        guard !shifts.contains(where: { isClipEditLocked($0.clipId) }) else { return 0 }
        var applied = 0
        for shift in shifts {
            guard let loc = findClip(id: shift.clipId) else { continue }
            timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame = shift.newStartFrame
            applied += 1
        }
        return applied
    }

    /// Ripple-delete timeline-frame `ranges` anchored to `anchorClipId`
    func rippleDeleteRanges(anchorClipId: String, ranges: [FrameRange]) -> RippleRangesOutcome {
        guard !isClipEditLocked(anchorClipId) else {
            return .refused("The track is locked.")
        }
        guard let anchorLoc = findClip(id: anchorClipId) else {
            return .refused("Clip not found: \(anchorClipId)")
        }
        return rippleDeleteRangesOnTrack(trackIndex: anchorLoc.trackIndex, ranges: ranges)
    }

    /// Deletes project-frame ranges from one track (spanning any clips) and closes the gaps; cuts linked A/V partners, shifts sync-locked tracks, refuses if any can't absorb.
    func rippleDeleteRangesOnTrack(trackIndex: Int, ranges: [FrameRange]) -> RippleRangesOutcome {
        guard timeline.tracks.indices.contains(trackIndex) else {
            return .refused("Track index out of range: \(trackIndex)")
        }
        guard !timeline.tracks[trackIndex].editLocked else {
            return .refused("The track is locked.")
        }
        let merged = RippleEngine.mergeRanges(ranges.filter { $0.length > 0 })
        guard !merged.isEmpty else { return .refused("No non-empty ranges to delete") }
        let totalRemoved = merged.reduce(0) { $0 + $1.length }

        let anchorTrackId = timeline.tracks[trackIndex].id
        var clearTrackIds: Set<String> = [anchorTrackId]
        // Linked partners of every touched clip, so A/V stays in sync across multi-clip ranges.
        for clip in timeline.tracks[trackIndex].clips
        where clip.linkGroupId != nil && merged.contains(where: { $0.start < clip.endFrame && $0.end > clip.startFrame }) {
            for pid in linkedPartnerIds(of: clip.id) {
                if let l = findClip(id: pid) { clearTrackIds.insert(timeline.tracks[l.trackIndex].id) }
            }
        }
        guard !timeline.tracks.contains(where: { clearTrackIds.contains($0.id) && $0.editLocked }) else {
            return .refused("The edit would change a locked linked track.")
        }

        // Refuse up front if a sync-locked follower can't absorb the shift. These tracks
        // aren't cleared, so their clips are unchanged when the shift is applied below.
        for ti in timeline.tracks.indices {
            let track = timeline.tracks[ti]
            guard !clearTrackIds.contains(track.id), track.syncLocked else { continue }
            let shifts = RippleEngine.computeRippleShiftsForRanges(clips: track.clips, removedRanges: merged)
            guard !track.editLocked || shifts.isEmpty else {
                return .refused("The edit would move clips on a locked track.")
            }
            if let reason = validateShifts(trackIndex: ti, shifts: shifts) {
                return .refused(reason)
            }
        }

        let anchorBeforeIds = Set(timeline.tracks[trackIndex].clips.map(\.id))

        var shiftedClips = 0
        withTimelineSwap(actionName: "Ripple Delete") {
            for tid in clearTrackIds {
                guard let ti = timeline.tracks.firstIndex(where: { $0.id == tid }) else { continue }
                for r in merged {
                    clearRegion(trackIndex: ti, start: r.start, end: r.end, prune: false)
                }
            }
            for ti in timeline.tracks.indices {
                let track = timeline.tracks[ti]
                guard clearTrackIds.contains(track.id) || track.syncLocked else { continue }
                let shifts = RippleEngine.computeRippleShiftsForRanges(clips: track.clips, removedRanges: merged)
                shiftedClips += applyShifts(shifts)
                sortClips(trackIndex: ti)
            }
        }

        // Anchor track's post-cut layout (surviving + new fragments) so the caller needn't re-read.
        let anchorTi = timeline.tracks.firstIndex { $0.id == anchorTrackId } ?? trackIndex
        let afterClips = timeline.tracks[anchorTi].clips
        let afterIds = Set(afterClips.map(\.id))
        let fragments = afterClips
            .filter { afterIds.subtracting(anchorBeforeIds).contains($0.id) || anchorBeforeIds.contains($0.id) }
            .sorted { $0.startFrame < $1.startFrame }
            .map { (clipId: $0.id, startFrame: $0.startFrame, durationFrames: $0.durationFrames) }
        return .ok(RippleRangesReport(
            removedFrames: totalRemoved,
            clearedTracks: clearTrackIds.count,
            shiftedClips: shiftedClips,
            anchorTrackIndex: anchorTi,
            resultingFragments: fragments,
            removedClipIds: Array(anchorBeforeIds.subtracting(afterIds))
        ))
    }

    func rippleDeleteSelectedGap() {
        guard let gap = selectedGap,
              timeline.tracks.indices.contains(gap.trackIndex),
              !timeline.tracks[gap.trackIndex].editLocked,
              gap.range.length > 0 else { return }
        // An out-of-band edit may have filled the gap.
        guard !timeline.tracks[gap.trackIndex].clips.contains(where: {
            $0.startFrame < gap.range.end && $0.endFrame > gap.range.start
        }) else { selectedGap = nil; return }

        var shiftsByTrack: [Int: [ClipShift]] = [:]
        for ti in timeline.tracks.indices {
            guard ti == gap.trackIndex || timeline.tracks[ti].syncLocked else { continue }
            let shifts = RippleEngine.computeRippleShiftsForRanges(
                clips: timeline.tracks[ti].clips,
                removedRanges: [gap.range]
            )
            // The gap track only ever moves clips into freed space; sync-locked followers may collide.
            if ti != gap.trackIndex, let reason = validateShifts(trackIndex: ti, shifts: shifts) {
                refuseRipple(reason: reason)
                return
            }
            guard !timeline.tracks[ti].editLocked || shifts.isEmpty else {
                refuseRipple(reason: "The edit would move clips on a locked track.")
                return
            }
            shiftsByTrack[ti] = shifts
        }

        withTimelineSwap(actionName: "Ripple Delete") {
            for shifts in shiftsByTrack.values { applyShifts(shifts) }
        }
        selectedGap = nil
    }

    /// Ripple insert: add clips at `atFrame` and push everything past it right by the
    /// insertion's duration on the target track and every sync-locked track.
    func rippleInsertTouchesLockedTrack(
        trackIndex: Int?,
        atFrame: Int,
        pushAmount: Int,
        needsLinkedAudio: Bool
    ) -> Bool {
        if let trackIndex {
            guard timeline.tracks.indices.contains(trackIndex) else { return false }
            guard !timeline.tracks[trackIndex].editLocked else { return true }
        }
        let existingLinkedAudioTrackIndex = needsLinkedAudio
            ? timeline.tracks.firstIndex { $0.type == .audio && !$0.editLocked }
            : nil
        let pushTracks = timeline.tracks.indices.filter {
            trackIndex == $0 || $0 == existingLinkedAudioTrackIndex || timeline.tracks[$0].syncLocked
        }
        for ti in pushTracks {
            let track = timeline.tracks[ti]
            let shifts = RippleEngine.computeRipplePush(
                clips: track.clips,
                insertFrame: atFrame,
                pushAmount: pushAmount
            )
            if track.editLocked, !shifts.isEmpty { return true }
            if let straddler = track.clips.first(where: {
                $0.startFrame < atFrame && atFrame < $0.endFrame
            }) {
                let affected = Set([straddler.id] + linkedPartnerIds(of: straddler.id))
                if affected.contains(where: isClipEditLocked) { return true }
            }
        }
        let pushTrackIDs = pushTracks.map { timeline.tracks[$0].id }
        return rippleInsertShiftPlan(
            pushTrackIDs: pushTrackIDs,
            atFrame: atFrame,
            pushAmount: pushAmount,
            splittingStraddlers: true
        ) == nil
    }

    @discardableResult
    func rippleInsertClips(assets: [MediaAsset], trackIndex: Int, atFrame: Int, segments: [String: ClosedRange<Double>] = [:]) -> [String] {
        guard timeline.tracks.indices.contains(trackIndex),
              !timeline.tracks[trackIndex].editLocked else { return [] }
        let totalPush = assets.reduce(0) { $0 + clipDurationFrames(for: $1, segment: segments[$1.id]) }
        let targetIsVideo = timeline.tracks[trackIndex].type == .video
        let needsLinkedAudio = targetIsVideo && assets.contains { $0.type == .video && $0.hasAudio }
        let existingLinkedAudioTrackIndex = needsLinkedAudio
            ? timeline.tracks.firstIndex { $0.type == .audio && !$0.editLocked }
            : nil
        guard !rippleInsertTouchesLockedTrack(
            trackIndex: trackIndex,
            atFrame: atFrame,
            pushAmount: totalPush,
            needsLinkedAudio: needsLinkedAudio
        ) else { return [] }
        var created: [String] = []
        do {
            try withTimelineSwap(actionName: "Ripple Insert Clips") {
                let linkedAudioTrackIndex: Int? = needsLinkedAudio
                    ? (existingLinkedAudioTrackIndex ?? insertTrack(at: timeline.tracks.count, type: .audio))
                    : nil
                let pushTracks = timeline.tracks.indices.filter {
                    $0 == trackIndex || $0 == linkedAudioTrackIndex || timeline.tracks[$0].syncLocked
                }
                let pushTrackIDs = pushTracks.map { timeline.tracks[$0].id }
                for ti in pushTracks {
                    if let straddler = timeline.tracks[ti].clips.first(where: {
                        $0.startFrame < atFrame && atFrame < $0.endFrame
                    }) {
                        _ = splitClip(clipId: straddler.id, atFrame: atFrame)
                    }
                }
                guard let shifts = rippleInsertShiftPlan(
                    pushTrackIDs: pushTrackIDs,
                    atFrame: atFrame,
                    pushAmount: totalPush
                ) else { throw RippleInsertError.invalidatedPlan }
                applyShifts(shifts)
                for index in timeline.tracks.indices { sortClips(trackIndex: index) }
                created = createClips(
                    from: assets,
                    trackIndex: trackIndex,
                    startFrame: atFrame,
                    linkedAudioTrackIndex: linkedAudioTrackIndex,
                    segments: segments
                )
                guard !created.isEmpty else { throw RippleInsertError.invalidatedPlan }
                sortClips(trackIndex: trackIndex)
            }
        } catch {
            return []
        }
        return created
    }

    struct RippleInsertSpec {
        let asset: MediaAsset
        let durationFrames: Int
        let trimStartFrame: Int?
        let trimEndFrame: Int?
    }

    /// Ripple insert with explicit per-clip duration and trim. Opens a gap at `atFrame`
    /// on the target track, every sync-locked track, and the audio track any linked
    /// audio lands on, then places the clips sequentially into the gap.
    @discardableResult
    func rippleInsertClips(specs: [RippleInsertSpec], trackIndex: Int, atFrame: Int) -> [String] {
        guard timeline.tracks.indices.contains(trackIndex),
              !timeline.tracks[trackIndex].editLocked,
              !specs.isEmpty else { return [] }
        let totalPush = specs.reduce(0) { $0 + $1.durationFrames }
        let targetIsVideo = timeline.tracks[trackIndex].type == .video
        let needsLinkedAudio = targetIsVideo && specs.contains { $0.asset.type == .video && $0.asset.hasAudio }
        let existingLinkedAudioTrackIndex = needsLinkedAudio
            ? timeline.tracks.firstIndex { $0.type == .audio && !$0.editLocked }
            : nil
        guard !rippleInsertTouchesLockedTrack(
            trackIndex: trackIndex,
            atFrame: atFrame,
            pushAmount: totalPush,
            needsLinkedAudio: needsLinkedAudio
        ) else { return [] }
        var created: [String] = []
        do {
            try withTimelineSwap(actionName: specs.count == 1 ? "Ripple Insert Clip (Agent)" : "Ripple Insert Clips (Agent)") {
                let linkedAudioTrackIndex: Int? = needsLinkedAudio
                    ? (existingLinkedAudioTrackIndex ?? insertTrack(at: timeline.tracks.count, type: .audio))
                    : nil
                let pushTracks = timeline.tracks.indices.filter {
                    $0 == trackIndex || $0 == linkedAudioTrackIndex || timeline.tracks[$0].syncLocked
                }
                let pushTrackIDs = pushTracks.map { timeline.tracks[$0].id }
                for ti in pushTracks {
                    if let straddler = timeline.tracks[ti].clips.first(where: {
                        $0.startFrame < atFrame && atFrame < $0.endFrame
                    }) {
                        _ = splitClip(clipId: straddler.id, atFrame: atFrame)
                    }
                }
                guard let shifts = rippleInsertShiftPlan(
                    pushTrackIDs: pushTrackIDs,
                    atFrame: atFrame,
                    pushAmount: totalPush
                ) else { throw RippleInsertError.invalidatedPlan }
                applyShifts(shifts)
                for index in timeline.tracks.indices { sortClips(trackIndex: index) }

                var cursor = atFrame
                for spec in specs {
                    let placed = placeClip(
                        asset: spec.asset, trackIndex: trackIndex,
                        startFrame: cursor, durationFrames: spec.durationFrames,
                        linkedAudioTrackIndex: linkedAudioTrackIndex,
                        trimStartFrame: spec.trimStartFrame, trimEndFrame: spec.trimEndFrame
                    )
                    guard !placed.isEmpty else { throw RippleInsertError.invalidatedPlan }
                    created.append(contentsOf: placed)
                    cursor += spec.durationFrames
                }
            }
        } catch {
            return []
        }
        return created
    }

    private func rippleInsertShiftPlan(
        pushTrackIDs: [String],
        atFrame: Int,
        pushAmount: Int,
        splittingStraddlers: Bool = false
    ) -> [ClipShift]? {
        var planningTimeline = timeline
        if splittingStraddlers {
            simulateRippleInsertSplits(
                in: &planningTimeline,
                pushTrackIDs: pushTrackIDs,
                atFrame: atFrame
            )
        }
        var newStarts: [String: Int] = [:]
        for trackID in pushTrackIDs {
            guard let trackIndex = planningTimeline.tracks.firstIndex(where: { $0.id == trackID }) else {
                return nil
            }
            let track = planningTimeline.tracks[trackIndex]
            let shifts = RippleEngine.computeRipplePush(
                clips: track.clips,
                insertFrame: atFrame,
                pushAmount: pushAmount
            )
            if track.editLocked, !shifts.isEmpty { return nil }
            for shift in shifts { newStarts[shift.clipId] = shift.newStartFrame }
        }

        var pending = Array(newStarts.keys)
        var visited: Set<String> = []
        while let clipID = pending.popLast() {
            guard visited.insert(clipID).inserted else { continue }
            for partnerID in linkedPartnerIDs(of: clipID, in: planningTimeline) {
                guard let location = clipLocation(of: partnerID, in: planningTimeline),
                      !planningTimeline.tracks[location.trackIndex].editLocked else { return nil }
                let partner = planningTimeline.tracks[location.trackIndex].clips[location.clipIndex]
                if newStarts[partnerID] == nil {
                    newStarts[partnerID] = partner.startFrame + pushAmount
                }
                pending.append(partnerID)
            }
        }

        for trackIndex in planningTimeline.tracks.indices {
            let shifts = planningTimeline.tracks[trackIndex].clips.compactMap { clip -> ClipShift? in
                guard let start = newStarts[clip.id] else { return nil }
                return ClipShift(clipId: clip.id, newStartFrame: start)
            }
            if !shifts.isEmpty,
               !shiftsAreValid(in: planningTimeline, trackIndex: trackIndex, shifts: shifts) {
                return nil
            }
        }
        return planningTimeline.tracks.flatMap { track in
            track.clips.compactMap { clip in
                newStarts[clip.id].map { ClipShift(clipId: clip.id, newStartFrame: $0) }
            }
        }
    }

    private func simulateRippleInsertSplits(
        in planningTimeline: inout Timeline,
        pushTrackIDs: [String],
        atFrame: Int
    ) {
        var splitOrdinal = 0
        for trackID in pushTrackIDs {
            guard let trackIndex = planningTimeline.tracks.firstIndex(where: { $0.id == trackID }),
                  let lead = planningTimeline.tracks[trackIndex].clips.first(where: {
                      $0.startFrame < atFrame && atFrame < $0.endFrame
                  }) else { continue }
            let groupIDs: Set<String>
            if let linkGroupID = lead.linkGroupId {
                groupIDs = Set(planningTimeline.tracks.flatMap(\.clips).compactMap { clip in
                    clip.linkGroupId == linkGroupID ? clip.id : nil
                })
            } else {
                groupIDs = [lead.id]
            }
            let existingGroupIDs = Set(planningTimeline.tracks.flatMap(\.clips).compactMap(\.linkGroupId))
            var rightGroupID = "__ripple-preflight-group-\(splitOrdinal)"
            while existingGroupIDs.contains(rightGroupID) { rightGroupID += "-" }
            for clipID in groupIDs {
                guard let location = clipLocation(of: clipID, in: planningTimeline) else { continue }
                let clip = planningTimeline.tracks[location.trackIndex].clips[location.clipIndex]
                guard clip.startFrame < atFrame && atFrame < clip.endFrame else { continue }
                let splitOffset = atFrame - clip.startFrame
                var left = clip
                left.durationFrames = splitOffset
                var right = clip
                var rightID = "__ripple-preflight-\(splitOrdinal)-\(clip.id)"
                while clipLocation(of: rightID, in: planningTimeline) != nil { rightID += "-" }
                right.id = rightID
                right.startFrame = atFrame
                right.durationFrames = clip.durationFrames - splitOffset
                if groupIDs.count > 1 { right.linkGroupId = rightGroupID }
                planningTimeline.tracks[location.trackIndex].clips[location.clipIndex] = left
                planningTimeline.tracks[location.trackIndex].clips.append(right)
                planningTimeline.tracks[location.trackIndex].clips.sort {
                    $0.startFrame == $1.startFrame ? $0.id < $1.id : $0.startFrame < $1.startFrame
                }
            }
            splitOrdinal += 1
        }
    }

    private func linkedPartnerIDs(of clipID: String, in planningTimeline: Timeline) -> [String] {
        guard let location = clipLocation(of: clipID, in: planningTimeline),
              let groupID = planningTimeline.tracks[location.trackIndex].clips[location.clipIndex].linkGroupId else {
            return []
        }
        return planningTimeline.tracks.flatMap(\.clips).compactMap { clip in
            clip.id != clipID && clip.linkGroupId == groupID ? clip.id : nil
        }
    }

    private func clipLocation(of clipID: String, in planningTimeline: Timeline) -> ClipLocation? {
        for trackIndex in planningTimeline.tracks.indices {
            if let clipIndex = planningTimeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                return ClipLocation(trackIndex: trackIndex, clipIndex: clipIndex)
            }
        }
        return nil
    }

    private func shiftsAreValid(
        in planningTimeline: Timeline,
        trackIndex: Int,
        shifts: [ClipShift]
    ) -> Bool {
        guard planningTimeline.tracks.indices.contains(trackIndex) else { return false }
        let shiftMap = Dictionary(uniqueKeysWithValues: shifts.map { ($0.clipId, $0.newStartFrame) })
        let intervals = planningTimeline.tracks[trackIndex].clips.map { clip in
            let start = shiftMap[clip.id] ?? clip.startFrame
            return FrameRange(start: start, end: start + clip.durationFrames)
        }.sorted { $0.start < $1.start }
        guard intervals.allSatisfy({ $0.start >= 0 }) else { return false }
        return intervals.indices.dropFirst().allSatisfy { index in
            intervals[index].start >= intervals[index - 1].end
        }
    }

    // MARK: - Internal

    fileprivate func trimClipInternal(clipId: String, trimStartFrame: Int, trimEndFrame: Int) {
        guard let loc = findClip(id: clipId) else { return }
        let ti = loc.trackIndex
        let clip = timeline.tracks[ti].clips[loc.clipIndex]
        let prevStart = clip.trimStartFrame
        let prevEnd = clip.trimEndFrame
        let prevDuration = clip.durationFrames
        // The incoming trim values are source frames; translate their deltas
        // into timeline frames before applying to `startFrame` / `durationFrames`.
        let deltaStartSource = trimStartFrame - prevStart
        let deltaEndSource = trimEndFrame - prevEnd
        let deltaStartTimeline = Int((Double(deltaStartSource) / clip.speed).rounded())
        let deltaEndTimeline = Int((Double(deltaEndSource) / clip.speed).rounded())
        let newDuration = prevDuration - deltaStartTimeline - deltaEndTimeline
        let newStartFrame = clip.startFrame + deltaStartTimeline

        undoManager?.beginUndoGrouping()

        timeline.tracks[ti].clips[loc.clipIndex].trimStartFrame = trimStartFrame
        timeline.tracks[ti].clips[loc.clipIndex].trimEndFrame = trimEndFrame
        timeline.tracks[ti].clips[loc.clipIndex].startFrame = newStartFrame
        timeline.tracks[ti].clips[loc.clipIndex].setDuration(newDuration)

        sortClips(trackIndex: ti)

        undoManager?.registerUndo(withTarget: self) { vm in
            vm.trimClipInternal(clipId: clipId, trimStartFrame: prevStart, trimEndFrame: prevEnd)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Trim Clip")
        notifyTimelineChanged()
    }

    // MARK: - Validation

    /// Dry-run: returns a blocking reason (collision or negative startFrame) or nil if safe.
    fileprivate func validateShifts(trackIndex: Int, shifts: [ClipShift]) -> String? {
        guard !shifts.isEmpty, timeline.tracks.indices.contains(trackIndex) else { return nil }
        let track = timeline.tracks[trackIndex]
        let label = timelineTrackDisplayLabel(at: trackIndex)
        let shiftMap = Dictionary(uniqueKeysWithValues: shifts.map { ($0.clipId, $0.newStartFrame) })
        var intervals: [FrameRange] = []
        for clip in track.clips {
            let start = shiftMap[clip.id] ?? clip.startFrame
            if start < 0 {
                return "Sync-locked track \"\(label)\" would move past the timeline start."
            }
            intervals.append(FrameRange(start: start, end: start + clip.durationFrames))
        }
        intervals.sort { $0.start < $1.start }
        for i in 1..<intervals.count where intervals[i].start < intervals[i-1].end {
            return "Sync-locked track \"\(label)\" doesn't have room to ripple."
        }
        return nil
    }

    /// Refuse a ripple edit: beep + log.
    fileprivate func refuseRipple(reason: String) {
        NSSound.beep()
        Log.editor.notice("ripple blocked: \(reason)")
    }
}
