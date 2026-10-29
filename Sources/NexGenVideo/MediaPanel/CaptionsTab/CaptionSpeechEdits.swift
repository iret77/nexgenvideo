import Foundation
import NexGenEngine

enum CaptionSpeechEdits {
    struct Range: Codable, Equatable, Sendable {
        let start: Int
        let end: Int
    }
    struct Word: Codable, Equatable, Sendable {
        let clipID: String
        let trackID: String
        let text: String
        let startFrame: Int
        let endFrame: Int
    }
    struct Change: Codable, Equatable, Sendable {
        let trackID: String
        let before: Clip
        let after: Clip?
    }
    struct Plan: Codable, Equatable, Sendable {
        let primaryTrackID: String
        let ranges: [Range]
        let timelineSHA256: String
        let changes: [Change]
    }

    static func prepare(timeline: Timeline, primaryTrackID: String, ranges: [Range], words: [Word],
                        replacements: [String: String] = [:]) throws -> Plan {
        let ranges = try normalized(ranges)
        let affected = try affectedCaptions(timeline: timeline, primaryTrackID: primaryTrackID, ranges: ranges)
        guard Set(affected.map { $0.clip.id }).count == affected.count else { throw ToolError("Affected captions have duplicate identities.") }
        let overlapping = Set(affected.filter { overlaps($0.clip, ranges: ranges) }.map { $0.clip.id })
        guard Set(replacements.keys).isSubset(of: overlapping), replacements.values.allSatisfy({ $0.count <= 4_000 }) else {
            throw ToolError("captionChanges may replace only captions intersecting the speech cut, using at most 4,000 characters each.")
        }
        let changes = try affected.map { item -> Change in
            let before = item.clip
            guard var after = mapped(before, ranges: ranges) else {
                guard replacements[before.id]?.isEmpty != false else {
                    throw ToolError("Caption \(before.id) is completely removed by the speech cut and cannot keep replacement text.")
                }
                return .init(trackID: item.trackID, before: before, after: nil)
            }
            if overlaps(before, ranges: ranges) {
                let text: String
                if let explicit = replacements[before.id] { text = explicit }
                else { text = try survivingText(before, primaryTrackID: primaryTrackID, words: words, ranges: ranges) }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .init(trackID: item.trackID, before: before, after: nil)
                }
                after.textContent = text
            }
            return .init(trackID: item.trackID, before: before, after: after)
        }
        let plan = Plan(primaryTrackID: primaryTrackID, ranges: ranges, timelineSHA256: try fingerprint(timeline), changes: changes)
        try requireCurrent(plan, timeline: timeline, primaryTrackID: primaryTrackID, ranges: ranges)
        return plan
    }

    static func requireCurrent(_ plan: Plan, timeline: Timeline, primaryTrackID: String, ranges: [Range]) throws {
        let canonical = try normalized(ranges)
        guard plan.primaryTrackID == primaryTrackID, plan.ranges == canonical,
              plan.timelineSHA256 == (try fingerprint(timeline)) else {
            throw ToolError("The speech cut or caption timeline changed. Request a new proposal.")
        }
        let affected = try affectedCaptions(timeline: timeline, primaryTrackID: primaryTrackID, ranges: canonical)
        guard affected.count == plan.changes.count, Set(plan.changes.map { $0.before.id }).count == plan.changes.count else {
            throw ToolError("The speech proposal omits an affected caption or repeats its identity.")
        }
        for (item, change) in zip(affected, plan.changes) {
            guard change.trackID == item.trackID, change.before == item.clip else {
                throw ToolError("An affected caption changed. Request a new speech proposal.")
            }
            let expected = mapped(item.clip, ranges: canonical)
            if let after = change.after {
                guard var allowed = expected, let text = after.textContent, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count <= 4_000 else { throw ToolError("The surviving caption has invalid text or timing.") }
                if overlaps(item.clip, ranges: canonical) { allowed.textContent = text }
                guard after == allowed else { throw ToolError("Speech cuts may change caption text and cut timing only.") }
            } else if expected != nil, !overlaps(item.clip, ranges: canonical) {
                throw ToolError("Speech cuts cannot remove a caption outside the removed interval.")
            }
        }
    }

    static func clearedTrackIDs(timeline: Timeline, primaryTrackID: String, ranges: [Range]) throws -> Set<String> {
        guard let primary = timeline.tracks.first(where: { $0.id == primaryTrackID }) else { throw ToolError("The speech track no longer exists.") }
        let groups = Set(primary.clips.filter { overlaps($0, ranges: ranges) }.compactMap(\.linkGroupId))
        return Set([primaryTrackID] + timeline.tracks.filter {
            $0.clips.contains { clip in clip.linkGroupId.map(groups.contains) == true }
        }.map(\.id))
    }

    private struct Located { let trackID: String; let clip: Clip }

    private static func affectedCaptions(timeline: Timeline, primaryTrackID: String, ranges: [Range]) throws -> [Located] {
        let cleared = try clearedTrackIDs(timeline: timeline, primaryTrackID: primaryTrackID, ranges: ranges)
        return timeline.tracks.filter { $0.syncLocked || cleared.contains($0.id) }.flatMap { track in
            track.clips.filter { clip in
                guard clip.mediaType == .text, clip.captionGroupId != nil else { return false }
                return overlaps(clip, ranges: ranges) || mappedFrame(clip.startFrame, ranges: ranges) != clip.startFrame
            }.map { Located(trackID: track.id, clip: $0) }
        }
    }

    private static func normalized(_ ranges: [Range]) throws -> [Range] {
        guard !ranges.isEmpty, ranges.allSatisfy({ $0.start >= 0 && $0.end > $0.start && $0.end <= Int(Int32.max) }) else {
            throw ToolError("Speech cuts need nonempty, nonnegative project-frame ranges.")
        }
        return RippleEngine.mergeRanges(ranges.map { FrameRange(start: $0.start, end: $0.end) })
            .map { Range(start: $0.start, end: $0.end) }
    }

    private static func overlaps(_ clip: Clip, ranges: [Range]) -> Bool {
        ranges.contains { $0.start < clip.endFrame && $0.end > clip.startFrame }
    }

    private static func mappedFrame(_ frame: Int, ranges: [Range]) -> Int {
        frame - ranges.reduce(0) { $0 + max(0, min(frame, $1.end) - $1.start) }
    }

    private static func mapped(_ clip: Clip, ranges: [Range]) -> Clip? {
        let start = mappedFrame(clip.startFrame, ranges: ranges), end = mappedFrame(clip.endFrame, ranges: ranges)
        guard end > start else { return nil }
        var originalStart = clip.startFrame
        for range in ranges where range.start <= originalStart && range.end > originalStart { originalStart = range.end }
        var result = end - start == clip.durationFrames ? clip
            : clip.animationWindow(originOffset: originalStart - clip.startFrame, duration: end - start)
        if clip.effects?.contains(where: { $0.type == ClipAnimationEnvelope.effectType }) != true,
           let index = result.effects?.firstIndex(where: { $0.type == ClipAnimationEnvelope.effectType }) {
            result.effects?[index].id = clip.id + ".speech-envelope"
        }
        result.startFrame = start
        return result
    }

    private static func survivingText(_ caption: Clip, primaryTrackID: String, words: [Word], ranges: [Range]) throws -> String {
        let candidates = words.filter { word in
            guard word.trackID == primaryTrackID, word.endFrame > word.startFrame else { return false }
            let midpoint = Double(word.startFrame) + Double(word.endFrame - word.startFrame) / 2
            return midpoint >= Double(caption.startFrame) && midpoint < Double(caption.endFrame)
        }.sorted { ($0.startFrame, $0.endFrame, $0.clipID) < ($1.startFrame, $1.endFrame, $1.clipID) }
        let tokens = (caption.textContent ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let sameText = !tokens.isEmpty && tokens.map(key) == candidates.map { key($0.text) }
        let nonoverlapping = zip(candidates, candidates.dropFirst()).allSatisfy { $0.0.endFrame <= $0.1.startFrame }
        guard sameText, nonoverlapping, !tokens.map(key).contains("") else { throw replacementRequired(caption.id) }
        return try zip(tokens, candidates).compactMap { pair -> String? in
            let (token, word) = pair
            let overlaps = ranges.filter { $0.start < word.endFrame && $0.end > word.startFrame }
            guard !overlaps.isEmpty else { return token }
            guard overlaps.contains(where: { $0.start <= word.startFrame && $0.end >= word.endFrame }) else {
                throw replacementRequired(caption.id)
            }
            return nil
        }.joined(separator: " ")
    }

    private static func key(_ text: String) -> String {
        let scalars = text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func replacementRequired(_ id: String) -> ToolError {
        ToolError("Caption \(id) intersects the speech cut but has no exact word alignment. Provide its reviewed replacement text in captionChanges; use empty text to remove it.")
    }

    private static func fingerprint(_ timeline: Timeline) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return FileDigest.sha256(of: try encoder.encode(timeline))
    }
}
