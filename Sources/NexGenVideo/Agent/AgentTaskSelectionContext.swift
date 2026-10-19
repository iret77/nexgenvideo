import Foundation

struct AgentTaskSelectionContext: Codable, Sendable, Equatable {
    struct FrameRange: Codable, Sendable, Equatable {
        let start: Int
        let end: Int
    }
    struct ClipBinding: Codable, Sendable, Equatable {
        let clipID: String
        let trackID: String
        let mediaRef: String
        let timelineRange: FrameRange
        let trimStartFrame: Int
        let trimEndFrame: Int
        let speed: Double?
        let generationRoutingShotID: String?
    }
    struct SourceBinding: Codable, Sendable, Equatable {
        let assetID: String
        let name: String
        let range: FrameRange?
        let inSeconds: Double?
        let outSeconds: Double?
        let playheadFrame: Int
        let targetTrackID: String?
    }

    let workspace: String
    let format: String?
    let label: String?
    let target: String?
    let timelineFrame: Int
    let editingFPS: Int
    let timelineRange: FrameRange?
    let planningShotID: String?
    let planningRevision: Int?
    let planningFingerprint: String?
    let clips: [ClipBinding]
    let source: SourceBinding?

    var hint: String {
        hint(frozenTask: true)
    }

    func hint(frozenTask: Bool) -> String {
        let plugin = format.map { "Active format plugin for this project: \($0)." }
            ?? "No format plugin is active — this project uses the generic production workflow."
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return plugin + " The origin selection could not be encoded; do not infer a target." }
        return plugin + " Captured selection (editing-grid frames, end exclusive; not a native-media clock): "
            + String(decoding: data, as: UTF8.self)
            + (frozenTask ? " Later workspace selections and get_timeline playheads do not replace this task's target, range or frame."
                : " This is the visible selection for this message; ask for a target if none is recorded.")
    }

    @MainActor
    static func capture(editor: EditorViewModel) -> Self {
        let editing = editor.workspaceFocus == .edit || editor.workspaceFocus == .postproduction
        let sourceFocus = editing || editor.workspaceFocus == .media
        var range: FrameRange?
        var source: SourceBinding?
        var label: String?
        var target: String?
        var ids = Set<String>()
        var planningShotID: String?
        var planningRevision: Int?
        var planningFingerprint: String?
        if editor.workspaceFocus == .production, editor.usesProductionPlanningV2,
           editor.cockpitTab == .shotlist, let selected = editor.productionPlanSelection,
           selected.home == editor.workingRoot, let shot = selected.shot {
            planningShotID = shot.id; planningRevision = selected.snapshot.projection.header.revision
            label = "Shot \(selected.snapshot.number(shot.id) ?? 0)"
            target = "production shot ID " + shot.id
        } else if editor.workspaceFocus == .production, editor.usesProductionPlanningV2,
                  editor.cockpitTab == .storyboard, let selected = editor.storyboardPlanningSelection,
                  selected.home == editor.workingRoot {
            planningShotID = selected.shot.id; planningFingerprint = selected.fingerprint
            label = "Storyboard Shot \(selected.number)"
            target = "storyboard shot ID " + selected.shot.id
        } else if editing, editor.activePreviewTab == .timeline, let selected = editor.validSelectedTimelineRange {
            range = FrameRange(start: selected.startFrame, end: selected.endFrame)
            label = "Timeline range " + timeLabel(selected.startFrame, selected.endFrame, fps: editor.timeline.fps)
            target = "timeline range [\(selected.startFrame), \(selected.endFrame)) in the \(editor.timeline.fps) fps editing grid"
            for track in editor.timeline.tracks {
                for clip in track.clips {
                    let end = clip.startFrame.addingReportingOverflow(clip.durationFrames)
                    if !end.overflow, clip.startFrame < selected.endFrame, end.partialValue > selected.startFrame { ids.insert(clip.id) }
                }
            }
        } else if sourceFocus, case .mediaAsset(let id, _, _) = editor.activePreviewTab,
                  let asset = editor.mediaAssets.first(where: { $0.id == id }) {
            let selected = editor.sourceFrameRange(for: asset)
            let marks = editor.sourcePreviewStates[id] ?? SourcePreviewState()
            source = SourceBinding(assetID: id, name: asset.libraryDisplayName,
                range: selected.map { FrameRange(start: $0.lowerBound, end: $0.upperBound) },
                inSeconds: marks.inSeconds.flatMap { $0.isFinite ? $0 : nil },
                outSeconds: marks.outSeconds.flatMap { $0.isFinite ? $0 : nil },
                playheadFrame: editor.sourcePlayheadFrame, targetTrackID: marks.targetTrackID)
            label = "Source “" + asset.libraryDisplayName + "”"
            target = "media asset ID " + id
            if let selected {
                label = "Source “" + asset.libraryDisplayName + "” · " + timeLabel(selected.lowerBound, selected.upperBound, fps: editor.timeline.fps)
                target = "media asset ID " + id + " source range [\(selected.lowerBound), \(selected.upperBound)) in the \(editor.timeline.fps) fps editing grid"
            }
        } else if editing, editor.activePreviewTab == .timeline, !editor.selectedClipIds.isEmpty {
            ids = editor.selectedClipIds
            label = editor.selectedClipIds.count > 1 ? "\(editor.selectedClipIds.count) timeline clips" : editor.selectionContextHint
            target = "timeline clip IDs " + ids.sorted().joined(separator: ", ")
        } else if let object = editor.inspectedObject, visibleObject(object, editor: editor) {
            label = editor.selectionContextHint
            target = object.taskTarget
            if case .clip(let id) = object { ids.insert(id) }
        }
        let clips = editor.timeline.tracks.flatMap { track in
            track.clips.compactMap { clip -> ClipBinding? in
                guard ids.contains(clip.id) else { return nil }
                let end = clip.startFrame.addingReportingOverflow(clip.durationFrames)
                guard !end.overflow else { return nil }
                return ClipBinding(clipID: clip.id, trackID: track.id, mediaRef: clip.mediaRef,
                    timelineRange: FrameRange(start: clip.startFrame, end: end.partialValue),
                    trimStartFrame: clip.trimStartFrame, trimEndFrame: clip.trimEndFrame,
                    speed: clip.speed.isFinite ? clip.speed : nil,
                    generationRoutingShotID: editor.mediaAssets.first(where: { $0.id == clip.mediaRef })?.generationInput?.productionRouting?.shotID)
            }
        }
        return Self(workspace: editor.workspaceFocus.rawValue, format: editor.activePluginName, label: label, target: target,
            timelineFrame: editor.currentFrame, editingFPS: editor.timeline.fps, timelineRange: range,
            planningShotID: planningShotID, planningRevision: planningRevision, planningFingerprint: planningFingerprint,
            clips: clips, source: source)
    }

    @MainActor
    private static func visibleObject(_ object: InspectedObject, editor: EditorViewModel) -> Bool {
        guard editor.workspaceFocus == .production else { return true }
        guard editor.cockpitTab != .storyboard, !(editor.cockpitTab == .shotlist && editor.usesProductionPlanningV2) else { return false }
        switch object {
        case .entity, .look: return editor.cockpitTab == .bible
        case .shot, .shotUse: return editor.cockpitTab == .shotlist || editor.cockpitTab == .review
        case .mediaAsset: return true
        case .clip: return false
        }
    }

    @MainActor
    private static func timeLabel(_ start: Int, _ end: Int, fps: Int) -> String {
        guard fps > 0 else { return "\(start)–\(end) editing frames" }
        return formatTimecode(frame: start, fps: fps) + "–" + formatTimecode(frame: end, fps: fps)
    }
}
