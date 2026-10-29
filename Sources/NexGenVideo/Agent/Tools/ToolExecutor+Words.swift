import Foundation

extension ToolExecutor {

    private static let removeWordsAllowedKeys: Set<String> = ["words", "cutAggressiveness"]

    func removeWords(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let options = try Self.wordRemovalOptions(args)
        let (words, skipped) = try await timelineWords(editor)
        let edits: WordRemovalEdits
        do { edits = try planWordRemoval(editor, options: options, words: words) }
        catch CaptionSpeechEdits.Failure.replacementRequired(let id) {
            throw ToolError("Caption \(id) needs reviewed replacement text. Use propose_caption_revision with kind=speech_cuts, words and captionChanges, then wait for native approval. remove_words does not accept captionChanges. Nothing was changed.")
        }
        var result = try edits.apply(editor)
        result["skipped"] = skipped
        guard let json = Self.jsonString(result) else { throw ToolError("Failed to encode result") }
        return .ok(json)
    }

    func prepareWordRemoval(_ editor: EditorViewModel, _ args: [String: Any], scope: CaptionRevisionScope? = nil,
                            captionChanges: [String: String] = [:]) async throws -> WordRemovalPlan {
        let options = try Self.wordRemovalOptions(args)
        let captured: CaptionRevisionScope
        if let scope { try scope.validateIdentity(editor); captured = scope }
        else { captured = try await CaptionRevisionScope.capture(editor, kind: .speechCuts) }
        guard captured.kind == .speechCuts else { throw ToolError("This task only proposes caption text changes.") }
        let (words, _) = try await timelineWords(editor, scope: captured)
        try await captured.validate(editor)
        let edits = try planWordRemoval(editor, options: options, words: words, strictIndices: true, captionChanges: captionChanges)
        return .init(scope: captured, edits: edits)
    }

    private static func wordRemovalOptions(_ args: [String: Any]) throws -> (spans: [(Int, Int)], aggressiveness: CutAggressiveness) {
        try validateUnknownKeys(args, allowed: removeWordsAllowedKeys, path: "remove_words")
        guard let rawWords = args["words"] as? [Any], !rawWords.isEmpty else {
            throw ToolError("Missing or empty 'words'. Pass word indices from get_transcript, e.g. [5, [12, 18]].")
        }
        let aggressiveness: CutAggressiveness
        if let raw = args.string("cutAggressiveness") {
            guard let value = CutAggressiveness(rawValue: raw) else {
                throw ToolError("cutAggressiveness must be one of: \(CutAggressiveness.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            aggressiveness = value
        } else { aggressiveness = .balanced }
        return (try parseWordSpans(rawWords), aggressiveness)
    }

    private func planWordRemoval(_ editor: EditorViewModel,
                                 options: (spans: [(Int, Int)], aggressiveness: CutAggressiveness),
                                 words allWords: [TimelineWord], strictIndices: Bool = false,
                                 captionChanges: [String: String] = [:]) throws -> WordRemovalEdits {
        let (spans, aggressiveness) = options
        guard !allWords.isEmpty else { throw ToolError("No transcribable speech on the timeline.") }

        let maxIndex = allWords.count - 1
        let selection = Self.boundedWordSelection(spans, maxIndex: maxIndex)
        let selected = selection.selected
        let ignored = selection.ignored
        guard !strictIndices || ignored.isEmpty else { throw ToolError("Some word indices are no longer available. Read the complete current transcript before proposing cuts.") }
        guard !selected.isEmpty else {
            throw ToolError("None of the requested word indices are in range 0...\(maxIndex). Re-read get_transcript.")
        }

        let keepGapFrames = msToFrames(aggressiveness.keptGapMs, fps: editor.timeline.fps)
        var removedTexts: [String] = []
        var rangesByTrack: [Int: [FrameRange]] = [:]
        var involvedClips: [String] = []
        forEachTimelineClipGroup(in: allWords) { clipId, trackIndex, clipStart, clipEnd, clipWords in
            guard clipWords.contains(where: { selected.contains($0.index) }) else { return }
            removedTexts.append(contentsOf: clipWords.filter { selected.contains($0.index) && $0.endFrame > $0.startFrame }.map(\.text))
            let plan = clipWords.map {
                WordCutPlanner.Word(startFrame: $0.startFrame, endFrame: $0.endFrame, selected: selected.contains($0.index))
            }
            let ranges = WordCutPlanner.cutRanges(words: plan, clipStart: clipStart, clipEnd: clipEnd, keepGapFrames: keepGapFrames)
            if !ranges.isEmpty {
                rangesByTrack[trackIndex, default: []].append(contentsOf: ranges)
                involvedClips.append(clipId)
            }
        }
        guard !rangesByTrack.isEmpty else {
            throw ToolError("The selected words resolved to no removable frames. Re-read get_transcript.")
        }

        // Cut one track; the ripple carries its linked A/V partners across the same span.
        let primaryTrack: Int
        if rangesByTrack.count == 1 {
            primaryTrack = rangesByTrack.first!.key
        } else {
            // Multiple tracks are only coherent as one linked unit (e.g. camera + mic); otherwise
            // cutting them together breaks alignment.
            let groupIds: [String] = involvedClips.compactMap { id in
                editor.findClip(id: id).flatMap { editor.timeline.tracks[$0.trackIndex].clips[$0.clipIndex].linkGroupId }
            }
            guard groupIds.count == involvedClips.count, Set(groupIds).count == 1 else {
                let tracks = rangesByTrack.keys.sorted().map(String.init).joined(separator: ", ")
                throw ToolError("Selected words span multiple unlinked tracks (\(tracks)). Remove words one track at a time — linked video/audio is cut automatically. If these tracks are the same source (e.g. camera + mic), link them into one unit first.")
            }
            primaryTrack = rangesByTrack.keys.min()!
        }
        // Use only the primary track's own ranges; the ripple removes the same span from linked
        // partners, so flattening foreign-track frames here would over-cut the primary track.
        let primaryRanges = RippleEngine.mergeRanges(rangesByTrack[primaryTrack]!)
        let trackID = editor.timeline.tracks[primaryTrack].id
        let captionEdits = try CaptionSpeechEdits.prepare(timeline: editor.timeline, primaryTrackID: trackID,
            ranges: primaryRanges.map { .init(start: $0.start, end: $0.end) },
            words: allWords.map { .init(clipID: $0.clipId, trackID: editor.timeline.tracks[$0.trackIndex].id,
                text: $0.text, startFrame: $0.startFrame, endFrame: $0.endFrame) }, replacements: captionChanges)
        try editor.preflightRippleDeleteRangesOnTrack(trackIndex: primaryTrack, ranges: primaryRanges, captionEdits: captionEdits)
        let affected = allWords.filter { $0.trackIndex == primaryTrack }
        let contexts = primaryRanges.map { range -> WordRemovalEdits.Context in
            let matching = affected.indices.filter { affected[$0].startFrame < range.end && affected[$0].endFrame > range.start }
            let lower = max(0, (matching.first ?? 0) - 5)
            let upper = min(affected.count, (matching.last ?? lower) + 6)
            let nearby = affected[lower..<upper]
            return .init(start: range.start, end: range.end, before: nearby.map(\.text).joined(separator: " "),
                after: nearby.filter { !selected.contains($0.index) || $0.endFrame <= $0.startFrame }.map(\.text).joined(separator: " "))
        }
        return .init(fps: editor.timeline.fps, trackID: trackID, ranges: primaryRanges.map { .init(start: $0.start, end: $0.end) },
            removedTexts: removedTexts, ignored: ignored, aggressiveness: aggressiveness.rawValue,
            contexts: contexts, captionEdits: captionEdits)
    }

    static func parseWordSpans(_ raw: [Any]) throws -> [(Int, Int)] {
        try raw.enumerated().map { i, element in
            if let n = intFromAny(element) { return (n, n) }
            guard let pair = element as? [Any], pair.count == 2,
                  let a = intFromAny(pair[0]), let b = intFromAny(pair[1]) else {
                throw ToolError(
                    "remove_words.words[\(i)]: expected a nonnegative integer index or an [start, end] pair."
                )
            }
            return (a, b)
        }
    }

    static func boundedWordSelection(
        _ spans: [(Int, Int)],
        maxIndex: Int
    ) -> (selected: Set<Int>, ignored: [Int]) {
        var selected = Set<Int>()
        var ignored: [Int] = []
        guard maxIndex >= 0 else { return (selected, ignored) }
        for (a, b) in spans {
            let lower = min(a, b)
            let upper = max(a, b)
            if lower > maxIndex {
                ignored.append(lower)
                continue
            }
            if upper > maxIndex { ignored.append(upper) }
            for index in lower...min(maxIndex, upper) { selected.insert(index) }
        }
        return (selected, ignored)
    }

    private static func intFromAny(_ v: Any) -> Int? {
        ToolIntegerArgument.exact(v, in: ToolIntegerArgument.frameBounds)
    }
}
