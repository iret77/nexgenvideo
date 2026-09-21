import Foundation

extension ToolExecutor {

    private static let removeWordsAllowedKeys: Set<String> = ["words", "cutAggressiveness"]

    func removeWords(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.removeWordsAllowedKeys, path: "remove_words")
        guard let rawWords = args["words"] as? [Any], !rawWords.isEmpty else {
            throw ToolError("Missing or empty 'words'. Pass word indices from get_transcript, e.g. [5, [12, 18]].")
        }
        let aggressiveness: CutAggressiveness
        if let raw = args.string("cutAggressiveness") {
            guard let a = CutAggressiveness(rawValue: raw) else {
                throw ToolError("cutAggressiveness must be one of: \(CutAggressiveness.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            aggressiveness = a
        } else { aggressiveness = .balanced }

        let spans = try Self.parseWordSpans(rawWords)

        let (allWords, _) = try await timelineWords(editor)
        guard !allWords.isEmpty else { throw ToolError("No transcribable speech on the timeline.") }

        let maxIndex = allWords.count - 1
        let selection = Self.boundedWordSelection(spans, maxIndex: maxIndex)
        let selected = selection.selected
        let ignored = selection.ignored
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
        let primaryRanges = rangesByTrack[primaryTrack]!

        editor.undoManager?.beginUndoGrouping()
        let outcome = editor.rippleDeleteRangesOnTrack(trackIndex: primaryTrack, ranges: primaryRanges)
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Remove Words (Agent)")
        guard case .ok(let report) = outcome else {
            if case .refused(let reason) = outcome { throw ToolError("Ripple delete refused: \(reason)") }
            throw ToolError("Ripple delete refused.")
        }

        var payload: [String: Any] = [
            "removedWords": removedTexts.count, "removedFrames": report.removedFrames,
            "tracksEdited": report.clearedTracks, "cutAggressiveness": aggressiveness.rawValue,
            "note": "Removed and closed the gaps. Re-read get_transcript before another remove_words.",
        ]
        let preview = removedTexts.prefix(24).joined(separator: " ")
        if !preview.isEmpty { payload["removedText"] = removedTexts.count > 24 ? preview + " …" : preview }
        if !ignored.isEmpty { payload["indicesIgnored"] = ignored.sorted() }
        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode result") }
        return .ok(json)
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
