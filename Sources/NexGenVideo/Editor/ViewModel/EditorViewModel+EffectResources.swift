import Foundation

extension EditorViewModel {
    var unresolvedEffectResourceProblems: [ProjectEffectResources.Problem] {
        effectResourceProblems.filter { problem in
            clipFor(id: problem.clipID)?.effects?.contains {
                $0.id == problem.effectID && $0.params["path"]?.string == problem.path
            } == true
        }
    }

    func inspectEffectResourceProblem(_ problem: ProjectEffectResources.Problem) {
        guard let clip = clipFor(id: problem.clipID), unresolvedEffectResourceProblems.contains(problem) else { return }
        theaterActive = false
        setWorkspaceFocus(.postproduction)
        maximizedPanel = nil
        inspectorPanelVisible = true
        selectPreviewTab(id: PreviewTab.timeline.id)
        selectedClipIds = [clip.id]
        selectedMediaAssetIds.removeAll()
        inspectedObject = .clip(clip.id)
        seekToFrame(clip.startFrame)
        focusedPanel = .inspector
        requestedLUTClipID = clip.id
    }
}
