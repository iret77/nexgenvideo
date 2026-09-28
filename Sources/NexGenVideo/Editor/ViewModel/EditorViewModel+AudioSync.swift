import Foundation

extension EditorViewModel {
    enum SyncMode: String, CaseIterable, Sendable {
        case auto
        case audio
        case timecode
    }

    enum SyncMethod: String, Sendable {
        case sourceTimecode = "source_timecode"
        case audio
        case captureDate = "capture_date"
    }

    struct SyncSuccess: Sendable, Equatable {
        let clipId: String
        let offsetFrames: Int
        let confidence: Double
        let method: SyncMethod
        let reason: String
        let driftPPM: Double?
        let matchedAnchors: Int?
        let evaluatedAnchors: Int?
    }

    struct SyncFailure: Sendable, Equatable {
        let clipId: String
        let method: SyncMethod?
        let confidence: Double?
        let reason: String
    }

    struct SyncBatchReport: Sendable, Equatable {
        var synced: [SyncSuccess] = []
        var failures: [SyncFailure] = []
        var shiftedFrames: Int = 0
    }

    struct SyncEvidence: Sendable {
        let timings: [String: SourceTiming]
        let envelopes: [String: AudioEnvelope]
    }

    struct SyncPlacement: Sendable, Equatable {
        let resultClipId: String
        let carrierClipId: String
        let rawStart: Int
        let confidence: Double
        let method: SyncMethod
        let reason: String
        let driftPPM: Double?
        let matchedAnchors: Int?
        let evaluatedAnchors: Int?
        let dependsOnClipId: String?
    }

    private struct AudioClip: Sendable {
        let logicalClipId: String
        let clipId: String
        let samples: [Float]
        let speed: Double
        let mediaRef: String
        let trimStartFrame: Int
        let currentStart: Int
    }

    private struct AudioAnchor: Sendable {
        let rawStart: Int
        let clip: AudioClip
        let reliability: Double
    }

    private struct PendingAudio: Sendable {
        let clip: AudioClip
        let fallbackNote: String?
    }

    private struct AudioAttempt: Sendable {
        let assessment: AudioSyncCorrelator.Assessment
        let usedCaptureDate: Bool
        let anchor: AudioAnchor
    }

    private struct AudioPairKey: Hashable {
        let anchorClipId: String
        let targetClipId: String
    }

    enum SyncDefaults {
        static let searchWindowSeconds: Double = 30
        static let maxSearchWindowSeconds: Double = 3_600
        static let minConfidence: Double = 0.7
        static let minSpeed: Double = 0.0001
        static let minOverlapSeconds: Double = 3
        static let maxDriftPPM = AudioSyncCorrelator.defaultMaxDriftPPM
    }

    nonisolated static func timecodeAlignedStart(
        refStartFrame: Int,
        refTrimStartFrame: Int,
        refSpeed: Double,
        refTimecode: SourceTimecode,
        targetTrimStartFrame: Int,
        targetTimecode: SourceTimecode,
        fps: Double
    ) -> Int? {
        guard fps.isFinite, fps > 0,
              let refSeconds = refTimecode.seconds,
              let targetSeconds = targetTimecode.seconds else { return nil }
        let refClock = refSeconds + Double(refTrimStartFrame) / fps
        let targetClock = targetSeconds + Double(targetTrimStartFrame) / fps
        let lagFrames = (targetClock - refClock) * fps / max(refSpeed, 0.0001)
        return boundedRoundedInt(Double(refStartFrame) + lagFrames)
    }

    nonisolated static func captureDateLagSeconds(
        referenceDate: Date,
        referenceTrimStartFrame: Int,
        targetDate: Date,
        targetTrimStartFrame: Int,
        fps: Double
    ) -> Double? {
        guard fps.isFinite, fps > 0 else { return nil }
        let lag = targetDate.timeIntervalSince(referenceDate)
            + (Double(targetTrimStartFrame) - Double(referenceTrimStartFrame)) / fps
        return lag.isFinite ? lag : nil
    }

    nonisolated private static func boundedRoundedInt(_ value: Double) -> Int? {
        let rounded = value.rounded()
        guard rounded.isFinite,
              rounded >= Double(Int.min),
              rounded < Double(Int.max) else { return nil }
        return Int(rounded)
    }

    @discardableResult
    func syncClips(
        referenceClipId: String,
        targetClipIds: [String],
        mode: SyncMode = .auto,
        searchWindowSeconds: Double = SyncDefaults.searchWindowSeconds,
        minConfidence: Double = SyncDefaults.minConfidence,
        evidence: SyncEvidence? = nil
    ) async -> SyncBatchReport {
        let fps = Double(timeline.fps)
        var uniqueTargets: [String] = []
        var seenTargetIds = Set<String>()
        for id in targetClipIds where id != referenceClipId && seenTargetIds.insert(id).inserted {
            uniqueTargets.append(id)
        }
        guard fps > 0, fps.isFinite, let refLocation = findClip(id: referenceClipId) else {
            return SyncBatchReport(failures: uniqueTargets.map {
                SyncFailure(clipId: $0, method: nil, confidence: nil, reason: "Reference clip unavailable.")
            })
        }
        let safeSearchWindow = searchWindowSeconds.isFinite
            && searchWindowSeconds > 0
            && searchWindowSeconds <= SyncDefaults.maxSearchWindowSeconds
            ? searchWindowSeconds
            : SyncDefaults.searchWindowSeconds
        let safeMinConfidence = min(1, max(0, minConfidence.isFinite ? minConfidence : SyncDefaults.minConfidence))
        let refClip = timeline.tracks[refLocation.trackIndex].clips[refLocation.clipIndex]
        let refUnitKey = refClip.linkGroupId ?? refClip.id

        func liveClip(_ id: String) -> Clip? {
            findClip(id: id).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] }
        }
        func unit(of clip: Clip) -> [Clip] {
            guard let group = clip.linkGroupId else { return [clip] }
            return timeline.tracks.flatMap(\.clips).filter { $0.linkGroupId == group }
        }
        func audioBearer(in clips: [Clip]) -> Clip? {
            clips.first(where: { $0.mediaType == .audio && captionCanTranscribe($0) })
                ?? clips.first(where: { captionCanTranscribe($0) })
        }

        var mediaRefs = Set(unit(of: refClip).map(\.mediaRef))
        for id in uniqueTargets {
            guard let clip = liveClip(id) else { continue }
            mediaRefs.formUnion(unit(of: clip).map(\.mediaRef))
        }
        let urlMap = mediaRefs.reduce(into: [String: URL]()) { result, mediaRef in
            result[mediaRef] = mediaResolver.resolveURL(for: mediaRef)
        }
        let timingCache: [String: SourceTiming]
        if let evidence {
            timingCache = evidence.timings
        } else {
            timingCache = await SourceTimingReader.cache(mediaRefs: mediaRefs, urls: urlMap)
        }

        func timecodeCarrier(in clips: [Clip]) -> (clip: Clip, timecode: SourceTimecode)? {
            let matches = clips.compactMap { clip in
                timingCache[clip.mediaRef]?.timecode.map { (clip, $0) }
            }
            return matches.first(where: { $0.0.mediaType.isVisual }) ?? matches.first
        }

        func loadAudioClip(logicalClipId: String, bearer: Clip) async -> AudioClip? {
            let loadedEnvelope: AudioEnvelope?
            if let evidence {
                loadedEnvelope = evidence.envelopes[bearer.mediaRef]
            } else {
                loadedEnvelope = await envelope(of: bearer, fps: fps)
            }
            guard let loadedEnvelope, !loadedEnvelope.samples.isEmpty else {
                return nil
            }
            return AudioClip(
                logicalClipId: logicalClipId,
                clipId: bearer.id,
                samples: loadedEnvelope.samples,
                speed: bearer.speed,
                mediaRef: bearer.mediaRef,
                trimStartFrame: bearer.trimStartFrame,
                currentStart: bearer.startFrame
            )
        }

        let referenceUnit = unit(of: refClip)
        let refTimecodeCarrier = mode == .audio ? nil : timecodeCarrier(in: referenceUnit)
        var report = SyncBatchReport()
        var placements: [SyncPlacement] = []
        var timecodeAudioAnchors: [(rawStart: Int, clips: [Clip], logicalId: String)] = []
        var pendingAudio: [PendingAudio] = []
        var seenUnits = Set<String>()

        for targetId in uniqueTargets {
            guard let targetClip = liveClip(targetId) else {
                report.failures.append(SyncFailure(
                    clipId: targetId,
                    method: nil,
                    confidence: nil,
                    reason: "Clip not found."
                ))
                continue
            }
            let unitKey = targetClip.linkGroupId ?? targetClip.id
            if unitKey == refUnitKey {
                report.failures.append(SyncFailure(
                    clipId: targetId,
                    method: nil,
                    confidence: nil,
                    reason: "Clip is linked to the reference and already moves with it."
                ))
                continue
            }
            guard seenUnits.insert(unitKey).inserted else { continue }
            let targetUnit = unit(of: targetClip)
            var fallbackNote: String?

            if mode != .audio,
               let (refCarrier, refTimecode) = refTimecodeCarrier,
               let (targetCarrier, targetTimecode) = timecodeCarrier(in: targetUnit) {
                let compatibility = refTimecode.compatibility(with: targetTimecode)
                if compatibility.isCompatible,
                   let liveReference = liveClip(refCarrier.id),
                   let liveTarget = liveClip(targetCarrier.id),
                   let rawStart = Self.timecodeAlignedStart(
                       refStartFrame: liveReference.startFrame,
                       refTrimStartFrame: liveReference.trimStartFrame,
                       refSpeed: liveReference.speed,
                       refTimecode: refTimecode,
                       targetTrimStartFrame: liveTarget.trimStartFrame,
                       targetTimecode: targetTimecode,
                       fps: fps
                   ) {
                    placements.append(SyncPlacement(
                        resultClipId: targetId,
                        carrierClipId: targetCarrier.id,
                        rawStart: rawStart,
                        confidence: 0.95,
                        method: .sourceTimecode,
                        reason: compatibility.reason,
                        driftPPM: nil,
                        matchedAnchors: nil,
                        evaluatedAnchors: nil,
                        dependsOnClipId: nil
                    ))
                    timecodeAudioAnchors.append((rawStart, targetUnit, targetId))
                    continue
                }
                fallbackNote = compatibility.reason
            } else if mode != .audio {
                fallbackNote = refTimecodeCarrier == nil
                    ? "Reference has no source timecode."
                    : "Clip has no source timecode."
            }

            if mode == .timecode {
                report.failures.append(SyncFailure(
                    clipId: targetId,
                    method: .sourceTimecode,
                    confidence: nil,
                    reason: fallbackNote ?? "Compatible source timecode is unavailable."
                ))
                continue
            }

            guard let bearer = audioBearer(in: targetUnit),
                  let audioClip = await loadAudioClip(logicalClipId: targetId, bearer: bearer) else {
                report.failures.append(dateOnlyFailure(
                    targetId: targetId,
                    targetUnit: targetUnit,
                    referenceUnit: referenceUnit,
                    timingCache: timingCache,
                    fps: fps,
                    fallbackNote: fallbackNote
                ))
                continue
            }
            pendingAudio.append(PendingAudio(clip: audioClip, fallbackNote: fallbackNote))
        }

        var anchors: [AudioAnchor] = []
        if !pendingAudio.isEmpty {
            if let bearer = audioBearer(in: referenceUnit),
               let audioClip = await loadAudioClip(logicalClipId: referenceClipId, bearer: bearer) {
                anchors.append(AudioAnchor(rawStart: bearer.startFrame, clip: audioClip, reliability: 1))
            }
            for metadataAnchor in timecodeAudioAnchors {
                guard let bearer = audioBearer(in: metadataAnchor.clips),
                      let audioClip = await loadAudioClip(
                          logicalClipId: metadataAnchor.logicalId,
                          bearer: bearer
                      ) else { continue }
                anchors.append(AudioAnchor(rawStart: metadataAnchor.rawStart, clip: audioClip, reliability: 0.95))
            }
        }

        let hop = AudioEnvelopeExtractor.hopSeconds
        let maxLag = max(1, Int((safeSearchWindow / hop).rounded()))
        let minOverlap = max(
            AudioSyncCorrelator.minOverlap,
            Int((SyncDefaults.minOverlapSeconds / hop).rounded())
        )
        let maxDriftPPM = SyncDefaults.maxDriftPPM

        func correlate(_ anchor: AudioAnchor, _ target: AudioClip) async -> AudioAttempt {
            let referenceSamples = anchor.clip.samples
            let targetSamples = target.samples
            let anchorSpeed = anchor.clip.speed.isFinite && anchor.clip.speed > 0
                ? max(anchor.clip.speed, SyncDefaults.minSpeed)
                : SyncDefaults.minSpeed
            let timelineCenterValue = (Double(target.currentStart) - Double(anchor.rawStart))
                * anchorSpeed / (hop * fps)
            let timelineCenter = Self.boundedRoundedInt(timelineCenterValue) ?? 0
            async let broadAssessment = Task.detached(priority: .userInitiated) {
                AudioSyncCorrelator.match(
                    reference: referenceSamples,
                    target: targetSamples,
                    maxLagHops: min(maxLag, max(referenceSamples.count, targetSamples.count)),
                    centerLagHops: timelineCenter,
                    minOverlapHops: minOverlap,
                    maxDriftPPM: maxDriftPPM
                )
            }.value

            var dateAssessment: AudioSyncCorrelator.Assessment?
            if let anchorDate = timingCache[anchor.clip.mediaRef]?.captureDate,
               let targetDate = timingCache[target.mediaRef]?.captureDate,
               let lagSeconds = Self.captureDateLagSeconds(
                   referenceDate: anchorDate,
                   referenceTrimStartFrame: anchor.clip.trimStartFrame,
                   targetDate: targetDate,
                   targetTrimStartFrame: target.trimStartFrame,
                   fps: fps
               ) {
                let centerValue = (lagSeconds / hop).rounded()
                if centerValue >= Double(Int.min), centerValue < Double(Int.max) {
                    let center = Int(centerValue)
                    dateAssessment = await Task.detached(priority: .userInitiated) {
                        AudioSyncCorrelator.match(
                            reference: referenceSamples,
                            target: targetSamples,
                            maxLagHops: min(maxLag, max(referenceSamples.count, targetSamples.count)),
                            centerLagHops: center,
                            minOverlapHops: minOverlap,
                            maxDriftPPM: maxDriftPPM
                        )
                    }.value
                }
            }

            let broad = await broadAssessment
            guard let dateAssessment else {
                return AudioAttempt(assessment: broad, usedCaptureDate: false, anchor: anchor)
            }
            let broadAccepted = broad.isAccepted
            let dateAccepted = dateAssessment.isAccepted
            if broadAccepted, dateAccepted,
               let broadResult = broad.result,
               let dateResult = dateAssessment.result,
               abs(Double(broadResult.lagHops) - Double(dateResult.lagHops))
                   > Double(max(25, minOverlap / 4)),
               abs(broadResult.confidence - dateResult.confidence) < 0.1 {
                let stronger = broadResult.confidence >= dateResult.confidence ? broadResult : dateResult
                let ambiguous = AudioSyncCorrelator.Result(
                    lagHops: stronger.lagHops,
                    confidence: min(stronger.confidence, 0.49),
                    driftPPM: stronger.driftPPM,
                    matchedAnchors: stronger.matchedAnchors,
                    evaluatedAnchors: stronger.evaluatedAnchors,
                    meanCorrelation: stronger.meanCorrelation,
                    isAmbiguous: true
                )
                return AudioAttempt(
                    assessment: AudioSyncCorrelator.Assessment(result: ambiguous, failure: .ambiguous),
                    usedCaptureDate: true,
                    anchor: anchor
                )
            }
            if dateAccepted != broadAccepted {
                return AudioAttempt(
                    assessment: dateAccepted ? dateAssessment : broad,
                    usedCaptureDate: dateAccepted,
                    anchor: anchor
                )
            }
            if (dateAssessment.result?.confidence ?? 0) > (broad.result?.confidence ?? 0) {
                return AudioAttempt(assessment: dateAssessment, usedCaptureDate: true, anchor: anchor)
            }
            return AudioAttempt(assessment: broad, usedCaptureDate: false, anchor: anchor)
        }

        var diagnostics: [String: AudioAttempt] = [:]
        var attemptCache: [AudioPairKey: AudioAttempt] = [:]
        var remaining = pendingAudio
        while !remaining.isEmpty, !anchors.isEmpty {
            var bestChoice: (pendingIndex: Int, attempt: AudioAttempt, confidence: Double)?
            for (pendingIndex, pending) in remaining.enumerated() {
                for anchor in anchors where anchor.clip.clipId != pending.clip.clipId {
                    let key = AudioPairKey(
                        anchorClipId: anchor.clip.clipId,
                        targetClipId: pending.clip.clipId
                    )
                    let attempt: AudioAttempt
                    if let cached = attemptCache[key] {
                        attempt = cached
                    } else {
                        attempt = await correlate(anchor, pending.clip)
                        attemptCache[key] = attempt
                    }
                    if diagnostics[pending.clip.logicalClipId] == nil
                        || (attempt.assessment.result?.confidence ?? 0)
                            > (diagnostics[pending.clip.logicalClipId]?.assessment.result?.confidence ?? 0) {
                        diagnostics[pending.clip.logicalClipId] = attempt
                    }
                    guard attempt.assessment.isAccepted,
                          let result = attempt.assessment.result else { continue }
                    let confidence = min(result.confidence, anchor.reliability)
                    guard confidence >= safeMinConfidence else { continue }
                    if confidence > (bestChoice?.confidence ?? -1) {
                        bestChoice = (pendingIndex, attempt, confidence)
                    }
                }
            }
            guard let bestChoice,
                  let result = bestChoice.attempt.assessment.result else { break }
            let pending = remaining.remove(at: bestChoice.pendingIndex)
            let anchor = bestChoice.attempt.anchor
            let anchorSpeed = anchor.clip.speed.isFinite && anchor.clip.speed > 0
                ? max(anchor.clip.speed, SyncDefaults.minSpeed)
                : SyncDefaults.minSpeed
            let lagFrames = Double(result.lagHops) * hop * fps
                / anchorSpeed
            guard let rawStart = Self.boundedRoundedInt(Double(anchor.rawStart) + lagFrames) else {
                report.failures.append(SyncFailure(
                    clipId: pending.clip.logicalClipId,
                    method: .audio,
                    confidence: bestChoice.confidence,
                    reason: "Audio alignment is outside the supported timeline range. No move was applied."
                ))
                continue
            }
            let reason = audioReason(
                result: result,
                usedCaptureDate: bestChoice.attempt.usedCaptureDate,
                anchorClipId: anchor.clip.logicalClipId,
                referenceClipId: referenceClipId,
                fallbackNote: pending.fallbackNote
            )
            placements.append(SyncPlacement(
                resultClipId: pending.clip.logicalClipId,
                carrierClipId: pending.clip.clipId,
                rawStart: rawStart,
                confidence: bestChoice.confidence,
                method: .audio,
                reason: reason,
                driftPPM: result.driftPPM,
                matchedAnchors: result.matchedAnchors,
                evaluatedAnchors: result.evaluatedAnchors,
                dependsOnClipId: anchor.clip.logicalClipId == referenceClipId
                    ? nil
                    : anchor.clip.logicalClipId
            ))
            anchors.append(AudioAnchor(
                rawStart: rawStart,
                clip: pending.clip,
                reliability: bestChoice.confidence
            ))
        }

        for pending in remaining {
            if let diagnostic = diagnostics[pending.clip.logicalClipId] {
                report.failures.append(audioFailure(
                    clipId: pending.clip.logicalClipId,
                    assessment: diagnostic.assessment,
                    usedCaptureDate: diagnostic.usedCaptureDate,
                    requiredConfidence: safeMinConfidence,
                    fallbackNote: pending.fallbackNote
                ))
            } else {
                let note = pending.fallbackNote.map { "\($0) " } ?? ""
                report.failures.append(SyncFailure(
                    clipId: pending.clip.logicalClipId,
                    method: .audio,
                    confidence: nil,
                    reason: note + "No placed clip has usable overlapping audio."
                ))
            }
        }

        applySyncPlacements(referenceClipId: referenceClipId, placements: placements, report: &report)
        return report
    }

    func applySyncPlacements(
        referenceClipId: String,
        placements: [SyncPlacement],
        report: inout SyncBatchReport
    ) {
        var allMoves: [(clipId: String, toTrack: Int, toFrame: Int)] = []
        var movedIds = Set<String>()

        func queueMove(of clipId: String, toFrame rawStart: Int, protectReference: Bool) -> String? {
            guard let location = findClip(id: clipId) else { return "Clip not found." }
            let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
            let (delta, deltaOverflow) = rawStart.subtractingReportingOverflow(clip.startFrame)
            guard !deltaOverflow else { return "Alignment is outside the supported timeline range." }
            var moves = [(clipId: clipId, toTrack: location.trackIndex, toFrame: rawStart)]
            for partnerId in linkedPartnerIds(of: clipId) {
                guard let partnerLocation = findClip(id: partnerId) else { continue }
                let partner = timeline.tracks[partnerLocation.trackIndex].clips[partnerLocation.clipIndex]
                let (partnerStart, overflow) = partner.startFrame.addingReportingOverflow(delta)
                guard !overflow else { return "Alignment is outside the supported timeline range." }
                moves.append((
                    clipId: partnerId,
                    toTrack: partnerLocation.trackIndex,
                    toFrame: partnerStart
                ))
            }
            if protectReference, movesWouldClobberReferenceUnit(moves, referenceClipId: referenceClipId) {
                return "Shares a reference track; move it to its own track first."
            }
            if movesOverlapQueued(moves, allMoves) {
                return "Overlaps another clip being synchronized on the same track."
            }
            for move in moves where movedIds.insert(move.clipId).inserted { allMoves.append(move) }
            return nil
        }

        var accepted: [(placement: SyncPlacement, currentStart: Int)] = []
        var rejectedResultIds = Set<String>()
        for placement in placements {
            if let dependency = placement.dependsOnClipId, rejectedResultIds.contains(dependency) {
                report.failures.append(SyncFailure(
                    clipId: placement.resultClipId,
                    method: placement.method,
                    confidence: placement.confidence,
                    reason: "Its audio anchor could not be placed. No move was applied."
                ))
                rejectedResultIds.insert(placement.resultClipId)
                continue
            }
            guard let clip = liveSyncClip(placement.carrierClipId) else {
                report.failures.append(SyncFailure(
                    clipId: placement.resultClipId,
                    method: placement.method,
                    confidence: placement.confidence,
                    reason: "Clip not found."
                ))
                rejectedResultIds.insert(placement.resultClipId)
                continue
            }
            if let failure = queueMove(
                of: placement.carrierClipId,
                toFrame: placement.rawStart,
                protectReference: true
            ) {
                report.failures.append(SyncFailure(
                    clipId: placement.resultClipId,
                    method: placement.method,
                    confidence: placement.confidence,
                    reason: failure
                ))
                rejectedResultIds.insert(placement.resultClipId)
                continue
            }
            accepted.append((placement, clip.startFrame))
        }

        let minimumStart = allMoves.map(\.toFrame).min() ?? 0
        guard minimumStart != Int.min else {
            for item in accepted {
                report.failures.append(SyncFailure(
                    clipId: item.placement.resultClipId,
                    method: item.placement.method,
                    confidence: item.placement.confidence,
                    reason: "Alignment is outside the supported timeline range. No move was applied."
                ))
            }
            return
        }
        let shift = minimumStart < 0 ? -minimumStart : 0
        if shift > 0 {
            guard let reference = liveSyncClip(referenceClipId) else {
                for item in accepted {
                    report.failures.append(SyncFailure(
                        clipId: item.placement.resultClipId,
                        method: item.placement.method,
                        confidence: item.placement.confidence,
                        reason: "Reference clip unavailable."
                    ))
                }
                return
            }
            if let failure = queueMove(
                of: referenceClipId,
                toFrame: reference.startFrame,
                protectReference: false
            ) {
                for item in accepted {
                    report.failures.append(SyncFailure(
                        clipId: item.placement.resultClipId,
                        method: item.placement.method,
                        confidence: item.placement.confidence,
                        reason: failure
                    ))
                }
                return
            }
        }
        var moves: [(clipId: String, toTrack: Int, toFrame: Int)] = []
        var invalidShift = false
        for move in allMoves {
            let (shiftedStart, overflow) = move.toFrame.addingReportingOverflow(shift)
            guard !overflow else {
                invalidShift = true
                break
            }
            guard let clip = liveSyncClip(move.clipId), shiftedStart != clip.startFrame else { continue }
            moves.append((move.clipId, move.toTrack, shiftedStart))
        }
        if invalidShift {
            for item in accepted {
                report.failures.append(SyncFailure(
                    clipId: item.placement.resultClipId,
                    method: item.placement.method,
                    confidence: item.placement.confidence,
                    reason: "Alignment is outside the supported timeline range. No move was applied."
                ))
            }
            return
        }
        if let blockedBy = stationaryCollision(for: moves) {
            for item in accepted {
                report.failures.append(SyncFailure(
                    clipId: item.placement.resultClipId,
                    method: item.placement.method,
                    confidence: item.placement.confidence,
                    reason: "Would overlap clip \(blockedBy). Move it or use an empty track first. No move was applied."
                ))
            }
            return
        }
        report.shiftedFrames = shift
        report.synced.append(contentsOf: accepted.compactMap { item in
            let placement = item.placement
            let (shiftedStart, startOverflow) = placement.rawStart.addingReportingOverflow(shift)
            guard !startOverflow else { return nil }
            let (offset, offsetOverflow) = shiftedStart.subtractingReportingOverflow(item.currentStart)
            guard !offsetOverflow else { return nil }
            return SyncSuccess(
                clipId: placement.resultClipId,
                offsetFrames: offset,
                confidence: placement.confidence,
                method: placement.method,
                reason: placement.reason,
                driftPPM: placement.driftPPM,
                matchedAnchors: placement.matchedAnchors,
                evaluatedAnchors: placement.evaluatedAnchors
            )
        })
        if !moves.isEmpty {
            moveClips(moves)
            undoManager?.setActionName("Synchronize")
        }
    }

    func syncSelection() -> (referenceClipId: String, targetClipIds: [String])? {
        let selected = timeline.tracks.flatMap(\.clips).filter { selectedClipIds.contains($0.id) }
        var units: [String: [Clip]] = [:]
        for clip in selected { units[clip.linkGroupId ?? clip.id, default: []].append(clip) }

        var bearers: [(unit: [Clip], clip: Clip)] = []
        for unit in units.values {
            guard let clip = unit.first(where: { $0.mediaType == .audio && captionCanTranscribe($0) })
                ?? unit.first(where: { captionCanTranscribe($0) })
                ?? unit.first(where: { $0.mediaType == .video }) else { continue }
            bearers.append((unit, clip))
        }
        guard bearers.count >= 2 else { return nil }

        func rank(_ bearer: (unit: [Clip], clip: Clip)) -> (Int, Int, Int) {
            (
                bearer.unit.contains { $0.linkGroupId != nil } ? 0 : 1,
                bearer.unit.contains { $0.mediaType.isVisual } ? 0 : 1,
                bearer.unit.map(\.startFrame).min() ?? 0
            )
        }
        let ordered = bearers.sorted { rank($0) < rank($1) }
        let targets = ordered.dropFirst()
            .sorted { $0.clip.startFrame < $1.clip.startFrame }
            .map(\.clip.id)
        return (ordered[0].clip.id, targets)
    }

    private func dateOnlyFailure(
        targetId: String,
        targetUnit: [Clip],
        referenceUnit: [Clip],
        timingCache: [String: SourceTiming],
        fps: Double,
        fallbackNote: String?
    ) -> SyncFailure {
        let reference = referenceUnit.compactMap { clip in
            timingCache[clip.mediaRef]?.captureDate.map { (clip, $0) }
        }.first
        let target = targetUnit.compactMap { clip in
            timingCache[clip.mediaRef]?.captureDate.map { (clip, $0) }
        }.first
        if let reference, let target,
           let lag = Self.captureDateLagSeconds(
               referenceDate: reference.1,
               referenceTrimStartFrame: reference.0.trimStartFrame,
               targetDate: target.1,
               targetTrimStartFrame: target.0.trimStartFrame,
               fps: fps
           ) {
            guard let frames = Self.boundedRoundedInt(lag * fps) else {
                return SyncFailure(
                    clipId: targetId,
                    method: .captureDate,
                    confidence: 0,
                    reason: "Capture-date offset is outside the supported timeline range. No move was applied."
                )
            }
            let prefix = fallbackNote.map { "\($0) " } ?? ""
            return SyncFailure(
                clipId: targetId,
                method: .captureDate,
                confidence: 0.35,
                reason: prefix
                    + "Capture dates suggest \(frames) frames, but recording clocks alone are not precise enough to move automatically."
            )
        }
        let prefix = fallbackNote.map { "\($0) " } ?? ""
        return SyncFailure(
            clipId: targetId,
            method: .audio,
            confidence: nil,
            reason: prefix + "Clip has no usable audio."
        )
    }

    private func audioReason(
        result: AudioSyncCorrelator.Result,
        usedCaptureDate: Bool,
        anchorClipId: String,
        referenceClipId: String,
        fallbackNote: String?
    ) -> String {
        var parts: [String] = []
        if let fallbackNote { parts.append(fallbackNote) }
        parts.append("\(result.matchedAnchors)/\(result.evaluatedAnchors) audio anchors agreed")
        if usedCaptureDate { parts.append("capture date centered the search") }
        if anchorClipId != referenceClipId { parts.append("matched through clip \(anchorClipId)") }
        parts.append("estimated drift \(Int(result.driftPPM.rounded())) ppm")
        return parts.joined(separator: "; ") + "."
    }

    private func audioFailure(
        clipId: String,
        assessment: AudioSyncCorrelator.Assessment,
        usedCaptureDate: Bool,
        requiredConfidence: Double,
        fallbackNote: String?
    ) -> SyncFailure {
        var prefix = fallbackNote.map { "\($0) " } ?? ""
        if usedCaptureDate { prefix += "Capture date centered the search, but audio did not confirm a unique match. " }
        let confidence = assessment.result?.confidence
        let reason: String
        switch assessment.failure {
        case .insufficientOverlap:
            reason = "Audio overlap is shorter than \(Int(SyncDefaults.minOverlapSeconds)) seconds."
        case .silence:
            reason = "Audio contains no usable non-silent anchors."
        case .weakCorrelation:
            reason = "Audio correlation is too weak for an automatic move."
        case .noConsensus:
            reason = "Audio anchors do not agree on one offset."
        case .ambiguous:
            reason = "Competing repeated audio matches are equally plausible."
        case .excessiveDrift:
            let drift = Int(abs(assessment.result?.driftPPM ?? 0).rounded())
            reason = "Estimated audio drift of \(drift) ppm requires retiming; synchronization only moves clips."
        case nil:
            reason = "Audio confidence is below the required \(Int((requiredConfidence * 100).rounded()))%."
        }
        return SyncFailure(
            clipId: clipId,
            method: .audio,
            confidence: confidence,
            reason: prefix + reason + " No move was applied."
        )
    }

    private func liveSyncClip(_ id: String) -> Clip? {
        findClip(id: id).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] }
    }

    private func movesWouldClobberReferenceUnit(
        _ moves: [(clipId: String, toTrack: Int, toFrame: Int)],
        referenceClipId: String
    ) -> Bool {
        let referenceIds = Set([referenceClipId] + linkedPartnerIds(of: referenceClipId))
        var referenceRanges: [(track: Int, start: Int, end: Int)] = []
        for id in referenceIds {
            guard let location = findClip(id: id) else { continue }
            let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
            let (end, overflow) = clip.startFrame.addingReportingOverflow(clip.durationFrames)
            if overflow { return true }
            referenceRanges.append((location.trackIndex, clip.startFrame, end))
        }
        for move in moves where !referenceIds.contains(move.clipId) {
            guard let location = findClip(id: move.clipId) else { continue }
            let duration = timeline.tracks[location.trackIndex].clips[location.clipIndex].durationFrames
            let (end, overflow) = move.toFrame.addingReportingOverflow(duration)
            if overflow { return true }
            if referenceRanges.contains(where: {
                $0.track == move.toTrack && move.toFrame < $0.end && $0.start < end
            }) {
                return true
            }
        }
        return false
    }

    private func movesOverlapQueued(
        _ moves: [(clipId: String, toTrack: Int, toFrame: Int)],
        _ queued: [(clipId: String, toTrack: Int, toFrame: Int)]
    ) -> Bool {
        func duration(_ clipId: String) -> Int {
            guard let location = findClip(id: clipId) else { return 0 }
            return timeline.tracks[location.trackIndex].clips[location.clipIndex].durationFrames
        }
        for move in moves {
            let (end, overflow) = move.toFrame.addingReportingOverflow(duration(move.clipId))
            if overflow { return true }
            for other in queued where other.toTrack == move.toTrack && other.clipId != move.clipId {
                let (otherEnd, otherOverflow) = other.toFrame.addingReportingOverflow(duration(other.clipId))
                if otherOverflow || (move.toFrame < otherEnd && other.toFrame < end) {
                    return true
                }
            }
        }
        return false
    }

    private func stationaryCollision(
        for moves: [(clipId: String, toTrack: Int, toFrame: Int)]
    ) -> String? {
        let movedIds = Set(moves.map(\.clipId))
        for move in moves {
            guard timeline.tracks.indices.contains(move.toTrack),
                  let location = findClip(id: move.clipId) else { continue }
            let duration = timeline.tracks[location.trackIndex].clips[location.clipIndex].durationFrames
            let (end, overflow) = move.toFrame.addingReportingOverflow(duration)
            guard !overflow else { return move.clipId }
            for clip in timeline.tracks[move.toTrack].clips where !movedIds.contains(clip.id) {
                let (otherEnd, otherOverflow) = clip.startFrame.addingReportingOverflow(clip.durationFrames)
                guard !otherOverflow else { return clip.id }
                if move.toFrame < otherEnd, clip.startFrame < end { return clip.id }
            }
        }
        return nil
    }

    private func envelope(of clip: Clip, fps: Double) async -> AudioEnvelope? {
        guard let url = mediaResolver.resolveURL(for: clip.mediaRef) else { return nil }
        let start = Double(clip.trimStartFrame) / fps
        let speed = clip.speed.isFinite && clip.speed > 0
            ? max(clip.speed, SyncDefaults.minSpeed)
            : SyncDefaults.minSpeed
        let end = start + Double(clip.durationFrames) * speed / fps
        return try? await AudioEnvelopeExtractor.extract(
            from: url,
            range: start...max(start + AudioEnvelopeExtractor.hopSeconds, end)
        )
    }
}
