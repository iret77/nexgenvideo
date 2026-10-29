import CoreGraphics
import Foundation

extension EditorViewModel {
    struct CaptionRequest {
        var sourceClipIds: [String] = []
        var autoDetect: Bool = false
        var style: TextStyle = TextStyle()
        var center: CGPoint = AppTheme.Caption.defaultCenter
        var textCase: CaptionCase = .auto
        var censorProfanity: Bool = false
        var locale: Locale? = nil
    }

    enum CaptionCase: String, CaseIterable, Sendable {
        case auto, upper, lower

        var label: String {
            switch self {
            case .auto: "Auto"
            case .upper: "UPPERCASE"
            case .lower: "lowercase"
            }
        }

        func apply(_ s: String) -> String {
            switch self {
            case .auto: s
            case .upper: s.uppercased()
            case .lower: s.lowercased()
            }
        }
    }

    func captionLineFits(_ line: String, style: TextStyle) -> Bool {
        let size = TextLayout.naturalSize(
            content: line, style: style, maxWidth: .greatestFiniteMagnitude, canvasHeight: CGFloat(timeline.height)
        )
        return size.width <= CGFloat(timeline.width) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio
    }

    enum CaptionError: LocalizedError, Equatable {
        case noSource
        case timelineChanged
        case sourceChanged
        case sourceUnavailable
        case notSubtitle(String)
        case subtitleOffline(String)
        case placementFailed

        var errorDescription: String? {
            switch self {
            case .noSource: "No audio clips to caption."
            case .timelineChanged: "The project or timeline changed while preparing captions. Start again."
            case .sourceChanged: "A source changed while preparing captions. Start again."
            case .sourceUnavailable: "A caption source is unavailable. Relink it, then start again."
            case .notSubtitle(let name): "“\(name)” is not an SRT or WebVTT file."
            case .subtitleOffline(let name): "“\(name)” is offline. Relink it, then import again."
            case .placementFailed: "The captions couldn't be placed. The timeline was not changed."
            }
        }
    }

    func captionCanTranscribe(_ clip: Clip) -> Bool {
        guard clip.mediaType == .video || clip.mediaType == .audio else { return false }
        guard let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }) else { return true }
        return asset.type == .audio || (asset.type == .video && asset.hasAudio)
    }

    func captionUsesVideoAudioExtraction(for clip: Clip) -> Bool {
        let assetType = mediaAssets.first(where: { $0.id == clip.mediaRef })?.type
        return assetType == .video || (assetType == nil && clip.mediaType == .video)
    }

    func captionTargets(ids: [String]) -> [Clip] {
        let pool: [Clip] = ids.isEmpty
            ? timeline.tracks.flatMap(\.clips)
            : ids.compactMap { findClip(id: $0).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] } }
        return captionTargets(in: pool)
    }

    func captionTargets(trackIds: Set<String>) -> [Clip] {
        guard !trackIds.isEmpty else { return [] }
        let audioGroups = Set(timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .audio }.compactMap(\.linkGroupId))
        let pool = timeline.tracks
            .filter { trackIds.contains($0.id) }
            .flatMap(\.clips)
            .filter { !($0.mediaType == .video && $0.linkGroupId.map(audioGroups.contains) == true) }
        return captionTargets(in: pool)
    }

    private func captionTargets(in pool: [Clip]) -> [Clip] {
        let linkGroupsWithAudio = Set(pool.filter { $0.mediaType == .audio }.compactMap(\.linkGroupId))
        return pool
            .filter { clip in
                guard captionCanTranscribe(clip) else { return false }
                guard clip.mediaType == .video, let groupId = clip.linkGroupId else { return true }
                return !linkGroupsWithAudio.contains(groupId)
            }
            .sorted { $0.startFrame < $1.startFrame }
    }

    private struct CaptionTarget {
        let id: String
        let trackId: String
        let clip: Clip
    }

    @discardableResult
    func generateCaptions(for request: CaptionRequest) async throws -> [String] {
        let state = CaptionProjectState(self)
        let candidates = request.autoDetect ? captionTargets(ids: []) : captionTargets(ids: request.sourceClipIds)
        guard !candidates.isEmpty else { throw CaptionError.noSource }

        var inputs: [String: URL] = [:]
        for clip in candidates {
            guard let url = mediaResolver.resolveURL(for: clip.mediaRef) else { throw CaptionError.sourceUnavailable }
            inputs[clip.mediaRef] = url
        }

        var targets = candidates.compactMap { c in
            findClip(id: c.id).map {
                CaptionTarget(id: c.id, trackId: timeline.tracks[$0.trackIndex].id, clip: timeline.tracks[$0.trackIndex].clips[$0.clipIndex])
            }
        }
        let capturedInputs = inputs
        let preparation = Task.detached(priority: .userInitiated) { try CaptionInputSnapshot.freeze(capturedInputs) }
        let frozen = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { frozen.discard() }
        try state.validate(self)
        let results = try await transcribe(targets, request: request, inputs: frozen, state: state)
        let verification = Task.detached(priority: .userInitiated) { try frozen.validateSources() }
        try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
        try state.validate(self)
        guard inputs.allSatisfy({ mediaResolver.resolveURL(for: $0.key) == $0.value }) else { throw CaptionError.sourceChanged }

        if request.autoDetect {
            guard let winner = dominantSpeechTrack(targets, results) else { return [] }
            targets = targets.filter { $0.trackId == winner }
        }

        let specs = captionSpecs(targets, results: results, request: request)
        guard !specs.isEmpty else { return [] }
        return try placeCaptionTrack(specs, actionName: "Generate Captions")
    }

    private func transcribe(_ targets: [CaptionTarget], request: CaptionRequest, inputs: CaptionInputSnapshot, state: CaptionProjectState) async throws -> [String: TranscriptionResult] {
        var results: [String: TranscriptionResult] = [:]
        for t in targets where results[t.clip.mediaRef] == nil {
            try state.validate(self)
            guard let source = inputs.sources[t.clip.mediaRef] else { throw CaptionError.sourceUnavailable }
            let range = visibleSourceUnion(for: t.clip.mediaRef, in: targets)
            let isVideo = captionUsesVideoAudioExtraction(for: t.clip)
            results[t.clip.mediaRef] = try await captionTranscriptionClient.transcribeFrozen(source, video: isVideo,
                range: range, censor: request.censorProfanity, locale: request.locale)
        }
        return results
    }

    private func visibleSourceUnion(for mediaRef: String, in targets: [CaptionTarget]) -> ClosedRange<Double>? {
        let fps = Double(timeline.fps)
        let spans = targets.filter { $0.clip.mediaRef == mediaRef }.map { visibleSource($0.clip) }
        guard fps > 0, let lo = spans.map(\.start).min(), let hi = spans.map(\.end).max(), hi > lo else { return nil }
        let pad = 1.0
        return max(lo / fps - pad, 0)...(hi / fps + pad)
    }

    private func dominantSpeechTrack(_ targets: [CaptionTarget], _ results: [String: TranscriptionResult]) -> String? {
        var wordsByTrack: [String: Int] = [:]
        for t in targets {
            guard let result = results[t.clip.mediaRef] else { continue }
            wordsByTrack[t.trackId, default: 0] += spokenWordCount(in: t.clip, result)
        }
        return wordsByTrack.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }

    private func captionSpecs(_ targets: [CaptionTarget], results: [String: TranscriptionResult], request: CaptionRequest) -> [TextClipSpec] {
        let fps = timeline.fps
        let groupId = UUID().uuidString
        let transformFor = captionTransform(style: request.style, center: request.center)

        var phrasesByClip: [String: [CaptionBuilder.Phrase]] = [:]
        for (ref, result) in results {
            let clips = targets.filter { $0.clip.mediaRef == ref }
            guard !clips.isEmpty else { continue }
            let phrases = result.segments.flatMap {
                CaptionBuilder.phrases(for: $0, fits: { captionLineFits($0, style: request.style) }, minDuration: AppTheme.Caption.minDisplayDuration)
            }
            for p in phrases {
                guard let owner = bestClip(for: p, among: clips) else { continue }
                phrasesByClip[owner.id, default: []].append(p)
            }
        }

        return targets.flatMap { t -> [TextClipSpec] in
            guard let phrases = phrasesByClip[t.id] else { return [] }
            let cased = phrases.map { CaptionBuilder.Phrase(text: request.textCase.apply($0.text), start: $0.start, end: $0.end) }
            return CaptionBuilder.specs(for: cased, sourceClip: t.clip, trackIndex: 0, fps: fps, style: request.style, captionGroupId: groupId, transformFor: transformFor)
        }
    }

    // The clip with the most overlap owns the phrase
    private func bestClip(for p: CaptionBuilder.Phrase, among clips: [CaptionTarget]) -> CaptionTarget? {
        let ps = p.start * Double(timeline.fps), pe = p.end * Double(timeline.fps)
        func overlap(_ c: Clip) -> Double {
            let v = visibleSource(c)
            return max(0, min(pe, v.end) - max(ps, v.start))
        }
        guard let best = clips.max(by: { overlap($0.clip) < overlap($1.clip) }) else { return nil }
        let o = overlap(best.clip)
        return o > 0 && o >= (pe - ps) / 2 ? best : nil
    }

    private func spokenWordCount(in clip: Clip, _ result: TranscriptionResult) -> Int {
        let v = visibleSource(clip)
        let fps = Double(timeline.fps)
        return result.words.reduce(0) { count, w in
            guard let s = w.start, let e = w.end else { return count }
            let mid = (s + e) / 2 * fps
            return v.start <= mid && mid < v.end ? count + 1 : count
        }
    }

    private func visibleSource(_ c: Clip) -> (start: Double, end: Double) {
        let s = Double(c.trimStartFrame)
        return (s, s + Double(c.durationFrames) * max(c.speed, 0.0001))
    }

    private func captionTransform(style: TextStyle, center: CGPoint) -> (String) -> Transform? {
        let canvasW = Double(timeline.width), canvasH = Double(timeline.height)
        return { text in
            let natural = TextLayout.naturalSize(
                content: text, style: style, maxWidth: CGFloat(canvasW) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio, canvasHeight: CGFloat(canvasH)
            )
            return Transform(
                center: (Double(center.x), Double(center.y)),
                width: Double(natural.width) / canvasW,
                height: Double(natural.height) / canvasH
            )
        }
    }

    private func placeCaptionTrack(_ specs: [TextClipSpec], actionName: String) throws -> [String] {
        var specs = specs
        var laneEnds: [Int] = []
        for index in specs.indices.sorted(by: { specs[$0].startFrame < specs[$1].startFrame }) {
            let spec = specs[index]
            let lane = laneEnds.firstIndex(where: { $0 <= spec.startFrame }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(0) }
            laneEnds[lane] = spec.startFrame + spec.durationFrames
            specs[index].trackIndex = lane
        }
        var ids: [String] = []
        try withTimelineSwap(actionName: actionName) {
            for _ in laneEnds { timeline.tracks.insert(Track(type: .video), at: 0) }
            ids = placeTextClips(specs)
            guard captionPlacementMatches(specs, ids) else { throw CaptionError.placementFailed }
        }
        return ids
    }

    private struct SubtitleSource {
        let url: URL
        let filename: String?
        let assetID: String?
    }

    private func prepareSubtitlePlans(_ sources: [SubtitleSource]) async throws -> [SubtitleCaptionPlan] {
        guard !sources.isEmpty else { return [] }
        let state = CaptionProjectState(self)
        let inputs = Dictionary(uniqueKeysWithValues: sources.enumerated().map { (String($0.offset), $0.element.url) })
        let preparation = Task.detached(priority: .userInitiated) { try CaptionInputSnapshot.freeze(inputs) }
        let frozen = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { frozen.discard() }
        var plans: [SubtitleCaptionPlan] = []
        for (index, source) in sources.enumerated() {
            try state.validate(self)
            guard let input = frozen.sources[String(index)] else { throw CaptionError.sourceUnavailable }
            let document = try await SubtitleFileParser.parseFile(at: input.frozen)
            let filename = MediaFilename.normalized(source.filename)
                ?? MediaFilename.normalized(source.url.lastPathComponent)
                ?? "Captions.\(document.format.rawValue)"
            let provenance = CaptionProvenance(sourceFilename: filename, sourceFormat: document.format.rawValue,
                languageIdentifier: document.languageIdentifier ?? SubtitleFileParser.languageIdentifier(fromFilename: filename),
                sourceAssetID: source.assetID)
            plans.append(try await SubtitleCaptionBuilder.build(document: document, fps: state.timeline.fps,
                canvasWidth: state.timeline.width, canvasHeight: state.timeline.height,
                style: TextStyle(fontSize: AppTheme.Caption.defaultFontSize), center: AppTheme.Caption.defaultCenter,
                provenance: provenance))
        }
        let verification = Task.detached(priority: .userInitiated) { try frozen.validateSources() }
        try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
        try state.validate(self)
        return plans
    }

    func subtitleCaptionPlan(from url: URL, sourceFilename: String? = nil, sourceAssetID: String? = nil) async throws -> SubtitleCaptionPlan {
        let plans = try await prepareSubtitlePlans([.init(url: url, filename: sourceFilename, assetID: sourceAssetID)])
        guard let plan = plans.first else { throw CaptionError.placementFailed }
        return plan
    }

    @discardableResult
    func importCaptions(from url: URL, sourceFilename: String? = nil, sourceAssetID: String? = nil) async throws -> [String] {
        let state = CaptionProjectState(self)
        let plans = try await prepareSubtitlePlans([.init(url: url, filename: sourceFilename, assetID: sourceAssetID)])
        try state.validate(self)
        return try placeSubtitleCaptionPlans(plans)
    }

    @discardableResult
    func placeCaptions(fromSubtitleAssets assets: [MediaAsset]) async throws -> [String] {
        let state = CaptionProjectState(self)
        let sources = try assets.map { asset -> SubtitleSource in
            guard asset.type == .subtitle else { throw CaptionError.notSubtitle(asset.userFacingFilename) }
            guard let url = mediaResolver.resolveURL(for: asset.id) else { throw CaptionError.subtitleOffline(asset.userFacingFilename) }
            return .init(url: url, filename: asset.userFacingFilename, assetID: asset.id)
        }
        let plans = try await prepareSubtitlePlans(sources)
        try state.validate(self)
        guard sources.allSatisfy({ source in source.assetID.map { mediaResolver.resolveURL(for: $0) == source.url } ?? true }) else {
            throw CaptionError.sourceChanged
        }
        return try placeSubtitleCaptionPlans(plans)
    }

    private func placeSubtitleCaptionPlans(_ plans: [SubtitleCaptionPlan]) throws -> [String] {
        guard !plans.isEmpty else { return [] }
        var specs: [TextClipSpec] = []
        var trackOffset = 0
        for plan in plans {
            specs.append(contentsOf: plan.specs.map { spec in
                var shifted = spec
                shifted.trackIndex += trackOffset
                return shifted
            })
            trackOffset += plan.trackCount
        }
        guard !specs.isEmpty else { throw CaptionError.placementFailed }

        var ids: [String] = []
        try withTimelineSwap(actionName: "Add Captions") {
            for _ in 0..<trackOffset {
                timeline.tracks.insert(Track(type: .video), at: 0)
            }
            ids = placeTextClips(specs)
            guard captionPlacementMatches(specs, ids) else { throw CaptionError.placementFailed }
        }
        let overlapCount = plans.reduce(0) { $0 + $1.overlappingCueCount }
        if overlapCount > 0 {
            mediaPanelToast = MediaPanelToast(
                message: "Added \(ids.count) captions. Preserved \(overlapCount) overlapping cues on separate tracks.",
                kind: .success
            )

        }
        return ids
    }

    private func captionPlacementMatches(_ specs: [TextClipSpec], _ ids: [String]) -> Bool {
        ids.count == specs.count && zip(ids, specs).allSatisfy { id, spec in
            guard let clip = clipFor(id: id) else { return false }
            return clip.startFrame == spec.startFrame && clip.durationFrames == spec.durationFrames
                && clip.textContent == spec.content && clip.captionGroupId == spec.captionGroupId
        }
    }

    private static let fillerWords = ["um", "uh", "er", "like", "you know"]

    private static let fillerWordPattern: NSRegularExpression = {
        let alternation = fillerWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\b(\(alternation))\\b(?:[ \\t]*,)?[ \\t]*", options: .caseInsensitive)
    }()

    static func stripFillerWords(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = fillerWordPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        func append(_ range: NSRange, to ranges: inout [NSRange]) {
            if let last = ranges.last, range.location <= NSMaxRange(last) {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else { ranges.append(range) }
        }
        let source = text as NSString
        func horizontalSpace(at index: Int) -> Bool {
            source.character(at: index) == 0x20 || source.character(at: index) == 0x09
        }
        let terminators = [0x2e, 0x21, 0x3f, 0x3b, 0x3a]
        func lineBreak(at index: Int) -> Bool {
            source.character(at: index) == 0x0a || source.character(at: index) == 0x0d
        }
        var runs: [NSRange] = []
        for match in matches { append(match.range, to: &runs) }
        var removals: [NSRange] = []
        for run in runs {
            var start = run.location
            var end = NSMaxRange(run)
            if end < source.length, terminators.contains(Int(source.character(at: end))) {
                while true {
                    while start > 0 && horizontalSpace(at: start - 1) { start -= 1 }
                    if start > 0, source.character(at: start - 1) == 0x2c {
                        start -= 1
                        while start > 0 && horizontalSpace(at: start - 1) { start -= 1 }
                    }
                    guard let previous = removals.last, start <= NSMaxRange(previous) else { break }
                    start = previous.location
                    removals.removeLast()
                }
                let startsLine = start == 0 || lineBreak(at: start - 1)
                if startsLine || terminators.contains(Int(source.character(at: start - 1))) {
                    while end < source.length && terminators.contains(Int(source.character(at: end))) { end += 1 }
                    while end < source.length && horizontalSpace(at: end) { end += 1 }
                    if startsLine || (end < source.length && !lineBreak(at: end)) {
                        while start < end && horizontalSpace(at: start) { start += 1 }
                    }
                }
            }
            append(NSRange(location: start, length: end - start), to: &removals)
        }
        let result = NSMutableString(string: text)
        for removal in removals.reversed() { result.deleteCharacters(in: removal) }
        return result as String
    }

    /// Strips a fixed filler-word list from every caption on the timeline. Deterministic —
    /// no model call — so this runs natively instead of round-tripping through the agent.
    /// Timing is untouched; one undo step for the whole pass.
    @discardableResult
    func removeFillerWordsFromCaptions() -> Int {
        let captionClips = timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text && $0.captionGroupId != nil }
        let edits: [(id: String, text: String)] = captionClips.compactMap { clip in
            guard let original = clip.textContent else { return nil }
            let stripped = Self.stripFillerWords(original)
            return stripped != original ? (clip.id, stripped) : nil
        }
        guard !edits.isEmpty else { return 0 }

        undoManager?.beginUndoGrouping()
        for edit in edits {
            commitClipProperty(clipId: edit.id) { $0.textContent = edit.text }
        }
        undoManager?.setActionName("Remove Filler Words")
        undoManager?.endUndoGrouping()
        return edits.count
    }
}
