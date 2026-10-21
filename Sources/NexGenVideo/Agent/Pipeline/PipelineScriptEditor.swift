import Foundation
import NexGenEngine

@MainActor
enum PipelineScriptEditor {
    static func replaceScene(_ scene: ScriptV1.Scene, in expected: ScriptV1, editor: EditorViewModel, filmFlow: FilmFlowAdoption.PreparedScript? = nil) throws {
        guard expected.scenes.contains(where: { $0.id == scene.id }) else { throw GateBlocked("This Script scene changed. Reload it before editing.") }
        let scenes = expected.scenes.map { $0.id == scene.id ? scene : $0 }
        try apply(summary: expected.summary, scenes: scenes, expected: expected, undo: false, editor: editor, filmFlow: filmFlow)
    }

    private static func apply(summary: String, scenes: [ScriptV1.Scene], expected: ScriptV1,
                              undo: Bool, editor: EditorViewModel, filmFlow: FilmFlowAdoption.PreparedScript? = nil) throws {
        let native = try PipelineNativeEditAccess(editor: editor, label: "Edit Script")
        defer { native.end(editor: editor) }
        let home = native.home, root = native.root, key = native.key, generation = editor.openWorkingCopyGeneration
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: native.declaration, phase: "script")
        let current = try PlanningWriterIO.script(dataRoot: root)
        let matching = undo
            ? current.header.projectID == expected.header.projectID && current.header.inputs == expected.header.inputs
                && current.summary == expected.summary && current.scenes == expected.scenes
            : current == expected
        guard matching else { throw GateBlocked("The Script changed since this edit. Reload it before making further changes.") }
        guard summary != current.summary || scenes != current.scenes else {
            if filmFlow != nil { throw GateBlocked("The selected FilmFlow action already matches this Script event. No adoption was applied.") }
            return
        }
        let written = try PipelineScriptWriter.write(summary: summary, scenes: scenes, origin: .userRevision,
            access: access, filmFlow: filmFlow, beforePublish: {
                try native.requireCurrent(editor: editor)
                guard editor.openWorkingCopyGeneration == generation else { throw GateBlocked("Open the original project before editing Script.") }
                try ProjectWorkingCopy.markDirty(key: key)
            })
        let manager = editor.undoManager
        let opensGroup = manager?.groupingLevel == 0
        if opensGroup { manager?.beginUndoGrouping() }
        manager?.registerUndo(withTarget: editor) { target in
            guard target.workingRoot == home, target.openWorkingCopyKey == key,
                  target.openWorkingCopyGeneration == generation else { return }
            do { try apply(summary: current.summary, scenes: current.scenes, expected: written, undo: true, editor: target) }
            catch { target.mediaPanelToast = MediaPanelToast(message: error.localizedDescription) }
        }
        manager?.setActionName("Edit Script")
        if opensGroup { manager?.endUndoGrouping() }
        editor.onPipelineChanged?()
        Task { await editor.refreshEngineState() }
    }
}
