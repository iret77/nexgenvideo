import Foundation
import NexGenEngine

struct CaptionRevisionScope: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case captions, speechCuts = "speech_cuts" }
    let kind: Kind
    struct Source: Codable, Equatable, Sendable {
        let assetID: String
        let url: URL
        let resolvedURL: URL
        let sha256: String
    }
    let projectID: String
    let workingRoot: URL
    let generation: UUID
    let timelineSHA256: String
    let captionIDs: [String]
    let sources: [Source]

    @MainActor static func capture(_ editor: EditorViewModel, kind: Kind = .captions) throws -> Self {
        guard let id = editor.projectId, let root = editor.workingRoot,
              let generation = editor.openWorkingCopyGeneration else {
            throw ToolError("Save the project before preparing caption changes.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let captions = editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text && $0.captionGroupId != nil }
        let refs = Set(editor.captionTargets(ids: []).map(\.mediaRef))
            .union(captions.compactMap { $0.captionProvenance?.sourceAssetID })
        let sources = try refs.sorted().map { ref -> Source in
            guard let url = editor.mediaResolver.resolveURL(for: ref) else {
                throw ToolError("A caption source is unavailable. Relink it before preparing changes.")
            }
            return .init(assetID: ref, url: url, resolvedURL: url.resolvingSymlinksInPath(), sha256: try FileDigest.sha256(of: url))
        }
        return .init(kind: kind, projectID: id, workingRoot: root, generation: generation,
            timelineSHA256: FileDigest.sha256(of: try encoder.encode(editor.timeline)),
            captionIDs: captions.map(\.id).sorted(), sources: sources)
    }

    @MainActor func validate(_ editor: EditorViewModel) throws {
        try Task.checkCancellation()
        guard try Self.capture(editor, kind: kind) == self else {
            throw ToolError("The project, timeline, or source changed. Discard this proposal and request a new one.")
        }
    }
}

struct WordRemovalPlan: Codable, Equatable, Sendable {
    struct Range: Codable, Equatable, Sendable {
        let start: Int
        let end: Int
    }
    let scope: CaptionRevisionScope
    let trackID: String
    let ranges: [Range]
    let removedTexts: [String]
    let ignored: [Int]
    let aggressiveness: String
    let before: String
    let after: String

    @MainActor func apply(_ editor: EditorViewModel) throws -> [String: Any] {
        try scope.validate(editor)
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ToolError("The speech track no longer exists.")
        }
        let outcome = editor.rippleDeleteRangesOnTrack(trackIndex: index,
            ranges: ranges.map { FrameRange(start: $0.start, end: $0.end) })
        guard case .ok(let report) = outcome else {
            if case .refused(let reason) = outcome { throw ToolError("Ripple delete refused: " + reason) }
            throw ToolError("Ripple delete refused.")
        }
        editor.undoManager?.setActionName("Remove Words")
        var payload: [String: Any] = ["removedWords": removedTexts.count, "removedFrames": report.removedFrames,
            "tracksEdited": report.clearedTracks, "cutAggressiveness": aggressiveness,
            "note": "Removed and closed the gaps. Re-read get_transcript before another remove_words."]
        let preview = removedTexts.prefix(24).joined(separator: " ")
        if !preview.isEmpty { payload["removedText"] = removedTexts.count > 24 ? preview + " …" : preview }
        if !ignored.isEmpty { payload["indicesIgnored"] = ignored.sorted() }
        return payload
    }
}

struct CaptionRevisionPlan: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        let clipID: String
        let text: String
    }
    struct Row: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let before: String
        let after: String
        let timeRange: String
    }
    let scope: CaptionRevisionScope
    let rows: [Row]
    let wordRemoval: WordRemovalPlan?

    @MainActor static func captions(_ changes: [Change], scope: CaptionRevisionScope, editor: EditorViewModel) throws -> Self {
        try scope.validate(editor)
        guard scope.kind == .captions else { throw ToolError("This task only proposes speech cuts.") }
        guard !changes.isEmpty, changes.count <= 500, Set(changes.map(\.clipID)).count == changes.count else {
            throw ToolError("Provide 1–500 unique caption changes.")
        }
        let rows = try changes.compactMap { change -> Row? in
            guard scope.captionIDs.contains(change.clipID), let location = editor.findClip(id: change.clipID) else {
                throw ToolError("Only existing captions in this task can be revised.")
            }
            let clip = editor.timeline.tracks[location.trackIndex].clips[location.clipIndex]
            guard let before = clip.textContent, change.text.count <= 4_000 else {
                throw ToolError("Caption text must contain at most 4,000 characters.")
            }
            guard before != change.text else { return nil }
            return .init(id: clip.id, before: before, after: change.text,
                timeRange: interval(clip.startFrame, clip.endFrame, fps: editor.timeline.fps))
        }
        guard !rows.isEmpty else { throw ToolError("The proposed captions already match the timeline.") }
        return .init(scope: scope, rows: rows, wordRemoval: nil)
    }

    @MainActor static func speech(_ removal: WordRemovalPlan, editor: EditorViewModel) throws -> Self {
        try removal.scope.validate(editor)
        return .init(scope: removal.scope, rows: [.init(id: "speech-cuts", before: removal.before,
            after: removal.after.isEmpty ? "No speech remains in this selection" : removal.after,
            timeRange: removal.ranges.map { interval($0.start, $0.end, fps: editor.timeline.fps) }.joined(separator: ", "))],
            wordRemoval: removal)
    }

    @MainActor func apply(selected: Set<String>, editor: EditorViewModel) throws -> Int {
        guard !selected.isEmpty, selected.isSubset(of: Set(rows.map(\.id))) else { throw ToolError("Select the changes to apply.") }
        try scope.validate(editor)
        if let wordRemoval {
            _ = try wordRemoval.apply(editor)
        } else {
            editor.withTimelineSwap(actionName: "Revise Captions") {
                for row in rows where selected.contains(row.id) {
                    if let location = editor.findClip(id: row.id) {
                        editor.timeline.tracks[location.trackIndex].clips[location.clipIndex].textContent = row.after
                    }
                }
            }
        }
        return selected.count
    }

    var dialog: AgentDialog {
        .init(id: UUID().uuidString, title: wordRemoval == nil ? "Review caption changes" : "Review speech cuts",
            symbol: "captions.bubble", intro: wordRemoval == nil
                ? "Select the caption changes to apply. Timing and audio are preserved."
                : "Review the removed time ranges. Applying cuts the speech and linked video, and closes the gaps.",
            costHint: nil, confirmLabel: "Apply Selected", textField: nil,
            sections: [.init(id: "caption-revision", label: "Proposed changes", kind: .choices(options: rows.map {
                .init(id: $0.id, label: $0.timeRange + " · " + $0.before + " → " + $0.after, shortLabel: $0.timeRange)
            }, multiSelect: true))], purpose: .captionRevision, captionRevision: self)
    }

    private static func interval(_ start: Int, _ end: Int, fps: Int) -> String {
        String(format: "%.2f–%.2f s", Double(start) / Double(max(1, fps)), Double(end) / Double(max(1, fps)))
    }
}
