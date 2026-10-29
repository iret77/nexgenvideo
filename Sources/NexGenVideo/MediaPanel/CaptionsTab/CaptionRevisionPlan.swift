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

    private struct Binding: Equatable, Sendable {
        let assetID: String
        let url: URL
        let resolvedURL: URL
    }
    private struct Identity: Equatable, Sendable {
        let projectID: String
        let root: URL
        let generation: UUID
        let timelineSHA256: String
        let captionIDs: [String]
        let sources: [Binding]
    }

    @MainActor private static func identity(_ editor: EditorViewModel, kind: Kind) throws -> Identity {
        guard let id = editor.projectId, let root = editor.workingRoot,
              let generation = editor.openWorkingCopyGeneration else {
            throw ToolError("Save the project before preparing caption changes.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let captions = editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text && $0.captionGroupId != nil }
        let targets = kind == .speechCuts ? editor.captionTargets(ids: []) : []
        let groups = Set(targets.compactMap(\.linkGroupId))
        let linked = editor.timeline.tracks.flatMap(\.clips).filter { $0.linkGroupId.map(groups.contains) == true }
        let refs = Set((targets + linked).filter { $0.mediaType != .text }.map(\.mediaRef))
        let sources = try refs.sorted().map { ref -> Binding in
            guard let url = editor.mediaResolver.resolveURL(for: ref) else {
                throw ToolError("A caption source is unavailable. Relink it before preparing changes.")
            }
            return .init(assetID: ref, url: url, resolvedURL: url.resolvingSymlinksInPath())
        }
        return .init(projectID: id, root: root, generation: generation,
            timelineSHA256: FileDigest.sha256(of: try encoder.encode(editor.timeline)),
            captionIDs: captions.map(\.id).sorted(), sources: sources)
    }

    @MainActor static func capture(_ editor: EditorViewModel, kind: Kind = .captions) async throws -> Self {
        let state = try identity(editor, kind: kind)
        let hashing = Task.detached(priority: .userInitiated) {
            var hashes: [URL: String] = [:]
            return try state.sources.map { source in
                let hash: String
                if let known = hashes[source.url] { hash = known }
                else { hash = try CaptionInputSnapshot.fingerprint(source.url); hashes[source.url] = hash }
                return Source(assetID: source.assetID, url: source.url, resolvedURL: source.resolvedURL, sha256: hash)
            }
        }
        let sources = try await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }
        try Task.checkCancellation()
        guard try identity(editor, kind: kind) == state else { throw changed() }
        return .init(kind: kind, projectID: state.projectID, workingRoot: state.root, generation: state.generation,
            timelineSHA256: state.timelineSHA256, captionIDs: state.captionIDs, sources: sources)
    }

    @MainActor func validateIdentity(_ editor: EditorViewModel) throws {
        try Task.checkCancellation()
        let expected = Identity(projectID: projectID, root: workingRoot, generation: generation,
            timelineSHA256: timelineSHA256, captionIDs: captionIDs,
            sources: sources.map { .init(assetID: $0.assetID, url: $0.url, resolvedURL: $0.resolvedURL) })
        guard try Self.identity(editor, kind: kind) == expected else { throw Self.changed() }
    }

    func validateFrozen(_ frozen: CaptionInputSnapshot) throws {
        for (id, source) in frozen.sources {
            guard let expected = sources.first(where: { $0.assetID == id }),
                  expected.url == source.original, expected.sha256 == source.sha256 else { throw Self.changed() }
        }
    }

    @MainActor func validate(_ editor: EditorViewModel) async throws {
        try validateIdentity(editor)
        guard try await Self.capture(editor, kind: kind) == self else { throw Self.changed() }
    }

    private static func changed() -> ToolError {
        ToolError("The project, timeline, or source changed. Discard this proposal and request a new one.")
    }

}

struct WordRemovalEdits: Codable, Equatable, Sendable {
    struct Range: Codable, Equatable, Sendable {
        let start: Int
        let end: Int
    }
    struct Context: Codable, Equatable, Sendable {
        let start: Int
        let end: Int
        let before: String
        let after: String
    }
    let fps: Int
    let trackID: String
    let ranges: [Range]
    let removedTexts: [String]
    let ignored: [Int]
    let aggressiveness: String
    let contexts: [Context]
    let captionEdits: CaptionSpeechEdits.Plan
    var before: String { contexts.map(\.before).joined(separator: " … ") }
    var after: String { contexts.map(\.after).joined(separator: " … ") }

    @MainActor func apply(_ editor: EditorViewModel) throws -> [String: Any] {
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ToolError("The speech track no longer exists.")
        }
        let outcome = editor.rippleDeleteRangesOnTrack(trackIndex: index,
            ranges: ranges.map { FrameRange(start: $0.start, end: $0.end) }, captionEdits: captionEdits)
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

struct WordRemovalPlan: Codable, Equatable, Sendable {
    let scope: CaptionRevisionScope
    let edits: WordRemovalEdits
    var ranges: [WordRemovalEdits.Range] { edits.ranges }
    var before: String { edits.before }
    var after: String { edits.after }

    @MainActor func apply(_ editor: EditorViewModel) async throws -> [String: Any] {
        try await scope.validate(editor)
        return try edits.apply(editor)
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

    @MainActor static func captions(_ changes: [Change], scope: CaptionRevisionScope, editor: EditorViewModel) async throws -> Self {
        try scope.validateIdentity(editor)
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

    @MainActor static func speech(_ removal: WordRemovalPlan, editor: EditorViewModel) async throws -> Self {
        try removal.scope.validateIdentity(editor)
        let single = removal.edits.contexts.count == 1
        return .init(scope: removal.scope, rows: [.init(id: "speech-cuts", before: single ? removal.before : "\(removal.ranges.count) speech cuts",
            after: single ? (removal.after.isEmpty ? "No speech remains in this selection" : removal.after) : "Apply all time ranges shown below",
            timeRange: single ? interval(removal.ranges[0].start, removal.ranges[0].end, fps: editor.timeline.fps) : "Speech and linked video")],
            wordRemoval: removal)
    }

    var speechContextRows: [Row] {
        guard let edits = wordRemoval?.edits else { return [] }
        return edits.contexts.enumerated().map { index, context in
            .init(id: "speech-context-\(index)", before: context.before, after: context.after,
                timeRange: Self.interval(context.start, context.end, fps: edits.fps))
        }
    }

    var captionImpactRows: [Row] {
        guard let edits = wordRemoval?.edits else { return [] }
        return edits.captionEdits.changes.map { change in
            .init(id: change.before.id, before: change.before.textContent ?? "", after: change.after?.textContent ?? "Caption removed",
                timeRange: Self.interval(change.before.startFrame, change.before.endFrame, fps: edits.fps) + " → "
                    + (change.after.map { Self.interval($0.startFrame, $0.endFrame, fps: edits.fps) } ?? "Removed"))
        }
    }

    @MainActor func apply(selected: Set<String>, editor: EditorViewModel, authorize: @MainActor () -> Bool = { true }) async throws -> Int {
        guard !selected.isEmpty, selected.isSubset(of: Set(rows.map(\.id))) else { throw ToolError("Select the changes to apply.") }
        try await scope.validate(editor)
        guard authorize() else { throw ToolError("The caption decision changed. Reopen the proposal before applying it.") }
        if let wordRemoval {
            _ = try wordRemoval.edits.apply(editor)
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

    func makeDialog() -> AgentDialog {
        .init(id: UUID().uuidString, title: wordRemoval == nil ? "Review caption changes" : "Review speech cuts",
            symbol: "captions.bubble", intro: wordRemoval == nil
                ? "Select the caption changes to apply. Timing and audio are preserved."
                : "Apply all shown speech cuts together. Linked video follows; affected captions change as shown below.",
            costHint: nil, confirmLabel: "Apply Selected", textField: nil,
            sections: [.init(id: "caption-revision", label: "Proposed changes", kind: .choices(options: rows.map {
                .init(id: $0.id, label: $0.timeRange + " · " + $0.before + " → " + $0.after, shortLabel: $0.timeRange)
            }, multiSelect: true))], purpose: .captionRevision, captionRevision: self)
    }

    private static func interval(_ start: Int, _ end: Int, fps: Int) -> String {
        String(format: "%.2f–%.2f s", Double(start) / Double(max(1, fps)), Double(end) / Double(max(1, fps)))
    }
}
