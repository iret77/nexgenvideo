import Foundation
import NexGenEngine

struct SequenceFindingNavigation: Sendable {
    struct Placement: Sendable {
        let clipID: String
        let shotID: String?
        let startFrame: Int
        let durationFrames: Int
    }

    let id = UUID()
    let startFrame: Int
    let endFrame: Int
    let clipIDs: Set<String>
    let notice: String?

    init(finding: SequenceReviewFindingV1, outputStart: Int, duration: Int, placements: [Placement]) throws {
        guard outputStart >= 0, finding.startFrame >= 0, finding.endFrame > finding.startFrame,
              finding.endFrame <= duration else { throw ToolError("The finding is outside the reviewed film.") }
        let start = outputStart.addingReportingOverflow(finding.startFrame)
        let end = outputStart.addingReportingOverflow(finding.endFrame)
        guard !start.overflow, !end.overflow else { throw ToolError("The finding's timeline range is invalid.") }
        let shots = Set(finding.shotIDs)
        var clips: Set<String> = []
        var matchedShots: Set<String> = []
        for placement in placements {
            let placementEnd = placement.startFrame.addingReportingOverflow(placement.durationFrames)
            guard placement.startFrame >= 0, placement.durationFrames > 0, !placementEnd.overflow else {
                throw ToolError("The reviewed clip range is invalid.")
            }
            guard placement.startFrame < end.partialValue, placementEnd.partialValue > start.partialValue,
                  shots.isEmpty || placement.shotID.map(shots.contains) == true else { continue }
            clips.insert(placement.clipID)
            if let shot = placement.shotID { matchedShots.insert(shot) }
        }
        let matches = shots.isSubset(of: matchedShots)
        notice = matches ? nil : "Opened the reviewed time range. Its shot references do not match this range, so no clip was selected."
        if !matches { clips = [] }
        startFrame = start.partialValue; endFrame = end.partialValue; clipIDs = clips
    }

    @MainActor
    func open(editor: EditorViewModel) {
        guard let home = editor.workingRoot else { return }
        editor.pause()
        editor.theaterActive = false
        editor.setWorkspaceFocus(.postproduction)
        editor.maximizedPanel = nil
        editor.inspectorPanelVisible = true
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        editor.isMarqueeSelecting = false
        editor.selectedGap = nil
        editor.selectedMediaAssetIds = []
        editor.selectedClipIds = clipIDs
        editor.setTimelineRange(startFrame: startFrame, endFrame: endFrame)
        editor.inspectedObject = editor.selectionInspectedObject
        editor.seekToFrame(startFrame)
        editor.focusedPanel = .timeline
        editor.sequenceFindingNavigation = (home, self)
        editor.sequenceFindingNotice = notice
    }
}
