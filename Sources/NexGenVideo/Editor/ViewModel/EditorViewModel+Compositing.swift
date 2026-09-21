import Foundation

extension EditorViewModel {
    func validateClipBlendModeTargets(_ clipIds: [String]) throws {
        guard !clipIds.isEmpty else { throw ToolError("Select at least one visual clip.") }
        for id in Set(clipIds) {
            guard let clip = clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType.isVisual else { throw ToolError("Blend modes require visual clips: \(id)") }
        }
    }

    @discardableResult
    func setClipBlendMode(_ mode: ClipBlendMode, clipIds: [String], grouped: Bool = true) throws -> Set<String> {
        try validateClipBlendModeTargets(clipIds)
        let changed = Set(clipIds).sorted().filter { id in
            guard let clip = clipFor(id: id) else { return false }
            return clip.blendMode != mode || clip.compositing?.supportedMode == nil && clip.compositing != nil
        }
        guard !changed.isEmpty else { return [] }
        if grouped { undoManager?.beginUndoGrouping() }
        commitClipProperties(clipIds: changed) { $0.blendMode = mode }
        if grouped {
            undoManager?.setActionName("Change Blend Mode")
            undoManager?.endUndoGrouping()
        }
        return Set(changed)
    }
}
